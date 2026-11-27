package engine

import (
	"context"
	"encoding/binary"
	"fmt"
	"net"
	"net/netip"
	"os"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestParseOptions(t *testing.T) {
	o, err := ParseOptions(nil)
	if err != nil || o.StartTimeoutMs != 15000 || o.StopTimeoutMs != 5000 || o.LogQueueSize != 512 || o.Tun.OutQueueBytes != 2<<20 {
		t.Fatalf("defaults: %+v %v", o, err)
	}
	for _, bad := range []string{
		`{"assetDir":"/x"}`, // Xray-only field: rejected, not ignored
		`{"tun":{"mode":"fd"}}`,
		`{"tun":{"mode":"weird"}}`,
		`{"tun":{"mtu":100}}`,
		`{"logLevel":"verbose"}`,
		`{"startTimeoutMs":-1}`,
		`{} {}`,
	} {
		if _, err := ParseOptions([]byte(bad)); err == nil || err.Code != CodeInvalidArgument {
			t.Errorf("%s: %v", bad, err)
		}
	}
	o, err = ParseOptions([]byte(`{"homeDir":"/tmp/x","tun":{"mode":"flow","mtu":1280},"memory":{"limitBytes":1000}}`))
	if err != nil || o.Tun.Mode != TunFlow || o.Tun.MTU != 1280 || o.HomeDir != "/tmp/x" {
		t.Fatalf("%+v %v", o, err)
	}
}

func prep(t *testing.T, yaml string, opts Options) (*prepared, *Error) {
	t.Helper()
	if err := opts.Normalize(); err != nil {
		t.Fatal(err)
	}
	opts.HomeDir = t.TempDir()
	if err := setHome(&opts); err != nil {
		t.Fatal(err)
	}
	return prepareConfig([]byte(yaml), &opts)
}

func TestPrepareConfig(t *testing.T) {
	// Defaults of the core that must not survive: recvmsgx on, find-process strict, controller.
	p, err := prep(t, "mode: rule\nexternal-controller: 127.0.0.1:9090\niptables:\n  enable: true\nrules:\n  - MATCH,DIRECT\ntun:\n  enable: true\n  auto-route: true\n  dns-hijack: [\"any:53\", \"tcp://8.8.8.8:53\"]\n",
		Options{Tun: TunOptions{Mode: TunFlow}})
	if err != nil {
		t.Fatal(err)
	}
	g := p.cfg.General
	if g.Tun.RecvMsgX || g.Tun.SendMsgX || g.Tun.Enable {
		t.Errorf("tun not neutralised: recvmsgx=%v sendmsgx=%v enable=%v", g.Tun.RecvMsgX, g.Tun.SendMsgX, g.Tun.Enable)
	}
	if g.FindProcessMode.String() != "off" || p.cfg.Controller.ExternalController != "" || p.cfg.IPTables.Enable {
		t.Errorf("find-process=%s controller=%q iptables=%v", g.FindProcessMode, p.cfg.Controller.ExternalController, p.cfg.IPTables.Enable)
	}
	if p.tun == nil || p.tun.mtu != 1500 || !p.summary.HasTun {
		t.Fatalf("tun spec %+v", p.tun)
	}
	// dns-hijack entries plus <tun address>.next():53 for each tun address. The core keeps the IPv6 tun
	// address only when the host has a global IPv6 address at parse time (config/utils.go verifyIP6), so the
	// count depends on the machine: 4 on a host with IPv6, 3 on one without (GitHub runners).
	if len(p.tun.inet4) != 1 {
		t.Fatalf("inet4 %v", p.tun.inet4)
	}
	if len(p.tun.dnsHijack) != 2+len(p.tun.inet4)+len(p.tun.inet6) || p.tun.dnsHijack[0].String() != "0.0.0.0:53" || p.tun.dnsHijack[1].String() != "8.8.8.8:53" {
		t.Errorf("dns hijack %v (inet4 %v, inet6 %v)", p.tun.dnsHijack, p.tun.inet4, p.tun.inet6)
	}
	for i, a := range append(append([]netip.Prefix(nil), p.tun.inet4...), p.tun.inet6...) {
		if want := netip.AddrPortFrom(a.Addr().Next(), 53); p.tun.dnsHijack[2+i] != want {
			t.Errorf("dns hijack [%d] = %v, want %v", 2+i, p.tun.dnsHijack[2+i], want)
		}
	}
	t.Logf("inet6 %v (host IPv6 decides whether the core keeps it)", p.tun.inet6)
	t.Logf("overridden: %q", p.summary.Overridden)
	joined := strings.Join(p.summary.Overridden, "\n")
	for _, want := range []string{"external-controller", "iptables", "find-process-mode", "auto-route"} {
		if !strings.Contains(joined, want) {
			t.Errorf("summary does not report %s", want)
		}
	}

	if p, err := prep(t, "tun:\n  enable: true\n  mtu: 9000\n", Options{Tun: TunOptions{Mode: TunFlow, MTU: 1400}}); err != nil || p.tun.mtu != 1400 {
		t.Errorf("mtu option: %+v %v", p, err)
	}

	cases := []struct {
		yaml string
		opts Options
		code Code
	}{
		{"mode: [", Options{}, CodeConfigParse},
		{"proxies:\n  - {name: x, type: nonsense}\n", Options{}, CodeConfigBuild},
		{"tun:\n  enable: true\n", Options{}, CodeConfigUnsupport},
		{"tun:\n  enable: true\n  stack: system\n", Options{Tun: TunOptions{Mode: TunFlow}}, CodeConfigUnsupport},
		{"tun:\n  enable: true\n  file-descriptor: 7\n", Options{Tun: TunOptions{Mode: TunFlow}}, CodeConfigUnsupport},
		{"listeners:\n  - {name: t, type: tun}\n", Options{}, CodeConfigUnsupport},
		{"listeners:\n  - {name: r, type: redir, port: 7895}\n", Options{}, CodeConfigUnsupport},
		{"   ", Options{}, CodeInvalidArgument},
	}
	for _, c := range cases {
		if _, err := prep(t, c.yaml, c.opts); err == nil || err.Code != c.code {
			t.Errorf("%q: got %v, want %s", c.yaml, err, c.code)
		}
	}
}

// frame builds a batch from packets.
func frame(pkts ...[]byte) []byte {
	var b []byte
	for _, p := range pkts {
		b = binary.LittleEndian.AppendUint16(b, uint16(len(p)))
		b = append(b, p...)
	}
	return b
}

// TestFlowDeviceHandoff drives flowDevice the way sing-tun's readLoop does: one Read per packet on its own
// goroutine, while writeBatch queues batches.
func TestFlowDeviceHandoff(t *testing.T) {
	// a full inbound queue drops (no reader attached to this device)
	full := newFlowDevice(1500, 128<<10, 128<<10, 0)
	full.attached.Store(true)
	big := frame(make([]byte, 1400), make([]byte, 1400), make([]byte, 1400), make([]byte, 1400))
	for i := 0; i < 40; i++ {
		if n, err := full.writeBatch(big); n != 4 || err != nil {
			t.Fatalf("batch %d: %d %v", i, n, err)
		}
	}
	if c := full.counters(); c.RxDropped == 0 || c.RxPackets+c.RxDropped != 160 || c.RxQueueHighest > 128<<10 {
		t.Errorf("full queue counters %+v", c)
	}

	d := newFlowDevice(100, 128<<10, 128<<10, 0)
	d.attached.Store(true)
	got := make(chan []byte, 64)
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		buf := make([]byte, 100)
		for {
			n, err := d.Read(buf)
			if err != nil {
				close(got)
				return
			}
			got <- append([]byte(nil), buf[:n]...)
		}
	}()
	n, err := d.writeBatch(frame([]byte("a"), make([]byte, 101), []byte("bc")))
	if err != nil || n != 3 {
		t.Fatalf("batch: %d %v", n, err)
	}
	if string(<-got) != "a" || string(<-got) != "bc" {
		t.Fatal("packets out of order or lost")
	}
	// malformed tail: one good packet, then a frame longer than the rest
	bad := append(frame([]byte("x")), 50, 0, 1, 2)
	n, err = d.writeBatch(bad)
	if n != 1 || err == nil || err.Code != CodeInvalidArgument {
		t.Fatalf("malformed: %d %v", n, err)
	}
	if string(<-got) != "x" {
		t.Fatal("packet before the bad frame lost")
	}
	c := d.counters()
	if c.RxPackets != 3 || c.RxOversize != 1 || c.RxMalformed != 1 {
		t.Errorf("counters %+v", c)
	}
	// core -> host
	_, _ = d.Write([]byte("reply"))
	out := make([]byte, 64)
	if n, err := d.out.read(out, time.Second); err != nil || string(out[2:n]) != "reply" {
		t.Fatalf("read: %q %v", out[:n], err)
	}
	// close wakes the reader and a waiting writer
	done := make(chan *Error, 1)
	_ = d.Close()
	go func() { _, err := d.writeBatch(frame([]byte("late"))); done <- err }()
	if err := <-done; err == nil || err.Code != CodeClosed {
		t.Errorf("write after close: %v", err)
	}
	wg.Wait()
	if _, err := d.out.read(out, 0); err == nil || err.Code != CodeClosed {
		t.Errorf("read after close: %v", err)
	}
}

