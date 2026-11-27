package engine

import (
	"encoding/json"
	"sort"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/tunnel"
)

// MemberObservation is what the core knows about one member of a group: the result of the group's own
// health checks (url-test, fallback). Nothing is measured here. Same JSON shape as the Xray bridge.
type MemberObservation struct {
	Tag   string `json:"tag"`
	Alive bool   `json:"alive"`
	// DelayMs is the last measured delay; 0 when the member has not been measured or is not alive.
	DelayMs        int64 `json:"delayMs,omitempty"`
	LastTryUnixMs  int64 `json:"lastTryUnixMs,omitempty"`
	LastSeenUnixMs int64 `json:"lastSeenUnixMs,omitempty"`
}

// GroupObservation is one proxy group of the running configuration.
type GroupObservation struct {
	Tag string `json:"tag"`
	// Kind is the group type as the core names it ("URLTest", "Selector", "Fallback", "LoadBalance").
	Kind string `json:"kind"`
	// Now is the member the group uses now, as the core reports it.
	Now string `json:"now,omitempty"`
	// Fixed is the member pinned with Select (for a selector: its current member); empty when the group chooses.
	Fixed   string              `json:"fixed,omitempty"`
	Members []MemberObservation `json:"members"`
}

// Observation is a snapshot of the groups of the running configuration.
type Observation struct {
	Groups []GroupObservation `json:"groups"`
}

// MaxObservedGroups and MaxObservedMembers bound a snapshot. Limits of this project, as in the Xray bridge.
const (
	MaxObservedGroups  = 16
	MaxObservedMembers = 512
)

// builtinGroup is the selector the core adds to every configuration; it is not part of the compiled profile.
const builtinGroup = "GLOBAL"

type groupState struct {
	TestURL string `json:"testUrl"`
	Fixed   string `json:"fixed"`
}

// Observe returns the proxy groups of the running configuration with their members' health. It reads the
// core's in-process state only: no health check is started and no controller listener is involved.
func (e *Engine) Observe() (obs Observation, rerr *Error) {
	defer guard(&rerr)
	if e.current() == nil {
		return obs, newError(CodeNotRunning, "engine is not running")
	}
	obs.Groups = []GroupObservation{}
	proxies := tunnel.Proxies()
	names := make([]string, 0, len(proxies))
	for name := range proxies {
		names = append(names, name)
	}
	sort.Strings(names)
	total := 0
	for _, name := range names {
		if name == builtinGroup || len(obs.Groups) == MaxObservedGroups {
			continue
		}
		p := proxies[name]
		group, ok := p.Adapter().(outboundgroup.ProxyGroup)
		if !ok {
			continue
		}
		var state groupState
		if raw, err := json.Marshal(p.Adapter()); err == nil {
			_ = json.Unmarshal(raw, &state)
		}
		g := GroupObservation{Tag: name, Kind: p.Type().String(), Now: group.Now(), Fixed: state.Fixed, Members: []MemberObservation{}}
		if _, isSelector := p.Adapter().(*outboundgroup.Selector); isSelector {
			g.Fixed = g.Now
		}
		for _, member := range group.Proxies() {
			if total == MaxObservedMembers {
				break
			}
			total++
			m := MemberObservation{Tag: member.Name()}
			history := member.DelayHistory()
			if state.TestURL != "" {
				history = member.ExtraDelayHistories()[state.TestURL].History
			}
			if len(history) > 0 {
				last := history[len(history)-1]
				m.Alive = last.Delay > 0
				if m.Alive {
					m.DelayMs = int64(last.Delay)
					m.LastSeenUnixMs = last.Time.UnixMilli()
				}
				m.LastTryUnixMs = last.Time.UnixMilli()
			}
			g.Members = append(g.Members, m)
		}
		obs.Groups = append(obs.Groups, g)
	}
	return obs, nil
}

// Select pins the member of a group new connections go to, without restarting anything: existing
// connections keep their proxy. An empty member clears the pin of a url-test or fallback group and gives the
// choice back to its health checks; a selector always has a member. A url-test group uses a pinned member
// only while its health check finds it alive (the core's rule).
func (e *Engine) Select(group, member string) (rerr *Error) {
	defer guard(&rerr)
	if e.current() == nil {
		return newError(CodeNotRunning, "engine is not running")
	}
	p, ok := tunnel.Proxies()[group]
	if !ok || group == builtinGroup {
		return newError(CodeInvalidArgument, "no group with that tag")
	}
	selectable, ok := p.Adapter().(outboundgroup.SelectAble)
	if !ok {
		return newError(CodeConfigUnsupport, "the group cannot pin a member")
	}
	if member == "" {
		if _, isSelector := p.Adapter().(*outboundgroup.Selector); isSelector {
			return newError(CodeInvalidArgument, "a selector needs a member")
		}
		selectable.ForceSet("")
		return nil
	}
	if err := selectable.Set(member); err != nil {
		return newError(CodeInvalidArgument, "the group has no such member")
	}
	return nil
}
