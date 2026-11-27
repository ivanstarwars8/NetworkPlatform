// Differential test: evaluates the corpus exported by the Swift RoutingEngine
// with the real Xray router (app/router, configured through infra/conf the
// same way a JSON engine config is) and compares the decisions.
//
// Run: go test -run TestParity -v ./...
// Environment:
//
//	PARITY_CORPUS  corpus path (default testdata/corpus.json)
//	PARITY_OUT     optional path for a JSON summary
package parity

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/xtls/xray-core/app/router"
	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/features/dns"
	"github.com/xtls/xray-core/features/outbound"
	"github.com/xtls/xray-core/features/routing"
	routing_session "github.com/xtls/xray-core/features/routing/session"
	"github.com/xtls/xray-core/infra/conf"
)

// ---- corpus format (engine-neutral, written by the Swift side) ----

type corpus struct {
	Version int     `json:"version"`
	Tables  []table `json:"tables"`
}

type table struct {
	Name           string `json:"name"`
	DomainStrategy string `json:"domainStrategy"`
	// FinalIsRule false: the table has no catch-all rule; "no rule matched"
	// means the engine's default outbound, which carries FinalAction.
	FinalIsRule bool                `json:"finalIsRule"`
	FinalAction string              `json:"finalAction"`
	Rules       []flatRule          `json:"rules"`
	Groups      map[string][]string `json:"groups"`
	Requests    []request           `json:"requests"`
}

type flatDomain struct {
	Kind  string `json:"kind"` // full | suffix | keyword | regex
	Value string `json:"value"`
}

type portRange struct {
	Lower int `json:"lower"`
	Upper int `json:"upper"`
}

type flatRule struct {
	Tag         string       `json:"tag"` // "r<ruleIndex>.<part>" or "final"
	Action      string       `json:"action"`
	Domains     []flatDomain `json:"domains"`
	IPs         []string     `json:"ips"`
	ExcludedIPs []string     `json:"excludedIPs"`
	Ports       []portRange  `json:"ports"`
	Networks    []string     `json:"networks"`
	SourceIPs   []string     `json:"sourceIPs"`
	SourcePorts []portRange  `json:"sourcePorts"`
	InboundTags []string     `json:"inboundTags"`
	Users       []string     `json:"users"`
	Protocols   []string     `json:"protocols"`
}

type decision struct {
	Rule   *int   `json:"rule"` // nil: final action
	Action string `json:"action"`
}

type request struct {
	Domain      *string  `json:"domain"`
	IP          *string  `json:"ip"`
	ResolvedIPs []string `json:"resolvedIPs"`
	Port        *int     `json:"port"`
	Network     *string  `json:"network"`
	SourceIP    *string  `json:"sourceIP"`
	SourcePort  *int     `json:"sourcePort"`
	InboundTag  *string  `json:"inboundTag"`
	User        *string  `json:"user"`
	Protocol    *string  `json:"protocol"`
	Swift       decision `json:"swift"`
	// "agree" (default) or "differ"; a "differ" case documents a known,
	// justified difference and must really differ.
	Expect string `json:"expect"`
	Reason string `json:"reason"`
}

// ---- translation of neutral flat rules into an Xray routing object ----

func actionTarget(action string) (key, tag string) {
	switch {
	case action == "direct":
		return "outboundTag", "direct"
	case action == "reject":
		return "outboundTag", "block"
	case strings.HasPrefix(action, "proxy:"):
		return "outboundTag", strings.TrimPrefix(action, "proxy:")
	case strings.HasPrefix(action, "group:"):
		return "balancerTag", strings.TrimPrefix(action, "group:")
	default: // chain:a>b stands for a synthesised chained outbound
		return "outboundTag", action
	}
}

func portList(ranges []portRange) string {
	parts := make([]string, 0, len(ranges))
	for _, r := range ranges {
		if r.Lower == r.Upper {
			parts = append(parts, strconv.Itoa(r.Lower))
		} else {
			parts = append(parts, fmt.Sprintf("%d-%d", r.Lower, r.Upper))
		}
	}
	return strings.Join(parts, ",")
}