func TestLifecycleAndLogs(t *testing.T) {
	e := New()
	if err := e.Stop(0); err != nil {
		t.Fatalf("stop idle: %v", err)
	}
	if _, err := e.TunWrite(frame([]byte{0x45})); err == nil || err.Code != CodeNotRunning {
		t.Fatalf("tun write idle: %v", err)
	}
	s, err := e.Validate([]byte("mode: rule\nrules:\n  - MATCH,DIRECT\n"), Options{HomeDir: t.TempDir()})
	if err != nil || s.Depth != "parse" || s.Rules != 1 {
		t.Fatalf("validate: %+v %v", s, err)
	}
	socks := freePort(t)
	cfg := fmt.Sprintf("mode: rule\nlog-level: debug\nsocks-port: %d\nrules:\n  - MATCH,DIRECT\n", socks)
	mustStart(t, e, cfg, Options{})
	waitTCP(t, socks)
	if h := e.Health(); h.State != "running" || !h.CoreRunning || h.Generation != 1 {
		t.Fatalf("health %+v", h)
	}
	if err := e.Start(context.Background(), []byte(cfg), Options{}); err == nil || err.Code != CodeInvalidState {
		t.Fatalf("second start: %v", err)
	}
	if _, err := New().Validate([]byte(cfg), Options{}); err == nil || err.Code != CodeInvalidState {
		t.Fatalf("validate while running: %v", err)
	}
	// a direct connection through the SOCKS inbound
	host := hostAddr(t)
	hostEcho := echoServer(t, host)
	c := socksConnect(t, socks, host, hostEcho)
	echoTCP(t, c, 64<<10)
	st, _ := e.Stats()
	if st.Connections != 1 || st.Total.Uplink < 64<<10 {
		t.Errorf("stats with one open connection: %+v", st)
	}
	c.Close()
	logs := e.ReadLogs(nil, 1000, time.Second)
	if len(logs) == 0 {
		t.Fatal("no log records")
	}
	t.Logf("%d log records, first: %+v", len(logs), logs[0])

	// Reload to a config on another port; the old port must close.
	socks2 := freePort(t)
	if err := e.Reload(context.Background(), []byte(strings.Replace(cfg, fmt.Sprint(socks), fmt.Sprint(socks2), 1))); err != nil {
		t.Fatalf("reload: %v", err)
	}
	waitTCP(t, socks2)
	if c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", socks), time.Second); err == nil {
		c.Close()
		t.Error("old socks port still open after reload")
	}
	// Reload to a broken config keeps the running one.
	if err := e.Reload(context.Background(), []byte("mode: [")); err == nil || err.Code != CodeConfigParse {
		t.Errorf("bad reload: %v", err)
	}
	if e.State() != StateRunning {
		t.Error("bad reload stopped the engine")
	}
}

