//go:build linux

package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/netip"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/net/dns/dnsmessage"
	"golang.org/x/sys/unix"
)

type clientFlags struct {
	test    string
	addr    string
	bytes   int64
	conns   int
	n       int
	size    int
	sizes   string
	df      bool
	timeout time.Duration
	dur     time.Duration
	rate    int64
	qtype   string
	name    string
	expect  string
	pid     int
	ctl     string
	label   string
}

// result is printed as one JSON line per test.
type result struct {
	Label  string         `json:"label"`
	Test   string         `json:"test"`
	Addr   string         `json:"addr"`
	OK     bool           `json:"ok"`
	Error  string         `json:"error,omitempty"`
	Values map[string]any `json:"values"`
	Proc   *procDelta     `json:"proc,omitempty"`
	Bridge *bridgeDelta   `json:"bridge,omitempty"`
}

type procDelta struct {
	CPUSec   float64 `json:"cpuSec"`
	RSSStart uint64  `json:"rssStart"`
	RSSPeak  uint64  `json:"rssPeak"`
	RSSEnd   uint64  `json:"rssEnd"`
	// private (anonymous) resident memory, the closer analogue of the iOS phys_footprint
	RSSAnonStart uint64 `json:"rssAnonStart"`
	RSSAnonPeak  uint64 `json:"rssAnonPeak"`
	RSSAnonEnd   uint64 `json:"rssAnonEnd"`
}

type bridgeDelta struct {
	AllocBytes       uint64        `json:"allocBytes"`
	AllocObjects     uint64        `json:"allocObjects"`
	GCCPUSec         float64       `json:"gcCPUSec"`
	GCPauseSec       float64       `json:"gcPauseSec"`
	GCCycles         uint64        `json:"gcCycles"`
	CPUSec           float64       `json:"cpuSec"`
	GoroutinesBefore uint64        `json:"goroutinesBefore"`
	GoroutinesAfter  uint64        `json:"goroutinesAfter"`
	HeapLiveAfter    uint64        `json:"heapLiveAfter"`
	MappedAfter      uint64        `json:"mappedAfter"`
	TunPackets       uint64        `json:"tunPackets"` // rx+tx packets of the flow device during the test
	TunBytes         uint64        `json:"tunBytes"`
	TxDropped        uint64        `json:"txDropped"`
	TxQueueHighest   int           `json:"txQueueHighest"`
	TxQueueBytes     int           `json:"txQueueBytes"`
	Pump             *pumpCounters `json:"pump,omitempty"` // delta
	After            *sample       `json:"-"`
}

