package engine

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/xtls/xray-core/core"
)

// ---- generic helpers ----

func freePort(t testing.TB) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func freeUDPPort(t testing.TB) int {
	t.Helper()
	c, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	return c.LocalAddr().(*net.UDPAddr).Port
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
		time.Sleep(30 * time.Millisecond)
	}
	t.Fatalf("port %d did not open", port)
}

func mustStart(t testing.TB, e *Engine, config string, opts Options) {
	t.Helper()
	if err := e.Start(context.Background(), []byte(config), opts); err != nil {
		t.Fatalf("start: %v", err)
	}
	t.Cleanup(func() {
		if err := e.Stop(10 * time.Second); err != nil {
			t.Errorf("stop: %v", err)
		}
		if t.Failed() {
			for _, r := range e.ReadLogs(nil, 200, 0) {
				t.Logf("core log #%d [%s/%s] %s", r.Seq, r.Kind, r.Level, r.Message)
			}
		}
	})
}

// settleGoroutines waits for the goroutine count to stop falling and returns it.
func settleGoroutines() int {
	last := runtime.NumGoroutine()
	for i := 0; i < 40; i++ {
		time.Sleep(25 * time.Millisecond)
		n := runtime.NumGoroutine()
		if n >= last && i > 4 {
			return n
		}
		last = n
	}
	return last
}

func goroutineDump() string {
	buf := make([]byte, 1<<20)
	return string(buf[:runtime.Stack(buf, true)])
}

// ---- echo servers ----

// startTCPEcho echoes every connection and returns the port.
func startTCPEcho(t testing.TB, network, addr string) int {
	t.Helper()
	l, err := net.Listen(network, addr)
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
				_, _ = io.Copy(c, c)
			}()
		}
	}()
	return l.Addr().(*net.TCPAddr).Port
}

// startTCPSource writes total bytes to every connection, then closes it.
func startTCPSource(t testing.TB, total int) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
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
				chunk := make([]byte, 64<<10)
				for left := total; left > 0; {
					n := min(left, len(chunk))
					if _, err := c.Write(chunk[:n]); err != nil {
						return
					}
					left -= n
				}
			}()
		}
	}()
	return l.Addr().(*net.TCPAddr).Port
}

func startUDPEcho(t testing.TB) int {
	t.Helper()
	c, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	go func() {
		buf := make([]byte, 65536)
		for {
			n, from, err := c.ReadFrom(buf)
			if err != nil {
				return
			}
			_, _ = c.WriteTo(buf[:n], from)
		}
	}()
	return c.LocalAddr().(*net.UDPAddr).Port
}

// ---- minimal SOCKS5 client (RFC 1928), enough for CONNECT and UDP ASSOCIATE to IPv4 targets ----

func socksHandshake(c net.Conn) error {
	if _, err := c.Write([]byte{5, 1, 0}); err != nil {
		return err
	}
	var r [2]byte
	if _, err := io.ReadFull(c, r[:]); err != nil {
		return err
	}
	if r != [2]byte{5, 0} {
		return fmt.Errorf("socks method reply %v", r)
	}
	return nil
}

func socksRequest(c net.Conn, cmd byte, ip net.IP, port int) (net.IP, int, error) {
	req := append([]byte{5, cmd, 0, 1}, ip.To4()...)
	req = binary.BigEndian.AppendUint16(req, uint16(port))
	if _, err := c.Write(req); err != nil {
		return nil, 0, err
	}
	var h [4]byte
	if _, err := io.ReadFull(c, h[:]); err != nil {
		return nil, 0, err
	}
	if h[1] != 0 {
		return nil, 0, fmt.Errorf("socks reply code %d", h[1])
	}
	size := 4
	if h[3] == 4 {
		size = 16
	} else if h[3] != 1 {
		return nil, 0, fmt.Errorf("socks reply atyp %d", h[3])
	}
	rest := make([]byte, size+2)
	if _, err := io.ReadFull(c, rest); err != nil {
		return nil, 0, err
	}
	return net.IP(rest[:size]), int(binary.BigEndian.Uint16(rest[size:])), nil
}

func socksConnect(t testing.TB, socksPort int, ip string, port int) net.Conn {
	t.Helper()
	c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", socksPort), 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	_ = c.SetDeadline(time.Now().Add(30 * time.Second))
	if err := socksHandshake(c); err != nil {
		t.Fatal(err)
	}
	if _, _, err := socksRequest(c, 1, net.ParseIP(ip), port); err != nil {
		t.Fatal(err)
	}
	return c
}

// socksUDP is a UDP association; the control connection must stay open for its lifetime.
type socksUDP struct {
	control net.Conn
	conn    net.PacketConn
	relay   net.Addr
}

func socksAssociate(t testing.TB, socksPort int) *socksUDP {
	t.Helper()
	control, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", socksPort), 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if err := socksHandshake(control); err != nil {
		t.Fatal(err)
	}
	_, port, err := socksRequest(control, 3, net.IPv4zero, 0)
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	u := &socksUDP{control: control, conn: conn, relay: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: port}}
	t.Cleanup(u.close)
	return u
}

func (u *socksUDP) close() { u.control.Close(); u.conn.Close() }

func (u *socksUDP) send(ip string, port int, payload []byte) error {
	p := append([]byte{0, 0, 0, 1}, net.ParseIP(ip).To4()...)
	p = binary.BigEndian.AppendUint16(p, uint16(port))
	_, err := u.conn.WriteTo(append(p, payload...), u.relay)
	return err
}

