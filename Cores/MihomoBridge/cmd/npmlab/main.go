//go:build linux

// Command npmlab runs the Mihomo bridge on a Linux kernel tun device for the lab stand
// (Cores/BuildScripts/bridge-tunlab.sh with ENGINE=mihomo). It is the Mihomo counterpart of "nplab bridge"
// from Cores/Bridge/cmd/nplab, with the same flags where they mean the same, the same control listener
// (/sample, /logs, /debug/pprof) and the same "ready"/"final" lines, so that the stand's client, sampler and
// soak/memcmp tables work unchanged. Only the flow mode exists (the bridge has no fd mode).
//
// It is a lab tool, not part of the shipped bridge, and is meant to run inside a namespace created by the
// stand; it never creates namespaces, routes or firewall rules.
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

	"networkplatform/mihomobridge/engine"
)

func main() {
	if len(os.Args) < 2 || os.Args[1] != "bridge" {
		fmt.Fprintln(os.Stderr, "usage: npmlab bridge [flags]")
		os.Exit(2)
	}
	if err := runBridge(os.Args[2:]); err != nil {
		fmt.Fprintln(os.Stderr, "npmlab:", err)
		os.Exit(1)
	}
}

// openTun attaches to the tun device name as IFF_TUN|IFF_NO_PI: one read or write is one IP packet, as with
// NEPacketTunnelFlow.
func openTun(name string) (int, error) {
	fd, err := unix.Open("/dev/net/tun", unix.O_RDWR|unix.O_CLOEXEC, 0)
	if err != nil {
		return -1, err
	}
	ifr, err := unix.NewIfreq(name)
	if err != nil {
		unix.Close(fd)
		return -1, err
	}
	ifr.SetUint16(unix.IFF_TUN | unix.IFF_NO_PI)
	if err := unix.IoctlIfreq(fd, unix.TUNSETIFF, ifr); err != nil {
		unix.Close(fd)
		return -1, fmt.Errorf("TUNSETIFF %s: %w", name, err)
	}
	return fd, nil
}

const frameHeader = 2

// pumpCounters: same JSON names as nplab's, for the stand's tables.
type pumpCounters struct {
	InPackets   uint64 `json:"inPackets"`
	InBytes     uint64 `json:"inBytes"`
	InBatches   uint64 `json:"inBatches"`
	InWriteErrs uint64 `json:"inWriteErrs"`
	LoopPackets uint64 `json:"loopPackets"`
	OutPackets  uint64 `json:"outPackets"`
	OutBytes    uint64 `json:"outBytes"`
	OutBatches  uint64 `json:"outBatches"`
	OutWriteErr uint64 `json:"outWriteErrs"`
}

type pump struct {
	e         *engine.Engine
	fd        int
	batchMax  int
	slot      int
	readBuf   int
	loopAddrs map[netip.Addr]bool
	dropLoop  bool
	stop      atomic.Bool
	wg        sync.WaitGroup

	inPackets, inBytes, inBatches, inErr, loop atomic.Uint64
	outPackets, outBytes, outBatches, outErr   atomic.Uint64
}

func (p *pump) counters() pumpCounters {
	return pumpCounters{
		InPackets: p.inPackets.Load(), InBytes: p.inBytes.Load(), InBatches: p.inBatches.Load(),
		InWriteErrs: p.inErr.Load(), LoopPackets: p.loop.Load(),
		OutPackets: p.outPackets.Load(), OutBytes: p.outBytes.Load(), OutBatches: p.outBatches.Load(),
		OutWriteErr: p.outErr.Load(),
	}
}

func dstOf(pkt []byte) (netip.Addr, bool) {
	if len(pkt) >= 20 && pkt[0]>>4 == 4 {
		return netip.AddrFrom4([4]byte(pkt[16:20])), true
	}
	if len(pkt) >= 40 && pkt[0]>>4 == 6 {
		return netip.AddrFrom16([16]byte(pkt[24:40])), true
	}
	return netip.Addr{}, false
}