func runClient(args []string) error {
	var f clientFlags
	fs := flag.NewFlagSet("client", flag.ExitOnError)
	fs.StringVar(&f.test, "test", "", "tcp-up|tcp-down|tcp-echo|tcp-halfclose|tcp-rr|tcp-setup|udp-rr|udp-echo|pmtu|dns|mix|burst")
	fs.StringVar(&f.addr, "addr", "", "target host:port")
	fs.Int64Var(&f.bytes, "bytes", 64<<20, "bytes to transfer (total over all connections)")
	fs.IntVar(&f.conns, "conns", 1, "parallel connections")
	fs.IntVar(&f.n, "n", 1000, "iterations")
	fs.IntVar(&f.size, "size", 1, "message size for rr tests")
	fs.StringVar(&f.sizes, "sizes", "1,1200", "comma list of UDP datagram sizes (udp-echo)")
	fs.BoolVar(&f.df, "df", false, "set don't-fragment on UDP sockets")
	fs.DurationVar(&f.timeout, "timeout", 120*time.Second, "test deadline")
	fs.DurationVar(&f.dur, "duration", time.Minute, "duration of the mix test")
	fs.Int64Var(&f.rate, "rate", 2<<20, "mix: bytes per second per worker")
	fs.StringVar(&f.qtype, "qtype", "A", "dns: A or AAAA")
	fs.StringVar(&f.name, "name", "host.np.test.", "dns: query name")
	fs.StringVar(&f.expect, "expect", "", "dns: expected address")
	fs.IntVar(&f.pid, "pid", 0, "measure CPU and RSS of this process")
	fs.StringVar(&f.ctl, "ctl", "", "bridge control address for runtime deltas (host:port)")
	fs.StringVar(&f.label, "label", "", "label copied to the result")
	_ = fs.Parse(args)

	res := result{Label: f.label, Test: f.test, Addr: f.addr, Values: map[string]any{}}
	var before *sample
	if f.ctl != "" {
		before, _ = fetchSample(f.ctl)
	}
	var cpu0 float64
	var rssStop chan struct{}
	var rssPeak, anonPeak atomic.Uint64
	var rssWG sync.WaitGroup
	if f.pid > 0 {
		cpu0 = procCPU(f.pid)
		rssStart := procRSS(f.pid)
		anonStart, _ := procRSSSplit(f.pid)
		res.Proc = &procDelta{RSSStart: rssStart, RSSAnonStart: anonStart}
		rssPeak.Store(rssStart)
		anonPeak.Store(anonStart)
		rssStop = make(chan struct{})
		rssWG.Add(1)
		go func() {
			defer rssWG.Done()
			t := time.NewTicker(50 * time.Millisecond)
			defer t.Stop()
			for {
				select {
				case <-t.C:
					storeMax(&rssPeak, procRSS(f.pid))
					a, _ := procRSSSplit(f.pid)
					storeMax(&anonPeak, a)
				case <-rssStop:
					return
				}
			}
		}()
	}

	var err error
	switch f.test {
	case "tcp-up":
		err = testTCPUp(&f, res.Values)
	case "tcp-down":
		err = testTCPDown(&f, res.Values)
	case "tcp-halfclose":
		err = testTCPHalfClose(&f, res.Values)
	case "tcp-echo":
		err = testTCPEcho(&f, res.Values)
	case "tcp-rr":
		err = testTCPRR(&f, res.Values)
	case "tcp-setup":
		err = testTCPSetup(&f, res.Values)
	case "udp-rr":
		err = testUDPRR(&f, res.Values)
	case "udp-echo":
		err = testUDPEcho(&f, res.Values)
	case "pmtu":
		err = testPMTU(&f, res.Values)
	case "dns":
		err = testDNS(&f, res.Values)
	case "mix":
		err = testMix(&f, res.Values)
	case "burst":
		err = testBurst(&f, res.Values)
	default:
		err = fmt.Errorf("unknown test %q", f.test)
	}
	res.OK = err == nil
	if err != nil {
		res.Error = err.Error()
	}

	if f.pid > 0 {
		close(rssStop)
		rssWG.Wait()
		res.Proc.CPUSec = procCPU(f.pid) - cpu0
		res.Proc.RSSEnd = procRSS(f.pid)
		storeMax(&rssPeak, res.Proc.RSSEnd)
		res.Proc.RSSPeak = rssPeak.Load()
		res.Proc.RSSAnonEnd, _ = procRSSSplit(f.pid)
		storeMax(&anonPeak, res.Proc.RSSAnonEnd)
		res.Proc.RSSAnonPeak = anonPeak.Load()
	}
	if before != nil {
		if after, aerr := fetchSample(f.ctl); aerr == nil {
			res.Bridge = deltaOf(before, after)
		}
	}
	b, _ := json.Marshal(res)
	fmt.Println(string(b))
	return nil
}

func fetchSample(ctl string) (*sample, error) {
	c := http.Client{Timeout: 5 * time.Second}
	resp, err := c.Get("http://" + ctl + "/sample")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var s sample
	if err := json.NewDecoder(resp.Body).Decode(&s); err != nil {
		return nil, err
	}
	return &s, nil
}

