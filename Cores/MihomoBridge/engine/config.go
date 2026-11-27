package engine

import (
	"bytes"
	"fmt"
	"net/netip"
	"sort"
	"strings"
	"time"

	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	IN "github.com/metacubex/mihomo/listener/inbound"
	"github.com/metacubex/mihomo/listener/sing"
	mlog "github.com/metacubex/mihomo/log"
)

// ConfigSummary describes a configuration the bridge accepted. Overridden lists every setting the bridge
// changed or ignored, so that nothing is dropped silently (ADR-0002).
type ConfigSummary struct {
	Mode          string   `json:"mode"`
	LogLevel      string   `json:"logLevel"`
	Proxies       int      `json:"proxies"` // proxies and groups, without the core's built-ins
	ProxyProvider int      `json:"proxyProviders"`
	RuleProviders int      `json:"ruleProviders"`
	Rules         int      `json:"rules"`
	Listeners     int      `json:"listeners"` // entries of the "listeners" section
	SocksPort     int      `json:"socksPort,omitempty"`
	MixedPort     int      `json:"mixedPort,omitempty"`
	HTTPPort      int      `json:"httpPort,omitempty"`
	HasTun        bool     `json:"hasTun"`
	Overridden    []string `json:"overridden,omitempty"`
	// Depth is always "parse": the core has no separate build step, parsing constructs every proxy, group,
	// provider object and rule. Nothing is dialled or listened on.
	Depth string `json:"depth"`
}

// tunSpec is what the bridge's packet stack takes from the config's tun section in TunFlow mode.
type tunSpec struct {
	mtu                    uint32
	inet4, inet6           []netip.Prefix
	loopback               []netip.Addr
	dnsHijack              []netip.AddrPort
	dnsServerIPs           []string
	udpTimeout             time.Duration
	icmpTimeout            time.Duration
	endpointIndependentNat bool
	disableICMPForwarding  bool
	congestionControl      string
}

type prepared struct {
	cfg     *config.Config
	summary ConfigSummary
	tun     *tunSpec // nil unless TunFlow and the config enables tun
}

var builtinProxies = map[string]bool{"DIRECT": true, "REJECT": true, "REJECT-DROP": true, "PASS": true, "COMPATIBLE": true, "GLOBAL": true}

// prepareConfig parses a Clash/Mihomo YAML (or JSON) document and rewrites the parts that would touch the
// operating system in ways a Packet Tunnel extension must not (system tun device, routes, iptables, process
// lookup, the private recvmsg_x path, an HTTP controller).
//
// Parsing is not free of side effects: config.Parse temporarily applies the "general" section to the core's
// process-wide state while it parses and rolls it back afterwards (config.go: temporaryUpdateGeneral), and it
// may download geodata into the home directory when rules need it.
func prepareConfig(data []byte, opts *Options) (*prepared, *Error) {
	if len(bytes.TrimSpace(data)) == 0 {
		return nil, newError(CodeInvalidArgument, "empty config")
	}
	if len(data) > MaxConfigBytes {
		return nil, newError(CodeInvalidArgument, "config exceeds %d bytes", MaxConfigBytes)
	}
	raw, err := config.UnmarshalRawConfig(data)
	if err != nil {
		return nil, newError(CodeConfigParse, "%v", err)
	}
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		return nil, newError(CodeConfigBuild, "%v", err)
	}
	p := &prepared{cfg: cfg}
	s := &p.summary
	s.Depth = "parse"
	note := func(format string, args ...any) { s.Overridden = append(s.Overridden, fmt.Sprintf(format, args...)) }
	g := cfg.General

	if opts.LogLevel != "" {
		lvl, _ := parseLevel(opts.LogLevel)
		if lvl != g.LogLevel {
			note("log-level: %s -> %s (bridge option)", g.LogLevel, lvl)
		}
		g.LogLevel = lvl
	}

	// Things that would reach outside the process.
	c := cfg.Controller
	if c.ExternalController != "" || c.ExternalControllerTLS != "" || c.ExternalControllerUnix != "" ||
		c.ExternalControllerPipe != "" || c.ExternalUI != "" || c.ExternalDohServer != "" {
		note("external-controller/external-ui: ignored (the bridge exposes no controller)")
	}
	*cfg.Controller = config.Controller{}
	if cfg.IPTables.Enable {
		note("iptables.enable: true -> false")
		cfg.IPTables.Enable = false
	}
	if cfg.NTP.WriteToSystem {
		note("ntp.write-to-system: true -> false")
		cfg.NTP.WriteToSystem = false
	}
	if g.FindProcessMode != process.FindProcessOff {
		note("find-process-mode: %s -> off (no process lookup inside an extension)", g.FindProcessMode)
		g.FindProcessMode = process.FindProcessOff
	}
	if g.RedirPort != 0 || g.TProxyPort != 0 {
		note("redir-port/tproxy-port: ignored")
		g.RedirPort, g.TProxyPort = 0, 0
	}
	if g.Interface != "" {
		note("interface-name %q kept: binding to a named interface may fail inside an extension", g.Interface)
	}
	names := make([]string, 0, len(cfg.Listeners))
	for name := range cfg.Listeners {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		switch cfg.Listeners[name].(type) {
		case *IN.Tun:
			return nil, newError(CodeConfigUnsupport, "listeners.%s: type tun opens a system device; use the top-level tun section with tun.mode \"flow\"", name)
		case *IN.Redir, *IN.TProxy:
			return nil, newError(CodeConfigUnsupport, "listeners.%s: redir/tproxy listeners are not supported", name)
		}
	}

	// The tun section is never given to the core's own TUN listener.
	t := &g.Tun
	// recvmsg_x/sendmsg_x are private Darwin system calls; the core enables recvmsgx by default. Forced off
	// even though TunFlow never opens a utun, so that no code path the bridge drives can reach them.
	if t.RecvMsgX || t.SendMsgX {
		t.RecvMsgX, t.SendMsgX = false, false
	}
	s.HasTun = t.Enable
	if t.Enable {
		if opts.Tun.Mode != TunFlow {
			return nil, newError(CodeConfigUnsupport, "config enables tun but tun.mode is not \"flow\"")
		}
		if t.Stack != C.TunMips {
			return nil, newError(CodeConfigUnsupport, "tun.stack %q: only the mips stack runs on the packet interface", t.Stack.String())
		}
		if t.FileDescriptor != 0 {
			return nil, newError(CodeConfigUnsupport, "tun.file-descriptor: not supported, packets come through tun.mode \"flow\"")
		}
		if t.AutoRoute || t.AutoDetectInterface || t.AutoRedirect || t.StrictRoute {
			note("tun.auto-route/auto-detect-interface/auto-redirect/strict-route: ignored (the host owns routes)")
		}
		if t.Device != "" {
			note("tun.device: ignored")
		}
		spec, err := tunSpecOf(t, opts)
		if err != nil {
			return nil, err
		}
		p.tun = spec
		t.Enable = false
	}

	// Summary.
	for name := range cfg.Proxies {
		if !builtinProxies[name] {
			s.Proxies++
		}
	}
	s.Mode = g.Mode.String()
	s.LogLevel = g.LogLevel.String()
	s.ProxyProvider = len(cfg.Providers)
	s.RuleProviders = len(cfg.RuleProviders)
	s.Rules = len(cfg.Rules)
	s.Listeners = len(cfg.Listeners)
	s.SocksPort, s.MixedPort, s.HTTPPort = g.SocksPort, g.MixedPort, g.Port
	return p, nil
}