// rx: kernel tun -> TunWrite, in batches of up to batchMax packets.
func (p *pump) rx() {
	defer p.wg.Done()
	buf := make([]byte, p.batchMax*(frameHeader+p.slot))
	pfd := []unix.PollFd{{Fd: int32(p.fd), Events: unix.POLLIN}}
	for !p.stop.Load() {
		if _, err := unix.Poll(pfd, 200); err != nil && !errors.Is(err, unix.EINTR) {
			fmt.Fprintln(os.Stderr, "pump rx poll:", err)
			return
		}
		off, count := 0, 0
		for count < p.batchMax {
			pkt := buf[off+frameHeader : off+frameHeader+p.slot]
			n, err := unix.Read(p.fd, pkt)
			if err != nil {
				if errors.Is(err, unix.EINTR) {
					continue
				}
				break
			}
			if n <= 0 {
				break
			}
			if dst, ok := dstOf(pkt[:n]); ok && p.loopAddrs[dst] {
				p.loop.Add(1)
				if p.dropLoop {
					continue
				}
			}
			binary.LittleEndian.PutUint16(buf[off:], uint16(n))
			off += frameHeader + n
			count++
		}
		if count == 0 {
			continue
		}
		if _, err := p.e.TunWrite(buf[:off]); err != nil {
			p.inErr.Add(1)
			if err.Code == engine.CodeNotRunning || err.Code == engine.CodeClosed {
				return
			}
		}
		p.inPackets.Add(uint64(count))
		p.inBytes.Add(uint64(off - count*frameHeader))
		p.inBatches.Add(1)
	}
}

// tx: TunRead -> kernel tun, one write per packet.
func (p *pump) tx() {
	defer p.wg.Done()
	dst := make([]byte, p.readBuf)
	pfd := []unix.PollFd{{Fd: int32(p.fd), Events: unix.POLLOUT}}
	for {
		n, err := p.e.TunRead(dst, 200*time.Millisecond)
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
		for b := dst[:n]; len(b) >= frameHeader; {
			size := int(binary.LittleEndian.Uint16(b))
			pkt := b[frameHeader : frameHeader+size]
			b = b[frameHeader+size:]
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
			p.outPackets.Add(1)
			p.outBytes.Add(uint64(size))
		}
	}
}

// sample: same field names as nplab's /sample (fields the Mihomo bridge has no equivalent for are absent).
type sample struct {
	TimeUnixMs  int64                 `json:"timeUnixMs"`
	CPUUserSec  float64               `json:"cpuUserSec"`
	CPUSysSec   float64               `json:"cpuSysSec"`
	RSSBytes    uint64                `json:"rssBytes"`
	RSSAnon     uint64                `json:"rssAnonBytes"`
	RSSFile     uint64                `json:"rssFileBytes"`
	AllocBytes  uint64                `json:"allocBytes"`
	AllocObjs   uint64                `json:"allocObjects"`
	GCCPUSec    float64               `json:"gcCPUSec"`
	Memory      engine.MemoryStats    `json:"memory"`
	Tun         *engine.TunCounters   `json:"tun,omitempty"`
	Pump        *pumpCounters         `json:"pump,omitempty"`
	Total       engine.TrafficCounter `json:"total"`
	Connections int                   `json:"connections"`
	IdleClosed  [2]uint64             `json:"idleClosedTcpUdp"`
	State       string                `json:"state"`
}

var sampleMetrics = []string{"/gc/heap/allocs:bytes", "/gc/heap/allocs:objects", "/cpu/classes/gc/total:cpu-seconds"}

func takeSample(e *engine.Engine, p *pump) sample {
	s := sample{TimeUnixMs: time.Now().UnixMilli(), State: e.State().String()}
	var ru unix.Rusage
	if unix.Getrusage(unix.RUSAGE_SELF, &ru) == nil {
		s.CPUUserSec = float64(ru.Utime.Sec) + float64(ru.Utime.Usec)/1e6
		s.CPUSysSec = float64(ru.Stime.Sec) + float64(ru.Stime.Usec)/1e6
	}
	s.RSSBytes, s.RSSAnon, s.RSSFile = procRSS()
	ms := make([]metrics.Sample, len(sampleMetrics))
	for i, n := range sampleMetrics {
		ms[i].Name = n
	}
	metrics.Read(ms)
	s.AllocBytes, s.AllocObjs, s.GCCPUSec = ms[0].Value.Uint64(), ms[1].Value.Uint64(), ms[2].Value.Float64()
	s.Memory = engine.ReadMemoryStats()
	if st, err := e.Stats(); err == nil {
		s.Tun, s.Total, s.Connections = st.Tun, st.Total, st.Connections
		s.IdleClosed = [2]uint64{st.IdleClosedTCP, st.IdleClosedUDP}
	}
	if p != nil {
		c := p.counters()
		s.Pump = &c
	}
	return s
}

// procRSS reads VmRSS, RssAnon and RssFile (bytes) of this process.
func procRSS() (rss, anon, file uint64) {
	b, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return 0, 0, 0
	}
	for _, line := range strings.Split(string(b), "\n") {
		var kb uint64
		switch {
		case strings.HasPrefix(line, "VmRSS:"):
			fmt.Sscanf(line, "VmRSS: %d kB", &kb)
			rss = kb << 10
		case strings.HasPrefix(line, "RssAnon:"):
			fmt.Sscanf(line, "RssAnon: %d kB", &kb)
			anon = kb << 10
		case strings.HasPrefix(line, "RssFile:"):
			fmt.Sscanf(line, "RssFile: %d kB", &kb)
			file = kb << 10
		}
	}
	return rss, anon, file
}

