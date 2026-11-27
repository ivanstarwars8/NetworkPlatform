//go:build linux

package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	_ "net/http/pprof" // profiles on the control listener (127.0.0.1 inside the lab namespace)
	"net/netip"
	"os"
	"os/signal"
	"runtime"
	"runtime/metrics"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/sys/unix"

	"networkplatform/bridge/engine"
)

// pumpCounters describe the host side of TunFlow mode: what the Linux stand-in for NEPacketTunnelFlow moved.
type pumpCounters struct {
	// kernel tun -> engine (readPackets -> npb_tun_write)
	InPackets   uint64 `json:"inPackets"`
	InBytes     uint64 `json:"inBytes"`
	InBatches   uint64 `json:"inBatches"`
	InMaxPacket uint64 `json:"inMaxPacket"`
	InFragments uint64 `json:"inFragments"`
	InDF        uint64 `json:"inDF"`
	InTruncated uint64 `json:"inTruncated"`
	InWriteErrs uint64 `json:"inWriteErrs"`
	// LoopPackets counts packets on the tun addressed to one of -loop-addrs: the core's own outbound
	// connections re-entering the tunnel. They are dropped when -drop-loop is set.
	LoopPackets uint64 `json:"loopPackets"`
	// engine -> kernel tun (npb_tun_read -> writePackets)
	OutPackets   uint64 `json:"outPackets"`
	OutBytes     uint64 `json:"outBytes"`
	OutBatches   uint64 `json:"outBatches"`
	OutMaxPacket uint64 `json:"outMaxPacket"`
	OutFragments uint64 `json:"outFragments"`
	OutWriteErrs uint64 `json:"outWriteErrs"`
	// time spent in the engine calls and in the kernel tun syscalls, nanoseconds
	InEngineNs   uint64 `json:"inEngineNs"`   // npb_tun_write
	OutEngineNs  uint64 `json:"outEngineNs"`  // npb_tun_read when it returned packets (no waiting)
	OutSyscallNs uint64 `json:"outSyscallNs"` // write() to the kernel tun
}

type pump struct {
	e         *engine.Engine
	fd        int
	batchMax  int
	slot      int
	readBuf   int
	readDelay time.Duration // slow reader: pause between npb_tun_read calls
	inDelay   time.Duration // slow writer: pause between npb_tun_write calls
	loopAddrs map[netip.Addr]bool
	dropLoop  bool
	stop      atomic.Bool
	wg        sync.WaitGroup

	inPackets, inBytes, inBatches, inMax, inFrag, inDF, inTrunc, inErr, loop atomic.Uint64
	outPackets, outBytes, outBatches, outMax, outFrag, outErr                atomic.Uint64
	inEngineNs, outEngineNs, outSyscallNs                                    atomic.Uint64
}

func storeMax(a *atomic.Uint64, v uint64) {
	for {
		old := a.Load()
		if v <= old || a.CompareAndSwap(old, v) {
			return
		}
	}
}

func (p *pump) counters() pumpCounters {
	return pumpCounters{
		InPackets: p.inPackets.Load(), InBytes: p.inBytes.Load(), InBatches: p.inBatches.Load(),
		InMaxPacket: p.inMax.Load(), InFragments: p.inFrag.Load(), InDF: p.inDF.Load(),
		InTruncated: p.inTrunc.Load(), InWriteErrs: p.inErr.Load(), LoopPackets: p.loop.Load(),
		OutPackets: p.outPackets.Load(), OutBytes: p.outBytes.Load(), OutBatches: p.outBatches.Load(),
		OutMaxPacket: p.outMax.Load(), OutFragments: p.outFrag.Load(), OutWriteErrs: p.outErr.Load(),
		InEngineNs: p.inEngineNs.Load(), OutEngineNs: p.outEngineNs.Load(), OutSyscallNs: p.outSyscallNs.Load(),
	}
}

