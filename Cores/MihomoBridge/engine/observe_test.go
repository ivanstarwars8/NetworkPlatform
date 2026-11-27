package engine

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/metacubex/mihomo/tunnel"
)

// TestObserveAndSelect starts a url-test group of two direct proxies whose health check probes a local HTTP
// server, waits for the core's measurements, and pins and unpins a member.
func TestObserveAndSelect(t *testing.T) {
	probe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) }))
	defer probe.Close()

	e := New()
	if _, err := e.Observe(); err == nil || err.Code != CodeNotRunning {
		t.Fatalf("observe idle: %v", err)
	}
	if err := e.Select("group-0000", ""); err == nil || err.Code != CodeNotRunning {
		t.Fatalf("select idle: %v", err)
	}
	cfg := fmt.Sprintf(`mode: rule
proxies:
  - {name: proxy-0000, type: direct}
  - {name: proxy-0001, type: direct}
proxy-groups:
  - {name: group-0000, type: url-test, proxies: [proxy-0000, proxy-0001], url: "%s/", interval: 300, lazy: false}
  - {name: group-0001, type: select, proxies: [group-0000, proxy-0000, proxy-0001]}
rules:
  - MATCH,group-0001
`, probe.URL)
	mustStart(t, e, cfg, Options{})

	find := func(obs Observation, tag string) *GroupObservation {
		for i := range obs.Groups {
			if obs.Groups[i].Tag == tag {
				return &obs.Groups[i]
			}
		}
		return nil
	}
	// Wait for the one health check at start through the core's locked history copy, then observe: the
	// pinned core reads its delay queue without the lock in URLTest.fast (queue.Last checks len unlocked), so
	// observing while a check writes is a race inside the core (the core's own dispatch path does the same).
	deadline := time.Now().Add(10 * time.Second)
	for {
		measured := 0
		for _, name := range []string{"proxy-0000", "proxy-0001"} {
			if p := tunnel.Proxies()[name]; p != nil && len(p.ExtraDelayHistories()[probe.URL+"/"].History) > 0 {
				measured++
			}
		}
		if measured == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("members not measured in time")
		}
		time.Sleep(100 * time.Millisecond)
	}
	obs, err := e.Observe()
	if err != nil {
		t.Fatalf("observe: %v", err)
	}
	if g := find(obs, "group-0000"); g == nil || len(g.Members) != 2 || !g.Members[0].Alive || !g.Members[1].Alive {
		t.Fatalf("members: %+v", obs)
	}
	if len(obs.Groups) != 2 || find(obs, "GLOBAL") != nil {
		t.Fatalf("groups %+v", obs.Groups)
	}
	auto := find(obs, "group-0000")
	if auto.Kind != "URLTest" || auto.Fixed != "" || (auto.Now != "proxy-0000" && auto.Now != "proxy-0001") {
		t.Fatalf("url-test %+v", auto)
	}
	for _, m := range auto.Members {
		if m.DelayMs <= 0 || m.LastTryUnixMs == 0 {
			t.Fatalf("member %+v", m)
		}
	}
	choice := find(obs, "group-0001")
	if choice.Kind != "Selector" || choice.Now != "group-0000" || choice.Fixed != "group-0000" {
		t.Fatalf("selector %+v", choice)
	}

	if err := e.Select("group-0001", "proxy-0001"); err != nil {
		t.Fatalf("select: %v", err)
	}
	if obs, _ = e.Observe(); find(obs, "group-0001").Now != "proxy-0001" {
		t.Fatalf("after select: %+v", find(obs, "group-0001"))
	}
	if err := e.Select("group-0000", "proxy-0001"); err != nil {
		t.Fatalf("pin url-test: %v", err)
	}
	if obs, _ = e.Observe(); find(obs, "group-0000").Fixed != "proxy-0001" || find(obs, "group-0000").Now != "proxy-0001" {
		t.Fatalf("after pin: %+v", find(obs, "group-0000"))
	}
	if err := e.Select("group-0000", ""); err != nil {
		t.Fatalf("clear: %v", err)
	}
	if obs, _ = e.Observe(); find(obs, "group-0000").Fixed != "" {
		t.Fatalf("after clear: %+v", find(obs, "group-0000"))
	}
	if err := e.Select("group-0001", ""); err == nil || err.Code != CodeInvalidArgument {
		t.Fatalf("empty member of a selector: %v", err)
	}
	if err := e.Select("group-0001", "proxy-0009"); err == nil || err.Code != CodeInvalidArgument {
		t.Fatalf("unknown member: %v", err)
	}
	if err := e.Select("GLOBAL", "DIRECT"); err == nil || err.Code != CodeInvalidArgument {
		t.Fatalf("builtin group: %v", err)
	}
}