func runBridge(args []string) error {
	fs := flag.NewFlagSet("bridge", flag.ExitOnError)
	configPath := fs.String("config", "", "Mihomo YAML config (with tun.enable and stack mips)")
	mode := fs.String("mode", "flow", "flow (the only mode of this bridge)")
	tunName := fs.String("tun", "nptun0", "kernel tun device")
	mtu := fs.Int("mtu", 0, "tun.mtu option (0 = config)")
	batch := fs.Int("batch", 64, "max packets per TunWrite")
	slot := fs.Int("slot", 1504, "bytes reserved per packet in the write batch; >= device MTU")
	readBuf := fs.Int("readbuf", 256<<10, "TunRead buffer bytes")
	outQueue := fs.Int("outq", 0, "tun.outQueueBytes (0 = default)")
	inQueue := fs.Int("inq", 0, "tun.inQueueBytes (0 = default)")
	ctl := fs.String("ctl", "127.0.0.1:6060", "control listener: /sample, /logs and /debug/pprof")
	loopAddrs := fs.String("loop-addrs", "", "comma list of proxy server addresses; packets to them on the tun are loop packets")
	dropLoop := fs.Bool("drop-loop", true, "drop loop packets instead of feeding them back to the core")
	memLimit := fs.Int64("memlimit", 0, "memory.limitBytes")
	gcPercent := fs.Int("gcpercent", 0, "memory.gcPercent")
	memProfile := fs.String("profile", "", "memory.profile: empty or mobile")
	maxFlows := fs.Int("maxflows", 0, "tun.maxFlows (0 = profile default / no cap)")
	tcpIdle := fs.Int("tcpidle-ms", 0, "tcpIdleTimeoutMs (0 = profile default / off)")
	udpIdle := fs.Int("udpidle-ms", 0, "udpIdleTimeoutMs (0 = profile default / off)")
	freeOS := fs.Int("freeos-ms", 0, "memory.freeOSMemoryIntervalMs")
	logLevel := fs.String("loglevel", "warning", "core log level")
	homeDir := fs.String("home", "", "homeDir (default: bridge default)")
	_ = fs.Parse(args)
	if *mode != "flow" {
		return fmt.Errorf("mode %q: the Mihomo bridge has only the flow mode", *mode)
	}

	config, err := os.ReadFile(*configPath)
	if err != nil {
		return err
	}
	fd, err := openTun(*tunName)
	if err != nil {
		return err
	}
	defer unix.Close(fd)
	if err := unix.SetNonblock(fd, true); err != nil {
		return err
	}

	opts := engine.Options{
		LogLevel: *logLevel,
		HomeDir:  *homeDir,
		Memory: engine.MemoryOptions{Profile: engine.MemoryProfile(*memProfile), LimitBytes: *memLimit,
			GCPercent: *gcPercent, FreeOSMemoryIntervalMs: *freeOS},
		Tun: engine.TunOptions{Mode: engine.TunFlow, MTU: *mtu, OutQueueBytes: *outQueue, InQueueBytes: *inQueue,
			MaxFlows: *maxFlows},
		TCPIdleTimeoutMs: *tcpIdle, UDPIdleTimeoutMs: *udpIdle,
	}
	e := engine.New()
	p := &pump{e: e, fd: fd, batchMax: *batch, slot: *slot, readBuf: *readBuf, dropLoop: *dropLoop,
		loopAddrs: map[netip.Addr]bool{}}
	for _, a := range strings.Split(*loopAddrs, ",") {
		if a = strings.TrimSpace(a); a != "" {
			addr, perr := netip.ParseAddr(a)
			if perr != nil {
				return perr
			}
			p.loopAddrs[addr] = true
		}
	}

	if serr := e.Start(context.Background(), config, opts); serr != nil {
		return serr
	}
	p.wg.Add(2)
	go p.rx()
	go p.tx()

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
	rss, anon, file := procRSS()
	fmt.Printf("{\"ready\":true,\"engine\":\"mihomo\",\"mode\":%q,\"profile\":%q,\"pid\":%d,\"gomaxprocs\":%d,\"rssBytes\":%d,\"rssAnonBytes\":%d,\"rssFileBytes\":%d,\"heapLive\":%d,\"goroutines\":%d}\n",
		*mode, *memProfile, os.Getpid(), runtime.GOMAXPROCS(0), rss, anon, file,
		engine.ReadMemoryStats().HeapObjects, runtime.NumGoroutine())

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	<-sig
	_ = srv.Close()
	final := takeSample(e, p)
	p.stop.Store(true)
	stopErr := e.Stop(10 * time.Second)
	p.wg.Wait()
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