func (u *socksUDP) recv(timeout time.Duration) ([]byte, error) {
	buf := make([]byte, 65536)
	_ = u.conn.SetReadDeadline(time.Now().Add(timeout))
	n, _, err := u.conn.ReadFrom(buf)
	if err != nil {
		return nil, err
	}
	if n < 10 || buf[3] != 1 {
		return nil, fmt.Errorf("unexpected socks udp header % x", buf[:min(n, 10)])
	}
	return buf[10:n], nil
}

// ---- servers ----

// stockXray is the path of an xray binary built from the pinned core (NP_STOCK_XRAY). With it the server
// side of every integration test is a separate, unmodified process; without it the server is a core instance
// in the test process.
var stockXray = os.Getenv("NP_STOCK_XRAY")

func startServer(t testing.TB, config string, waitPort int) {
	t.Helper()
	if stockXray != "" {
		dir := t.TempDir()
		path := filepath.Join(dir, "server.json")
		if err := os.WriteFile(path, []byte(config), 0o600); err != nil {
			t.Fatal(err)
		}
		var out bytes.Buffer
		cmd := exec.Command(stockXray, "run", "-c", path)
		cmd.Stdout, cmd.Stderr = &out, &out
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			_ = cmd.Process.Kill()
			_ = cmd.Wait() // also waits for the goroutine that copies the output
			if t.Failed() {
				t.Logf("stock xray output:\n%s", out.String())
			}
		})
	} else {
		instance, err := core.StartInstance("json", []byte(config))
		if err != nil {
			t.Fatalf("in-process server: %v", err)
		}
		t.Cleanup(func() { _ = instance.Close() })
	}
	if waitPort != 0 {
		waitTCP(t, waitPort)
	}
}

// ---- key material ----

type testCert struct {
	certPEM, keyPEM []string // lines, as the core's inline "certificate"/"key" arrays expect
	sha256Hex       string   // of the DER certificate
	tls             tls.Certificate
}

func newTestCert(t testing.TB, name string) *testCert {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: name},
		DNSNames:     []string{name},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
	pair, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(der)
	return &testCert{
		certPEM:   strings.Split(strings.TrimSpace(string(certPEM)), "\n"),
		keyPEM:    strings.Split(strings.TrimSpace(string(keyPEM)), "\n"),
		sha256Hex: hex.EncodeToString(sum[:]),
		tls:       pair,
	}
}

func newX25519(t testing.TB) (private, public string) {
	t.Helper()
	k, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return base64.RawURLEncoding.EncodeToString(k.Bytes()), base64.RawURLEncoding.EncodeToString(k.PublicKey().Bytes())
}

func randomBase64(t testing.TB, n int) string {
	t.Helper()
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(b)
}

// startTLSTarget is the "real site" a REALITY server borrows its handshake from: a local TLS 1.3 server.
func startTLSTarget(t testing.TB, name string) int {
	t.Helper()
	cert := newTestCert(t, name)
	l, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{
		Certificates: []tls.Certificate{cert.tls},
		MinVersion:   tls.VersionTLS13,
		NextProtos:   []string{"h2", "http/1.1"},
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

// ---- counting relay ----

// wireRelay forwards TCP and UDP between the client engine and the server and counts what actually crossed
// the loopback "wire" in each direction, independently of the core's own counters.
type wireRelay struct {
	port     int
	up, down atomic.Int64 // client->server, server->client (TCP stream bytes plus UDP datagram payloads)
}

func startWireRelay(t testing.TB, serverPort int) *wireRelay {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	r := &wireRelay{port: l.Addr().(*net.TCPAddr).Port}
	pc, err := net.ListenPacket("udp", fmt.Sprintf("127.0.0.1:%d", r.port))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close(); pc.Close() })
	server := fmt.Sprintf("127.0.0.1:%d", serverPort)
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				s, err := net.Dial("tcp", server)
				if err != nil {
					c.Close()
					return
				}
				pipe := func(dst, src net.Conn, n *atomic.Int64) {
					buf := make([]byte, 32<<10)
					for {
						k, err := src.Read(buf)
						if k > 0 {
							n.Add(int64(k))
							if _, werr := dst.Write(buf[:k]); werr != nil {
								break
							}
						}
						if err != nil {
							break
						}
					}
					if tc, ok := dst.(*net.TCPConn); ok {
						_ = tc.CloseWrite()
					}
				}
				done := make(chan struct{})
				go func() { pipe(s, c, &r.up); close(done) }()
				pipe(c, s, &r.down)
				<-done
				c.Close()
				s.Close()
			}()
		}
	}()
	go func() {
		serverAddr, _ := net.ResolveUDPAddr("udp", server)
		var client net.Addr
		buf := make([]byte, 65536)
		for {
			n, from, err := pc.ReadFrom(buf)
			if err != nil {
				return
			}
			if from.String() == serverAddr.String() {
				if client != nil {
					r.down.Add(int64(n))
					_, _ = pc.WriteTo(buf[:n], client)
				}
				continue
			}
			client = from
			r.up.Add(int64(n))
			_, _ = pc.WriteTo(buf[:n], serverAddr)
		}
	}()
	return r
}

func getenv(k string) string { return os.Getenv(k) }

func jsonUnmarshal(s string, v any) error { return json.Unmarshal([]byte(s), v) }
