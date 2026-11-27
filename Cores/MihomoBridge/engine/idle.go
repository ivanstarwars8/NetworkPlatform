package engine

import (
	"sync/atomic"
	"time"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// idleSweeper closes connections the core tracks (statistic.DefaultManager: every TCP connection and UDP session
// of every inbound) after they carried no data in either direction for the configured time.
//
// Why the bridge does this itself: the core's relay has no TCP idle timeout at all, and its UDP session timeout
// (tunnel/tunnel.go udpTimeout, 60 s in v1.19.34) is an unexported variable without a configuration key —
// tun.udp-timeout only reaches the system and gvisor stacks, the mips stack the bridge runs does not read it
// (sing-tun v0.4.29 NewMipstack). Closing a tracker is what the core's own controller does for "close
// connection": for TCP it closes the outbound connection and the relay then closes the tun side; for UDP it
// closes the outbound packet connection and the core's NAT goroutine removes the session.
// Documentation/Performance/memory-budget.md, Mihomo section.
type idleSweeper struct {
	tcp, udp time.Duration // 0 = off for that network
	every    time.Duration
	seen     map[string]idleSeen
	stop     chan struct{}
	done     chan struct{}

	closedTCP, closedUDP atomic.Uint64
}

type idleSeen struct {
	up, down int64
	since    time.Time // last time the counters moved (or the tracker first appeared)
}

// newIdleSweeper returns nil when both timeouts are off. The check interval is a quarter of the shorter
// timeout, between 250 ms and 5 s, so a connection is closed between timeout and timeout + interval.
func newIdleSweeper(tcp, udp time.Duration) *idleSweeper {
	if tcp <= 0 && udp <= 0 {
		return nil
	}
	shortest := tcp
	if shortest <= 0 || (udp > 0 && udp < shortest) {
		shortest = udp
	}
	every := min(max(shortest/4, 250*time.Millisecond), 5*time.Second)
	return &idleSweeper{tcp: tcp, udp: udp, every: every, seen: map[string]idleSeen{},
		stop: make(chan struct{}), done: make(chan struct{})}
}

func (s *idleSweeper) start() {
	go func() {
		defer close(s.done)
		t := time.NewTicker(s.every)
		defer t.Stop()
		for {
			select {
			case now := <-t.C:
				s.sweep(now)
			case <-s.stop:
				return
			}
		}
	}()
}

func (s *idleSweeper) close() {
	close(s.stop)
	<-s.done
}

// sweep is one pass over the tracked connections. Only the sweeper goroutine calls it (and tests).
func (s *idleSweeper) sweep(now time.Time) {
	alive := make(map[string]struct{}, len(s.seen))
	var idle []statistic.Tracker
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		info := c.Info()
		limit := s.tcp
		if info.Metadata != nil && info.Metadata.NetWork == C.UDP {
			limit = s.udp
		}
		if limit <= 0 {
			return true
		}
		id := c.ID()
		alive[id] = struct{}{}
		up, down := info.UploadTotal.Load(), info.DownloadTotal.Load()
		prev, ok := s.seen[id]
		if !ok || prev.up != up || prev.down != down {
			s.seen[id] = idleSeen{up: up, down: down, since: now}
			return true
		}
		if now.Sub(prev.since) >= limit {
			idle = append(idle, c)
		}
		return true
	})
	for id := range s.seen {
		if _, ok := alive[id]; !ok {
			delete(s.seen, id)
		}
	}
	// closed outside Range: Close removes the tracker from the manager's map
	for _, c := range idle {
		if c.Info().Metadata != nil && c.Info().Metadata.NetWork == C.UDP {
			s.closedUDP.Add(1)
		} else {
			s.closedTCP.Add(1)
		}
		delete(s.seen, c.ID())
		_ = c.Close()
	}
}
