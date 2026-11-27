package engine

import (
	"context"
	"encoding/json"
	"time"

	"github.com/xtls/xray-core/app/observatory"
	"github.com/xtls/xray-core/features/extension"
	"github.com/xtls/xray-core/features/outbound"
	"github.com/xtls/xray-core/features/routing"
)

// MemberObservation is what the core knows about one member of a group. The numbers are the core's own
// measurements (Xray observatory / burst observatory); nothing is measured here.
type MemberObservation struct {
	Tag   string `json:"tag"`
	Alive bool   `json:"alive"`
	// DelayMs is the last measured delay; 0 when the member has not been measured or is not alive.
	DelayMs        int64 `json:"delayMs,omitempty"`
	LastTryUnixMs  int64 `json:"lastTryUnixMs,omitempty"`
	LastSeenUnixMs int64 `json:"lastSeenUnixMs,omitempty"`
}

// GroupObservation is one balancer of the running configuration.
type GroupObservation struct {
	Tag string `json:"tag"`
	// Kind is the balancing strategy ("leastPing", "leastLoad", "random", "roundRobin").
	Kind string `json:"kind"`
	// Now is the member new connections go to, when the core can say: the pinned member, else the strategy's
	// pick, else the fallback. Empty when the strategy picks per connection (random, round robin).
	Now string `json:"now,omitempty"`
	// Fixed is the member pinned with Select; empty when the strategy chooses.
	Fixed   string              `json:"fixed,omitempty"`
	Members []MemberObservation `json:"members"`
}

// Observation is a snapshot of the groups of the running configuration.
type Observation struct {
	Groups []GroupObservation `json:"groups"`
}

// MaxObservedGroups and MaxObservedMembers bound a snapshot, so that the reply stays small whatever the
// configuration holds. Limits of this project.
const (
	MaxObservedGroups  = 16
	MaxObservedMembers = 512
)

type balancerSpec struct {
	Tag         string   `json:"tag"`
	Selector    []string `json:"selector"`
	FallbackTag string   `json:"fallbackTag"`
	Strategy    struct {
		Type string `json:"type"`
	} `json:"strategy"`
}

// balancers reads the balancer definitions of a configuration (already validated at start).
func balancers(config []byte) []balancerSpec {
	var doc struct {
		Routing struct {
			Balancers []balancerSpec `json:"balancers"`
		} `json:"routing"`
	}
	if json.Unmarshal(config, &doc) != nil {
		return nil
	}
	return doc.Routing.Balancers
}

// Observe returns the balancers of the running configuration with the observatory's view of their members.
// It reads in-process state only: no probe is sent and no listener is involved.
func (e *Engine) Observe() (obs Observation, rerr *Error) {
	defer guard(&rerr)
	r := e.current()
	if r == nil {
		return obs, newError(CodeNotRunning, "engine is not running")
	}
	obs.Groups = []GroupObservation{}
	specs := balancers(r.config)
	if len(specs) == 0 {
		return obs, nil
	}

	status := map[string]*observatory.OutboundStatus{}
	if o, ok := r.instance.GetFeature(extension.ObservatoryType()).(extension.Observatory); ok && o != nil {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		msg, err := o.GetObservation(ctx)
		cancel()
		if err == nil {
			if result, ok := msg.(*observatory.ObservationResult); ok {
				for _, s := range result.GetStatus() {
					status[s.GetOutboundTag()] = s
				}
			}
		}
	}
	selector, _ := r.instance.GetFeature(outbound.ManagerType()).(outbound.HandlerSelector)
	router, _ := r.instance.GetFeature(routing.RouterType()).(routing.Router)
	overrider, _ := router.(routing.BalancerOverrider)
	principle, _ := router.(routing.BalancerPrincipleTarget)

	total := 0
	for _, spec := range specs {
		if len(obs.Groups) == MaxObservedGroups {
			break
		}
		g := GroupObservation{Tag: spec.Tag, Kind: spec.Strategy.Type, Members: []MemberObservation{}}
		if g.Kind == "" {
			g.Kind = "random"
		}
		members := spec.Selector
		if selector != nil {
			// The core's own prefix matching, so the list is exactly what the balancer chooses from.
			members = selector.Select(spec.Selector)
		}
		for _, tag := range members {
			if total == MaxObservedMembers {
				break
			}
			total++
			m := MemberObservation{Tag: tag}
			if s := status[tag]; s != nil {
				m.Alive = s.GetAlive()
				if m.Alive && s.GetDelay() > 0 {
					m.DelayMs = s.GetDelay()
				}
				m.LastTryUnixMs = s.GetLastTryTime() * 1000
				m.LastSeenUnixMs = s.GetLastSeenTime() * 1000
			}
			g.Members = append(g.Members, m)
		}
		if overrider != nil {
			g.Fixed, _ = overrider.GetOverrideTarget(spec.Tag)
		}
		switch {
		case g.Fixed != "":
			g.Now = g.Fixed
		case g.Kind == "leastPing" && principle != nil:
			if picks, err := principle.GetPrincipleTarget(spec.Tag); err == nil && len(picks) > 0 && picks[0] != "" {
				g.Now = picks[0]
			} else {
				g.Now = spec.FallbackTag
			}
		}
		obs.Groups = append(obs.Groups, g)
	}
	return obs, nil
}

// Select pins the members new connections of a balancer go to, without restarting anything: existing
// connections keep their outbound. An empty member clears the pin and gives the choice back to the strategy.
// The member must be one the balancer chooses from.
func (e *Engine) Select(group, member string) (rerr *Error) {
	defer guard(&rerr)
	r := e.current()
	if r == nil {
		return newError(CodeNotRunning, "engine is not running")
	}
	var spec *balancerSpec
	specs := balancers(r.config)
	for i := range specs {
		if specs[i].Tag == group {
			spec = &specs[i]
			break
		}
	}
	if spec == nil {
		return newError(CodeInvalidArgument, "no balancer with that tag")
	}
	if member != "" {
		members := spec.Selector
		if selector, ok := r.instance.GetFeature(outbound.ManagerType()).(outbound.HandlerSelector); ok {
			members = selector.Select(spec.Selector)
		}
		found := false
		for _, tag := range members {
			if tag == member {
				found = true
				break
			}
		}
		if !found {
			return newError(CodeInvalidArgument, "the balancer has no such member")
		}
	}
	router, _ := r.instance.GetFeature(routing.RouterType()).(routing.Router)
	overrider, ok := router.(routing.BalancerOverrider)
	if !ok {
		return newError(CodeConfigUnsupport, "the router cannot pin a balancer member")
	}
	if err := overrider.SetOverrideTarget(group, member); err != nil {
		return newError(CodeInvalidArgument, "%v", err)
	}
	return nil
}