func deltaOf(a, b *sample) *bridgeDelta {
	d := &bridgeDelta{
		AllocBytes: b.AllocBytes - a.AllocBytes, AllocObjects: b.AllocObjs - a.AllocObjs,
		GCCPUSec: b.GCCPUSec - a.GCCPUSec, GCPauseSec: b.GCPauseSecs - a.GCPauseSecs,
		GCCycles:         b.Memory.GCCycles - a.Memory.GCCycles,
		CPUSec:           (b.CPUUserSec + b.CPUSysSec) - (a.CPUUserSec + a.CPUSysSec),
		GoroutinesBefore: a.Memory.Goroutines, GoroutinesAfter: b.Memory.Goroutines,
		HeapLiveAfter: b.Memory.HeapLive, MappedAfter: b.Memory.Mapped, After: b,
	}
	if a.Tun != nil && b.Tun != nil {
		d.TunPackets = (b.Tun.RxPackets + b.Tun.TxPackets) - (a.Tun.RxPackets + a.Tun.TxPackets)
		d.TunBytes = (b.Tun.RxBytes + b.Tun.TxBytes) - (a.Tun.RxBytes + a.Tun.TxBytes)
		d.TxDropped = b.Tun.TxDropped - a.Tun.TxDropped
		d.TxQueueHighest, d.TxQueueBytes = b.Tun.TxQueueHighest, b.Tun.TxQueueBytes
	}
	if a.Pump != nil && b.Pump != nil {
		x, y := a.Pump, b.Pump
		d.Pump = &pumpCounters{
			InPackets: y.InPackets - x.InPackets, InBytes: y.InBytes - x.InBytes, InBatches: y.InBatches - x.InBatches,
			InMaxPacket: y.InMaxPacket, InFragments: y.InFragments - x.InFragments, InDF: y.InDF - x.InDF,
			InTruncated: y.InTruncated - x.InTruncated, InWriteErrs: y.InWriteErrs - x.InWriteErrs,
			LoopPackets: y.LoopPackets - x.LoopPackets,
			OutPackets:  y.OutPackets - x.OutPackets, OutBytes: y.OutBytes - x.OutBytes, OutBatches: y.OutBatches - x.OutBatches,
			OutMaxPacket: y.OutMaxPacket, OutFragments: y.OutFragments - x.OutFragments, OutWriteErrs: y.OutWriteErrs - x.OutWriteErrs,
			InEngineNs: y.InEngineNs - x.InEngineNs, OutEngineNs: y.OutEngineNs - x.OutEngineNs, OutSyscallNs: y.OutSyscallNs - x.OutSyscallNs,
		}
	}
	return d
}

// procCPU returns utime+stime of a process in seconds (/proc/<pid>/stat fields 14 and 15, USER_HZ=100).
func procCPU(pid int) float64 {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return 0
	}
	s := string(b)
	i := strings.LastIndexByte(s, ')')
	if i < 0 {
		return 0
	}
	fields := strings.Fields(s[i+1:])
	if len(fields) < 13 {
		return 0
	}
	u, _ := strconv.ParseFloat(fields[11], 64)
	st, _ := strconv.ParseFloat(fields[12], 64)
	return (u + st) / 100
}

func mbps(n int64, d time.Duration) float64 { return float64(n) * 8 / d.Seconds() / 1e6 }

func runConns(f *clientFlags, per func(i int, share int64) error) (time.Duration, error) {
	share := f.bytes / int64(f.conns)
	start := time.Now()
	errs := make(chan error, f.conns)
	for i := 0; i < f.conns; i++ {
		go func(i int) { errs <- per(i, share) }(i)
	}
	var first error
	for i := 0; i < f.conns; i++ {
		if err := <-errs; err != nil && first == nil {
			first = err
		}
	}
	return time.Since(start), first
}

func testTCPDown(f *clientFlags, v map[string]any) error {
	var total atomic.Int64
	el, err := runConns(f, func(_ int, share int64) error {
		c, err := net.DialTimeout("tcp", f.addr, 10*time.Second)
		if err != nil {
			return err
		}
		defer c.Close()
		_ = c.SetDeadline(time.Now().Add(f.timeout))
		var b [8]byte
		binary.BigEndian.PutUint64(b[:], uint64(share))
		if _, err := c.Write(b[:]); err != nil {
			return err
		}
		n, err := io.Copy(io.Discard, c)
		total.Add(n)
		if err != nil {
			return err
		}
		if n != share {
			return fmt.Errorf("received %d of %d bytes", n, share)
		}
		return nil
	})
	v["bytes"], v["seconds"], v["mbps"] = total.Load(), el.Seconds(), mbps(total.Load(), el)
	return err
}

