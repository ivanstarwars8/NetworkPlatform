package engine

import (
	"bytes"
	"fmt"
	"strings"

	"github.com/xtls/xray-core/app/log"
	apppolicy "github.com/xtls/xray-core/app/policy"
	"github.com/xtls/xray-core/app/proxyman"
	appstats "github.com/xtls/xray-core/app/stats"
	xlog "github.com/xtls/xray-core/common/log"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf"
	confserial "github.com/xtls/xray-core/infra/conf/serial"
	"github.com/xtls/xray-core/proxy/tun"
)

// HandlerInfo names one inbound or outbound of a configuration.
type HandlerInfo struct {
	Tag string `json:"tag"`
	// Type is the protobuf type of the proxy settings, e.g. "xray.proxy.vless.outbound.Config".
	Type string `json:"type"`
}

// ConfigSummary is what Validate reports about an accepted configuration. It contains no addresses or secrets.
type ConfigSummary struct {
	Inbounds  []HandlerInfo `json:"inbounds"`
	Outbounds []HandlerInfo `json:"outbounds"`
	// HasTun tells whether the config has a "tun" inbound, i.e. whether it expects a packet interface.
	HasTun bool `json:"hasTun"`
	// Depth is "instance" when the core also constructed (but did not start) an instance from the config, or
	// "build" when only the config build ran because an engine was active in this process.
	Depth string `json:"depth"`
}

// tunSpec is what the bridge keeps of the config's "tun" inbound in TunFlow mode.
type tunSpec struct {
	tag       string
	mtu       uint32
	userLevel uint32
	sniffing  session.SniffingRequest
	receiver  *serial.TypedMessage
	proxy     *serial.TypedMessage
}

// prepared is a configuration ready for core.New.
type prepared struct {
	config  *core.Config
	summary ConfigSummary
	tun     *tunSpec // non-nil in TunFlow mode when the config has a tun inbound
}

const tunConfigType = "xray.proxy.tun.Config"

// prepareConfig parses and builds a JSON configuration and applies the bridge's policies to it.
// It does not create an instance and has no effect on a running one.
func prepareConfig(data []byte, opts *Options) (p *prepared, rerr *Error) {
	defer func() {
		if r := recover(); r != nil {
			// The core's builders are not written to be panic-free on hostile input.
			p, rerr = nil, newError(CodeConfigBuild, "config build panicked: %v", r)
		}
	}()
	if len(data) == 0 {
		return nil, newError(CodeInvalidArgument, "empty config")
	}
	if len(data) > MaxConfigBytes {
		return nil, newError(CodeInvalidArgument, "config exceeds %d bytes", MaxConfigBytes)
	}
	// Strict RFC 8259 JSON: the config is compiler output, not a hand-edited file with comments.
	jc, err := confserial.DecodeJSONConfigStrict(bytes.NewReader(data))
	if err != nil {
		return nil, newError(CodeConfigParse, "%v", err)
	}
	if e := refuseSections(jc); e != nil {
		return nil, e
	}
	pb, err := jc.Build()
	if err != nil {
		return nil, newError(CodeConfigBuild, "%v", err)
	}
	p = &prepared{config: pb}
	if e := p.applyLogPolicy(opts); e != nil {
		return nil, e
	}
	if !opts.DisableStats {
		if e := p.enableStats(); e != nil {
			return nil, e
		}
	}
	if e := p.resolveTun(opts); e != nil {
		return nil, e
	}
	for _, in := range pb.Inbound {
		p.summary.Inbounds = append(p.summary.Inbounds, HandlerInfo{Tag: in.Tag, Type: in.GetProxySettings().GetType()})
	}
	if p.tun != nil {
		p.summary.Inbounds = append(p.summary.Inbounds, HandlerInfo{Tag: p.tun.tag, Type: tunConfigType})
	}
	for _, out := range pb.Outbound {
		p.summary.Outbounds = append(p.summary.Outbounds, HandlerInfo{Tag: out.Tag, Type: out.GetProxySettings().GetType()})
	}
	p.summary.Depth = "build"
	return p, nil
}

// refuseSections rejects configuration sections with process-wide or network-exposed side effects.
func refuseSections(jc *conf.Config) *Error {
	var refused []string
	if len(jc.Env) > 0 {
		// conf.Config.Build applies "env" with os.Setenv; the environment belongs to the bridge's options.
		refused = append(refused, "env")
	}
	if jc.API != nil {
		// Statistics are read in-process; a gRPC listener inside the extension is attack surface.
		refused = append(refused, "api")
	}
	if jc.Metrics != nil {
		refused = append(refused, "metrics")
	}
	if len(refused) > 0 {
		return newError(CodeConfigUnsupport, "config sections not accepted by the bridge: %s", strings.Join(refused, ", "))
	}
	return nil
}