// rx reads packets from the kernel tun and hands them to the engine in batches of up to batchMax, the way
// the extension forwards the array a readPackets completion delivers.
func (p *pump) rx() {
	defer p.wg.Done()
	buf := make([]byte, p.batchMax*(engineFrameHeader+p.slot))
	pfd := []unix.PollFd{{Fd: int32(p.fd), Events: unix.POLLIN}}
	for !p.stop.Load() {
		if _, err := unix.Poll(pfd, 200); err != nil && !errors.Is(err, unix.EINTR) {
			fmt.Fprintln(os.Stderr, "pump rx poll:", err)
			return
		}
		off, count := 0, 0
		for count < p.batchMax {
			pkt := buf[off+engineFrameHeader : off+engineFrameHeader+p.slot]
			n, err := unix.Read(p.fd, pkt)
			if err != nil {
				if errors.Is(err, unix.EINTR) {
					continue
				}
				if !errors.Is(err, unix.EAGAIN) {
					fmt.Fprintln(os.Stderr, "pump rx read:", err)
				}
				break
			}
			if n <= 0 {
				break
			}
			if n == p.slot {
				p.inTrunc.Add(1)
			}
			if pi, ok := inspect(pkt[:n]); ok {
				if p.loopAddrs[pi.dst] {
					p.loop.Add(1)
					if p.dropLoop {
						continue
					}
				}
				if pi.fragment {
					p.inFrag.Add(1)
				}
				if pi.df {
					p.inDF.Add(1)
				}
			}
			storeMax(&p.inMax, uint64(n))
			binary.LittleEndian.PutUint16(buf[off:], uint16(n))
			off += engineFrameHeader + n
			count++
		}
		if count == 0 {
			continue
		}
		t0 := time.Now()
		_, err := p.e.TunWrite(buf[:off])
		p.inEngineNs.Add(uint64(time.Since(t0)))
		if err != nil {
			p.inErr.Add(1)
			if err.Code == engine.CodeNotRunning {
				return
			}
		}
		p.inPackets.Add(uint64(count))
		p.inBytes.Add(uint64(off - count*engineFrameHeader))
		p.inBatches.Add(1)
		if p.inDelay > 0 {
			time.Sleep(p.inDelay)
		}
	}
}

// tx takes batches from the engine and writes each packet to the kernel tun (writePackets on Apple takes
// the whole array in one call; Linux tun takes one packet per write).
func (p *pump) tx() {
	defer p.wg.Done()
	dst := make([]byte, p.readBuf)
	pfd := []unix.PollFd{{Fd: int32(p.fd), Events: unix.POLLOUT}}
	for {
		// poll first so that the timed call below measures copying, not waiting
		t0 := time.Now()
		n, err := p.e.TunRead(dst, 0)
		if err == nil && n > 0 {
			p.outEngineNs.Add(uint64(time.Since(t0)))
		} else if err == nil {
			n, err = p.e.TunRead(dst, 200*time.Millisecond)
		}
		if err != nil {
			if err.Code == engine.CodeClosed || err.Code == engine.CodeNotRunning {
				return
			}
			fmt.Fprintln(os.Stderr, "pump tx read:", err)
			return
		}
		if n == 0 {
			if p.stop.Load() {
				return
			}
			continue
		}
		p.outBatches.Add(1)
		for b := dst[:n]; len(b) >= engineFrameHeader; {
			size := int(binary.LittleEndian.Uint16(b))
			pkt := b[engineFrameHeader : engineFrameHeader+size]
			b = b[engineFrameHeader+size:]
			if pi, ok := inspect(pkt); ok && pi.fragment {
				p.outFrag.Add(1)
			}
			storeMax(&p.outMax, uint64(size))
			t1 := time.Now()
			for {
				_, werr := unix.Write(p.fd, pkt)
				if werr == nil {
					break
				}
				if errors.Is(werr, unix.EAGAIN) {
					_, _ = unix.Poll(pfd, 100)
					continue
				}
				if errors.Is(werr, unix.EINTR) {
					continue
				}
				p.outErr.Add(1)
				break
			}
			p.outSyscallNs.Add(uint64(time.Since(t1)))
			p.outPackets.Add(1)
			p.outBytes.Add(uint64(size))
		}
		if p.readDelay > 0 {
			time.Sleep(p.readDelay)
		}
	}
}

const engineFrameHeader = 2

// sample is one snapshot of the bridge process, served on /sample. Counters are cumulative; the client
// subtracts two samples taken around a test.
type sample struct {
	TimeUnixMs  int64                   `json:"timeUnixMs"`
	CPUUserSec  float64                 `json:"cpuUserSec"`
	CPUSysSec   float64                 `json:"cpuSysSec"`
	RSSBytes    uint64                  `json:"rssBytes"`
	RSSAnon     uint64                  `json:"rssAnonBytes"`
	RSSFile     uint64                  `json:"rssFileBytes"`
	AllocBytes  uint64                  `json:"allocBytes"`   // /gc/heap/allocs:bytes, cumulative
	AllocObjs   uint64                  `json:"allocObjects"` // /gc/heap/allocs:objects, cumulative
	GCCPUSec    float64                 `json:"gcCPUSec"`     // /cpu/classes/gc/total:cpu-seconds (runtime estimate)
	GCPauseSecs float64                 `json:"gcPauseSec"`   // /sched/pauses/total/gc:seconds, sum of the histogram
	Memory      engine.MemoryStats      `json:"memory"`
	Tun         *engine.TunCounters     `json:"tun,omitempty"`
	Pump        *pumpCounters           `json:"pump,omitempty"`
	Inbounds    []engine.TrafficCounter `json:"inbounds,omitempty"`
	Outbounds   []engine.TrafficCounter `json:"outbounds,omitempty"`
	State       string                  `json:"state"`
}