// testTCPUp sends a length header and then the payload to the sink port, which answers with the count. It does
// not depend on TCP half-close, which the proxy protocols do not carry (see testTCPHalfClose).
func testTCPUp(f *clientFlags, v map[string]any) error {
	var total atomic.Int64
	el, err := runConns(f, func(_ int, share int64) error {
		c, err := net.DialTimeout("tcp", f.addr, 10*time.Second)
		if err != nil {
			return err
		}
		defer c.Close()
		_ = c.SetDeadline(time.Now().Add(f.timeout))
		var b [8]byte
		binary.BigEndian.PutUint64(b[:], uint64(share))
		if _, err := c.Write(b[:]); err != nil {
			return err
		}
		chunk := make([]byte, 128<<10)
		for left := share; left > 0; {
			n := int64(len(chunk))
			if left < n {
				n = left
			}
			w, err := c.Write(chunk[:n])
			total.Add(int64(w))
			if err != nil {
				return err
			}
			left -= int64(w)
		}
		if _, err := io.ReadFull(c, b[:]); err != nil {
			return fmt.Errorf("sink count: %w", err)
		}
		if got := int64(binary.BigEndian.Uint64(b[:])); got != share {
			return fmt.Errorf("server counted %d of %d bytes", got, share)
		}
		return nil
	})
	v["bytes"], v["seconds"], v["mbps"] = total.Load(), el.Seconds(), mbps(total.Load(), el)
	return err
}

// testTCPHalfClose writes f.bytes to the discard port, half-closes (FIN) and waits for the count the server
// sends only after it saw the FIN. It reports how long the answer took or how the connection ended.
func testTCPHalfClose(f *clientFlags, v map[string]any) error {
	c, err := net.DialTimeout("tcp", f.addr, 10*time.Second)
	if err != nil {
		return err
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(f.timeout))
	if _, err := c.Write(make([]byte, f.bytes)); err != nil {
		return err
	}
	t := time.Now()
	if err := c.(*net.TCPConn).CloseWrite(); err != nil {
		return err
	}
	var b [8]byte
	_, err = io.ReadFull(c, b[:])
	v["secondsAfterFIN"] = time.Since(t).Seconds()
	if err != nil {
		return fmt.Errorf("no answer after FIN: %w", err)
	}
	v["count"] = binary.BigEndian.Uint64(b[:])
	return nil
}

func testTCPEcho(f *clientFlags, v map[string]any) error {
	c, err := net.DialTimeout("tcp", f.addr, 10*time.Second)
	if err != nil {
		return err
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(f.timeout))
	if mss, err := tcpMSS(c); err == nil {
		v["mss"] = mss
	}
	start := time.Now()
	sent := sha256.New()
	werr := make(chan error, 1)
	go func() {
		chunk := make([]byte, 64<<10)
		for left := f.bytes; left > 0; {
			n := int64(len(chunk))
			if left < n {
				n = left
			}
			_, _ = rand.Read(chunk[:n])
			sent.Write(chunk[:n])
			if _, err := c.Write(chunk[:n]); err != nil {
				werr <- err
				return
			}
			left -= n
		}
		werr <- nil
	}()
	// read exactly what was sent: waiting for EOF would depend on half-close, which proxies do not carry
	got := sha256.New()
	n, err := io.CopyN(got, c, f.bytes)
	if e := <-werr; e != nil {
		return e
	}
	el := time.Since(start)
	v["bytes"], v["seconds"], v["mbps"] = n, el.Seconds(), mbps(2*n, el)
	if err != nil {
		return err
	}
	if n != f.bytes || !bytes.Equal(sent.Sum(nil), got.Sum(nil)) {
		return fmt.Errorf("echo mismatch: %d of %d bytes, digest equal=%v", n, f.bytes, bytes.Equal(sent.Sum(nil), got.Sum(nil)))
	}
	v["sha256"] = "equal"
	return nil
}

func tcpMSS(c net.Conn) (int, error) {
	raw, err := c.(*net.TCPConn).SyscallConn()
	if err != nil {
		return 0, err
	}
	var mss int
	var serr error
	_ = raw.Control(func(fd uintptr) { mss, serr = unix.GetsockoptInt(int(fd), unix.IPPROTO_TCP, unix.TCP_MAXSEG) })
	return mss, serr
}

