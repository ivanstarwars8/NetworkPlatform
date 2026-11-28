package engine

import (
	"fmt"
	"strings"
	"testing"
)

// TestConnectionsList: open connections through the flow tun appear in Connections with their destination,
// network, rule and byte counts; the list is bounded by the limit; a closed connection leaves it.
func TestConnectionsList(t *testing.T) {
	if _, err := New().Connections(0); err == nil || err.Code != CodeNotRunning {
		t.Fatalf("Connections while idle: %v, want not_running", err)
	}
	host := hostAddr(t)
	echo := echoServer(t, host)
	e := New()
	mustStart(t, e, directFlowYAML, Options{Tun: TunOptions{Mode: TunFlow}})
	p := newOSPeer(t, e, 1500)
	target := fmt.Sprintf("%s:%d", host, echo)
	a, b := p.dialTCP(target), p.dialTCP(target)
	echoTCP(t, a, 4096)
	echoTCP(t, b, 2048)

	var list Connections
	waitFor(t, "two tracked connections with traffic", func() bool {
		var err *Error
		list, err = e.Connections(0)
		if err != nil || list.Total != 2 || len(list.Items) != 2 {
			return false
		}
		return list.Items[0].Download > 0 && list.Items[1].Download > 0
	})
	for _, c := range list.Items {
		if c.Network != "tcp" || !strings.HasSuffix(c.Destination, fmt.Sprintf(":%d", echo)) {
			t.Errorf("connection %+v: want tcp to port %d", c, echo)
		}
		if !strings.HasPrefix(c.Rule, "Match") || len(c.Chain) == 0 || c.Chain[len(c.Chain)-1] != "DIRECT" {
			t.Errorf("connection %+v: want rule Match and chain ending in DIRECT", c)
		}
		if c.ID == "" || c.StartMs <= 0 || c.Upload <= 0 {
			t.Errorf("connection %+v: missing id, start or upload", c)
		}
	}
	if list.Items[0].StartMs < list.Items[1].StartMs {
		t.Errorf("items not newest first: %d < %d", list.Items[0].StartMs, list.Items[1].StartMs)
	}

	limited, err := e.Connections(1)
	if err != nil || limited.Total != 2 || len(limited.Items) != 1 {
		t.Fatalf("Connections(1): total %d items %d err %v, want 2/1", limited.Total, len(limited.Items), err)
	}

	a.Close()
	waitFor(t, "closed connection leaves the list", func() bool {
		l, err := e.Connections(0)
		return err == nil && l.Total == 1
	})
	b.Close()
}