var sampleMetrics = []string{
	"/gc/heap/allocs:bytes",
	"/gc/heap/allocs:objects",
	"/cpu/classes/gc/total:cpu-seconds",
	"/sched/pauses/total/gc:seconds",
}

func takeSample(e *engine.Engine, p *pump) sample {
	s := sample{TimeUnixMs: time.Now().UnixMilli(), State: e.State().String()}
	var ru unix.Rusage
	if unix.Getrusage(unix.RUSAGE_SELF, &ru) == nil {
		s.CPUUserSec = float64(ru.Utime.Sec) + float64(ru.Utime.Usec)/1e6
		s.CPUSysSec = float64(ru.Stime.Sec) + float64(ru.Stime.Usec)/1e6
	}
	s.RSSBytes = procRSS(os.Getpid())
	s.RSSAnon, s.RSSFile = procRSSSplit(os.Getpid())
	ms := make([]metrics.Sample, len(sampleMetrics))
	for i, n := range sampleMetrics {
		ms[i].Name = n
	}
	metrics.Read(ms)
	s.AllocBytes = ms[0].Value.Uint64()
	s.AllocObjs = ms[1].Value.Uint64()
	s.GCCPUSec = ms[2].Value.Float64()
	if ms[3].Value.Kind() == metrics.KindFloat64Histogram {
		h := ms[3].Value.Float64Histogram()
		for i, c := range h.Counts {
			// bucket i spans Buckets[i]..Buckets[i+1]; take the lower bound (upper may be +Inf)
			lo := h.Buckets[i]
			if lo < 0 || lo > 1e9 {
				lo = 0
			}
			s.GCPauseSecs += float64(c) * lo
		}
	}
	s.Memory = engine.ReadMemoryStats()
	if st, err := e.Stats(); err == nil {
		s.Tun, s.Inbounds, s.Outbounds = st.Tun, st.Inbounds, st.Outbounds
	}
	if p != nil {
		c := p.counters()
		s.Pump = &c
	}
	return s
}

// procRSSSplit reads RssAnon and RssFile (bytes) from /proc/<pid>/status. RssAnon is private memory, the
// closer analogue of the phys_footprint iOS enforces; RssFile is mostly clean text pages of the binary.
func procRSSSplit(pid int) (anon, file uint64) {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/status", pid))
	if err != nil {
		return 0, 0
	}
	for _, line := range strings.Split(string(b), "\n") {
		var kb uint64
		if _, err := fmt.Sscanf(line, "RssAnon: %d kB", &kb); err == nil {
			anon = kb << 10
		} else if _, err := fmt.Sscanf(line, "RssFile: %d kB", &kb); err == nil {
			file = kb << 10
		}
	}
	return anon, file
}

// procRSS reads the resident set of a process from /proc/<pid>/statm.
func procRSS(pid int) uint64 {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/statm", pid))
	if err != nil {
		return 0
	}
	var size, rss uint64
	if _, err := fmt.Sscan(string(b), &size, &rss); err != nil {
		return 0
	}
	return rss * uint64(os.Getpagesize())
}