func xrayRule(r flatRule) map[string]any {
	out := map[string]any{"ruleTag": r.Tag}
	key, tag := actionTarget(r.Action)
	out[key] = tag
	if len(r.Domains) > 0 {
		list := make([]string, 0, len(r.Domains))
		for _, d := range r.Domains {
			switch d.Kind {
			case "full":
				list = append(list, "full:"+d.Value)
			case "suffix":
				list = append(list, "domain:"+d.Value)
			case "keyword":
				list = append(list, "keyword:"+d.Value)
			case "regex":
				list = append(list, "regexp:"+d.Value)
			default:
				panic("unknown domain kind " + d.Kind)
			}
		}
		out["domain"] = list
	}
	if len(r.IPs)+len(r.ExcludedIPs) > 0 {
		list := append([]string{}, r.IPs...)
		for _, c := range r.ExcludedIPs {
			list = append(list, "!"+c)
		}
		out["ip"] = list
	}
	if len(r.Ports) > 0 {
		out["port"] = portList(r.Ports)
	}
	if len(r.Networks) > 0 {
		out["network"] = strings.Join(r.Networks, ",")
	}
	if len(r.SourceIPs) > 0 {
		out["sourceIP"] = r.SourceIPs
	}
	if len(r.SourcePorts) > 0 {
		out["sourcePort"] = portList(r.SourcePorts)
	}
	if len(r.InboundTags) > 0 {
		out["inboundTag"] = r.InboundTags
	}
	if len(r.Users) > 0 {
		out["user"] = r.Users
	}
	if len(r.Protocols) > 0 {
		out["protocol"] = r.Protocols
	}
	return out
}

func xrayRouting(t table) ([]byte, error) {
	rules := make([]map[string]any, 0, len(t.Rules))
	for _, r := range t.Rules {
		rules = append(rules, xrayRule(r))
	}
	strategy := map[string]string{"asIs": "AsIs", "ipIfNonMatch": "IPIfNonMatch", "ipOnDemand": "IPOnDemand"}[t.DomainStrategy]
	if strategy == "" {
		return nil, fmt.Errorf("unknown domain strategy %q", t.DomainStrategy)
	}
	obj := map[string]any{"domainStrategy": strategy, "rules": rules}
	if len(t.Groups) > 0 {
		names := make([]string, 0, len(t.Groups))
		for name := range t.Groups {
			names = append(names, name)
		}
		sort.Strings(names)
		balancers := make([]map[string]any, 0, len(names))
		for _, name := range names {
			balancers = append(balancers, map[string]any{"tag": name, "selector": t.Groups[name]})
		}
		obj["balancers"] = balancers
	}
	return json.Marshal(obj)
}

// ---- mocks for the two features the router needs ----

type fakeDNS struct{ answers []net.IP }

func (*fakeDNS) Type() interface{} { return dns.ClientType() }
func (*fakeDNS) Start() error      { return nil }
func (*fakeDNS) Close() error      { return nil }
func (d *fakeDNS) LookupIP(string, dns.IPOption) ([]net.IP, uint32, error) {
	if len(d.answers) == 0 {
		return nil, 0, dns.ErrEmptyResponse
	}
	return d.answers, 600, nil
}

// fakeOutbounds implements outbound.Manager and outbound.HandlerSelector.
// Select returns the selector strings themselves: the corpus lists group
// members by exact tag.
type fakeOutbounds struct{}

func (fakeOutbounds) Type() interface{}                                  { return outbound.ManagerType() }
func (fakeOutbounds) Start() error                                       { return nil }
func (fakeOutbounds) Close() error                                       { return nil }
func (fakeOutbounds) GetHandler(string) outbound.Handler                 { return nil }
func (fakeOutbounds) GetDefaultHandler() outbound.Handler                { return nil }
func (fakeOutbounds) AddHandler(context.Context, outbound.Handler) error { return nil }
func (fakeOutbounds) RemoveHandler(context.Context, string) error        { return nil }
func (fakeOutbounds) ListHandlers(context.Context) []outbound.Handler    { return nil }
func (fakeOutbounds) Select(selectors []string) []string                 { return selectors }

func parseIP(text string) (net.IP, error) {
	addr := net.ParseAddress(text)
	if !addr.Family().IsIP() {
		return nil, fmt.Errorf("not an IP: %q", text)
	}
	return addr.IP(), nil
}

