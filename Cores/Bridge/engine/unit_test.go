package engine

import (
	"context"
	"encoding/binary"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/xtls/xray-core/core"
)

func frame(p []byte) []byte {
	return append(binary.LittleEndian.AppendUint16(nil, uint16(len(p))), p...)
}

func TestPacketQueueOrderWrapAndDrop(t *testing.T) {
	q := newPacketQueue(64)
	// 3 packets of 18+2 bytes fit, the 4th does not
	for i := 0; i < 4; i++ {
		p := make([]byte, 18)
		p[0] = byte(i)
		if ok := q.push(p[:10], p[10:]); ok != (i < 3) {
			t.Fatalf("push %d: queued=%v", i, ok)
		}
	}
	if q.dropped != 1 || q.packets != 3 {
		t.Fatalf("dropped=%d packets=%d", q.dropped, q.packets)
	}
	dst := make([]byte, 45) // room for two frames only
	n, err := q.read(dst, 0)
	if err != nil || n != 40 || dst[2] != 0 || dst[22] != 1 {
		t.Fatalf("read: n=%d err=%v", n, err)
	}
	// wrap around the end of the ring many times
	for round := 0; round < 100; round++ {
		p := []byte{byte(round), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
		if !q.push(p, nil) {
			t.Fatalf("round %d: push failed", round)
		}
		n, err := q.read(dst, 0)
		if err != nil || n == 0 {
			t.Fatalf("round %d: n=%d err=%v", round, n, err)
		}
	}
	if _, err := q.read(make([]byte, 4), 0); err != nil {
		t.Fatalf("empty poll: %v", err)
	}
	q.push(make([]byte, 20), nil)
	if _, err := q.read(make([]byte, 4), 0); CodeOf(err) != CodeBufferTooSmall {
		t.Fatalf("small buffer: %v", err)
	}
}

func TestPacketQueueBlockingReadAndClose(t *testing.T) {
	q := newPacketQueue(1024)
	start := time.Now()
	if n, err := q.read(make([]byte, 100), 30*time.Millisecond); n != 0 || err != nil || time.Since(start) < 25*time.Millisecond {
		t.Fatalf("timeout read: n=%d err=%v after %s", n, err, time.Since(start))
	}
	go func() {
		time.Sleep(20 * time.Millisecond)
		q.push([]byte{0x45, 1, 2}, nil)
	}()
	if n, err := q.read(make([]byte, 100), -1); n != 5 || err != nil {
		t.Fatalf("blocking read: n=%d err=%v", n, err)
	}
	go func() {
		time.Sleep(20 * time.Millisecond)
		q.close()
	}()
	if _, err := q.read(make([]byte, 100), -1); CodeOf(err) != CodeClosed {
		t.Fatalf("read after close: %v", err)
	}
	if q.push([]byte{1}, nil) {
		t.Fatal("push after close succeeded")
	}
}

func TestLogQueueDropsOldestAndCounts(t *testing.T) {
	q := newLogQueue(4)
	for i := 0; i < 10; i++ {
		q.push("info", "general", strings.Repeat("x", i))
	}
	produced, dropped, pending := q.stats()
	if produced != 10 || dropped != 6 || pending != 4 {
		t.Fatalf("produced=%d dropped=%d pending=%d", produced, dropped, pending)
	}
	recs, ok := q.pop(nil, 3, 0)
	if !ok || len(recs) != 3 || recs[0].Seq != 7 || recs[2].Seq != 9 {
		t.Fatalf("pop: %+v", recs)
	}
	q.push("error", "general", strings.Repeat("y", 5000))
	recs, _ = q.pop(nil, 10, 0)
	if len(recs) != 2 || len(recs[1].Message) != maxLogMessageBytes {
		t.Fatalf("pop 2: %d records", len(recs))
	}
	// a producer must never block, even with nobody reading
	done := make(chan struct{})
	go func() {
		for i := 0; i < 100000; i++ {
			q.push("debug", "general", "m")
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("producer blocked")
	}
	q.close()
	if _, ok := q.pop(nil, 0, time.Second); ok {
		// drained with max=0 leaves records; closed and non-empty still reports ok
	}
}

func TestParseOptions(t *testing.T) {
	o, err := ParseOptions(nil)
	if err != nil || o.StartTimeoutMs != 15000 || o.StopTimeoutMs != 5000 || o.LogQueueSize != 512 || o.Tun.OutQueueBytes != 2<<20 {
		t.Fatalf("defaults: %+v %v", o, err)
	}
	for _, bad := range []string{
		`{"unknown":1}`, `{"logLevel":"loud"}`, `{"tun":{"mode":"fd","fd":1}}`, `{"tun":{"mode":"x"}}`,
		`{"startTimeoutMs":-1}`, `{"tun":{"mtu":100}}`, `{"memory":{"limitBytes":-5}}`, `[]`, `{} {}`, `{"logQueueSize":-1}`,
	} {
		if _, err := ParseOptions([]byte(bad)); CodeOf(err) != CodeInvalidArgument {
			t.Errorf("%s: got %v", bad, err)
		}
	}
	if _, err := ParseOptions([]byte(`{"tun":{"mode":"flow","mtu":1400},"memory":{"limitBytes":1000000,"gcPercent":50}}`)); err != nil {
		t.Fatal(err)
	}
}

const minimalConfig = `{"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"}]}`

func tunConfig(extraInbounds string) string {
	return `{"inbounds":[{"tag":"tun-in","protocol":"tun","settings":{"mtu":1400},"sniffing":{"enabled":true,"destOverride":["tls","http"]}}` +
		extraInbounds + `],"outbounds":[{"protocol":"freedom","tag":"direct"}]}`
}

func TestPrepareConfigRejections(t *testing.T) {
	cases := []struct {
		name, config string
		opts         Options
		want         Code
	}{
		{"empty", ``, Options{}, CodeInvalidArgument},
		{"not json", `{"inbounds":`, Options{}, CodeConfigParse},
		{"comments are not accepted", "{// c\n\"outbounds\":[]}", Options{}, CodeConfigParse},
		{"wrong type", `{"inbounds":{}}`, Options{}, CodeConfigParse},
		{"unknown protocol", `{"outbounds":[{"protocol":"nope"}]}`, Options{}, CodeConfigBuild},
		{"bad uuid", `{"outbounds":[{"protocol":"vless","settings":{"address":"127.0.0.1","port":1,"id":"","encryption":"none"},"streamSettings":{"security":"reality","realitySettings":{"password":"zz"}}}]}`, Options{}, CodeConfigBuild},
		{"env", `{"env":{"A":"B"},"outbounds":[{"protocol":"freedom"}]}`, Options{}, CodeConfigUnsupport},
		{"api", `{"api":{"tag":"api","listen":"127.0.0.1:1"},"outbounds":[{"protocol":"freedom"}]}`, Options{}, CodeConfigUnsupport},
		{"metrics", `{"metrics":{"tag":"m"},"outbounds":[{"protocol":"freedom"}]}`, Options{}, CodeConfigUnsupport},
		{"flow without tun", minimalConfig, Options{Tun: TunOptions{Mode: TunFlow}}, CodeConfigUnsupport},
		{"fd without tun", minimalConfig, Options{Tun: TunOptions{Mode: TunFD, FD: 5}}, CodeConfigUnsupport},
		{"two tuns", tunConfig(`,{"tag":"t2","protocol":"tun"}`), Options{Tun: TunOptions{Mode: TunFlow}}, CodeConfigUnsupport},
		{"oversized", `{"x":"` + strings.Repeat("a", MaxConfigBytes) + `"}`, Options{}, CodeInvalidArgument},
	}
	for _, c := range cases {
		opts := c.opts
		if err := opts.Normalize(); err != nil {
			t.Fatalf("%s: options: %v", c.name, err)
		}
		if _, err := prepareConfig([]byte(c.config), &opts); CodeOf(err) != c.want {
			t.Errorf("%s: got %v, want %s", c.name, err, c.want)
		}
	}
}

func TestPrepareConfigPolicies(t *testing.T) {
	opts := Options{Tun: TunOptions{Mode: TunFlow}, LogLevel: "info"}
	_ = opts.Normalize()
	cfg := `{"log":{"access":"/tmp/np-should-never-exist-access.log","error":"/tmp/np-should-never-exist-error.log","loglevel":"debug"},` + tunConfig(`,{"tag":"s","listen":"127.0.0.1","port":1080,"protocol":"socks"}`)[1:]
	p, err := prepareConfig([]byte(cfg), &opts)
	if err != nil {
		t.Fatal(err)
	}
	if p.tun == nil || p.tun.tag != "tun-in" || p.tun.mtu != 1400 || !p.tun.sniffing.Enabled {
		t.Fatalf("tun spec: %+v", p.tun)
	}
	if len(p.config.Inbound) != 1 || p.config.Inbound[0].Tag != "s" {
		t.Fatalf("tun inbound was not taken out: %d inbounds", len(p.config.Inbound))
	}
	if !p.summary.HasTun || len(p.summary.Inbounds) != 2 || len(p.summary.Outbounds) != 1 {
		t.Fatalf("summary: %+v", p.summary)
	}
	var sawLog, sawStats, sawPolicy bool
	for _, app := range p.config.App {
		msg, _ := app.GetInstance()
		text := strings.ToLower(app.GetType() + " " + strings.ReplaceAll(mustString(msg), " ", ""))
		switch app.GetType() {
		case "xray.app.log.Config":
			sawLog = true
			if strings.Contains(text, "np-should-never-exist") || strings.Contains(text, "file") {
				t.Errorf("log config still points at files: %s", text)
			}
		case "xray.app.stats.Config":
			sawStats = true
		case "xray.app.policy.Config":
			sawPolicy = true
			if !strings.Contains(text, "inbound_uplink:true") || !strings.Contains(text, "outbound_downlink:true") {
				t.Errorf("policy stats not enabled: %s", text)
			}
		}
	}
	if !sawLog || !sawStats || !sawPolicy {
		t.Fatalf("apps: log=%v stats=%v policy=%v", sawLog, sawStats, sawPolicy)
	}
}

func mustString(v any) string {
	if s, ok := v.(interface{ String() string }); ok {
		return s.String()
	}
	return ""
}

// The bridge reaches core components with a context built from an exported key type and a known value.
func TestInstanceContextKey(t *testing.T) {
	opts := Options{}
	_ = opts.Normalize()
	p, err := prepareConfig([]byte(minimalConfig), &opts)
	if err != nil {
		t.Fatal(err)
	}
	instance, nerr := core.New(p.config)
	if nerr != nil {
		t.Fatal(nerr)
	}
	defer instance.Close()
	if core.FromContext(instanceContext(instance)) != instance {
		t.Fatal("core.XrayKey(1) no longer carries the instance; instanceContext must be updated for this core version")
	}
}

func TestValidateDepth(t *testing.T) {
	e := New()
	s, err := e.Validate([]byte(tunConfig("")), Options{})
	if err != nil || s.Depth != "instance" || !s.HasTun {
		t.Fatalf("idle validate: %+v %v", s, err)
	}
	if e.State() != StateIdle || activeEngine.Load() != nil {
		t.Fatalf("validate left state %s", e.State())
	}
	// a routing rule to an outbound that does not exist passes the build but fails at instance construction or not at all;
	// either way Validate must not start anything
	mustStart(t, e, minimalConfig, Options{})
	s, err = e.Validate([]byte(minimalConfig), Options{})
	if err != nil || s.Depth != "build" {
		t.Fatalf("validate while running: %+v %v", s, err)
	}
	if e.State() != StateRunning {
		t.Fatalf("validate disturbed the running engine: %s", e.State())
	}
	if _, err := e.Validate([]byte(`{"outbounds":[{"protocol":"nope"}]}`), Options{}); CodeOf(err) != CodeConfigBuild {
		t.Fatalf("invalid while running: %v", err)
	}
}

func TestLifecycleStateMachine(t *testing.T) {
	e := New()
	if err := e.Stop(time.Second); err != nil {
		t.Fatalf("stop idle: %v", err)
	}
	if _, err := e.Stats(); CodeOf(err) != CodeNotRunning {
		t.Fatalf("stats idle: %v", err)
	}
	if _, err := e.TunWrite([]byte{1, 0, 0x45}); CodeOf(err) != CodeNotRunning {
		t.Fatalf("tun write idle: %v", err)
	}
	if err := e.Reload(context.Background(), []byte(minimalConfig)); CodeOf(err) != CodeInvalidState {
		t.Fatalf("reload idle: %v", err)
	}
	// invalid config leaves the engine idle and records the error
	if err := e.Start(context.Background(), []byte(`{"outbounds":[{"protocol":"nope"}]}`), Options{}); CodeOf(err) != CodeConfigBuild {
		t.Fatalf("start invalid: %v", err)
	}
	if h := e.Health(); h.State != "idle" || h.LastErrorCode != CodeConfigBuild || activeEngine.Load() != nil {
		t.Fatalf("after failed start: %+v", h)
	}
	// a port that is taken fails at core start, after the instance was created: must be torn down
	busy := startTCPEcho(t, "tcp", "127.0.0.1:0")
	cfg := `{"inbounds":[{"listen":"127.0.0.1","port":` + itoa(busy) + `,"protocol":"socks"}],"outbounds":[{"protocol":"freedom"}]}`
	if err := e.Start(context.Background(), []byte(cfg), Options{}); CodeOf(err) != CodeStartFailed {
		t.Fatalf("start on busy port: %v", err)
	}
	if e.State() != StateIdle {
		t.Fatalf("state after failed start: %s", e.State())
	}

	if err := e.Start(context.Background(), []byte(minimalConfig), Options{}); err != nil {
		t.Fatal(err)
	}
	if err := e.Start(context.Background(), []byte(minimalConfig), Options{}); CodeOf(err) != CodeInvalidState {
		t.Fatalf("double start: %v", err)
	}
	if err := New().Start(context.Background(), []byte(minimalConfig), Options{}); CodeOf(err) != CodeInvalidState {
		t.Fatalf("second engine in the process: %v", err)
	}
	if h := e.Health(); h.State != "running" || !h.CoreRunning || h.LastErrorCode != CodeOK || h.Generation != 3 {
		t.Fatalf("health: %+v", h)
	}
	// concurrent stops join one teardown
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := e.Stop(5 * time.Second); err != nil {
				t.Errorf("concurrent stop: %v", err)
			}
		}()
	}
	wg.Wait()
	if e.State() != StateIdle || activeEngine.Load() != nil {
		t.Fatalf("after stop: %s", e.State())
	}
}