func TestStartFailures(t *testing.T) {
	// SOCKS port taken: ApplyConfig only logs it; Start must report it and leave nothing running.
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	port := l.Addr().(*net.TCPAddr).Port
	e := New()
	err2 := e.Start(context.Background(), []byte(fmt.Sprintf("socks-port: %d\nrules:\n  - MATCH,DIRECT\n", port)), Options{HomeDir: t.TempDir()})
	if err2 == nil || err2.Code != CodeStartFailed {
		t.Fatalf("start on a taken port: %v", err2)
	}
	if e.State() != StateIdle || e.Health().LastErrorCode != CodeStartFailed {
		t.Fatalf("after failed start: %+v", e.Health())
	}
	// Stop during a slow start aborts it.
	testHookBringUp = func() { time.Sleep(300 * time.Millisecond) }
	defer func() { testHookBringUp = nil }()
	errc := make(chan *Error, 1)
	go func() {
		errc <- e.Start(context.Background(), []byte("rules:\n  - MATCH,DIRECT\n"), Options{HomeDir: t.TempDir()})
	}()
	time.Sleep(50 * time.Millisecond)
	if err := e.Stop(5 * time.Second); err != nil {
		t.Fatalf("stop during start: %v", err)
	}
	if err := <-errc; err == nil || err.Code != CodeCancelled {
		t.Fatalf("aborted start returned %v", err)
	}
	if e.State() != StateIdle {
		t.Fatal("not idle after abort")
	}
}