// routingContext builds the same session-backed routing context the
// dispatcher hands to the router.
func routingContext(q request) (routing.Context, error) {
	network := net.Network_Unknown
	if q.Network != nil {
		switch *q.Network {
		case "tcp":
			network = net.Network_TCP
		case "udp":
			network = net.Network_UDP
		default:
			return nil, fmt.Errorf("unknown network %q", *q.Network)
		}
	}
	port := net.Port(0)
	if q.Port != nil {
		port = net.Port(*q.Port)
	}
	ob := &session.Outbound{}
	switch {
	case q.IP != nil:
		ip, err := parseIP(*q.IP)
		if err != nil {
			return nil, err
		}
		ob.Target = net.Destination{Address: net.IPAddress(ip), Port: port, Network: network}
		if q.Domain != nil { // sniffed domain with routeOnly
			ob.RouteTarget = net.Destination{Address: net.DomainAddress(*q.Domain), Port: port, Network: network}
		}
	case q.Domain != nil:
		ob.Target = net.Destination{Address: net.DomainAddress(*q.Domain), Port: port, Network: network}
	default:
		return nil, fmt.Errorf("request has neither domain nor ip")
	}
	ctx := session.ContextWithOutbounds(context.Background(), []*session.Outbound{ob})

	in := &session.Inbound{}
	if q.InboundTag != nil {
		in.Tag = *q.InboundTag
	}
	if q.SourceIP != nil {
		ip, err := parseIP(*q.SourceIP)
		if err != nil {
			return nil, err
		}
		sport := net.Port(0)
		if q.SourcePort != nil {
			sport = net.Port(*q.SourcePort)
		}
		srcNet := network
		if srcNet == net.Network_Unknown {
			srcNet = net.Network_TCP
		}
		in.Source = net.Destination{Address: net.IPAddress(ip), Port: sport, Network: srcNet}
	}
	if q.User != nil {
		in.User = &protocol.MemoryUser{Email: *q.User}
	}
	ctx = session.ContextWithInbound(ctx, in)
	if q.Protocol != nil {
		ctx = session.ContextWithContent(ctx, &session.Content{Protocol: *q.Protocol})
	}
	return routing_session.AsRoutingContext(ctx), nil
}

type xrayResult struct {
	RuleTag  string
	Outbound string
	NoRoute  bool
}

func ruleIndexOf(tag string) (*int, error) {
	if tag == "final" {
		return nil, nil
	}
	if !strings.HasPrefix(tag, "r") {
		return nil, fmt.Errorf("unexpected rule tag %q", tag)
	}
	head, _, _ := strings.Cut(tag[1:], ".")
	n, err := strconv.Atoi(head)
	if err != nil {
		return nil, err
	}
	return &n, nil
}

func showIndex(p *int) string {
	if p == nil {
		return "final"
	}
	return strconv.Itoa(*p)
}

// agrees reports whether the Xray result equals the Swift decision.
func agrees(t table, q request, x xrayResult) (bool, string) {
	if x.NoRoute {
		// The dispatcher falls back to the default outbound
		// (app/dispatcher/default.go), which the compiled config sets to the
		// final action when the table has no catch-all rule.
		if t.FinalIsRule {
			return false, "xray: no rule matched (ErrNoClue) although the table has a catch-all rule"
		}
		if q.Swift.Rule != nil {
			return false, fmt.Sprintf("rule: swift=%d xray=no rule matched (default outbound)", *q.Swift.Rule)
		}
		if q.Swift.Action != t.FinalAction {
			return false, fmt.Sprintf("final action: swift=%q table=%q", q.Swift.Action, t.FinalAction)
		}
		return true, ""
	}
	idx, err := ruleIndexOf(x.RuleTag)
	if err != nil {
		return false, err.Error()
	}
	if (idx == nil) != (q.Swift.Rule == nil) || (idx != nil && *idx != *q.Swift.Rule) {
		return false, fmt.Sprintf("rule: swift=%s xray=%s", showIndex(q.Swift.Rule), showIndex(idx))
	}
	key, want := actionTarget(q.Swift.Action)
	if key == "balancerTag" {
		for _, member := range t.Groups[want] {
			if member == x.Outbound {
				return true, ""
			}
		}
		return false, fmt.Sprintf("outbound %q is not a member of group %q", x.Outbound, want)
	}
	if want != x.Outbound {
		return false, fmt.Sprintf("outbound: swift=%q xray=%q", want, x.Outbound)
	}
	return true, ""
}

type mismatch struct {
	Table   string  `json:"table"`
	Request int     `json:"request"`
	Detail  string  `json:"detail"`
	Reason  string  `json:"reason,omitempty"`
	Query   request `json:"query"`
}