func tunSpecOf(t *LC.Tun, opts *Options) (*tunSpec, *Error) {
	spec := &tunSpec{
		mtu:                    t.MTU,
		inet4:                  t.Inet4Address,
		inet6:                  t.Inet6Address,
		loopback:               t.LoopbackAddress,
		endpointIndependentNat: t.EndpointIndependentNat,
		disableICMPForwarding:  t.DisableICMPForwarding,
		congestionControl:      t.CongestionController,
		udpTimeout:             sing.UDPTimeout,
		icmpTimeout:            sing.ICMPTimeout,
	}
	if opts.Tun.MTU != 0 {
		spec.mtu = uint32(opts.Tun.MTU)
	}
	if spec.mtu == 0 {
		spec.mtu = 1500
	}
	if spec.mtu < 576 || spec.mtu > 65535 {
		return nil, newError(CodeConfigBuild, "tun.mtu %d out of range [576, 65535]", spec.mtu)
	}
	if t.UDPTimeout > 0 {
		spec.udpTimeout = time.Duration(t.UDPTimeout) * time.Second
	}
	if t.ICMPTimeout > 0 {
		spec.icmpTimeout = time.Duration(t.ICMPTimeout) * time.Second
	}
	// Same hijack set as the core's TUN listener (listener/sing_tun/server.go): the configured dns-hijack
	// entries plus port 53 of the address after each tun address.
	for _, d := range t.DNSHijack {
		if _, after, ok := strings.Cut(d, "://"); ok {
			d = after
		}
		d = strings.Replace(d, "any", "0.0.0.0", 1)
		ap, err := netip.ParseAddrPort(d)
		if err != nil {
			return nil, newError(CodeConfigBuild, "tun.dns-hijack %q: %v", d, err)
		}
		spec.dnsHijack = append(spec.dnsHijack, ap)
	}
	for _, a := range append(append([]netip.Prefix(nil), t.Inet4Address...), t.Inet6Address...) {
		next := a.Addr().Next()
		spec.dnsServerIPs = append(spec.dnsServerIPs, next.String())
		spec.dnsHijack = append(spec.dnsHijack, netip.AddrPortFrom(next, 53))
	}
	return spec, nil
}

// emptyConfig is applied on Stop: no proxies, rules, listeners, DNS or tun. It is what "stopped" means for a
// core that cannot be torn down without ending the process (see engine.go, Stop).
func emptyConfig(level mlog.LogLevel) (*config.Config, error) {
	doc := fmt.Sprintf("mode: direct\nlog-level: %s\nfind-process-mode: off\nprofile:\n  store-selected: false\n  store-fake-ip: false\ndns:\n  enable: false\ntun:\n  enable: false\n  recvmsgx: false\n", level)
	return config.Parse([]byte(doc))
}