// latencyStats fills v with percentiles in microseconds.
func latencyStats(v map[string]any, prefix string, d []time.Duration) {
	if len(d) == 0 {
		return
	}
	sort.Slice(d, func(i, j int) bool { return d[i] < d[j] })
	pct := func(p float64) float64 {
		i := int(math.Ceil(p*float64(len(d)))) - 1
		if i < 0 {
			i = 0
		}
		return float64(d[i].Microseconds())
	}
	var sum time.Duration
	for _, x := range d {
		sum += x
	}
	v[prefix+"p50us"], v[prefix+"p95us"], v[prefix+"p99us"] = pct(0.50), pct(0.95), pct(0.99)
	v[prefix+"minus"], v[prefix+"maxus"] = float64(d[0].Microseconds()), float64(d[len(d)-1].Microseconds())
	v[prefix+"meanus"] = float64(sum.Microseconds()) / float64(len(d))
	v[prefix+"count"] = len(d)
}

func testTCPRR(f *clientFlags, v map[string]any) error {
	c, err := net.DialTimeout("tcp", f.addr, 10*time.Second)
	if err != nil {
		return err
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(f.timeout))
	_ = c.(*net.TCPConn).SetNoDelay(true)
	msg, got := make([]byte, f.size), make([]byte, f.size)
	// warm-up: the first exchange carries the proxy handshake
	if _, err := c.Write(msg); err != nil {
		return err
	}
	if _, err := io.ReadFull(c, got); err != nil {
		return err
	}
	lat := make([]time.Duration, 0, f.n)
	for i := 0; i < f.n; i++ {
		t := time.Now()
		if _, err := c.Write(msg); err != nil {
			return err
		}
		if _, err := io.ReadFull(c, got); err != nil {
			return err
		}
		lat = append(lat, time.Since(t))
	}
	latencyStats(v, "", lat)
	return nil
}

// testTCPSetup measures a new connection up to the first echoed byte: through the proxy this includes the
// outbound handshake (REALITY/TLS) the stack-level SYN/ACK does not wait for.
func testTCPSetup(f *clientFlags, v map[string]any) error {
	lat := make([]time.Duration, 0, f.n)
	var b [1]byte
	for i := 0; i < f.n; i++ {
		t := time.Now()
		c, err := net.DialTimeout("tcp", f.addr, 10*time.Second)
		if err != nil {
			return err
		}
		_ = c.SetDeadline(time.Now().Add(10 * time.Second))
		_, err = c.Write(b[:])
		if err == nil {
			_, err = io.ReadFull(c, b[:])
		}
		c.Close()
		if err != nil {
			return fmt.Errorf("connection %d: %w", i, err)
		}
		lat = append(lat, time.Since(t))
	}
	latencyStats(v, "", lat)
	return nil
}

func dialUDP(f *clientFlags) (*net.UDPConn, error) {
	c, err := net.Dial("udp", f.addr)
	if err != nil {
		return nil, err
	}
	u := c.(*net.UDPConn)
	if f.df {
		if err := setDF(u, true); err != nil {
			u.Close()
			return nil, err
		}
	}
	return u, nil
}

func isV6(c *net.UDPConn) bool { return c.RemoteAddr().(*net.UDPAddr).IP.To4() == nil }

func setDF(c *net.UDPConn, on bool) error {
	raw, err := c.SyscallConn()
	if err != nil {
		return err
	}
	var serr error
	_ = raw.Control(func(fd uintptr) {
		if isV6(c) {
			val := 0
			if on {
				val = 1
			}
			serr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IPV6, unix.IPV6_DONTFRAG, val)
			if serr == nil && on {
				serr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IPV6, unix.IPV6_MTU_DISCOVER, unix.IPV6_PMTUDISC_DO)
			}
		} else {
			mode := unix.IP_PMTUDISC_DONT
			if on {
				mode = unix.IP_PMTUDISC_DO
			}
			serr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_MTU_DISCOVER, mode)
		}
	})
	return serr
}

func pathMTU(c *net.UDPConn) (int, error) {
	raw, err := c.SyscallConn()
	if err != nil {
		return 0, err
	}
	var mtu int
	var serr error
	_ = raw.Control(func(fd uintptr) {
		if isV6(c) {
			mtu, serr = unix.GetsockoptInt(int(fd), unix.IPPROTO_IPV6, unix.IPV6_MTU)
		} else {
			mtu, serr = unix.GetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_MTU)
		}
	})
	return mtu, serr
}

