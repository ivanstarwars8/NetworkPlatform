package engine

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"runtime/pprof"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/metacubex/mipstack"
)

// ---- ports and servers on 127.0.0.1 ----

func freePort(t testing.TB) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func waitTCP(t testing.TB, port int) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 200*time.Millisecond)
		if err == nil {
			c.Close()
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("port %d did not open", port)
}

// echoServer starts a TCP and a UDP echo on one port number of host (an IP literal).
func echoServer(t testing.TB, host string) int {
	t.Helper()
	for i := 0; i < 20; i++ {
		l, err := net.Listen("tcp", net.JoinHostPort(host, "0"))
		if err != nil {
			t.Fatal(err)
		}
		port := l.Addr().(*net.TCPAddr).Port
		pc, err := net.ListenPacket("udp", net.JoinHostPort(host, strconv.Itoa(port)))
		if err != nil {
			l.Close()
			continue
		}
		t.Cleanup(func() { l.Close(); pc.Close() })
		go func() {
			for {
				c, err := l.Accept()
				if err != nil {
					return
				}
				go func() { defer c.Close(); _, _ = io.Copy(c, c) }()
			}
		}()
		go func() {
			buf := make([]byte, 65536)
			for {
				n, from, err := pc.ReadFrom(buf)
				if err != nil {
					return
				}
				_, _ = pc.WriteTo(buf[:n], from)
			}
		}()
		return port
	}
	t.Fatal("no port free for both TCP and UDP")
	return 0
}

// echoTCP writes n random bytes through c and checks they come back unchanged.
func echoTCP(t testing.TB, c net.Conn, n int) {
	t.Helper()
	_ = c.SetDeadline(time.Now().Add(60 * time.Second))
	data := make([]byte, n)
	_, _ = rand.Read(data)
	errc := make(chan error, 1)
	go func() { _, err := c.Write(data); errc <- err }()
	got := make([]byte, n)
	if _, err := io.ReadFull(c, got); err != nil {
		t.Fatalf("echo read after %d bytes: %v", n, err)
	}
	if err := <-errc; err != nil {
		t.Fatalf("echo write: %v", err)
	}
	if !bytes.Equal(got, data) {
		t.Fatal("echo data differs")
	}
}

// echoUDP sends datagrams of the given sizes over a connected UDP socket and checks the echoes, retrying a
// lost one twice as any UDP application would.
func echoUDP(t testing.TB, c net.Conn, sizes ...int) {
	t.Helper()
	got := make([]byte, 65536)
	for _, size := range sizes {
		payload := make([]byte, size)
		_, _ = rand.Read(payload)
		ok := false
		for attempt := 0; attempt < 3 && !ok; attempt++ {
			if _, err := c.Write(payload); err != nil {
				t.Fatalf("udp write %d: %v", size, err)
			}
			_ = c.SetReadDeadline(time.Now().Add(3 * time.Second))
			n, err := c.Read(got)
			if err != nil {
				continue
			}
			if !bytes.Equal(got[:n], payload) {
				t.Fatalf("udp echo of %d bytes differs (got %d)", size, n)
			}
			ok = true
		}
		if !ok {
			t.Fatalf("udp echo of %d bytes: no reply", size)
		}
	}
}

// hostAddr returns a non-loopback IPv4 address of this machine: the DIRECT outbound must reach the echo
// server, and the packet stack reflects packets to non-global destinations such as 127.0.0.1 instead of
// handing them to the core.
func hostAddr(t testing.TB) string {
	t.Helper()
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		if p, ok := a.(*net.IPNet); ok {
			if ip := p.IP.To4(); ip != nil && !ip.IsLoopback() && ip.IsGlobalUnicast() {
				return ip.String()
			}
		}
	}
	t.Skip("no non-loopback IPv4 address on this host")
	return ""
}

// ---- SOCKS5 client (RFC 1928, no auth) ----

func socksConnect(t testing.TB, socksPort int, host string, port int) net.Conn {
	t.Helper()
	c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", socksPort), 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	_ = c.SetDeadline(time.Now().Add(15 * time.Second))
	if _, err := c.Write([]byte{5, 1, 0}); err != nil {
		t.Fatal(err)
	}
	r := bufio.NewReader(c)
	hello := make([]byte, 2)
	if _, err := io.ReadFull(r, hello); err != nil || hello[1] != 0 {
		t.Fatalf("socks hello: %v %v", hello, err)
	}
	ip := net.ParseIP(host).To4()
	req := append([]byte{5, 1, 0, 1}, ip...)
	req = binary.BigEndian.AppendUint16(req, uint16(port))
	if _, err := c.Write(req); err != nil {
		t.Fatal(err)
	}
	head := make([]byte, 4)
	if _, err := io.ReadFull(r, head); err != nil || head[1] != 0 {
		t.Fatalf("socks connect reply: %v %v", head, err)
	}
	var skip int
	switch head[3] {
	case 1:
		skip = 4 + 2
	case 4:
		skip = 16 + 2
	case 3:
		l, _ := r.ReadByte()
		skip = int(l) + 2
	}
	if _, err := io.ReadFull(r, make([]byte, skip)); err != nil {
		t.Fatal(err)
	}
	_ = c.SetDeadline(time.Time{})
	if r.Buffered() != 0 {
		t.Fatal("unexpected data after socks reply")
	}
	return c
}