// applyLogPolicy routes all core logging into the bridge's queue: never stdout, never a file.
func (p *prepared) applyLogPolicy(opts *Options) *Error {
	for i, app := range p.config.App {
		if app.GetType() != serial.GetMessageType((*log.Config)(nil)) {
			continue
		}
		msg, err := app.GetInstance()
		if err != nil {
			return newError(CodeConfigBuild, "log config: %v", err)
		}
		lc := msg.(*log.Config)
		lc.ErrorLogPath, lc.AccessLogPath = "", ""
		if lc.ErrorLogType != log.LogType_None {
			lc.ErrorLogType = log.LogType_Console
		}
		lc.AccessLogType = log.LogType_None
		if opts.AccessLog {
			lc.AccessLogType = log.LogType_Console
		}
		switch opts.LogLevel {
		case "debug":
			lc.ErrorLogType, lc.ErrorLogLevel = log.LogType_Console, xlog.Severity_Debug
		case "info":
			lc.ErrorLogType, lc.ErrorLogLevel = log.LogType_Console, xlog.Severity_Info
		case "warning":
			lc.ErrorLogType, lc.ErrorLogLevel = log.LogType_Console, xlog.Severity_Warning
		case "error":
			lc.ErrorLogType, lc.ErrorLogLevel = log.LogType_Console, xlog.Severity_Error
		case "none":
			lc.ErrorLogType, lc.AccessLogType = log.LogType_None, log.LogType_None
		}
		p.config.App[i] = serial.ToTypedMessage(lc)
	}
	return nil
}

// enableStats makes sure the stats feature exists and the per-inbound/per-outbound traffic counters are on.
func (p *prepared) enableStats() *Error {
	statsType := serial.GetMessageType((*appstats.Config)(nil))
	policyType := serial.GetMessageType((*apppolicy.Config)(nil))
	hasStats, hasPolicy := false, false
	for i, app := range p.config.App {
		switch app.GetType() {
		case statsType:
			hasStats = true
		case policyType:
			msg, err := app.GetInstance()
			if err != nil {
				return newError(CodeConfigBuild, "policy config: %v", err)
			}
			pc := msg.(*apppolicy.Config)
			if pc.System == nil {
				pc.System = &apppolicy.SystemPolicy{}
			}
			if pc.System.Stats == nil {
				pc.System.Stats = &apppolicy.SystemPolicy_Stats{}
			}
			st := pc.System.Stats
			st.InboundUplink, st.InboundDownlink, st.OutboundUplink, st.OutboundDownlink = true, true, true, true
			p.config.App[i] = serial.ToTypedMessage(pc)
			hasPolicy = true
		}
	}
	if !hasStats {
		p.config.App = append(p.config.App, serial.ToTypedMessage(&appstats.Config{}))
	}
	if !hasPolicy {
		p.config.App = append(p.config.App, serial.ToTypedMessage(&apppolicy.Config{
			System: &apppolicy.SystemPolicy{Stats: &apppolicy.SystemPolicy_Stats{
				InboundUplink: true, InboundDownlink: true, OutboundUplink: true, OutboundDownlink: true,
			}},
		}))
	}
	return nil
}

// resolveTun applies the tun mode to the config's "tun" inbounds.
func (p *prepared) resolveTun(opts *Options) *Error {
	var kept []*core.InboundHandlerConfig
	var tuns []*core.InboundHandlerConfig
	for _, in := range p.config.Inbound {
		if in.GetProxySettings().GetType() == tunConfigType {
			tuns = append(tuns, in)
		} else {
			kept = append(kept, in)
		}
	}
	p.summary.HasTun = len(tuns) > 0
	if len(tuns) > 1 {
		return newError(CodeConfigUnsupport, "%d tun inbounds; at most one is supported", len(tuns))
	}
	switch opts.Tun.Mode {
	case TunNone:
		// Left in place for Validate; Start refuses it (see Engine.Start) so that the core never opens a
		// system tun device on its own.
	case TunFD:
		if len(tuns) != 1 {
			return newError(CodeConfigUnsupport, "tun.mode=fd needs exactly one tun inbound in the config")
		}
	case TunFlow:
		if len(tuns) != 1 {
			return newError(CodeConfigUnsupport, "tun.mode=flow needs exactly one tun inbound in the config")
		}
		spec, e := newTunSpec(tuns[0], opts)
		if e != nil {
			return e
		}
		p.tun = spec
		p.config.Inbound = kept
	}
	return nil
}

func newTunSpec(in *core.InboundHandlerConfig, opts *Options) (*tunSpec, *Error) {
	msg, err := in.ProxySettings.GetInstance()
	if err != nil {
		return nil, newError(CodeConfigBuild, "tun settings: %v", err)
	}
	tc, ok := msg.(*tun.Config)
	if !ok {
		return nil, newError(CodeInternal, "tun settings have type %T", msg)
	}
	spec := &tunSpec{tag: in.Tag, mtu: tc.MTU, userLevel: tc.UserLevel, receiver: in.ReceiverSettings, proxy: in.ProxySettings}
	if opts.Tun.MTU != 0 {
		spec.mtu = uint32(opts.Tun.MTU)
	}
	if spec.mtu == 0 {
		spec.mtu = 1500
	}
	if in.ReceiverSettings != nil {
		rmsg, err := in.ReceiverSettings.GetInstance()
		if err != nil {
			return nil, newError(CodeConfigBuild, "tun receiver settings: %v", err)
		}
		if rc, ok := rmsg.(*proxyman.ReceiverConfig); ok {
			req, err := proxyman.BuildSniffingRequest(rc.SniffingSettings)
			if err != nil {
				return nil, newError(CodeConfigBuild, "tun sniffing: %v", err)
			}
			spec.sniffing = req
		}
	}
	return spec, nil
}

func (s ConfigSummary) String() string {
	return fmt.Sprintf("%d inbounds, %d outbounds, tun=%v, depth=%s", len(s.Inbounds), len(s.Outbounds), s.HasTun, s.Depth)
}