// TestFlowPacketPathDirect: packets -> TunWrite -> mips stack -> tunnel -> DIRECT -> echo on a host address,
// and back through TunRead. No proxy server involved.
func TestFlowPacketPathDirect(t *testing.T) {
	host := hostAddr(t)
	echo := echoServer(t, host)
	e := New()
	mustStart(t, e, "mode: rule\nrules:\n  - MATCH,DIRECT\ntun:\n  enable: true\n  stack: mips\n  mtu: 1500\n", Options{Tun: TunOptions{Mode: TunFlow}})
	p := newOSPeer(t, e, 1500)
	target := fmt.Sprintf("%s:%d", host, echo)
	c := p.dialTCP(target)
	echoTCP(t, c, 4<<20)
	c.Close()
	u := p.dialUDP(target)
	echoUDP(t, u, 1, 1472, 3000, 8000)
	u.Close()
	st, _ := e.Stats()
	p.mu.Lock()
	t.Logf("host->core %d packets in %d batches (largest %d); core->host %d packets", p.writePackets, p.writeBatches, p.maxBatchSent, p.readPackets)
	p.mu.Unlock()
	t.Logf("tun counters %+v, total %+v", *st.Tun, st.Total)
	if st.Tun.RxMalformed != 0 || st.Tun.RxOversize != 0 || st.Total.Uplink < 4<<20 {
		t.Errorf("unexpected counters %+v %+v", *st.Tun, st.Total)
	}
}

// TestStartStopCycles measures what 50 start/stop cycles leave behind: each cycle starts a config with a
// SOCKS inbound, a packet stack, a proxy group and a connection through both, then stops.
func TestStartStopCycles(t *testing.T) {
	cycles := 50
	if testing.Short() {
		cycles = 5
	}
	host := hostAddr(t)
	echo := echoServer(t, host)
	target := fmt.Sprintf("%s:%d", host, echo)
	e := New()
	home := t.TempDir()
	type sample struct {
		goroutines int
		heap       uint64
		rss        int64
	}
	measure := func() sample {
		g := settleGoroutines()
		runtime.GC()
		debug.FreeOSMemory()
		var ms runtime.MemStats
		runtime.ReadMemStats(&ms)
		return sample{g, ms.HeapAlloc, rssKiB()}
	}
	before := measure()
	var samples []sample
	for i := 0; i < cycles; i++ {
		socks := freePort(t)
		cfg := fmt.Sprintf("mode: rule\nsocks-port: %d\nproxies:\n  - {name: d1, type: direct}\nproxy-groups:\n  - {name: g, type: select, proxies: [d1, DIRECT]}\nrules:\n  - MATCH,g\ntun:\n  enable: true\n  stack: mips\n", socks)
		if err := e.Start(context.Background(), []byte(cfg), Options{HomeDir: home, Tun: TunOptions{Mode: TunFlow}}); err != nil {
			t.Fatalf("cycle %d start: %v\n%s", i, err, drainLogs(e))
		}
		c := socksConnect(t, socks, host, echo)
		echoTCP(t, c, 32<<10)
		p := newOSPeerNoCleanup(t, e, 1500)
		pc := p.dialTCP(target)
		echoTCP(t, pc, 32<<10)
		// connections are left open on purpose: Stop must close them
		if err := e.Stop(10 * time.Second); err != nil {
			t.Fatalf("cycle %d stop: %v", i, err)
		}
		p.close()
		c.Close()
		pc.Close()
		e.ReadLogs(nil, 100000, 0)
		if i == 0 || i == 9 || i == cycles-1 {
			samples = append(samples, measure())
		}
	}
	after := samples[len(samples)-1]
	t.Logf("before: goroutines=%d heap=%d KiB rss=%d KiB", before.goroutines, before.heap>>10, before.rss)
	for i, s := range samples {
		t.Logf("sample %d: goroutines=%d heap=%d KiB rss=%d KiB", i, s.goroutines, s.heap>>10, s.rss)
	}
	first := samples[0]
	perCycle := (int64(after.heap) - int64(first.heap)) / int64(cycles-1)
	t.Logf("after first cycle -> after %d: goroutines %+d, heap %+d KiB (%+d B/cycle), rss %+d KiB",
		cycles, after.goroutines-first.goroutines, (int64(after.heap)-int64(first.heap))>>10, perCycle, after.rss-first.rss)
	if after.goroutines > first.goroutines+5 {
		t.Errorf("goroutines grew from %d to %d", first.goroutines, after.goroutines)
	}
	if perCycle > 64<<10 {
		t.Errorf("heap grows %d bytes per cycle", perCycle)
	}
	if e.State() != StateIdle {
		t.Error("not idle")
	}
}

