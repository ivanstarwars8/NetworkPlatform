package engine

import (
	"context"
	"os"
	"runtime"
	"strconv"
	"testing"
	"time"
)

func heapInUse() uint64 {
	runtime.GC()
	runtime.GC()
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	return m.HeapAlloc
}

// TestStartStopCycles starts and stops a realistic client configuration 200 times after a warm-up (NP_CYCLES overrides) and
// checks that neither goroutines nor heap accumulate. Traffic flows through SOCKS and through the packet
// interface on a part of the cycles so that the teardown of live connections is covered too.
func TestStartStopCycles(t *testing.T) {
	cycles := 200
	if v, err := strconv.Atoi(os.Getenv("NP_CYCLES")); err == nil && v > 0 {
		cycles = v
	}
	if testing.Short() {
		cycles = 20
	}
	echo := samePortEcho(t)
	socksPort := freePort(t)
	_, public := newX25519(t)
	config := mustJSON(t, obj{
		"log": obj{"loglevel": "warning"},
		"inbounds": arr{
			tunInbound(1500),
			obj{"tag": "socks", "listen": "127.0.0.1", "port": socksPort, "protocol": "socks", "settings": obj{"udp": true}},
		},
		"outbounds": arr{
			obj{"tag": "direct", "protocol": "freedom", "settings": obj{"redirect": "127.0.0.1:" + itoa(echo)}},
			// never dialled here; present so that the cycle constructs and destroys a full proxy outbound
			obj{"tag": "proxy", "protocol": "vless",
				"settings": obj{"address": "127.0.0.1", "port": 9, "id": testUUID, "encryption": "none", "flow": "xtls-rprx-vision"},
				"streamSettings": obj{"network": "raw", "security": "reality", "realitySettings": obj{
					"serverName": "reality.test", "fingerprint": "chrome", "password": public, "shortId": "0123abcd"}}},
			obj{"tag": "dns-out", "protocol": "dns"},
			obj{"tag": "block", "protocol": "blackhole"},
		},
		"dns": obj{"servers": arr{"127.0.0.1"}},
		"routing": obj{"domainStrategy": "AsIs", "rules": arr{
			obj{"type": "field", "inboundTag": arr{"tun-in"}, "port": 53, "outboundTag": "dns-out"},
			obj{"type": "field", "ip": arr{"192.0.2.0/24"}, "outboundTag": "proxy"},
			obj{"type": "field", "ip": arr{"198.51.100.0/24"}, "outboundTag": "block"},
		}},
	})
	opts := Options{Tun: TunOptions{Mode: TunFlow}, Memory: MemoryOptions{LimitBytes: 48 << 20, GCPercent: 50}}

	e := New()
	cycle := func(i int) {
		if err := e.Start(context.Background(), []byte(config), opts); err != nil {
			t.Fatalf("cycle %d: start: %v", i, err)
		}
		if i%10 == 0 {
			c := socksConnect(t, socksPort, "127.0.0.1", echo)
			echoTCP(t, c, 64<<10)
			// left open on purpose on every other traffic cycle: Stop has to cut it
			if i%20 == 0 {
				c.Close()
			} else {
				defer c.Close()
			}
			p := newFlowPeerNoCleanup(t, e, 1500)
			pc := p.dialTCP("10.9.0.1:80")
			echoTCP(t, pc, 64<<10)
			udpEchoThroughPeer(t, p, "10.9.0.1:80", 512)
			if i%20 == 0 {
				pc.Close()
			}
			defer p.close()
		}
		if err := e.Stop(10 * time.Second); err != nil {
			t.Fatalf("cycle %d: stop: %v", i, err)
		}
		if st := e.State(); st != StateIdle {
			t.Fatalf("cycle %d: state %s after stop", i, st)
		}
	}

	// Warm up over two traffic cycles: lazily initialised globals of the core and the runtime, and the
	// long-lived goroutines of this test's own echo servers, are not leaks.
	const warmup = 20
	for i := 1; i <= warmup; i++ {
		cycle(i)
	}
	baseGoroutines, baseHeap := settleGoroutines(), heapInUse()
	start := time.Now()
	for i := warmup + 1; i <= warmup+cycles; i++ {
		cycle(i)
		if i%50 == 0 {
			g := settleGoroutines()
			t.Logf("after %3d cycles: goroutines=%d heap=%d KiB", i, g, heapInUse()>>10)
		}
	}
	elapsed := time.Since(start)
	endGoroutines, endHeap := settleGoroutines(), heapInUse()
	growth := int64(endHeap) - int64(baseHeap)
	t.Logf("%d cycles in %s (%.1f ms/cycle): goroutines %d -> %d, heap %d -> %d KiB (%+d KiB, %+d B/cycle)",
		cycles, elapsed.Round(time.Millisecond), float64(elapsed.Milliseconds())/float64(cycles),
		baseGoroutines, endGoroutines, baseHeap>>10, endHeap>>10, growth>>10, growth/int64(cycles))
	if endGoroutines > baseGoroutines+2 {
		_ = os.WriteFile("goroutines-leak.txt", []byte(goroutineDump()), 0o644)
		t.Errorf("goroutines leaked: %d -> %d (dump in goroutines-leak.txt)", baseGoroutines, endGoroutines)
	}
	// Some memory of a finished run is released late: objects still referenced by timers of the core that
	// have not fired yet. Follow the heap until it is back near the baseline, for a bounded time, and report
	// the whole trajectory; what is still there after that is a leak.
	const allowed = 1 << 20
	for waited := time.Duration(0); growth > allowed && waited < 60*time.Second; waited += 5 * time.Second {
		time.Sleep(5 * time.Second)
		endHeap = heapInUse()
		growth = int64(endHeap) - int64(baseHeap)
		t.Logf("  +%2.0fs idle: heap %d KiB (%+d KiB vs baseline), goroutines %d", (waited + 5*time.Second).Seconds(), endHeap>>10, growth>>10, runtime.NumGoroutine())
	}
	if growth > allowed {
		t.Errorf("heap grew by %d KiB over %d cycles and did not come back", growth>>10, cycles)
	}
	if got := ReadMemoryStats(); got.Limit == 48<<20 {
		t.Error("memory limit of the run survived the stop")
	}
}