func runBridge(args []string) error {
	fs := flag.NewFlagSet("bridge", flag.ExitOnError)
	configPath := fs.String("config", "", "xray JSON config (with a tun inbound)")
	mode := fs.String("mode", "flow", "flow | fd")
	tunName := fs.String("tun", "nptun0", "kernel tun device")
	mtu := fs.Int("mtu", 0, "tun.mtu option for the bridge's stack (0 = config)")
	batch := fs.Int("batch", 64, "max packets per npb_tun_write (flow)")
	slot := fs.Int("slot", 1504, "bytes reserved per packet in the write batch; >= device MTU")
	readBuf := fs.Int("readbuf", 256<<10, "npb_tun_read buffer bytes (flow)")
	outQueue := fs.Int("outq", 0, "tun.outQueueBytes (0 = default 2 MiB)")
	readDelay := fs.Duration("read-delay", 0, "pause after each npb_tun_read (slow reader)")
	inDelay := fs.Duration("write-delay", 0, "pause after each npb_tun_write (slow writer)")
	ctl := fs.String("ctl", "127.0.0.1:6060", "control listener: /sample and /debug/pprof")
	loopAddrs := fs.String("loop-addrs", "", "comma list of proxy server addresses; packets to them on the tun are loop packets")
	dropLoop := fs.Bool("drop-loop", true, "drop loop packets instead of feeding them back to the core")
	memLimit := fs.Int64("memlimit", 0, "memory.limitBytes")
	gcPercent := fs.Int("gcpercent", 0, "memory.gcPercent")
	memProfile := fs.String("profile", "", "memory.profile: empty or mobile")
	maxFlows := fs.Int("maxflows", 0, "tun.maxFlows (0 = profile default / no cap)")
	freeOS := fs.Int("freeos-ms", 0, "memory.freeOSMemoryIntervalMs")
	logLevel := fs.String("loglevel", "warning", "core log level")
	_ = fs.Parse(args)

	config, err := os.ReadFile(*configPath)
	if err != nil {
		return err
	}
	fd, err := openTun(*tunName, true)
	if err != nil {
		return err
	}
	defer unix.Close(fd)

	opts := engine.Options{
		LogLevel: *logLevel,
		Memory: engine.MemoryOptions{Profile: engine.MemoryProfile(*memProfile), LimitBytes: *memLimit,
			GCPercent: *gcPercent, FreeOSMemoryIntervalMs: *freeOS},
		Tun: engine.TunOptions{MTU: *mtu, OutQueueBytes: *outQueue, MaxFlows: *maxFlows},
	}
	e := engine.New()
	var p *pump
	switch *mode {
	case "flow":
		opts.Tun.Mode = engine.TunFlow
		if err := unix.SetNonblock(fd, true); err != nil {
			return err
		}
		p = &pump{e: e, fd: fd, batchMax: *batch, slot: *slot, readBuf: *readBuf,
			readDelay: *readDelay, inDelay: *inDelay, dropLoop: *dropLoop, loopAddrs: map[netip.Addr]bool{}}
		for _, a := range strings.Split(*loopAddrs, ",") {
			if a = strings.TrimSpace(a); a != "" {
				addr, perr := netip.ParseAddr(a)
				if perr != nil {
					return perr
				}
				p.loopAddrs[addr] = true
			}
		}
	case "fd":
		opts.Tun.Mode = engine.TunFD
		opts.Tun.FD = fd
	default:
		return fmt.Errorf("unknown mode %q", *mode)
	}

	if serr := e.Start(context.Background(), config, opts); serr != nil {
		return serr
	}
	if p != nil {
		p.wg.Add(2)
		go p.rx()
		go p.tx()
	}

	http.HandleFunc("/sample", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(takeSample(e, p))
	})
	http.HandleFunc("/logs", func(w http.ResponseWriter, _ *http.Request) {
		for _, r := range e.ReadLogs(nil, 1000, 0) {
			fmt.Fprintf(w, "#%d [%s/%s] %s\n", r.Seq, r.Kind, r.Level, r.Message)
		}
	})
	ln, err := net.Listen("tcp", *ctl)
	if err != nil {
		_ = e.Stop(5 * time.Second)
		return err
	}
	srv := &http.Server{ReadHeaderTimeout: 5 * time.Second}
	go func() { _ = srv.Serve(ln) }()
	// cold start: process memory right after Start, before any packet
	anon, file := procRSSSplit(os.Getpid())
	fmt.Printf("{\"ready\":true,\"mode\":%q,\"profile\":%q,\"pid\":%d,\"gomaxprocs\":%d,\"rssBytes\":%d,\"rssAnonBytes\":%d,\"rssFileBytes\":%d,\"heapLive\":%d,\"goroutines\":%d}\n",
		*mode, *memProfile, os.Getpid(), runtime.GOMAXPROCS(0), procRSS(os.Getpid()), anon, file,
		engine.ReadMemoryStats().HeapObjects, runtime.NumGoroutine())

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	<-sig
	_ = srv.Close()
	final := takeSample(e, p)
	if p != nil {
		p.stop.Store(true)
	}
	stopErr := e.Stop(10 * time.Second)
	if p != nil {
		p.wg.Wait()
	}
	b, _ := json.Marshal(final)
	fmt.Printf("{\"final\":%s}\n", b)
	for _, r := range e.ReadLogs(nil, 50, 0) {
		if r.Level == "error" || r.Level == "warning" {
			fmt.Fprintf(os.Stderr, "core log #%d [%s] %s\n", r.Seq, r.Level, r.Message)
		}
	}
	if stopErr != nil {
		return stopErr
	}
	return nil
}
