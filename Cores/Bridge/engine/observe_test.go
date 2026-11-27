package engine

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// TestObserveAndSelect starts a balancer of two freedom outbounds with an observatory that probes a local
// HTTP server, waits for the core's measurements, and pins and unpins a member.
func TestObserveAndSelect(t *testing.T) {
	probe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) }))
	defer probe.Close()

	e := New()
	if _, err := e.Observe(); CodeOf(err) != CodeNotRunning {
		t.Fatalf("observe idle: %v", err)
	}
	if err := e.Select("group-0000", ""); CodeOf(err) != CodeNotRunning {
		t.Fatalf("select idle: %v", err)
	}
	cfg := `{"outbounds":[{"tag":"proxy-0000","protocol":"freedom"},{"tag":"proxy-0001","protocol":"freedom"}],
"observatory":{"subjectSelector":["proxy-0000","proxy-0001"],"probeURL":"` + probe.URL + `/","probeInterval":"1s"},
"routing":{"balancers":[{"tag":"group-0000","selector":["proxy-0000","proxy-0001"],"fallbackTag":"proxy-0000","strategy":{"type":"leastPing"}}],
"rules":[{"type":"field","network":"tcp,udp","balancerTag":"group-0000"}]}}`
	mustStart(t, e, cfg, Options{})

	var obs Observation
	deadline := time.Now().Add(10 * time.Second)
	for {
		var err *Error
		obs, err = e.Observe()
		if err != nil {
			t.Fatalf("observe: %v", err)
		}
		if len(obs.Groups) == 1 && len(obs.Groups[0].Members) == 2 &&
			obs.Groups[0].Members[0].Alive && obs.Groups[0].Members[1].Alive {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("members not measured in time: %+v", obs)
		}
		time.Sleep(100 * time.Millisecond)
	}
	g := obs.Groups[0]
	if g.Tag != "group-0000" || g.Kind != "leastPing" || g.Fixed != "" {
		t.Fatalf("group %+v", g)
	}
	if g.Now != "proxy-0000" && g.Now != "proxy-0001" {
		t.Fatalf("now %q", g.Now)
	}
	for _, m := range g.Members {
		if m.DelayMs <= 0 || m.LastTryUnixMs == 0 {
			t.Fatalf("member %+v", m)
		}
	}

	if err := e.Select("group-0000", "proxy-0001"); err != nil {
		t.Fatalf("select: %v", err)
	}
	if obs, _ = e.Observe(); obs.Groups[0].Fixed != "proxy-0001" || obs.Groups[0].Now != "proxy-0001" {
		t.Fatalf("after select: %+v", obs.Groups[0])
	}
	if err := e.Select("group-0000", "proxy-0009"); CodeOf(err) != CodeInvalidArgument {
		t.Fatalf("unknown member: %v", err)
	}
	if err := e.Select("group-0009", ""); CodeOf(err) != CodeInvalidArgument {
		t.Fatalf("unknown group: %v", err)
	}
	if err := e.Select("group-0000", ""); err != nil {
		t.Fatalf("clear: %v", err)
	}
	if obs, _ = e.Observe(); obs.Groups[0].Fixed != "" {
		t.Fatalf("after clear: %+v", obs.Groups[0])
	}
}

// TestObserveWithoutBalancers reports no groups for a configuration without balancers.
func TestObserveWithoutBalancers(t *testing.T) {
	e := New()
	mustStart(t, e, minimalConfig, Options{})
	obs, err := e.Observe()
	if err != nil || obs.Groups == nil || len(obs.Groups) != 0 {
		t.Fatalf("observe: %+v %v", obs, err)
	}
}