// TestSoakRSS (opt-in: NP_SOAK=<duration>) runs the packet path through a stock Xray server with
// VLESS+REALITY+Vision for the given time with TCP connections opened and closed continuously plus UDP, and
// samples the RSS of this process (engine + the test's peer stack + client + echo; the Xray server is a
// separate process). Also reports the idle RSS right after Start.
func TestSoakRSS(t *testing.T) {
	d, err := time.ParseDuration(os.Getenv("NP_SOAK"))
	if err != nil || d <= 0 {
		t.Skip("NP_SOAK not set")
	}
	echo := echoServer(t, "127.0.0.1")
	proxy := startProxyServer(t, proxyCases()[0], echo)
	e := New()
	runtime.GC()
	debug.FreeOSMemory()
	t.Logf("RSS before start: %d KiB", rssKiB())
	opts := Options{Tun: TunOptions{Mode: TunFlow}}
	if lim := os.Getenv("NP_SOAK_LIMIT"); lim != "" {
		var v int64
		fmt.Sscan(lim, &v)
		opts.Memory = MemoryOptions{LimitBytes: v, GCPercent: 50}
	}
	mustStart(t, e, clientYAML(freePort(t), proxy, true), opts)
	time.Sleep(3 * time.Second)
	t.Logf("idle RSS after start: %d KiB, %+v", rssKiB(), ReadMemoryStats())
	p := newOSPeer(t, e, 1500)

	stop := make(chan struct{})
	var wg sync.WaitGroup
	var mu sync.Mutex
	var bytesMoved, conns, failures int64
	for w := 0; w < 4; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			buf := make([]byte, 32<<10)
			got := make([]byte, 32<<10)
			for i := 0; ; i++ {
				select {
				case <-stop:
					return
				default:
				}
				ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
				c, err := p.stack.DialTCP(ctx, "tcp", zeroAddrPort, mustAddrPort(fmt.Sprintf("10.9.%d.%d:7000", w, i%250+1)))
				cancel()
				if err != nil {
					mu.Lock()
					failures++
					mu.Unlock()
					continue
				}
				_ = c.SetDeadline(time.Now().Add(30 * time.Second))
				ok := true
				for k := 0; k < 64 && ok; k++ {
					if _, err := c.Write(buf); err != nil {
						ok = false
						break
					}
					if _, err := readFull(c, got); err != nil {
						ok = false
					}
				}
				c.Close()
				mu.Lock()
				conns++
				if ok {
					bytesMoved += 2 * 64 * int64(len(buf))
				} else {
					failures++
				}
				mu.Unlock()
				if i%20 == 0 {
					u, err := p.stack.DialUDP(context.Background(), "udp", zeroAddrPort, mustAddrPort(fmt.Sprintf("10.9.%d.%d:7001", w, i%250+1)))
					if err == nil {
						_, _ = u.Write(buf[:1000])
						_ = u.Close()
					}
				}
			}
		}(w)
	}
	began := time.Now()
	ticker := time.NewTicker(30 * time.Second)
	var peak int64
	for time.Since(began) < d {
		<-ticker.C
		r := rssKiB()
		peak = max(peak, r)
		m := ReadMemoryStats()
		mu.Lock()
		anon, file := rssSplitKiB()
		t.Logf("t=%3.0fs rss=%d KiB anon=%d file=%d heapLive=%d KiB mapped=%d KiB goroutines=%d conns=%d bytes=%d MiB failures=%d",
			time.Since(began).Seconds(), r, anon, file, m.HeapLive>>10, m.Mapped>>10, m.Goroutines, conns, bytesMoved>>20, failures)
		mu.Unlock()
	}
	ticker.Stop()
	if dir := os.Getenv("NP_SOAK_PROF"); dir != "" {
		// heap and goroutine profiles under load (this process: engine + the test's peer stack and client)
		writeProfiles(t, dir, "soak-loaded")
	}
	close(stop)
	wg.Wait()
	st, _ := e.Stats()
	t.Logf("soak done: peak rss=%d KiB, conns=%d, %d MiB, failures=%d, stats %+v tun %+v", peak, conns, bytesMoved>>20, failures, st.Total, *st.Tun)
	if failures > conns/100 {
		t.Errorf("%d failures in %d connections", failures, conns)
	}
}