func testUDPRR(f *clientFlags, v map[string]any) error {
	c, err := dialUDP(f)
	if err != nil {
		return err
	}
	defer c.Close()
	msg, got := make([]byte, f.size), make([]byte, 65536)
	lat := make([]time.Duration, 0, f.n)
	lost := 0
	// warm-up exchange (creates the UDP session in the core)
	_, _ = c.Write(msg)
	_ = c.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, _ = c.Read(got)
	deadline := time.Now().Add(f.timeout)
	for i := 0; i < f.n && time.Now().Before(deadline); i++ {
		binary.BigEndian.PutUint32(msg[:min(4, len(msg))], uint32(i))
		t := time.Now()
		if _, err := c.Write(msg); err != nil {
			return err
		}
		for {
			_ = c.SetReadDeadline(time.Now().Add(time.Second))
			n, err := c.Read(got)
			if err != nil {
				lost++
				break
			}
			if n == len(msg) && bytes.Equal(got[:n], msg) {
				lat = append(lat, time.Since(t))
				break
			}
			// a late reply of an earlier probe: keep waiting for ours
		}
	}
	v["lost"] = lost
	latencyStats(v, "", lat)
	if lost > f.n/10 {
		return fmt.Errorf("%d of %d probes lost", lost, f.n)
	}
	return nil
}

// testUDPEcho sends one datagram per size and checks the echo. The outcome per size is ok, emsgsize (the
// kernel refused a DF datagram larger than the path MTU), lost, or mismatch.
func testUDPEcho(f *clientFlags, v map[string]any) error {
	c, err := dialUDP(f)
	if err != nil {
		return err
	}
	defer c.Close()
	if mtu, err := pathMTU(c); err == nil {
		v["pathMTU"] = mtu
	}
	outcome := map[string]string{}
	var failed []string
	for _, s := range strings.Split(f.sizes, ",") {
		size, err := strconv.Atoi(strings.TrimSpace(s))
		if err != nil {
			return err
		}
		outcome[s] = udpOnce(c, size, 3)
		if outcome[s] != "ok" && !(f.df && outcome[s] == "emsgsize") {
			failed = append(failed, s+"="+outcome[s])
		}
	}
	v["outcome"] = outcome
	if len(failed) > 0 {
		return fmt.Errorf("udp echo failed: %s", strings.Join(failed, " "))
	}
	return nil
}

func udpOnce(c *net.UDPConn, size, tries int) string {
	msg, got := make([]byte, size), make([]byte, 65536)
	_, _ = rand.Read(msg)
	for try := 0; try < tries; try++ {
		if _, err := c.Write(msg); err != nil {
			if errors.Is(err, syscall.EMSGSIZE) {
				return "emsgsize"
			}
			return "write:" + err.Error()
		}
		_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
		for {
			n, err := c.Read(got)
			if err != nil {
				break // retry
			}
			if n == size && bytes.Equal(got[:n], msg) {
				return "ok"
			}
			if n != size {
				continue // a reply to another size
			}
			return "mismatch"
		}
	}
	return "lost"
}

// testPMTU checks the don't-fragment behaviour at the edge of the path MTU: the largest DF datagram must pass,
// one byte more must be refused locally with EMSGSIZE, and the TCP MSS must match the MTU.
func testPMTU(f *clientFlags, v map[string]any) error {
	f.df = true
	c, err := dialUDP(f)
	if err != nil {
		return err
	}
	defer c.Close()
	mtu, err := pathMTU(c)
	if err != nil {
		return err
	}
	hdr := 28
	if isV6(c) {
		hdr = 48
	}
	v["pathMTU"] = mtu
	maxPayload := mtu - hdr
	v["dfMax"] = udpOnce(c, maxPayload, 3)
	v["dfMaxPlus1"] = udpOnce(c, maxPayload+1, 1)
	_ = setDF(c, false)
	v["noDFLarge"] = udpOnce(c, 2*mtu, 3)
	tc, err := net.DialTimeout("tcp", f.addr, 10*time.Second)
	if err == nil {
		if mss, err := tcpMSS(tc); err == nil {
			v["tcpMSS"] = mss
		}
		tc.Close()
	}
	if v["dfMax"] != "ok" || v["dfMaxPlus1"] != "emsgsize" {
		return fmt.Errorf("DF edge: max=%v max+1=%v", v["dfMax"], v["dfMaxPlus1"])
	}
	return nil
}

