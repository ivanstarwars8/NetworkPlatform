package engine

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"sync/atomic"
	"time"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// State is the lifecycle state of an Engine. Values match the Xray bridge.
type State int32

const (
	StateIdle     State = 0
	StateStarting State = 1
	StateRunning  State = 2
	StateStopping State = 3
)

func (s State) String() string {
	switch s {
	case StateIdle:
		return "idle"
	case StateStarting:
		return "starting"
	case StateRunning:
		return "running"
	case StateStopping:
		return "stopping"
	}
	return "unknown"
}

// CoreVersion is the pinned Mihomo release (go.mod); C.Version is only set by the core's own build flags.
const CoreVersion = "v1.19.34"

// The core is a set of process-wide singletons (tunnel, resolver, statistic manager, listeners, dialer
// hooks), so at most one engine may be active per process.
var activeEngine atomic.Pointer[Engine]

// Engine runs the core for at most one configuration at a time. All methods are safe for concurrent use.
//
// Lifecycle (same as the Xray bridge):
//
//	idle --Start--> starting --ok--> running --Stop--> stopping --> idle
//	                   |  fail / timeout / Stop                       ^
//	                   +---------------> stopping --------------------+
//
// What Stop releases and what it cannot: the core has no shutdown that returns it to its initial state
// (hub/executor.Shutdown only closes the TUN listener). Stop therefore
//
//  1. suspends the tunnel (new inbound connections are rejected),
//  2. closes the bridge's packet stack and device,
//  3. closes every tracked connection (statistic.DefaultManager),
//  4. closes the proxy and rule providers of the configuration (their health-check and update timers),
//  5. closes the inbound listeners, then applies an empty configuration (mode direct, no proxies, rules,
//     listeners, DNS, tun), which drops the previous proxies, rules, resolvers and DNS server,
//  6. suspends the tunnel again (ApplyConfig resumes it) and restores the Go memory settings.
//
// What remains for the life of the process: the core's package-level goroutines started by init() and on
// first use (statistic ticker, log observable, the tunnel's TCP/UDP worker pools, the bridge's own log
// subscriber), the cache.db handle in the home directory once opened, process-wide settings (home directory,
// dialer defaults, keep-alive, geodata loader choice) and geodata files loaded into memory. Whether memory
// is otherwise returned is measured by TestStartStopCycles.
type Engine struct {
	mu         sync.Mutex
	state      State
	run        *run
	generation uint64
	lastErr    *Error

	reloadMu sync.Mutex

	logs atomic.Pointer[logQueue]
}

// New returns an idle engine.
func New() *Engine {
	e := &Engine{}
	e.logs.Store(newLogQueue(512))
	return e
}

type run struct {
	engine *Engine
	config []byte
	opts   Options
	prep   *prepared

	abort     bool
	abortCode Code

	booted  chan struct{}
	bootErr *Error
	gone    chan struct{}
	stopErr *Error

	applied   bool // the configuration reached the core
	flow      *flowListener
	device    *flowDevice
	memory    *memoryControl
	idle      *idleSweeper
	startedAt time.Time
}

// State returns the current lifecycle state.
func (e *Engine) State() State {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.state
}

func guard(dst **Error) {
	if r := recover(); r != nil {
		buf := make([]byte, 2048)
		buf = buf[:runtime.Stack(buf, false)]
		*dst = newError(CodeInternal, "panic: %v\n%s", r, buf)
	}
}

func homeDir(opts *Options) string {
	if opts.HomeDir != "" {
		return opts.HomeDir
	}
	return filepath.Join(os.TempDir(), "np-mihomo")
}

func setHome(opts *Options) *Error {
	dir := homeDir(opts)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return newError(CodeInvalidArgument, "homeDir: %v", err)
	}
	C.SetHomeDir(dir)
	return nil
}

// Validate parses a configuration without applying it. It is refused while an engine is active: parsing
// temporarily applies the config's general section to the running core (config.Parse,
// temporaryUpdateGeneral) and sets the process-wide home directory.
func (e *Engine) Validate(data []byte, opts Options) (summary ConfigSummary, rerr *Error) {
	defer guard(&rerr)
	if err := opts.Normalize(); err != nil {
		return summary, err
	}
	if !activeEngine.CompareAndSwap(nil, e) {
		return summary, newError(CodeInvalidState, "validate while an engine is active: parsing would change the running core's settings")
	}
	e.mu.Lock()
	if e.state != StateIdle {
		e.mu.Unlock()
		activeEngine.CompareAndSwap(e, nil)
		return summary, newError(CodeInternal, "claimed process while %s", e.state)
	}
	e.state = StateStarting
	e.mu.Unlock()
	defer func() {
		e.mu.Lock()
		e.state = StateIdle
		e.mu.Unlock()
		activeEngine.CompareAndSwap(e, nil)
	}()
	if err := setHome(&opts); err != nil {
		return summary, err
	}
	prep, err := prepareConfig(data, &opts)
	if err != nil {
		return summary, err
	}
	return prep.summary, nil
}

