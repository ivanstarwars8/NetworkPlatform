package engine

import (
	"sync"
	"sync/atomic"
	"time"

	applog "github.com/xtls/xray-core/app/log"
	"github.com/xtls/xray-core/common"
	xlog "github.com/xtls/xray-core/common/log"
)

// maxLogMessageBytes truncates a single record; a project limit that bounds the memory held by the queue.
const maxLogMessageBytes = 2048

// LogRecord is one structured log line of the core.
type LogRecord struct {
	// Seq increases by one per record produced, including dropped ones, so gaps reveal losses.
	Seq uint64 `json:"seq"`
	// TimeUnixMs is the wall-clock time the record was produced.
	TimeUnixMs int64 `json:"t"`
	// Level: "error", "warning", "info", "debug" for general messages, "" otherwise.
	Level string `json:"lvl,omitempty"`
	// Kind: "general", "access" or "dns".
	Kind    string `json:"kind"`
	Message string `json:"msg"`
}

// logQueue is a bounded ring of records. Producers never block: when the ring is full the oldest record is
// overwritten and counted as dropped.
type logQueue struct {
	mu      sync.Mutex
	ring    []LogRecord
	head    int // index of the oldest record
	count   int
	seq     uint64
	dropped uint64
	closed  bool
	notify  chan struct{} // capacity 1, signalled when the ring becomes non-empty or is closed
}

func newLogQueue(capacity int) *logQueue {
	return &logQueue{ring: make([]LogRecord, capacity), notify: make(chan struct{}, 1)}
}

func (q *logQueue) push(level, kind, message string) {
	if len(message) > maxLogMessageBytes {
		message = message[:maxLogMessageBytes]
	}
	now := time.Now().UnixMilli()
	q.mu.Lock()
	if q.closed {
		q.mu.Unlock()
		return
	}
	q.seq++
	rec := LogRecord{Seq: q.seq, TimeUnixMs: now, Level: level, Kind: kind, Message: message}
	if q.count == len(q.ring) {
		q.ring[q.head] = rec
		q.head = (q.head + 1) % len(q.ring)
		q.dropped++
	} else {
		q.ring[(q.head+q.count)%len(q.ring)] = rec
		q.count++
	}
	q.mu.Unlock()
	select {
	case q.notify <- struct{}{}:
	default:
	}
}

// pop moves up to max records into dst. It waits up to timeout for the first record; a zero timeout polls.
// ok is false once the queue is closed and drained.
func (q *logQueue) pop(dst []LogRecord, max int, timeout time.Duration) (out []LogRecord, ok bool) {
	var timer *time.Timer
	for {
		q.mu.Lock()
		if q.count > 0 {
			for q.count > 0 && len(dst) < max {
				dst = append(dst, q.ring[q.head])
				q.ring[q.head] = LogRecord{}
				q.head = (q.head + 1) % len(q.ring)
				q.count--
			}
			q.mu.Unlock()
			if timer != nil {
				timer.Stop()
			}
			return dst, true
		}
		closed := q.closed
		q.mu.Unlock()
		if closed {
			return dst, false
		}
		if timeout <= 0 {
			return dst, true
		}
		if timer == nil {
			timer = time.NewTimer(timeout)
		}
		select {
		case <-q.notify:
		case <-timer.C:
			return dst, true
		}
	}
}

func (q *logQueue) close() {
	q.mu.Lock()
	q.closed = true
	q.mu.Unlock()
	select {
	case q.notify <- struct{}{}:
	default:
	}
}

func (q *logQueue) stats() (produced, dropped uint64, pending int) {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.seq, q.dropped, q.count
}

// activeLogQueue is where the core's console log handlers deliver. The core keeps one process-wide log handler
// (common/log.RegisterHandler), so there is exactly one sink per process as well.
var activeLogQueue atomic.Pointer[logQueue]

// coreLogHandler is what the core's log app gets when it asks for a "console" writer. It never writes to
// stdout/stderr: inside an app extension nobody reads those.
type coreLogHandler struct{}

func (coreLogHandler) Handle(msg xlog.Message) {
	q := activeLogQueue.Load()
	if q == nil {
		return
	}
	inner := msg
	if w, ok := msg.(*applog.MaskedMsgWrapper); ok {
		inner = w.Message
	}
	level, kind := "", "general"
	switch m := inner.(type) {
	case *xlog.GeneralMessage:
		switch m.Severity {
		case xlog.Severity_Error:
			level = "error"
		case xlog.Severity_Warning:
			level = "warning"
		case xlog.Severity_Info:
			level = "info"
		case xlog.Severity_Debug:
			level = "debug"
		}
	case *xlog.AccessMessage:
		kind = "access"
	case *xlog.DNSLog:
		kind = "dns"
	}
	// No value of the configuration (keys, ids, server addresses) reaches the host's log.
	q.push(level, kind, activeRedactor.Load().redactLog(msg.String()))
}

func (coreLogHandler) Close() error { return nil }

func init() {
	// Replace the core's stdout writer for LogType_Console. The file writer stays registered but the bridge
	// rewrites every log config to console/none before it reaches the core (see prepareConfig).
	common.Must(applog.RegisterHandlerCreator(applog.LogType_Console,
		func(applog.LogType, applog.HandlerCreatorOptions) (xlog.Handler, error) {
			return coreLogHandler{}, nil
		}))
}
