package engine

import (
	"fmt"
	"io"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

const directFlowYAML = "mode: rule\nrules:\n  - MATCH,DIRECT\ntun:\n  enable: true\n  stack: mips\n  mtu: 1500\n"

func TestMobileProfileOptions(t *testing.T) {
	o, err := ParseOptions([]byte(`{"memory":{"profile":"mobile"},"tun":{"mode":"flow"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if o.Memory.LimitBytes != MobileMemoryLimitBytes || o.Memory.GCPercent != MobileGCPercent ||
		o.Tun.OutQueueBytes != MobileOutQueueBytes || o.Tun.InQueueBytes != MobileInQueueBytes ||
		o.Tun.MaxFlows != MobileMaxFlows || o.LogQueueSize != MobileLogQueueSize ||
		o.TCPIdleTimeoutMs != MobileTCPIdleTimeoutMs || o.UDPIdleTimeoutMs != MobileUDPIdleTimeoutMs {
		t.Fatalf("mobile defaults not applied: %+v", o)
	}
	// explicit values win over the profile
	o, err = ParseOptions([]byte(`{"memory":{"profile":"mobile","limitBytes":67108864,"gcPercent":50},
		"logQueueSize":64,"tcpIdleTimeoutMs":60000,"udpIdleTimeoutMs":10000,
		"tun":{"mode":"flow","outQueueBytes":1048576,"inQueueBytes":131072,"maxFlows":7}}`))
	if err != nil {
		t.Fatal(err)
	}
	if o.Memory.LimitBytes != 64<<20 || o.Memory.GCPercent != 50 || o.LogQueueSize != 64 ||
		o.Tun.OutQueueBytes != 1<<20 || o.Tun.InQueueBytes != 128<<10 || o.Tun.MaxFlows != 7 ||
		o.TCPIdleTimeoutMs != 60000 || o.UDPIdleTimeoutMs != 10000 {
		t.Fatalf("explicit options overridden: %+v", o)
	}
	// without a profile nothing new is switched on
	o, _ = ParseOptions(nil)
	if o.Tun.MaxFlows != 0 || o.TCPIdleTimeoutMs != 0 || o.UDPIdleTimeoutMs != 0 || o.Memory.LimitBytes != 0 {
		t.Fatalf("defaults changed: %+v", o)
	}
	for _, bad := range []string{
		`{"memory":{"profile":"tiny"}}`,
		`{"tun":{"maxFlows":-1}}`,
		`{"tcpIdleTimeoutMs":30}`, // seconds given as milliseconds
		`{"udpIdleTimeoutMs":999}`,
		`{"tun":{"tcpIdleTimeoutMs":30000}}`, // not a tun option
	} {
		if _, err := ParseOptions([]byte(bad)); err == nil || err.Code != CodeInvalidArgument {
			t.Errorf("%s: %v", bad, err)
		}
	}
	if s := newIdleSweeper(0, 0); s != nil {
		t.Error("sweeper without timeouts")
	}
	if s := newIdleSweeper(300*time.Second, 30*time.Second); s.every != 5*time.Second {
		t.Errorf("check interval %v, want 5s", s.every)
	}
	if s := newIdleSweeper(0, time.Second); s.every != 250*time.Millisecond {
		t.Errorf("check interval %v, want 250ms", s.every)
	}
}

// TestFlowMaxFlows: with tun.maxFlows 2 the third concurrent TCP connection is closed without reaching the
// core; after one of the first two ends, a new one passes again.
func TestFlowMaxFlows(t *testing.T) {
	host := hostAddr(t)
	echo := echoServer(t, host)
	e := New()
	mustStart(t, e, directFlowYAML, Options{Tun: TunOptions{Mode: TunFlow, MaxFlows: 2}})
	p := newOSPeer(t, e, 1500)
	target := fmt.Sprintf("%s:%d", host, echo)
	a, b := p.dialTCP(target), p.dialTCP(target)
	echoTCP(t, a, 4096)
	echoTCP(t, b, 4096)

	c := p.dialTCP(target) // the peer stack completes the handshake with the bridge's stack, then gets reset
	_ = c.SetDeadline(time.Now().Add(10 * time.Second))
	_, _ = c.Write([]byte("x"))
	if _, err := io.ReadFull(c, make([]byte, 1)); err == nil {
		t.Fatal("third connection over tun.maxFlows=2 was relayed")
	}
	c.Close()
	st, _ := e.Stats()
	if st.Tun.FlowsRejected != 1 || st.Tun.FlowsActive != 2 || st.Tun.FlowsHighest != 2 {
		t.Fatalf("counters after rejection: %+v", *st.Tun)
	}

	a.Close()
	waitFor(t, "closed connection no longer counted", func() bool { st, _ := e.Stats(); return st.Tun.FlowsActive == 1 })
	d := p.dialTCP(target)
	echoTCP(t, d, 4096)
	d.Close()
	b.Close()
}

// TestFlowTCPIdleTimeout: a connection without data for tcpIdleTimeoutMs is closed by the bridge, one with data
// more often than that is not.
func TestFlowTCPIdleTimeout(t *testing.T) {
	host := hostAddr(t)
	echo := echoServer(t, host)
	e := New()
	mustStart(t, e, directFlowYAML, Options{TCPIdleTimeoutMs: 1000, Tun: TunOptions{Mode: TunFlow}})
	p := newOSPeer(t, e, 1500)
	target := fmt.Sprintf("%s:%d", host, echo)

	quiet, busy := p.dialTCP(target), p.dialTCP(target)
	echoTCP(t, quiet, 1024)
	echoTCP(t, busy, 1024)
	for i := 0; i < 10; i++ { // 3 s with traffic every 300 ms on busy
		time.Sleep(300 * time.Millisecond)
		echoTCP(t, busy, 512)
	}
	_ = quiet.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.ReadFull(quiet, make([]byte, 1)); err == nil {
		t.Fatal("idle connection was not closed")
	}
	echoTCP(t, busy, 512) // still open
	st, _ := e.Stats()
	if st.IdleClosedTCP != 1 || st.IdleClosedUDP != 0 {
		t.Fatalf("idle closed tcp=%d udp=%d, want 1/0", st.IdleClosedTCP, st.IdleClosedUDP)
	}
	busy.Close()
	quiet.Close()
}

// TestFlowUDPIdleTimeout: a UDP session without packets for udpIdleTimeoutMs is ended by the bridge (well
// before the core's own 60 s), one with packets more often than that is not; a new datagram after the
// timeout opens a new session.
func TestFlowUDPIdleTimeout(t *testing.T) {
	host := hostAddr(t)
	echo := echoServer(t, host)
	e := New()
	mustStart(t, e, directFlowYAML, Options{UDPIdleTimeoutMs: 1000, Tun: TunOptions{Mode: TunFlow}})
	p := newOSPeer(t, e, 1500)
	target := fmt.Sprintf("%s:%d", host, echo)

	quiet, busy := p.dialUDP(target), p.dialUDP(target)
	echoUDP(t, quiet, 100)
	echoUDP(t, busy, 100)
	if n := udpSessions(); n != 2 {
		t.Fatalf("%d UDP sessions, want 2", n)
	}
	for i := 0; i < 10; i++ {
		time.Sleep(300 * time.Millisecond)
		echoUDP(t, busy, 100)
	}
	st, _ := e.Stats()
	if n := udpSessions(); n != 1 || st.IdleClosedUDP != 1 {
		t.Fatalf("after 3 s: %d UDP sessions (want 1), idle closed %d (want 1)", n, st.IdleClosedUDP)
	}
	echoUDP(t, quiet, 100) // a new session for the same socket
	if n := udpSessions(); n != 2 {
		t.Fatalf("%d UDP sessions after the quiet socket spoke again, want 2", n)
	}
	quiet.Close()
	busy.Close()
}

func udpSessions() (n int) {
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		if m := c.Info().Metadata; m != nil && m.NetWork == C.UDP {
			n++
		}
		return true
	})
	return n
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting: %s", what)
		}
		time.Sleep(20 * time.Millisecond)
	}
}