// Start parses config and applies it to the core. It returns when the core runs, failed, or the start
// timeout elapsed. ctx cancellation aborts the wait the same way a timeout does (CodeCancelled).
func (e *Engine) Start(ctx context.Context, data []byte, opts Options) (rerr *Error) {
	defer guard(&rerr)
	if err := opts.Normalize(); err != nil {
		return err
	}
	if ctx == nil {
		ctx = context.Background()
	}
	r := &run{
		engine: e, config: append([]byte(nil), data...), opts: opts,
		booted: make(chan struct{}), gone: make(chan struct{}),
	}
	e.mu.Lock()
	if e.state != StateIdle {
		st := e.state
		e.mu.Unlock()
		return newError(CodeInvalidState, "start while %s", st)
	}
	if !activeEngine.CompareAndSwap(nil, e) {
		e.mu.Unlock()
		return newError(CodeInvalidState, "another engine is active in this process")
	}
	e.state = StateStarting
	e.run = r
	e.generation++
	e.mu.Unlock()

	go r.boot()

	timer := time.NewTimer(opts.startTimeout())
	defer timer.Stop()
	select {
	case <-r.booted:
		return r.bootErr
	case <-timer.C:
		return e.abortBoot(r, CodeTimeout, fmt.Sprintf("start exceeded %s", opts.startTimeout()))
	case <-ctx.Done():
		return e.abortBoot(r, CodeCancelled, "start cancelled: "+ctx.Err().Error())
	}
}

func (e *Engine) abortBoot(r *run, code Code, message string) *Error {
	e.mu.Lock()
	if e.run == r && e.state == StateStarting {
		r.abort, r.abortCode = true, code
		e.mu.Unlock()
		return newError(code, "%s", message)
	}
	e.mu.Unlock()
	<-r.booted
	return r.bootErr
}

func (r *run) boot() {
	e := r.engine
	err := r.bringUp()

	e.mu.Lock()
	if err == nil && !r.abort {
		r.startedAt = time.Now()
		e.state = StateRunning
		e.lastErr = nil
		e.mu.Unlock()
		close(r.booted)
		return
	}
	if err == nil {
		err = newError(r.abortCode, "start aborted")
	}
	e.state = StateStopping
	e.mu.Unlock()

	r.tearDown()

	e.mu.Lock()
	e.state = StateIdle
	e.run = nil
	e.lastErr = err
	e.mu.Unlock()
	activeEngine.CompareAndSwap(e, nil)
	r.bootErr = err
	close(r.booted)
	close(r.gone)
}

func (r *run) bringUp() (rerr *Error) {
	defer guard(&rerr)
	opts := &r.opts
	if err := setHome(opts); err != nil {
		return err
	}
	prep, perr := prepareConfig(r.config, opts)
	if perr != nil {
		return perr
	}
	r.prep = prep
	if testHookBringUp != nil {
		testHookBringUp()
	}

	if q := r.engine.logs.Load(); len(q.ring) != opts.LogQueueSize {
		r.engine.logs.Store(newLogQueue(opts.LogQueueSize))
		q.close()
	}
	activeLogQueue.Store(r.engine.logs.Load())
	logThreshold.Store(int32(prep.cfg.General.LogLevel))
	r.memory = applyMemory(opts.Memory)
	statistic.DefaultManager.ResetStatistic()

	// ApplyConfig reports nothing: failures of listeners, DNS and providers are only logged. The listener
	// ports are checked below; provider failures stay in the log.
	r.applied = true
	executor.ApplyConfig(prep.cfg, true)

	g := prep.cfg.General
	ports := listener.GetPorts()
	if g.SocksPort != 0 && ports.SocksPort != g.SocksPort {
		return newError(CodeStartFailed, "socks-port %d did not open (see log)", g.SocksPort)
	}
	if g.MixedPort != 0 && ports.MixedPort != g.MixedPort {
		return newError(CodeStartFailed, "mixed-port %d did not open (see log)", g.MixedPort)
	}
	if g.Port != 0 && ports.Port != g.Port {
		return newError(CodeStartFailed, "port %d did not open (see log)", g.Port)
	}

	if r.idle = newIdleSweeper(time.Duration(opts.TCPIdleTimeoutMs)*time.Millisecond,
		time.Duration(opts.UDPIdleTimeoutMs)*time.Millisecond); r.idle != nil {
		r.idle.start()
	}

	if prep.tun != nil {
		r.device = newFlowDevice(int(prep.tun.mtu), opts.Tun.InQueueBytes, opts.Tun.OutQueueBytes, opts.Tun.MaxFlows)
		l, err := startFlowListener(prep.tun, r.device)
		if err != nil {
			return newError(CodeStartFailed, "packet stack: %v", err)
		}
		r.flow = l
	}
	return nil
}

