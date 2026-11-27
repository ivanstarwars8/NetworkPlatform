package engine

import (
	"io"
	"sync"
	"sync/atomic"
	"time"

	mlog "github.com/metacubex/mihomo/log"
	"github.com/sirupsen/logrus"
)

// maxLogMessageBytes truncates a single record; a project limit that bounds the memory held by the queue.
const maxLogMessageBytes = 2048

// LogRecord is one structured log line of the core. Same shape as the Xray bridge's record.
type LogRecord struct {
	// Seq increases by one per record produced, including dropped ones, so gaps reveal losses.
	Seq uint64 `json:"seq"`
	// TimeUnixMs is the wall-clock time the record was produced.
	TimeUnixMs int64 `json:"t"`
	// Level: "error", "warning", "info", "debug".
	Level string `json:"lvl,omitempty"`
	// Kind is always "general": the core has no separate access or DNS log stream.
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

// activeLogQueue is where the core's log events are delivered. The core has one process-wide log channel
// (mihomo/log), so there is exactly one sink per process as well.
var activeLogQueue atomic.Pointer[logQueue]

// logThreshold is the lowest mihomo LogLevel delivered (DEBUG=0 ... SILENT=4). The core's own level variable
// is written without synchronisation by ApplyConfig, so the bridge keeps its own copy.
var logThreshold atomic.Int32

func init() {
	logThreshold.Store(int32(mlog.INFO))
	// The core prints every event through logrus to stdout as well; inside an app extension nobody reads
	// stdout, so that copy is discarded. The structured events are taken from the core's subscription channel.
	logrus.SetOutput(io.Discard)
	sub := mlog.Subscribe()
	// One process-wide goroutine for the lifetime of the process. It must keep draining: the core's
	// observable blocks its producer once a subscriber's 200-event buffer is full.
	go func() {
		for ev := range sub {
			if int32(ev.LogLevel) < logThreshold.Load() {
				continue
			}
			q := activeLogQueue.Load()
			if q == nil {
				continue
			}
			q.push(levelName(ev.LogLevel), "general", ev.Payload)
		}
	}()
}

func levelName(l mlog.LogLevel) string {
	switch l {
	case mlog.DEBUG:
		return "debug"
	case mlog.INFO:
		return "info"
	case mlog.WARNING:
		return "warning"
	case mlog.ERROR:
		return "error"
	}
	return ""
}

// parseLevel maps the option names onto the core's levels ("none" = silent).
func parseLevel(s string) (mlog.LogLevel, bool) {
	switch s {
	case "debug":
		return mlog.DEBUG, true
	case "info":
		return mlog.INFO, true
	case "warning":
		return mlog.WARNING, true
	case "error":
		return mlog.ERROR, true
	case "none", "silent":
		return mlog.SILENT, true
	}
	return mlog.INFO, false
}
