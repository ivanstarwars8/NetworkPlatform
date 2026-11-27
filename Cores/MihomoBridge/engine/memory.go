package engine

import (
	"runtime/debug"
	"runtime/metrics"
	"time"
)

// MemoryStats is a snapshot of the Go runtime's memory accounting, read through runtime/metrics (no
// stop-the-world). All sizes are bytes. On Apple platforms the figure the OS enforces is the process
// phys_footprint, which the host has to read itself; Mapped is the Go runtime's share of it at most.
type MemoryStats struct {
	// Mapped is memory the runtime currently holds from the OS: total minus released.
	Mapped uint64 `json:"mapped"`
	// Total is all memory ever mapped by the runtime and not unmapped, including released pages.
	Total        uint64 `json:"total"`
	HeapObjects  uint64 `json:"heapObjects"` // bytes in live and not-yet-swept objects
	HeapLive     uint64 `json:"heapLive"`    // bytes marked live by the last GC
	HeapFree     uint64 `json:"heapFree"`    // free heap spans retained by the runtime
	HeapReleased uint64 `json:"heapReleased"`
	Stacks       uint64 `json:"stacks"`
	Goroutines   uint64 `json:"goroutines"`
	GCCycles     uint64 `json:"gcCycles"`
	// Limit and GCPercent are the settings in effect (math.MaxInt64 means no limit; -1 means the percent-based GC is off:
	// the runtime reports MaxUint64 for it, which wraps to -1).
	Limit     int64 `json:"limit"`
	GCPercent int64 `json:"gcPercent"`
}

var memorySampleNames = []string{
	"/memory/classes/total:bytes",
	"/memory/classes/heap/released:bytes",
	"/memory/classes/heap/objects:bytes",
	"/gc/heap/live:bytes",
	"/memory/classes/heap/free:bytes",
	"/memory/classes/heap/stacks:bytes",
	"/sched/goroutines:goroutines",
	"/gc/cycles/total:gc-cycles",
	"/gc/gomemlimit:bytes",
	"/gc/gogc:percent",
}

// ReadMemoryStats samples the runtime. It is cheap enough to call once per second.
func ReadMemoryStats() MemoryStats {
	samples := make([]metrics.Sample, len(memorySampleNames))
	for i, n := range memorySampleNames {
		samples[i].Name = n
	}
	metrics.Read(samples)
	u := func(i int) uint64 {
		if samples[i].Value.Kind() == metrics.KindUint64 {
			return samples[i].Value.Uint64()
		}
		return 0
	}
	m := MemoryStats{
		Total: u(0), HeapReleased: u(1), HeapObjects: u(2), HeapLive: u(3), HeapFree: u(4),
		Stacks: u(5), Goroutines: u(6), GCCycles: u(7), Limit: int64(u(8)), GCPercent: int64(u(9)),
	}
	m.Mapped = m.Total - m.HeapReleased
	return m
}

// memoryControl applies MemoryOptions to the process and can undo them.
type memoryControl struct {
	limitSet  bool
	prevLimit int64
	gcSet     bool
	prevGC    int
	stop      chan struct{}
	done      chan struct{}
}

func applyMemory(o MemoryOptions) *memoryControl {
	c := &memoryControl{}
	if o.LimitBytes > 0 {
		c.prevLimit = debug.SetMemoryLimit(o.LimitBytes)
		c.limitSet = true
	}
	if o.GCPercent != 0 {
		c.prevGC = debug.SetGCPercent(o.GCPercent)
		c.gcSet = true
	}
	if o.FreeOSMemoryIntervalMs > 0 {
		c.stop, c.done = make(chan struct{}), make(chan struct{})
		go func(interval time.Duration) {
			defer close(c.done)
			t := time.NewTicker(interval)
			defer t.Stop()
			for {
				select {
				case <-t.C:
					debug.FreeOSMemory()
				case <-c.stop:
					return
				}
			}
		}(time.Duration(o.FreeOSMemoryIntervalMs) * time.Millisecond)
	}
	return c
}

func (c *memoryControl) restore() {
	if c.stop != nil {
		close(c.stop)
		<-c.done
	}
	if c.gcSet {
		debug.SetGCPercent(c.prevGC)
	}
	if c.limitSet {
		debug.SetMemoryLimit(c.prevLimit)
	}
}