func testDNS(f *clientFlags, v map[string]any) error {
	qt := dnsmessage.TypeA
	if f.qtype == "AAAA" {
		qt = dnsmessage.TypeAAAA
	}
	name, err := dnsmessage.NewName(f.name)
	if err != nil {
		return err
	}
	c, err := net.Dial("udp", f.addr)
	if err != nil {
		return err
	}
	defer c.Close()
	lat := make([]time.Duration, 0, f.n)
	var answer string
	failures := 0
	buf := make([]byte, 1500)
	for i := 0; i < f.n; i++ {
		id := uint16(i + 1)
		b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: id, RecursionDesired: true})
		_ = b.StartQuestions()
		_ = b.Question(dnsmessage.Question{Name: name, Type: qt, Class: dnsmessage.ClassINET})
		q, _ := b.Finish()
		t := time.Now()
		if _, err := c.Write(q); err != nil {
			return err
		}
		_ = c.SetReadDeadline(time.Now().Add(3 * time.Second))
		n, err := c.Read(buf)
		if err != nil {
			failures++
			continue
		}
		var p dnsmessage.Parser
		h, err := p.Start(buf[:n])
		if err != nil || h.ID != id {
			failures++
			continue
		}
		_ = p.SkipAllQuestions()
		for {
			rh, err := p.AnswerHeader()
			if err != nil {
				break
			}
			switch rh.Type {
			case dnsmessage.TypeA:
				r, _ := p.AResource()
				answer = netip.AddrFrom4(r.A).String()
			case dnsmessage.TypeAAAA:
				r, _ := p.AAAAResource()
				answer = netip.AddrFrom16(r.AAAA).String()
			default:
				_ = p.SkipAnswer()
			}
		}
		lat = append(lat, time.Since(t))
	}
	v["answer"], v["failures"] = answer, failures
	latencyStats(v, "", lat)
	if failures > 0 {
		return fmt.Errorf("%d of %d queries failed", failures, f.n)
	}
	if f.expect != "" && answer != f.expect {
		return fmt.Errorf("answer %q, expected %q", answer, f.expect)
	}
	return nil
}

// testMix is the soak load: f.conns workers, each repeatedly opens a new TCP connection, downloads and
// uploads 1 MiB at f.rate bytes/s, and exchanges a few UDP datagrams, until f.dur elapses. -addr is the
// target host (ports are the fixed target ports).
func testMix(f *clientFlags, v map[string]any) error {
	var bytesDone, conns, udpOK, udpLost, errs atomic.Int64
	var lastErr atomic.Value
	stop := time.Now().Add(f.dur)
	var wg sync.WaitGroup
	for w := 0; w < f.conns; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			const unit = 1 << 20
			chunk := make([]byte, 32<<10)
			pace := time.Duration(float64(len(chunk)) / float64(f.rate) * float64(time.Second))
			fail := func(err error) {
				errs.Add(1)
				lastErr.Store(err.Error())
				time.Sleep(time.Second)
			}
			for time.Now().Before(stop) {
				// download 1 MiB, paced by reading slowly
				c, err := net.DialTimeout("tcp", net.JoinHostPort(f.addr, fmt.Sprint(portSource)), 10*time.Second)
				if err != nil {
					fail(err)
					continue
				}
				conns.Add(1)
				_ = c.SetDeadline(time.Now().Add(60 * time.Second))
				var hdr [8]byte
				binary.BigEndian.PutUint64(hdr[:], unit)
				_, err = c.Write(hdr[:])
				var got int64
				for err == nil && got < unit {
					var n int
					n, err = io.ReadFull(c, chunk[:min(len(chunk), int(unit-got))])
					got += int64(n)
					time.Sleep(pace)
				}
				c.Close()
				bytesDone.Add(got)
				if err != nil {
					fail(err)
					continue
				}
				// upload 1 MiB, paced
				c, err = net.DialTimeout("tcp", net.JoinHostPort(f.addr, fmt.Sprint(portSink)), 10*time.Second)
				if err != nil {
					fail(err)
					continue
				}
				conns.Add(1)
				_ = c.SetDeadline(time.Now().Add(60 * time.Second))
				binary.BigEndian.PutUint64(hdr[:], unit)
				_, err = c.Write(hdr[:])
				for sent := 0; err == nil && sent < unit; sent += len(chunk) {
					_, err = c.Write(chunk)
					time.Sleep(pace)
				}
				if err == nil {
					_, err = io.ReadFull(c, hdr[:])
				}
				c.Close()
				if err != nil {
					fail(err)
					continue
				}
				bytesDone.Add(unit)
				// a few UDP exchanges on a fresh socket (new UDP session in the core each round)
				u, err := net.Dial("udp", net.JoinHostPort(f.addr, fmt.Sprint(portEcho)))
				if err != nil {
					fail(err)
					continue
				}
				for i := 0; i < 5; i++ {
					if udpOnce(u.(*net.UDPConn), 512, 1) == "ok" {
						udpOK.Add(1)
					} else {
						udpLost.Add(1)
					}
				}
				u.Close()
			}
		}()
	}
	wg.Wait()
	v["bytes"], v["connections"], v["udpOK"], v["udpLost"], v["errors"] =
		bytesDone.Load(), conns.Load(), udpOK.Load(), udpLost.Load(), errs.Load()
	if s, ok := lastErr.Load().(string); ok {
		v["lastError"] = s
	}
	if errs.Load() > conns.Load()/100+1 {
		return fmt.Errorf("%d errors in %d connections", errs.Load(), conns.Load())
	}
	return nil
}

