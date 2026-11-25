package engine

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/xtls/xray-core/proxy/tun"
	"golang.org/x/net/dns/dnsmessage"
)

// flowPeer plays the operating system on the other side of the packet interface: a second instance of the
// core's userspace TCP/IP stack that opens connections, wired to the engine only through TunWrite/TunRead
// batches. Everything between the two stacks is real IP packets.
type flowPeer struct {
	t      testing.TB
	engine *Engine
	stack  tun.Stack

	mu      sync.Mutex
	pending []byte
	kick    chan struct{}
	stop    chan struct{}
	// deaf makes the peer stop reading the packets of the engine, like a host whose write side stalled
	deaf atomic.Bool
	wg   sync.WaitGroup

	// observations
	obs                                       sync.Mutex
	writeBatches, writePackets, maxWriteBatch int
	readBatches, readPackets, maxReadBatch    int
}

var peerV4, peerV6 = netip.MustParseAddr("10.8.0.2"), netip.MustParseAddr("fd00:8::2")

func newFlowPeer(t testing.TB, e *Engine, mtu uint32) *flowPeer {
	t.Helper()
	p := newFlowPeerNoCleanup(t, e, mtu)
	t.Cleanup(p.close)
	return p
}

// newFlowPeerNoCleanup leaves closing to the caller, so that a long-running test does not keep every peer
// alive through t.Cleanup.
func newFlowPeerNoCleanup(t testing.TB, e *Engine, mtu uint32) *flowPeer {
	t.Helper()
	p := &flowPeer{t: t, engine: e, kick: make(chan struct{}, 1), stop: make(chan struct{})}
	s, err := tun.NewStack(context.Background(), tun.StackOptions{Tun: p, MTU: mtu, Addresses: []netip.Addr{peerV4, peerV6}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	p.stack = s
	p.wg.Add(2)
	go p.pumpOut()
	go p.pumpIn()
	return p
}

func (p *flowPeer) close() {
	select {
	case <-p.stop:
		return
	default:
	}
	close(p.stop)
	p.wg.Wait()
	_ = p.stack.Close()
}

func (p *flowPeer) Start() error                      { return nil }
func (p *flowPeer) Close() error                      { return nil }
func (p *flowPeer) Name() (string, error)             { return "peer", nil }
func (p *flowPeer) Index() (int, error)               { return 0, nil }
func (p *flowPeer) ReadPacket([]byte) ([]byte, error) { return nil, io.EOF }

// WritePacket queues a packet for the next batch, the way a host would collect what readPackets returned.
func (p *flowPeer) WritePacket(header, payload []byte) error {
	p.mu.Lock()
	p.pending = binary.LittleEndian.AppendUint16(p.pending, uint16(len(header)+len(payload)))
	p.pending = append(append(p.pending, header...), payload...)
	p.mu.Unlock()
	select {
	case p.kick <- struct{}{}:
	default:
	}
	return nil
}

func (p *flowPeer) pumpOut() {
	defer p.wg.Done()
	var batch []byte
	for {
		select {
		case <-p.stop:
			return
		case <-p.kick:
		}
		p.mu.Lock()
		batch, p.pending = p.pending, batch[:0]
		p.mu.Unlock()
		if len(batch) == 0 {
			continue
		}
		n, err := p.engine.TunWrite(batch)
		if err != nil && CodeOf(err) != CodeNotRunning {
			p.t.Errorf("TunWrite: %v", err)
		}
		p.obs.Lock()
		p.writeBatches++
		p.writePackets += n
		p.maxWriteBatch = max(p.maxWriteBatch, n)
		p.obs.Unlock()
	}
}

func (p *flowPeer) pumpIn() {
	defer p.wg.Done()
	buf := make([]byte, 256<<10)
	for {
		select {
		case <-p.stop:
			return
		default:
		}
		if p.deaf.Load() {
			time.Sleep(10 * time.Millisecond)
			continue
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
		count := 0
		for b := buf[:n]; len(b) > 0; count++ {
			size := int(binary.LittleEndian.Uint16(b))
			p.stack.Input(b[frameHeaderSize : frameHeaderSize+size])
			b = b[frameHeaderSize+size:]
		}
		if count > 0 {
			p.obs.Lock()
			p.readBatches++
			p.readPackets += count
			p.maxReadBatch = max(p.maxReadBatch, count)
			p.obs.Unlock()
		}
	}
}

// seen returns the batch observations: host->core packets, batches, largest; core->host the same.
func (p *flowPeer) seen() (wp, wb, wmax, rp, rb, rmax int) {
	p.obs.Lock()
	defer p.obs.Unlock()
	return p.writePackets, p.writeBatches, p.maxWriteBatch, p.readPackets, p.readBatches, p.maxReadBatch
}

func (p *flowPeer) dialTCP(addr string) net.Conn {
	p.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	c, err := p.stack.DialTCP(ctx, netip.MustParseAddrPort(addr))
	if err != nil {
		p.t.Fatalf("dial %s through the packet interface: %v", addr, err)
	}
	_ = c.SetDeadline(time.Now().Add(60 * time.Second))
	return c
}

// samePortEcho starts a TCP and a UDP echo server on one loopback port number.
func samePortEcho(t testing.TB) int {
	t.Helper()
	for i := 0; i < 20; i++ {
		port := startTCPEcho(t, "tcp", "127.0.0.1:0")
		c, err := net.ListenPacket("udp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			continue
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
		return port
	}
	t.Fatal("no port free for both TCP and UDP")
	return 0
}

func tunInbound(mtu int) obj {
	return obj{"tag": "tun-in", "protocol": "tun", "settings": obj{"mtu": mtu}}
}

func udpEchoThroughPeer(t testing.TB, p *flowPeer, target string, sizes ...int) (total int64) {
	t.Helper()
	pc, err := p.stack.DialUDP()
	if err != nil {
		t.Fatal(err)
	}
	defer pc.Close()
	dst := net.UDPAddrFromAddrPort(netip.MustParseAddrPort(target))
	for _, size := range sizes {
		payload := make([]byte, size)
		_, _ = rand.Read(payload)
		got := make([]byte, 65536)
		var n int
		// UDP may be lost by design (bounded queues); allow a retry, as any UDP application would.
		for attempt := 0; ; attempt++ {
			if _, err := pc.WriteTo(payload, dst); err != nil {
				t.Fatal(err)
			}
			total += int64(size)
			type result struct {
				n    int
				from net.Addr
				err  error
			}
			done := make(chan result, 1)
			go func() {
				n, from, err := pc.ReadFrom(got)
				done <- result{n, from, err}
			}()
			select {
			case r := <-done:
				if r.err != nil {
					t.Fatalf("udp read: %v", r.err)
				}
				if r.from.String() != dst.String() {
					t.Fatalf("udp reply from %s, want %s", r.from, dst)
				}
				n = r.n
			case <-time.After(3 * time.Second):
				if attempt < 2 {
					continue
				}
				t.Fatalf("udp echo of %d bytes: no reply", size)
			}
			break
		}
		if !bytes.Equal(got[:n], payload) {
			t.Fatalf("udp echo of %d bytes: data differs (got %d bytes)", size, n)
		}
	}
	return total
}

// TestFlowPacketPathDirect drives the batched packet interface end to end without a proxy server:
// packets -> TunWrite -> core stack -> dispatcher -> freedom -> loopback echo, and back through TunRead.
func TestFlowPacketPathDirect(t *testing.T) {
	const mtu = 1500
	echo := samePortEcho(t)
	config := mustJSON(t, obj{
		"inbounds": arr{tunInbound(mtu)},
		"outbounds": arr{obj{"tag": "direct", "protocol": "freedom",
			"settings": obj{"redirect": fmt.Sprintf("127.0.0.1:%d", echo)}}},
	})
	e := New()
	mustStart(t, e, config, Options{Tun: TunOptions{Mode: TunFlow}})
	p := newFlowPeer(t, e, mtu)

	const tcpBytes = 2 << 20
	c := p.dialTCP("10.9.0.1:7000")
	echoTCP(t, c, tcpBytes)
	c.Close()

	c6 := p.dialTCP("[fd00:9::1]:7000")
	echoTCP(t, c6, tcpBytes)
	c6.Close()

	// 1 byte, a full unfragmented datagram, and two that need IP fragmentation in both directions
	udpBytes := udpEchoThroughPeer(t, p, "10.9.0.1:7000", 1, mtu-28, 3000, 8000)
	udpBytes += udpEchoThroughPeer(t, p, "[fd00:9::1]:7000", 1, mtu-48, 3000)

	want := int64(2*tcpBytes) + udpBytes
	var st Stats
	deadline := time.Now().Add(5 * time.Second)
	for {
		st, _ = e.Stats()
		in := counterOf(st.Inbounds, "tun-in")
		if (in.Uplink >= want && in.Downlink >= want) || time.Now().After(deadline) {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	in, out := counterOf(st.Inbounds, "tun-in"), counterOf(st.Outbounds, "direct")
	t.Logf("payload=%d | inbound tun-in up=%d down=%d | outbound direct up=%d down=%d", want, in.Uplink, in.Downlink, out.Uplink, out.Downlink)
	t.Logf("tun counters: %+v", *st.Tun)
	wp, wb, wmax, rp, rb, rmax := p.seen()
	t.Logf("host->core: %d packets in %d batches (largest %d) | core->host: %d packets in %d batches (largest %d)", wp, wb, wmax, rp, rb, rmax)
	// The tun inbound counts transport payload (no IP/TCP/UDP headers); UDP retries count as sent.
	if in.Uplink != want || in.Downlink < want-8000 || in.Downlink > want {
		t.Errorf("tun inbound counters up=%d down=%d, payload %d", in.Uplink, in.Downlink, want)
	}
	if out.Uplink != in.Uplink || out.Downlink != in.Downlink {
		t.Errorf("freedom outbound counters %+v differ from the tun inbound %+v", out, in)
	}
	if st.Tun.RxMalformed != 0 || st.Tun.RxNoStack != 0 {
		t.Errorf("unexpected tun errors: %+v", *st.Tun)
	}
	// taken before the Stats snapshot was, so the peer can only be behind
	if st.Tun.RxPackets > uint64(wp) || st.Tun.RxPackets == 0 || st.Tun.TxPackets > uint64(rp)+64 || st.Tun.TxPackets == 0 {
		t.Errorf("tun packet counters %+v do not match the peer (%d written, %d read)", *st.Tun, wp, rp)
	}
}

// startTestResolver answers A queries for name with ip and counts the queries it saw.
func startTestResolver(t testing.TB, name string, ip [4]byte) (port int, queries func() int) {
	t.Helper()
	c, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	var mu sync.Mutex
	seen := 0
	go func() {
		buf := make([]byte, 4096)
		for {
			n, from, err := c.ReadFrom(buf)
			if err != nil {
				return
			}
			var m dnsmessage.Message
			if m.Unpack(buf[:n]) != nil || len(m.Questions) != 1 {
				continue
			}
			q := m.Questions[0]
			mu.Lock()
			seen++
			mu.Unlock()
			m.Response, m.RecursionAvailable = true, true
			if q.Type == dnsmessage.TypeA && q.Name.String() == name {
				m.Answers = []dnsmessage.Resource{{
					Header: dnsmessage.ResourceHeader{Name: q.Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 60},
					Body:   &dnsmessage.AResource{A: ip},
				}}
			} else if q.Name.String() != name {
				m.RCode = dnsmessage.RCodeNameError
			}
			if out, err := m.Pack(); err == nil {
				_, _ = c.WriteTo(out, from)
			}
		}
	}()
	return c.LocalAddr().(*net.UDPAddr).Port, func() int { mu.Lock(); defer mu.Unlock(); return seen }
}

// TestFlowThroughProxyWithDNS is the full client data path of a tunnel: IP packets in, a real proxy protocol
// to a real server, and DNS resolved through the tunnel.
//
//	peer stack --packets--> engine (tun inbound, flow mode) --VLESS+REALITY--> server --> loopback echo
//	DNS: UDP/53 packet -> routing -> "dns" outbound -> built-in DNS client -> through the proxy -> test resolver
func TestFlowThroughProxyWithDNS(t *testing.T) {
	const mtu = 1400
	echo := samePortEcho(t)
	resolver, queries := startTestResolver(t, "tunnel.np-test.", [4]byte{203, 0, 113, 7})

	serverPort := freePort(t)
	// VLESS+REALITY+Vision by default. NP_TEST_FLOW_PROXY selects another case by name: under the race
	// detector the pinned core reports a race of its own inside Vision (proxy/proxy.go, TrafficState shared by
	// VisionReader and VisionWriter), which fails this test without telling anything about the bridge. Running
	// it a second time over a protocol without Vision gives the bridge's packet path its own race verdict.
	proxyCase := protoCases()[1]
	if name := os.Getenv("NP_TEST_FLOW_PROXY"); name != "" {
		found := false
		for _, c := range protoCases() {
			if c.name == name {
				proxyCase, found = c, true
			}
		}
		if !found {
			t.Fatalf("NP_TEST_FLOW_PROXY=%q: no such protocol case", name)
		}
	}
	t.Logf("proxy protocol: %s", proxyCase.name)
	in, out := proxyCase.build(t, serverPort)
	// The server sends everything to the echo port, except what is addressed to the resolver.
	server := obj{}
	if err := jsonUnmarshal(serverConfig(t, in, serverPort, fmt.Sprintf("127.0.0.1:%d", echo)), &server); err != nil {
		t.Fatal(err)
	}
	server["outbounds"] = append(server["outbounds"].([]any), obj{"tag": "plain", "protocol": "freedom",
		"settings": obj{"finalRules": arr{obj{"action": "allow"}}}})
	server["routing"] = obj{"rules": arr{obj{"type": "field", "port": resolver, "network": "udp", "outboundTag": "plain"}}}
	startServer(t, mustJSON(t, server), serverPort)

	out["tag"] = "proxy"
	config := mustJSON(t, obj{
		"inbounds":  arr{tunInbound(mtu)},
		"outbounds": arr{out, obj{"tag": "dns-out", "protocol": "dns"}, obj{"tag": "direct", "protocol": "freedom"}},
		"dns": obj{"tag": "dns-internal", "queryStrategy": "UseIPv4",
			"servers": arr{obj{"address": "127.0.0.1", "port": resolver}}},
		"routing": obj{"rules": arr{
			obj{"type": "field", "inboundTag": arr{"tun-in"}, "port": 53, "outboundTag": "dns-out"},
			obj{"type": "field", "inboundTag": arr{"dns-internal"}, "outboundTag": "proxy"},
		}},
	})
	e := New()
	mustStart(t, e, config, Options{Tun: TunOptions{Mode: TunFlow}, LogLevel: getenv("NP_TEST_LOGLEVEL")})
	p := newFlowPeer(t, e, mtu)

	const tcpBytes = 1 << 20
	// With REALITY the first connection takes about five seconds: the server library waits for its probe of
	// the target's post-handshake records (xtls/reality record_detect.go, 5 s read deadline), and the local
	// test target sends nothing after its handshake. Measured: first echo 5.04 s, the next one 16 ms.
	c := p.dialTCP("10.9.0.1:443")
	echoTCP(t, c, tcpBytes)
	c.Close()
	c6 := p.dialTCP("[fd00:9::1]:443")
	echoTCP(t, c6, 256<<10)
	c6.Close()
	udpEchoThroughPeer(t, p, "10.9.0.1:9000", 64, 1200, 3000)

	// DNS, the way an app's resolver sends it to the tunnel's DNS server address
	pc, err := p.stack.DialUDP()
	if err != nil {
		t.Fatal(err)
	}
	defer pc.Close()
	query := dnsmessage.Message{
		Header:    dnsmessage.Header{ID: 0x4e50, RecursionDesired: true},
		Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName("tunnel.np-test."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}},
	}
	packed, _ := query.Pack()
	dnsServer := net.UDPAddrFromAddrPort(netip.MustParseAddrPort("10.9.0.53:53"))
	if _, err := pc.WriteTo(packed, dnsServer); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, 1500)
	type res struct {
		n   int
		err error
	}
	done := make(chan res, 1)
	go func() { n, _, err := pc.ReadFrom(reply); done <- res{n, err} }()
	var n int
	select {
	case r := <-done:
		if r.err != nil {
			t.Fatal(r.err)
		}
		n = r.n
	case <-time.After(10 * time.Second):
		t.Fatal("no DNS reply through the tunnel")
	}
	var m dnsmessage.Message
	if err := m.Unpack(reply[:n]); err != nil {
		t.Fatal(err)
	}
	if m.ID != 0x4e50 || len(m.Answers) != 1 {
		t.Fatalf("dns reply: %+v", m)
	}
	if a, ok := m.Answers[0].Body.(*dnsmessage.AResource); !ok || a.A != [4]byte{203, 0, 113, 7} {
		t.Fatalf("dns answer: %+v", m.Answers[0])
	}
	if queries() == 0 {
		t.Fatal("the test resolver saw no query")
	}

	st, serr := e.Stats()
	if serr != nil {
		t.Fatal(serr)
	}
	direct, proxy, dnsOut := counterOf(st.Outbounds, "direct"), counterOf(st.Outbounds, "proxy"), counterOf(st.Outbounds, "dns-out")
	t.Logf("outbound proxy %+v | dns-out %+v | direct %+v | resolver queries %d | tun %+v", proxy, dnsOut, direct, queries(), *st.Tun)
	if direct.Uplink > 0 || direct.Downlink > 0 {
		t.Errorf("traffic bypassed the proxy: %+v", direct)
	}
	if proxy.Uplink < tcpBytes || proxy.Downlink < tcpBytes {
		t.Errorf("proxy counters too small: %+v", proxy)
	}
}

// TestFlowBackpressureAndRestart: with nobody reading, the outbound queue fills, drops and never blocks the
// core; stopping wakes a blocked reader; a restarted engine gets a fresh device.
func TestFlowBackpressureAndRestart(t *testing.T) {
	source := startTCPSource(t, 8<<20)
	config := mustJSON(t, obj{
		"inbounds": arr{tunInbound(1500)},
		"outbounds": arr{obj{"tag": "direct", "protocol": "freedom",
			"settings": obj{"redirect": fmt.Sprintf("127.0.0.1:%d", source)}}},
	})
	e := New()
	opts := Options{Tun: TunOptions{Mode: TunFlow, OutQueueBytes: 128 << 10}}
	if err := e.Start(context.Background(), []byte(config), opts); err != nil {
		t.Fatal(err)
	}
	p := newFlowPeer(t, e, 1500)
	// Many downloads in flight, then the host stops reading packets: every sender keeps transmitting up to
	// its congestion window and then retransmits, so the queue must fill and drop instead of growing.
	buf := make([]byte, 32<<10)
	for i := 0; i < 32; i++ {
		c := p.dialTCP("10.9.0.1:80")
		if _, err := io.ReadFull(c, buf); err != nil {
			t.Fatal(err)
		}
	}
	p.deaf.Store(true)
	deadline := time.Now().Add(15 * time.Second)
	var tc TunCounters
	for {
		tc = *e.Health().Tun
		if tc.TxDropped > 0 || time.Now().After(deadline) {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Logf("with the host not reading: %+v", tc)
	if tc.TxDropped == 0 {
		t.Error("the queue never overflowed")
	}
	if tc.TxQueueHighest > tc.TxQueueBytes {
		t.Errorf("queue grew past its bound: %+v", tc)
	}
	// malformed batches are rejected and counted, the good prefix is consumed
	good := frame([]byte{0x45, 0, 0, 20, 0, 0, 0, 0, 64, 17, 0, 0, 10, 8, 0, 2, 10, 9, 0, 1})
	if n, err := e.TunWrite(append(append([]byte{}, good...), 0xff, 0xff, 1)); n != 1 || CodeOf(err) != CodeInvalidArgument {
		t.Errorf("malformed batch: n=%d err=%v", n, err)
	}
	if n, err := e.TunWrite([]byte{0, 0}); n != 0 || CodeOf(err) != CodeInvalidArgument {
		t.Errorf("zero-length frame: n=%d err=%v", n, err)
	}

	// a reader looping on TunRead with no timeout is released by Stop
	p.close()
	drain := make([]byte, 1<<20)
	blocked := make(chan *Error, 1)
	go func() {
		for {
			if _, err := e.TunRead(drain, -1); err != nil {
				blocked <- err
				return
			}
		}
	}()
	time.Sleep(50 * time.Millisecond)
	if err := e.Stop(10 * time.Second); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-blocked:
		// closed if it was parked inside the call, not_running if it was between two calls
		if c := CodeOf(err); c != CodeClosed && c != CodeNotRunning {
			t.Errorf("blocked reader got %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("TunRead stayed blocked after Stop")
	}
	if _, err := e.TunRead(drain, 0); CodeOf(err) != CodeNotRunning {
		t.Errorf("TunRead after stop: %v", err)
	}

	// restart: new device, counters from zero, traffic flows again
	mustStart(t, e, config, opts)
	if tc := *e.Health().Tun; tc.TxPackets != 0 || tc.RxPackets != 0 {
		t.Errorf("device counters survived the restart: %+v", tc)
	}
	p2 := newFlowPeer(t, e, 1500)
	c2 := p2.dialTCP("10.9.0.1:80")
	got, err := io.Copy(io.Discard, c2)
	if err != nil || got != 8<<20 {
		t.Fatalf("download after restart: %d bytes, %v", got, err)
	}
}

// TestFlowThroughput reports the capacity of the packet path on this machine; it is a measurement, the only
// assertion is that the download completes.
func TestFlowThroughput(t *testing.T) {
	if testing.Short() {
		t.Skip("measurement")
	}
	const total = 256 << 20
	source := startTCPSource(t, total)
	config := mustJSON(t, obj{
		"inbounds": arr{tunInbound(1500)},
		"outbounds": arr{obj{"tag": "direct", "protocol": "freedom",
			"settings": obj{"redirect": fmt.Sprintf("127.0.0.1:%d", source)}}},
	})
	for _, queue := range []int{256 << 10, 2 << 20, 8 << 20} {
		e := New()
		if err := e.Start(context.Background(), []byte(config), Options{Tun: TunOptions{Mode: TunFlow, OutQueueBytes: queue}}); err != nil {
			t.Fatal(err)
		}
		p := newFlowPeer(t, e, 1500)
		c := p.dialTCP("10.9.0.1:80")
		_ = c.SetDeadline(time.Now().Add(5 * time.Minute))
		start := time.Now()
		got, err := io.Copy(io.Discard, c)
		elapsed := time.Since(start)
		if err != nil || got != total {
			t.Fatalf("queue %d: %d bytes, %v", queue, got, err)
		}
		tc := *e.Health().Tun
		wp, wb, _, rp, rb, rmax := p.seen()
		t.Logf("queue=%4d KiB: %.0f Mbit/s download; core->host %d packets in %d batches (avg %.1f, max %d), dropped %d (%.3f%%), high-water %d KiB; host->core %d packets in %d batches (avg %.1f)",
			queue>>10, float64(got)*8/elapsed.Seconds()/1e6, rp, rb, float64(rp)/float64(max(rb, 1)), rmax,
			tc.TxDropped, 100*float64(tc.TxDropped)/float64(max(tc.TxPackets+tc.TxDropped, 1)), tc.TxQueueHighest>>10,
			wp, wb, float64(wp)/float64(max(wb, 1)))
		p.close()
		if err := e.Stop(10 * time.Second); err != nil {
			t.Fatal(err)
		}
	}
}