// ---- stock Xray server ----

// stockXray is the path of an unmodified xray binary (NP_STOCK_XRAY) that plays the server in the
// interoperability tests; the tests are skipped without it.
var stockXray = os.Getenv("NP_STOCK_XRAY")

func startXray(t testing.TB, config string, waitPort int) {
	t.Helper()
	if stockXray == "" {
		t.Skip("NP_STOCK_XRAY not set")
	}
	path := filepath.Join(t.TempDir(), "server.json")
	if err := os.WriteFile(path, []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	var mu sync.Mutex
	cmd := exec.Command(stockXray, "run", "-c", path)
	// Only the tail is kept: the server logs at debug level, and an unbounded buffer grew by ~12 MB in a 3-minute
	// TestSoakRSS (17 % of that process's heap; Mihomo section of memory-budget.md).
	const keep = 256 << 10
	w := writerFunc(func(p []byte) (int, error) {
		mu.Lock()
		defer mu.Unlock()
		out.Write(p)
		if out.Len() > 2*keep {
			tail := append([]byte(nil), out.Bytes()[out.Len()-keep:]...)
			out.Reset()
			out.Write(tail)
		}
		return len(p), nil
	})
	cmd.Stdout, cmd.Stderr = w, w
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		if t.Failed() {
			mu.Lock()
			t.Logf("stock xray output:\n%s", out.String())
			mu.Unlock()
		}
	})
	waitTCP(t, waitPort)
}

type writerFunc func([]byte) (int, error)

func (f writerFunc) Write(p []byte) (int, error) { return f(p) }

func mustJSON(t testing.TB, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

type obj = map[string]any
type arr = []any

func newX25519(t testing.TB) (private, public string) {
	t.Helper()
	k, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return base64.RawURLEncoding.EncodeToString(k.Bytes()), base64.RawURLEncoding.EncodeToString(k.PublicKey().Bytes())
}

// startTLSTarget is the site a REALITY server borrows its handshake from: a local TLS 1.3 server.
func startTLSTarget(t testing.TB, name string) int {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: name}, DNSNames: []string{name},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(24 * time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	l, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{
		Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}},
		MinVersion:   tls.VersionTLS13, NextProtos: []string{"h2", "http/1.1"},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				_ = c.SetDeadline(time.Now().Add(10 * time.Second))
				_, _ = io.Copy(io.Discard, c)
			}()
		}
	}()
	return l.Addr().(*net.TCPAddr).Port
}

// ---- engine helpers ----

func mustStart(t testing.TB, e *Engine, config string, opts Options) {
	t.Helper()
	if opts.HomeDir == "" {
		opts.HomeDir = t.TempDir()
	}
	if err := e.Start(context.Background(), []byte(config), opts); err != nil {
		t.Fatalf("start: %v\nlogs:\n%s", err, drainLogs(e))
	}
	t.Cleanup(func() {
		if t.Failed() {
			t.Logf("engine log:\n%s", drainLogs(e))
		}
		if err := e.Stop(10 * time.Second); err != nil {
			t.Errorf("stop: %v", err)
		}
	})
}

func drainLogs(e *Engine) string {
	var b strings.Builder
	for _, r := range e.ReadLogs(nil, 4096, 0) {
		fmt.Fprintf(&b, "[%s] %s\n", r.Level, r.Message)
	}
	return b.String()
}

func settleGoroutines() int {
	n := runtime.NumGoroutine()
	for i := 0; i < 50; i++ {
		runtime.GC()
		time.Sleep(20 * time.Millisecond)
		m := runtime.NumGoroutine()
		if m == n && i > 5 {
			break
		}
		n = m
	}
	return n
}

// rssKiB reads VmRSS of this process (Linux).
func rssKiB() int64 {
	b, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return -1
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, "VmRSS:") {
			f := strings.Fields(line)
			v, _ := strconv.ParseInt(f[1], 10, 64)
			return v
		}
	}
	return -1
}

// rssSplitKiB reads RssAnon and RssFile of this process (Linux).
func rssSplitKiB() (anon, file int64) {
	b, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return -1, -1
	}
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		switch f[0] {
		case "RssAnon:":
			anon, _ = strconv.ParseInt(f[1], 10, 64)
		case "RssFile:":
			file, _ = strconv.ParseInt(f[1], 10, 64)
		}
	}
	return anon, file
}

// writeProfiles writes <dir>/<name>-heap.pprof and <name>-goroutine.txt.
func writeProfiles(t testing.TB, dir, name string) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Error(err)
		return
	}
	for _, p := range []struct {
		profile, file string
		debug         int
	}{{"heap", name + "-heap.pprof", 0}, {"goroutine", name + "-goroutine.txt", 1}} {
		f, err := os.Create(filepath.Join(dir, p.file))
		if err != nil {
			t.Error(err)
			return
		}
		if err := pprof.Lookup(p.profile).WriteTo(f, p.debug); err != nil {
			t.Error(err)
		}
		f.Close()
	}
}