func TestStartTimeoutCancelAndStopDuringStart(t *testing.T) {
	release := make(chan struct{})
	entered := make(chan struct{}, 4)
	testHookBringUp = func() { entered <- struct{}{}; <-release }
	defer func() { testHookBringUp = nil }()

	e := New()
	// 1. timeout: Start returns, the engine is not usable until the boot has unwound, then it is idle
	err := e.Start(context.Background(), []byte(minimalConfig), Options{StartTimeoutMs: 50})
	if CodeOf(err) != CodeTimeout {
		t.Fatalf("slow start: %v", err)
	}
	if st := e.State(); st != StateStarting {
		t.Fatalf("state during abandoned boot: %s", st)
	}
	if err := e.Start(context.Background(), []byte(minimalConfig), Options{}); CodeOf(err) != CodeInvalidState {
		t.Fatalf("start during abandoned boot: %v", err)
	}
	release <- struct{}{}
	waitState(t, e, StateIdle)
	if h := e.Health(); h.LastErrorCode != CodeTimeout {
		t.Fatalf("last error after timeout: %+v", h)
	}

	// 2. context cancellation
	ctx, cancel := context.WithCancel(context.Background())
	go func() { <-entered; <-entered; cancel() }()
	if err := e.Start(ctx, []byte(minimalConfig), Options{}); CodeOf(err) != CodeCancelled {
		t.Fatalf("cancelled start: %v", err)
	}
	release <- struct{}{}
	waitState(t, e, StateIdle)

	// 3. Stop during Start: Start reports cancelled, Stop waits for the teardown
	startErr := make(chan *Error, 1)
	go func() { startErr <- e.Start(context.Background(), []byte(minimalConfig), Options{}) }()
	<-entered
	stopErr := make(chan *Error, 1)
	go func() { stopErr <- e.Stop(5 * time.Second) }()
	time.Sleep(30 * time.Millisecond)
	release <- struct{}{}
	if err := <-startErr; CodeOf(err) != CodeCancelled {
		t.Fatalf("start interrupted by stop: %v", err)
	}
	if err := <-stopErr; err != nil {
		t.Fatalf("stop during start: %v", err)
	}
	if e.State() != StateIdle || activeEngine.Load() != nil {
		t.Fatalf("final state %s", e.State())
	}

	// 4. and the engine still works
	testHookBringUp = nil
	mustStart(t, e, minimalConfig, Options{})
}