type summary struct {
	XrayModule       string     `json:"xrayModule"`
	Tables           int        `json:"tables"`
	Rules            int        `json:"flatRules"`
	Requests         int        `json:"requests"`
	Agreed           int        `json:"agreed"`
	KnownDifferences []mismatch `json:"knownDifferences"`
	Unexpected       []mismatch `json:"unexpectedDifferences"`
	StaleKnown       []mismatch `json:"knownDifferencesThatAgree"`
}

func TestParity(t *testing.T) {
	path := os.Getenv("PARITY_CORPUS")
	if path == "" {
		path = "testdata/corpus.json"
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var c corpus
	if err := json.Unmarshal(raw, &c); err != nil {
		t.Fatal(err)
	}
	if len(c.Tables) == 0 {
		t.Fatal("corpus has no tables")
	}

	sum := summary{XrayModule: xrayModuleVersion(), Tables: len(c.Tables)}
	for _, tb := range c.Tables {
		sum.Rules += len(tb.Rules)
		routingJSON, err := xrayRouting(tb)
		if err != nil {
			t.Fatalf("table %s: %v", tb.Name, err)
		}
		rc := new(conf.RouterConfig)
		if err := json.Unmarshal(routingJSON, rc); err != nil {
			t.Fatalf("table %s: routing object rejected: %v", tb.Name, err)
		}
		cfg, err := rc.Build()
		if err != nil {
			t.Fatalf("table %s: routing object does not build: %v", tb.Name, err)
		}
		fake := &fakeDNS{}
		r := new(router.Router)
		if err := r.Init(context.Background(), cfg, fake, fakeOutbounds{}, nil); err != nil {
			t.Fatalf("table %s: router init: %v", tb.Name, err)
		}

		for i, q := range tb.Requests {
			sum.Requests++
			fake.answers = fake.answers[:0]
			for _, text := range q.ResolvedIPs {
				ip, err := parseIP(text)
				if err != nil {
					t.Fatalf("table %s request %d: %v", tb.Name, i, err)
				}
				fake.answers = append(fake.answers, ip)
			}
			ctx, err := routingContext(q)
			if err != nil {
				t.Fatalf("table %s request %d: %v", tb.Name, i, err)
			}
			var x xrayResult
			route, err := r.PickRoute(ctx)
			switch {
			case err == common.ErrNoClue:
				x.NoRoute = true
			case err != nil:
				t.Fatalf("table %s request %d: PickRoute: %v", tb.Name, i, err)
			default:
				x.RuleTag = route.GetRuleTag()
				x.Outbound = route.GetOutboundTag()
			}
			if os.Getenv("PARITY_DUMP") != "" {
				qj, _ := json.Marshal(q)
				t.Logf("dump table=%s request=%d xray=%+v query=%s", tb.Name, i, x, qj)
			}
			ok, detail := agrees(tb, q, x)
			m := mismatch{Table: tb.Name, Request: i, Detail: detail, Reason: q.Reason, Query: q}
			switch {
			case q.Expect == "differ" && !ok:
				sum.KnownDifferences = append(sum.KnownDifferences, m)
			case q.Expect == "differ" && ok:
				sum.StaleKnown = append(sum.StaleKnown, m)
			case ok:
				sum.Agreed++
			default:
				sum.Unexpected = append(sum.Unexpected, m)
			}
		}
		_ = r.Close()
	}

	t.Logf("xray=%s tables=%d flatRules=%d requests=%d agreed=%d knownDifferences=%d unexpected=%d staleKnown=%d",
		sum.XrayModule, sum.Tables, sum.Rules, sum.Requests, sum.Agreed, len(sum.KnownDifferences), len(sum.Unexpected), len(sum.StaleKnown))
	for _, m := range sum.KnownDifferences {
		t.Logf("known difference: table=%s request=%d: %s -- %s", m.Table, m.Request, m.Detail, m.Reason)
	}
	if out := os.Getenv("PARITY_OUT"); out != "" {
		data, _ := json.MarshalIndent(sum, "", "  ")
		if err := os.WriteFile(out, append(data, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for n, m := range sum.Unexpected {
		if n >= 40 {
			t.Errorf("... and %d more unexpected differences", len(sum.Unexpected)-n)
			break
		}
		q, _ := json.Marshal(m.Query)
		t.Errorf("UNEXPECTED difference: table=%s request=%d: %s\n  %s", m.Table, m.Request, m.Detail, q)
	}
	for _, m := range sum.StaleKnown {
		t.Errorf("case marked as a known difference now agrees: table=%s request=%d (%s)", m.Table, m.Request, m.Reason)
	}
}