// tearDown releases what bringUp created; see the Engine comment for what can and cannot be released.
func (r *run) tearDown() {
	defer guard(&r.stopErr)
	if r.idle != nil {
		r.idle.close()
	}
	tunnel.OnSuspend()
	if r.flow != nil {
		_ = r.flow.Close()
	} else if r.device != nil {
		_ = r.device.Close()
	}
	if r.applied {
		statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
			_ = c.Close()
			return true
		})
		for _, p := range tunnel.Providers() {
			if c, ok := p.(io.Closer); ok {
				_ = c.Close()
			}
		}
		for _, p := range tunnel.RuleProviders() {
			if c, ok := p.(io.Closer); ok {
				_ = c.Close()
			}
		}
		// Close the inbound listeners before ApplyConfig: it rewrites process-wide inbound settings (allowed
		// IPs, auth, ...) that the accept loops of live listeners read without synchronisation, and only then
		// closes those listeners (a data race inside the core, seen under -race).
		closeListeners()
		empty, err := emptyConfig(r.prep.cfg.General.LogLevel)
		if err != nil {
			r.stopErr = newError(CodeStopFailed, "empty config: %v", err)
		} else {
			executor.ApplyConfig(empty, true)
		}
		tunnel.OnSuspend()
	}
	if r.memory != nil {
		r.memory.restore()
	}
	// The log queue outlives the run on purpose: the lines of the shutdown stay readable.
}

func closeListeners() {
	t := tunnel.Tunnel
	listener.ReCreateHTTP(0, t)
	listener.ReCreateSocks(0, t)
	listener.ReCreateMixed(0, t)
	listener.ReCreateRedir(0, t)
	listener.ReCreateTProxy(0, t)
	listener.ReCreateShadowSocks("", t)
	listener.ReCreateVmess("", t)
	listener.ReCreateTuic(LC.TuicServer{}, t)
	listener.PatchInboundListeners(map[string]C.InboundListener{}, t, true)
	listener.PatchTunnel(nil, t)
}

// Stop shuts the configuration down and waits up to timeout (0 = the stop timeout of the run's options) for
// the teardown. Idempotent; concurrent Stops join; Stop during Start aborts it. On CodeTimeout the teardown
// continues in the background and the engine stays in StateStopping until it finishes.
func (e *Engine) Stop(timeout time.Duration) (rerr *Error) {
	defer guard(&rerr)
	e.mu.Lock()
	r := e.run
	switch e.state {
	case StateIdle:
		e.mu.Unlock()
		return nil
	case StateStarting:
		if r == nil {
			e.mu.Unlock()
			return newError(CodeInvalidState, "validation in progress")
		}
		if !r.abort {
			r.abort, r.abortCode = true, CodeCancelled
		}
	case StateRunning:
		e.state = StateStopping
		go func() {
			r.tearDown()
			e.mu.Lock()
			e.state = StateIdle
			e.run = nil
			if r.stopErr != nil {
				e.lastErr = r.stopErr
			}
			e.mu.Unlock()
			activeEngine.CompareAndSwap(e, nil)
			close(r.gone)
		}()
	case StateStopping:
	}
	if timeout <= 0 {
		timeout = r.opts.stopTimeout()
	}
	e.mu.Unlock()

	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-r.gone:
		return r.stopErr
	case <-timer.C:
		return newError(CodeTimeout, "stop exceeded %s; teardown continues", timeout)
	}
}

// Reload replaces the running configuration by validate -> Stop -> Start, with the previous configuration
// restarted if the new one fails (same contract as the Xray bridge). The core could apply a new config in
// place (ApplyConfig), but connections and the packet device would then outlive a configuration change in
// ways the Xray bridge does not have; keeping one contract for both engines is the reason. Parsing the new
// config briefly applies its general section to the running core (see Validate).
func (e *Engine) Reload(ctx context.Context, data []byte) (rerr *Error) {
	defer guard(&rerr)
	e.reloadMu.Lock()
	defer e.reloadMu.Unlock()

	e.mu.Lock()
	if e.state != StateRunning {
		st := e.state
		e.mu.Unlock()
		return newError(CodeInvalidState, "reload while %s", st)
	}
	old := e.run
	e.mu.Unlock()

	opts := old.opts
	if _, err := prepareConfig(data, &opts); err != nil {
		return err
	}
	if err := e.Stop(0); err != nil {
		return newError(err.Code, "reload: stopping the previous config: %s", err.Message)
	}
	err := e.Start(ctx, data, opts)
	if err == nil {
		return nil
	}
	if back := e.Start(context.Background(), old.config, opts); back != nil {
		return newError(err.Code, "reload failed (%s) and the previous config did not restart (%s); engine is %s",
			err.Message, back.Message, e.State())
	}
	return newError(err.Code, "reload failed, previous config restored: %s", err.Message)
}

