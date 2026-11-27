package engine

import (
	"context"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/xtls/xray-core/common/platform"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/inbound"
	"github.com/xtls/xray-core/features/stats"

	// Registers every protocol, transport and app of the core, plus the JSON config loader.
	_ "github.com/xtls/xray-core/main/distro/all"
)

// State is the lifecycle state of an Engine.
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

// The core keeps process-wide state (system dialer, log handler, environment-driven settings), so only one
// engine may be active (not idle) per process. activeEngine enforces that across Engine values.
var activeEngine atomic.Pointer[Engine]

// Engine runs at most one core instance at a time. All methods are safe for concurrent use.
//
// Lifecycle:
//
//	idle --Start--> starting --ok--> running --Stop--> stopping --> idle
//	                   |  fail / timeout / Stop                       ^
//	                   +---------------> stopping --------------------+
//
// A Start that times out or is cancelled does not leave the engine half-started: the boot goroutine tears
// down whatever the core created once the core returns, and only then the engine becomes idle again.
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

// testHookBringUp, when set by a test, runs inside the boot goroutine before the core instance is created.
var testHookBringUp func()

// run is one start..stop cycle.
type run struct {
	engine *Engine
	config []byte
	opts   Options
	prep   *prepared

	// abort is set (under Engine.mu) to make a boot in progress tear itself down; abortCode is what Start reports.
	abort     bool
	abortCode Code

	booted  chan struct{} // closed when the boot finished either way
	bootErr *Error        // valid after booted
	gone    chan struct{} // closed when the run is fully torn down
	stopErr *Error        // valid after gone

	instance       *core.Instance
	cancelInstance context.CancelFunc
	device         *flowDevice
	memory         *memoryControl
	env            []envRestore
	startedAt      time.Time
}

type envRestore struct {
	key   string
	value string
	had   bool
}

