package engine

import (
	"context"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func rssKiB() int {
	data, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "VmRSS:") {
			f := strings.Fields(line)
			if len(f) >= 2 {
				n, _ := strconv.Atoi(f[1])
				return n
			}
		}
	}
	return 0
}

// TestMemoryProfiles measures what the memory options cost and save under load: 8 parallel downloads through
// the packet interface and a VLESS+REALITY+Vision outbound to a stock xray server in another process (so
// that only the client's memory is in this process). It is a measurement; it asserts only completion.
func TestMemoryProfiles(t *testing.T) {
	if testing.Short() || stockXray == "" {
		t.Skip("measurement; needs NP_STOCK_XRAY")
	}
	const streams, perStream = 8, 48 << 20
	source := startTCPSource(t, perStream)
	serverPort := freePort(t)
	in, out := protoCases()[1].build(t, serverPort)
	startServer(t, serverConfig(t, in, serverPort, fmt.Sprintf("127.0.0.1:%d", source)), serverPort)
	out["tag"] = "proxy"
	config := mustJSON(t, obj{"inbounds": arr{tunInbound(1500)}, "outbounds": arr{out}})

	profiles := []struct {
		name string
		mem  MemoryOptions
	}{
		{"runtime defaults (GOGC=100, no limit)", MemoryOptions{}},
		{"limit 40 MiB, GOGC=100", MemoryOptions{LimitBytes: 40 << 20}},
		{"limit 40 MiB, GOGC=50", MemoryOptions{LimitBytes: 40 << 20, GCPercent: 50}},
		{"limit 30 MiB, GOGC=10, FreeOSMemory 1s", MemoryOptions{LimitBytes: 30 << 20, GCPercent: 10, FreeOSMemoryIntervalMs: 1000}},
		{"limit 24 MiB, GOGC=50", MemoryOptions{LimitBytes: 24 << 20, GCPercent: 50}},
	}
	for _, pr := range profiles {
		e := New()
		if err := e.Start(context.Background(), []byte(config), Options{Tun: TunOptions{Mode: TunFlow}, Memory: pr.mem}); err != nil {
			t.Fatal(err)
		}
		p := newFlowPeerNoCleanup(t, e, 1500)
		idle := ReadMemoryStats()

		stop := make(chan struct{})
		var peakMapped, peakLive, peakObjects uint64
		var peakRSS int
		var sampler sync.WaitGroup
		sampler.Add(1)
		go func() {
			defer sampler.Done()
			for {
				m := ReadMemoryStats()
				peakMapped, peakLive, peakObjects = max(peakMapped, m.Mapped), max(peakLive, m.HeapLive), max(peakObjects, m.HeapObjects)
				peakRSS = max(peakRSS, rssKiB())
				select {
				case <-stop:
					return
				case <-time.After(10 * time.Millisecond):
				}
			}
		}()

		gc0 := ReadMemoryStats().GCCycles
		start := time.Now()
		var wg sync.WaitGroup
		for i := 0; i < streams; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				c := p.dialTCP("10.9.0.1:80")
				_ = c.SetDeadline(time.Now().Add(5 * time.Minute))
				if n, err := io.Copy(io.Discard, c); err != nil || n != perStream {
					t.Errorf("%s: stream got %d bytes, %v", pr.name, n, err)
				}
				c.Close()
			}()
		}
		wg.Wait()
		elapsed := time.Since(start)
		close(stop)
		sampler.Wait()
		end := ReadMemoryStats()
		tc := *e.Health().Tun
		t.Logf("%-40s | %4.0f Mbit/s | Go mapped: idle %4.1f peak %4.1f MiB | heap live peak %4.1f, objects peak %4.1f MiB | RSS peak %5.1f MiB | GC cycles %4d | tun drops %d",
			pr.name, float64(streams*perStream)*8/elapsed.Seconds()/1e6,
			float64(idle.Mapped)/(1<<20), float64(peakMapped)/(1<<20), float64(peakLive)/(1<<20), float64(peakObjects)/(1<<20),
			float64(peakRSS)/1024, end.GCCycles-gc0, tc.TxDropped)
		p.close()
		if err := e.Stop(10 * time.Second); err != nil {
			t.Fatal(err)
		}
		time.Sleep(6 * time.Second) // let the late releases of this run go before the next profile is measured
	}
}