// testBurst opens -conns TCP connections and as many UDP sockets to addr at once; every worker echoes
// -bytes/-conns bytes over TCP and 5 UDP datagrams, and all of them stay open until the last one is done, so
// the core holds -conns TCP connections and -conns UDP sessions at the same time.
func testBurst(f *clientFlags, v map[string]any) error {
	per := max(f.bytes/int64(f.conns), 1)
	var errs, udpOK, udpLost atomic.Int64
	var lastErr atomic.Value
	var done, release sync.WaitGroup
	done.Add(f.conns)
	release.Add(1)
	var finished sync.WaitGroup
	finished.Add(f.conns)
	t0 := time.Now()
	for w := 0; w < f.conns; w++ {
		go func() {
			defer finished.Done()
			fail := func(err error) { errs.Add(1); lastErr.Store(err.Error()) }
			var conns []net.Conn
			defer func() {
				release.Wait()
				for _, c := range conns {
					c.Close()
				}
			}()
			defer done.Done()
			c, err := net.DialTimeout("tcp", net.JoinHostPort(f.addr, fmt.Sprint(portEcho)), 20*time.Second)
			if err != nil {
				fail(err)
				return
			}
			conns = append(conns, c)
			_ = c.SetDeadline(time.Now().Add(f.timeout))
			out := make([]byte, per)
			werr := make(chan error, 1)
			go func() { _, err := c.Write(out); werr <- err }()
			if _, err := io.ReadFull(c, make([]byte, per)); err != nil {
				fail(err)
				return
			}
			if err := <-werr; err != nil {
				fail(err)
				return
			}
			u, err := net.Dial("udp", net.JoinHostPort(f.addr, fmt.Sprint(portEcho)))
			if err != nil {
				fail(err)
				return
			}
			conns = append(conns, u)
			for i := 0; i < 5; i++ {
				if udpOnce(u.(*net.UDPConn), 512, 2) == "ok" {
					udpOK.Add(1)
				} else {
					udpLost.Add(1)
				}
			}
		}()
	}
	done.Wait()
	elapsed := time.Since(t0)
	release.Done()
	finished.Wait()
	v["workers"], v["bytesPerWorker"], v["seconds"] = f.conns, per, elapsed.Seconds()
	v["errors"], v["udpOK"], v["udpLost"] = errs.Load(), udpOK.Load(), udpLost.Load()
	if s, ok := lastErr.Load().(string); ok {
		v["lastError"] = s
	}
	if errs.Load() > 0 {
		return fmt.Errorf("%d of %d workers failed", errs.Load(), f.conns)
	}
	return nil
}