func waitState(t *testing.T, e *Engine, want State) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for e.State() != want {
		if time.Now().After(deadline) {
			t.Fatalf("state %s, want %s", e.State(), want)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestReload(t *testing.T) {
	e := New()
	p1, p2 := freePort(t), freePort(t)
	socks := func(port int) string {
		return `{"inbounds":[{"tag":"socks","listen":"127.0.0.1","port":` + itoa(port) + `,"protocol":"socks"}],"outbounds":[{"protocol":"freedom","tag":"direct"}]}`
	}
	mustStart(t, e, socks(p1), Options{})
	waitTCP(t, p1)

	// invalid new config: nothing changes
	if err := e.Reload(context.Background(), []byte(`{"outbounds":[{"protocol":"nope"}]}`)); CodeOf(err) != CodeConfigBuild {
		t.Fatalf("reload invalid: %v", err)
	}
	if e.State() != StateRunning || e.Health().Generation != 1 {
		t.Fatalf("invalid reload disturbed the engine: %+v", e.Health())
	}
	// valid: the new listener replaces the old one
	if err := e.Reload(context.Background(), []byte(socks(p2))); err != nil {
		t.Fatal(err)
	}
	waitTCP(t, p2)
	// valid config that cannot start (port taken): the previous config comes back
	busy := startTCPEcho(t, "tcp", "127.0.0.1:0")
	err := e.Reload(context.Background(), []byte(socks(busy)))
	if CodeOf(err) != CodeStartFailed || !strings.Contains(err.Message, "previous config restored") {
		t.Fatalf("reload onto busy port: %v", err)
	}
	if e.State() != StateRunning {
		t.Fatalf("state after rollback: %s", e.State())
	}
	waitTCP(t, p2)
}

func TestMemoryOptionsAppliedAndRestored(t *testing.T) {
	before := ReadMemoryStats()
	e := New()
	if err := e.Start(context.Background(), []byte(minimalConfig), Options{Memory: MemoryOptions{LimitBytes: 64 << 20, GCPercent: 40, FreeOSMemoryIntervalMs: 20}}); err != nil {
		t.Fatal(err)
	}
	during := ReadMemoryStats()
	if during.Limit != 64<<20 || during.GCPercent != 40 {
		t.Errorf("during: limit=%d gc=%d", during.Limit, during.GCPercent)
	}
	if during.Goroutines == 0 || during.Mapped == 0 || during.HeapObjects == 0 {
		t.Errorf("empty memory stats: %+v", during)
	}
	time.Sleep(60 * time.Millisecond)
	if err := e.Stop(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	after := ReadMemoryStats()
	if after.Limit != before.Limit || after.GCPercent != before.GCPercent {
		t.Errorf("not restored: before limit=%d gc=%d, after limit=%d gc=%d", before.Limit, before.GCPercent, after.Limit, after.GCPercent)
	}
}

func TestLogsDeliveredAndEnvRestored(t *testing.T) {
	t.Setenv("xray.location.asset", "/np-test-previous")
	e := New()
	dir := t.TempDir()
	if err := e.Start(context.Background(), []byte(minimalConfig), Options{LogLevel: "debug", AssetDir: dir, LogQueueSize: 64}); err != nil {
		t.Fatal(err)
	}
	if got := getenv("xray.location.asset"); got != dir {
		t.Errorf("asset dir during run: %q", got)
	}
	recs := e.ReadLogs(nil, 100, time.Second)
	var started bool
	for _, r := range recs {
		if strings.Contains(r.Message, "started") && r.Level == "warning" && r.Kind == "general" && r.TimeUnixMs > 0 {
			started = true
		}
	}
	if !started {
		t.Errorf("no start record among %d records", len(recs))
	}
	if err := e.Stop(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	if got := getenv("xray.location.asset"); got != "/np-test-previous" {
		t.Errorf("asset dir after stop: %q", got)
	}
	if recs := e.ReadLogs(nil, 100, 0); len(recs) == 0 {
		t.Error("shutdown produced no readable records")
	}
	if h := e.Health(); h.LogProduced == 0 {
		t.Errorf("health: %+v", h)
	}
}