// ---- the operating system side of the packet interface ----

// osPeer plays the operating system: an independent mipstack instance with ordinary sockets, wired to the
// engine only through TunWrite/TunRead batches. Everything between the two stacks is real IP packets.
type osPeer struct {
	t      testing.TB
	engine *Engine
	stack  *mipstack.Stack
	stop   chan struct{}
	wg     sync.WaitGroup

	mu                                       sync.Mutex
	writeBatches, writePackets, maxBatchSent int
	readPackets                              int
}

var peerV4, peerV6 = netip.MustParsePrefix("10.8.0.2/32"), netip.MustParsePrefix("fd00:8::2/128")

func newOSPeer(t testing.TB, e *Engine, mtu int) *osPeer {
	t.Helper()
	p := newOSPeerNoCleanup(t, e, mtu)
	t.Cleanup(p.close)
	return p
}

func newOSPeerNoCleanup(t testing.TB, e *Engine, mtu int) *osPeer {
	t.Helper()
	s, err := mipstack.New(mipstack.Config{LocalAddresses: []netip.Prefix{peerV4, peerV6}, MTU: uint32(mtu)})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Start(); err != nil {
		t.Fatal(err)
	}
	p := &osPeer{t: t, engine: e, stack: s, stop: make(chan struct{})}
	p.wg.Add(2)
	go p.pumpOut(mtu)
	go p.pumpIn()
	return p
}

func (p *osPeer) close() {
	select {
	case <-p.stop:
		return
	default:
	}
	close(p.stop)
	_ = p.stack.Close()
	p.wg.Wait()
}

// pumpOut: peer stack -> TunWrite, in the batches the stack hands out (up to 64 packets).
func (p *osPeer) pumpOut(mtu int) {
	defer p.wg.Done()
	n := p.stack.BatchSize()
	bufs := make([][]byte, n)
	for i := range bufs {
		bufs[i] = make([]byte, mtu)
	}
	sizes := make([]int, n)
	var batch []byte
	for {
		count, err := p.stack.Read(bufs, sizes, 0)
		batch = batch[:0]
		for i := 0; i < count; i++ {
			batch = binary.LittleEndian.AppendUint16(batch, uint16(sizes[i]))
			batch = append(batch, bufs[i][:sizes[i]]...)
		}
		if count > 0 {
			got, werr := p.engine.TunWrite(batch)
			if werr != nil && CodeOf(werr) != CodeNotRunning && CodeOf(werr) != CodeClosed {
				p.t.Errorf("TunWrite: %v", werr)
			}
			p.mu.Lock()
			p.writeBatches++
			p.writePackets += got
			p.maxBatchSent = max(p.maxBatchSent, count)
			p.mu.Unlock()
		}
		if err != nil {
			return
		}
	}
}

// pumpIn: TunRead -> peer stack.
func (p *osPeer) pumpIn() {
	defer p.wg.Done()
	buf := make([]byte, 256<<10)
	var pkts [][]byte
	for {
		select {
		case <-p.stop:
			return
		default:
		}
		n, err := p.engine.TunRead(buf, 50*time.Millisecond)
		if err != nil {
			if c := CodeOf(err); c == CodeClosed || c == CodeNotRunning {
				time.Sleep(10 * time.Millisecond)
				continue
			}
			p.t.Errorf("TunRead: %v", err)
			return
		}
		pkts = pkts[:0]
		for b := buf[:n]; len(b) > 0; {
			size := int(binary.LittleEndian.Uint16(b))
			pkts = append(pkts, b[frameHeaderSize:frameHeaderSize+size])
			b = b[frameHeaderSize+size:]
		}
		if len(pkts) > 0 {
			_, _ = p.stack.Write(pkts, 0)
			p.mu.Lock()
			p.readPackets += len(pkts)
			p.mu.Unlock()
		}
	}
}

func (p *osPeer) dialTCP(addr string) net.Conn {
	p.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	c, err := p.stack.DialTCP(ctx, "tcp", netip.AddrPort{}, netip.MustParseAddrPort(addr))
	if err != nil {
		p.t.Fatalf("dial %s through the packet interface: %v", addr, err)
	}
	return c
}

func (p *osPeer) dialUDP(addr string) net.Conn {
	p.t.Helper()
	c, err := p.stack.DialUDP(context.Background(), "udp", netip.AddrPort{}, netip.MustParseAddrPort(addr))
	if err != nil {
		p.t.Fatalf("udp socket to %s: %v", addr, err)
	}
	return c
}

func isClosed(err error) bool {
	return errors.Is(err, net.ErrClosed) || errors.Is(err, io.EOF)
}

var zeroAddrPort netip.AddrPort

func mustAddrPort(s string) netip.AddrPort { return netip.MustParseAddrPort(s) }

func readFull(c net.Conn, b []byte) (int, error) { return io.ReadFull(c, b) }