func (e *Engine) current() *run {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.state != StateRunning {
		return nil
	}
	return e.run
}

// TrafficCounter has the same shape as the Xray bridge's counter.
type TrafficCounter struct {
	Tag      string `json:"tag"`
	Uplink   int64  `json:"uplink"`
	Downlink int64  `json:"downlink"`
}

// Stats is a snapshot of the core's traffic accounting. The core counts per connection, not per inbound or
// outbound, so instead of the Xray bridge's inbounds/outbounds lists there is one total since Start
// (statistic.DefaultManager, reset on Start) and the number of open connections.
type Stats struct {
	UptimeMs    int64          `json:"uptimeMs"`
	Total       TrafficCounter `json:"total"`
	Connections int            `json:"connections"`
	// Connections the bridge closed for tcpIdleTimeoutMs / udpIdleTimeoutMs since Start.
	IdleClosedTCP uint64       `json:"idleClosedTcp"`
	IdleClosedUDP uint64       `json:"idleClosedUdp"`
	Tun           *TunCounters `json:"tun,omitempty"`
}

func (e *Engine) Stats() (st Stats, rerr *Error) {
	defer guard(&rerr)
	r := e.current()
	if r == nil {
		return st, newError(CodeNotRunning, "engine is not running")
	}
	st.UptimeMs = time.Since(r.startedAt).Milliseconds()
	up, down := statistic.DefaultManager.Total()
	st.Total = TrafficCounter{Tag: "total", Uplink: up, Downlink: down}
	statistic.DefaultManager.Range(func(statistic.Tracker) bool { st.Connections++; return true })
	if r.idle != nil {
		st.IdleClosedTCP, st.IdleClosedUDP = r.idle.closedTCP.Load(), r.idle.closedUDP.Load()
	}
	if r.device != nil {
		c := r.device.counters()
		st.Tun = &c
	}
	return st, nil
}

// Health has the same shape as the Xray bridge's.
type Health struct {
	State         string       `json:"state"`
	Generation    uint64       `json:"generation"`
	UptimeMs      int64        `json:"uptimeMs"`
	CoreRunning   bool         `json:"coreRunning"` // the core's tunnel status is "running"
	LastErrorCode Code         `json:"lastErrorCode"`
	LastError     string       `json:"lastError,omitempty"`
	Goroutines    int          `json:"goroutines"`
	LogProduced   uint64       `json:"logProduced"`
	LogDropped    uint64       `json:"logDropped"`
	LogPending    int          `json:"logPending"`
	Tun           *TunCounters `json:"tun,omitempty"`
}

func (e *Engine) Health() Health {
	h := Health{Goroutines: runtime.NumGoroutine()}
	h.LogProduced, h.LogDropped, h.LogPending = e.logs.Load().stats()
	e.mu.Lock()
	defer e.mu.Unlock()
	h.State, h.Generation = e.state.String(), e.generation
	if e.lastErr != nil {
		h.LastErrorCode, h.LastError = e.lastErr.Code, e.lastErr.Message
	}
	if e.state == StateRunning && e.run != nil {
		h.UptimeMs = time.Since(e.run.startedAt).Milliseconds()
		h.CoreRunning = tunnel.Status() == tunnel.Running
		if e.run.device != nil {
			c := e.run.device.counters()
			h.Tun = &c
		}
	}
	return h
}

// ReadLogs appends up to max pending log records to dst, waiting up to timeout for the first one.
func (e *Engine) ReadLogs(dst []LogRecord, max int, timeout time.Duration) []LogRecord {
	for {
		q := e.logs.Load()
		out, ok := q.pop(dst, max, timeout)
		if ok || e.logs.Load() == q {
			return out
		}
		dst = out
	}
}

// TunWrite hands a batch of IP packets (frame format in packetqueue.go) to the core and returns the number
// of packets consumed. Packets are copied into the inbound queue; the batch is not retained.
func (e *Engine) TunWrite(batch []byte) (int, *Error) {
	r := e.current()
	if r == nil || r.device == nil {
		return 0, newError(CodeNotRunning, "no packet device")
	}
	return r.device.writeBatch(batch)
}

// TunRead fills dst with queued packets; see the Xray bridge for the timeout semantics.
func (e *Engine) TunRead(dst []byte, timeout time.Duration) (int, *Error) {
	r := e.current()
	if r == nil || r.device == nil {
		return 0, newError(CodeNotRunning, "no packet device")
	}
	return r.device.out.read(dst, timeout)
}

// testHookBringUp, when set by a test, runs inside the boot goroutine after parsing.
var testHookBringUp func()