func (r *run) setenv(key, value string) error {
	old, had := os.LookupEnv(key)
	if err := os.Setenv(key, value); err != nil {
		return err
	}
	r.env = append(r.env, envRestore{key, old, had})
	return nil
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

// Validate checks a configuration without starting anything. opts supplies the tun mode and the asset
// directory the config is meant to run with.
//
// When no engine is active in the process, the core also constructs an instance from the config (and closes
// it without starting), which catches errors that only surface at construction. When an engine is active,
// only the build step runs, because constructing a second instance would overwrite process-wide state of the
// running one; ConfigSummary.Depth tells which one happened.
func (e *Engine) Validate(config []byte, opts Options) (summary ConfigSummary, rerr *Error) {
	defer guard(&rerr)
	if err := opts.Normalize(); err != nil {
		return summary, err
	}
	// Claim the process if it is free. If it is not, an engine is running with its own environment and the
	// build below reads that environment.
	claimed := activeEngine.CompareAndSwap(nil, e)
	if claimed {
		e.mu.Lock()
		if e.state != StateIdle {
			// cannot happen: an active engine is never idle, and we hold the claim
			e.mu.Unlock()
			activeEngine.CompareAndSwap(e, nil)
			return summary, newError(CodeInternal, "claimed process while %s", e.state)
		}
		e.state = StateStarting // blocks Start while the trial instance exists
		e.mu.Unlock()
		defer func() {
			e.mu.Lock()
			e.state = StateIdle
			e.mu.Unlock()
			activeEngine.CompareAndSwap(e, nil)
		}()
		if opts.AssetDir != "" {
			tmp := &run{}
			if err := tmp.setenv(platform.AssetLocation, opts.AssetDir); err != nil {
				return summary, newError(CodeInvalidArgument, "assetDir: %v", err)
			}
			defer tmp.restoreEnv()
		}
	}
	prep, err := prepareConfig(config, &opts)
	if err != nil {
		return summary, err
	}
	summary = prep.summary
	if !claimed {
		return summary, nil
	}
	// No engine runs in the process: the trial's own log lines are redacted with this config's values.
	activeRedactor.Store(newRedactor(config))
	// A trial instance must never be able to open a system tun device, even though the core only does that on Start.
	trial := prep.config
	if prep.summary.HasTun && prep.tun == nil {
		trial.Inbound = withoutTun(trial.Inbound)
	}
	instance, nerr := core.New(trial)
	if nerr != nil {
		return summary, newRedactor(config).redactError(newError(CodeConfigBuild, "%v", nerr))
	}
	_ = instance.Close()
	summary.Depth = "instance"
	return summary, nil
}

func withoutTun(in []*core.InboundHandlerConfig) []*core.InboundHandlerConfig {
	var out []*core.InboundHandlerConfig
	for _, h := range in {
		if h.GetProxySettings().GetType() != tunConfigType {
			out = append(out, h)
		}
	}
	return out
}

// Start validates config and brings the core up. It returns when the core is running, failed, or the start
// timeout elapsed. ctx cancellation aborts the wait the same way a timeout does (CodeCancelled).
func (e *Engine) Start(ctx context.Context, config []byte, opts Options) (rerr *Error) {
	defer guard(&rerr)
	if err := opts.Normalize(); err != nil {
		return err
	}
	if ctx == nil {
		ctx = context.Background()
	}
	r := &run{
		engine: e, config: append([]byte(nil), config...), opts: opts,
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

// abortBoot marks a boot in progress for teardown. If the boot won the race and finished, its result stands.
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

// boot runs on its own goroutine and owns every state transition out of StateStarting.
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

// bringUp creates and starts the core instance. Whatever it creates is recorded in r for tearDown.
func (r *run) bringUp() (rerr *Error) {
	red := newRedactor(r.config)
	// Declared before guard so that it runs after it: a recovered panic is redacted as well.
	defer func() { rerr = red.redactError(rerr) }()
	defer guard(&rerr)
	opts := &r.opts
	activeRedactor.Store(red)

	if opts.AssetDir != "" {
		if err := r.setenv(platform.AssetLocation, opts.AssetDir); err != nil {
			return newError(CodeInvalidArgument, "assetDir: %v", err)
		}
	}
	prep, perr := prepareConfig(r.config, opts)
	if perr != nil {
		return perr
	}
	r.prep = prep
	if testHookBringUp != nil {
		testHookBringUp()
	}
	if prep.summary.HasTun && opts.Tun.Mode == TunNone {
		return newError(CodeConfigUnsupport, "config has a tun inbound but tun.mode is not set")
	}
	if opts.Tun.Mode == TunFD {
		if err := r.setenv(platform.TunFdKey, strconv.Itoa(opts.Tun.FD)); err != nil {
			return newError(CodeInvalidArgument, "tun fd: %v", err)
		}
	}

	if q := r.engine.logs.Load(); len(q.ring) != opts.LogQueueSize {
		r.engine.logs.Store(newLogQueue(opts.LogQueueSize))
		q.close()
	}
	activeLogQueue.Store(r.engine.logs.Load())
	r.memory = applyMemory(opts.Memory)

	// The instance context is the parent of every session the core's inbounds start. instance.Close() closes
	// listeners and features but leaves established sessions to their idle timers; cancelling this context
	// in tearDown is what ends them (verified by TestStartStopCycles).
	ictx, cancel := context.WithCancel(context.Background())
	r.cancelInstance = cancel
	instance, err := core.NewWithContext(ictx, prep.config)
	if err != nil {
		return newError(CodeStartFailed, "create instance: %v", err)
	}
	r.instance = instance

	if prep.tun != nil {
		r.device = newFlowDevice(opts.Tun.OutQueueBytes, opts.Tun.MaxFlows)
		ctx := instanceContext(instance)
		h, err := newFlowInbound(ctx, instance, prep.tun, r.device)
		if err != nil {
			return newError(CodeStartFailed, "tun inbound: %v", err)
		}
		manager, _ := instance.GetFeature(inbound.ManagerType()).(inbound.Manager)
		if manager == nil {
			return newError(CodeStartFailed, "inbound manager is not registered")
		}
		// Added before Start: the manager starts it together with the config's own inbounds.
		if err := manager.AddHandler(ctx, h); err != nil {
			return newError(CodeStartFailed, "tun inbound: %v", err)
		}
	}

	if err := instance.Start(); err != nil {
		return newError(CodeStartFailed, "%v", err)
	}
	return nil
}

func (r *run) restoreEnv() {
	for i := len(r.env) - 1; i >= 0; i-- {
		if v := r.env[i]; v.had {
			_ = os.Setenv(v.key, v.value)
		} else {
			_ = os.Unsetenv(v.key)
		}
	}
	r.env = nil
}

// tearDown releases everything bringUp created, in reverse order. It is called exactly once per run.
func (r *run) tearDown() {
	func() {
		defer guard(&r.stopErr)
		if r.instance != nil {
			if err := r.instance.Close(); err != nil {
				r.stopErr = newError(CodeStopFailed, "%v", err)
			}
		}
	}()
	if r.cancelInstance != nil {
		r.cancelInstance()
	}
	if r.device != nil {
		// Wakes a host thread blocked in TunRead; it gets CodeClosed.
		_ = r.device.Close()
	}
	if r.memory != nil {
		r.memory.restore()
	}
	r.restoreEnv()
	// The log queue outlives the run on purpose: the lines of the shutdown stay readable.
}

// Stop shuts the core down and waits up to timeout (0 = the stop timeout of the run's options) for the
// teardown to finish. It is idempotent: stopping an idle engine succeeds, and concurrent Stops join the same
// teardown. Stop during a Start aborts that Start.
//
// On CodeTimeout the teardown keeps going in the background and the engine stays in StateStopping until it
// finishes; the host may then decide to end the process.
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
			// a Validate trial is in progress; it finishes on its own
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

// Reload replaces the running configuration. The core cannot swap a configuration in place (core.Instance
// has no reload), so this is: validate the new config (on failure nothing changes) -> Stop -> Start(new).
// If the new config fails to start, the previous one is started again and the returned error says so.
// Connections do not survive a reload, and in TunFlow mode the packet device is replaced (TunRead returns
// CodeClosed once). Options, including the tun mode and fd, are those of the running engine.
func (e *Engine) Reload(ctx context.Context, config []byte) (rerr *Error) {
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
	if _, err := prepareConfig(config, &opts); err != nil {
		return err
	}
	if err := e.Stop(0); err != nil {
		return newError(err.Code, "reload: stopping the previous config: %s", err.Message)
	}
	err := e.Start(ctx, config, opts)
	if err == nil {
		return nil
	}
	if back := e.Start(context.Background(), old.config, opts); back != nil {
		return newError(err.Code, "reload failed (%s) and the previous config did not restart (%s); engine is %s",
			err.Message, back.Message, e.State())
	}
	return newError(err.Code, "reload failed, previous config restored: %s", err.Message)
}

// current returns the run if the engine is running.
func (e *Engine) current() *run {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.state != StateRunning {
		return nil
	}
	return e.run
}

// TrafficCounter is the traffic of one inbound or outbound since the engine started, in bytes.
type TrafficCounter struct {
	Tag      string `json:"tag"`
	Uplink   int64  `json:"uplink"`
	Downlink int64  `json:"downlink"`
}

// Stats is a snapshot of the core's traffic counters.
type Stats struct {
	UptimeMs  int64            `json:"uptimeMs"`
	Inbounds  []TrafficCounter `json:"inbounds"`
	Outbounds []TrafficCounter `json:"outbounds"`
	Tun       *TunCounters     `json:"tun,omitempty"`
}

// Stats reads the counters of the core's stats feature in-process; no API listener is involved.
func (e *Engine) Stats() (st Stats, rerr *Error) {
	defer guard(&rerr)
	r := e.current()
	if r == nil {
		return st, newError(CodeNotRunning, "engine is not running")
	}
	st.UptimeMs = time.Since(r.startedAt).Milliseconds()
	if r.device != nil {
		c := r.device.counters()
		st.Tun = &c
	}
	manager, _ := r.instance.GetFeature(stats.ManagerType()).(stats.Manager)
	if manager == nil {
		return st, nil
	}
	in, out := map[string]*TrafficCounter{}, map[string]*TrafficCounter{}
	manager.VisitCounters(func(name string, c stats.Counter) bool {
		// "<inbound|outbound>>>><tag>>>>traffic>>><uplink|downlink>"
		parts := strings.Split(name, ">>>")
		if len(parts) != 4 || parts[2] != "traffic" {
			return true
		}
		var m map[string]*TrafficCounter
		switch parts[0] {
		case "inbound":
			m = in
		case "outbound":
			m = out
		default:
			return true
		}
		tc := m[parts[1]]
		if tc == nil {
			tc = &TrafficCounter{Tag: parts[1]}
			m[parts[1]] = tc
		}
		switch parts[3] {
		case "uplink":
			tc.Uplink = c.Value()
		case "downlink":
			tc.Downlink = c.Value()
		}
		return true
	})
	st.Inbounds, st.Outbounds = sortedCounters(in), sortedCounters(out)
	return st, nil
}

// Health describes the engine as a whole. It never fails and may be called in any state.
type Health struct {
	State      string `json:"state"`
	Generation uint64 `json:"generation"` // number of Starts attempted
	UptimeMs   int64  `json:"uptimeMs"`
	// CoreRunning is the core instance's own running flag; false while not running.
	CoreRunning bool `json:"coreRunning"`
	// LastErrorCode / LastError describe the most recent failed start or stop; cleared by a successful start.
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
		h.CoreRunning = e.run.instance.IsRunning()
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
		// the queue was replaced by a Start with a different size; continue on the new one
		dst = out
	}
}

// TunWrite hands a batch of IP packets (see the frame format in packetqueue.go) to the core and returns the
// number of packets consumed. The batch is not retained; the core may modify it in place.
func (e *Engine) TunWrite(batch []byte) (int, *Error) {
	r := e.current()
	if r == nil || r.device == nil {
		return 0, newError(CodeNotRunning, "no packet device")
	}
	return r.device.writeBatch(batch)
}

// TunRead fills dst with as many queued packets as fit and returns the number of bytes written. It waits up
// to timeout for the first packet (0 polls, negative waits indefinitely). It returns CodeClosed when the
// engine stops while waiting, and CodeNotRunning when there is no packet device.
func (e *Engine) TunRead(dst []byte, timeout time.Duration) (int, *Error) {
	r := e.current()
	if r == nil || r.device == nil {
		return 0, newError(CodeNotRunning, "no packet device")
	}
	return r.device.out.read(dst, timeout)
}

// CoreVersion returns the version string of the linked core.
func CoreVersion() string { return core.Version() }
