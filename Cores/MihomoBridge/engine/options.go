package engine

import (
	"bytes"
	"encoding/json"
	"time"
)

// Project limits (not platform limits).
const (
	// MaxConfigBytes bounds the size of a configuration document accepted by Validate/Start/Reload.
	MaxConfigBytes = 4 << 20
	// MaxOptionsBytes bounds the size of the options document.
	MaxOptionsBytes = 64 << 10
)

// TunMode selects how IP packets reach the core.
type TunMode string

const (
	// TunNone: no packet interface; a config with "tun: {enable: true}" is rejected.
	TunNone TunMode = ""
	// TunFlow: the host hands over batches of packets (TunWrite/TunRead). The config's tun section is not
	// given to the core's own TUN listener (which would open a system device); the bridge runs the same
	// sing-tun "mips" stack on a device fed from TunWrite instead, with the section's MTU, DNS hijack and
	// timeouts.
	TunFlow TunMode = "flow"
)

// Options configures one engine run. The zero value is valid; Normalize fills the defaults.
//
// The document has the same shape as the Xray bridge's options where the meaning is the same; fields that
// only make sense for one core differ (no assetDir/accessLog/disableStats/tun.fd here, homeDir instead).
type Options struct {
	// StartTimeoutMs / StopTimeoutMs bound Start and Stop. Defaults: 15000 / 5000.
	StartTimeoutMs int `json:"startTimeoutMs"`
	StopTimeoutMs  int `json:"stopTimeoutMs"`

	// HomeDir is the core's home directory: geodata files, rule/proxy provider caches, cache.db (selected
	// proxies, fake-ip pool). Process-wide in the core. Default: <os.TempDir()>/np-mihomo.
	HomeDir string `json:"homeDir"`

	// LogLevel overrides the config's log-level: "debug", "info", "warning", "error", "none". Empty keeps the
	// config's.
	LogLevel string `json:"logLevel"`
	// LogQueueSize is the capacity of the bounded log queue in records. Default 512.
	LogQueueSize int `json:"logQueueSize"`

	// TCPIdleTimeoutMs / UDPIdleTimeoutMs: the bridge closes a TCP connection / UDP session of any inbound after
	// this long without data in either direction (idle.go). The core itself has no TCP idle timeout and ends
	// a UDP session 60 s after its last packet without a configuration key for it. Counted in
	// Stats.IdleClosedTCP/UDP. 0 = off (UDP: the core's 60 s still applies); the mobile profile sets
	// MobileTCPIdleTimeoutMs / MobileUDPIdleTimeoutMs.
	TCPIdleTimeoutMs int `json:"tcpIdleTimeoutMs"`
	UDPIdleTimeoutMs int `json:"udpIdleTimeoutMs"`

	Memory MemoryOptions `json:"memory"`
	Tun    TunOptions    `json:"tun"`
}

// MemoryProfile selects a set of defaults for memory-related options (same names as the Xray bridge).
type MemoryProfile string

const (
	// MemoryProfileDefault leaves every unset option at its ordinary default.
	MemoryProfileDefault MemoryProfile = ""
	// MemoryProfileMobile fills unset options with the values measured for a process with a memory budget of
	// about 50 MiB (an iOS packet tunnel provider; Documentation/Performance/memory-budget.md, Mihomo section).
	// Options set explicitly are kept. It does not change the configuration document.
	MemoryProfileMobile MemoryProfile = "mobile"
)

// Defaults of the mobile profile. Project choices from measurements on Linux, not platform limits.
const (
	MobileMemoryLimitBytes = 40 << 20
	MobileGCPercent        = 25
	MobileOutQueueBytes    = 512 << 10
	MobileMaxFlows         = 512
	MobileLogQueueSize     = 128
	MobileUDPIdleTimeoutMs = 30_000
	MobileTCPIdleTimeoutMs = 300_000
)

// MemoryOptions are process-wide Go runtime settings applied on Start and restored on Stop.
type MemoryOptions struct {
	// Profile fills the options below (and tun.outQueueBytes, tun.maxFlows, logQueueSize, tcpIdleTimeoutMs,
	// udpIdleTimeoutMs) that are left at zero. See MemoryProfileMobile. tun.inQueueBytes keeps its 1 MiB
	// default: 256 and 512 KiB cut upload throughput by 38-54 % on the lab stand with GOGC 25 (the stack's
	// single reader falls behind and the queue tail-drops).
	Profile MemoryProfile `json:"profile"`
	// LimitBytes is passed to debug.SetMemoryLimit. 0 = leave the runtime's setting unchanged.
	LimitBytes int64 `json:"limitBytes"`
	// GCPercent is passed to debug.SetGCPercent. 0 = leave unchanged; negative disables the percent-based GC
	// (only meaningful together with LimitBytes).
	GCPercent int `json:"gcPercent"`
	// FreeOSMemoryIntervalMs, if > 0, calls debug.FreeOSMemory periodically. Default 0 (off).
	FreeOSMemoryIntervalMs int `json:"freeOSMemoryIntervalMs"`
}

// TunOptions configures the packet interface.
type TunOptions struct {
	Mode TunMode `json:"mode"`
	// MTU overrides the MTU of the config's tun section in TunFlow mode. 0 keeps the config's mtu, and a
	// config without one gets 1500 (the core's own default, 9000, is meant for a system device).
	MTU int `json:"mtu"`
	// OutQueueBytes bounds the queue of packets waiting for TunRead (TunFlow). Default 2 MiB.
	OutQueueBytes int `json:"outQueueBytes"`
	// InQueueBytes bounds the queue of packets from TunWrite waiting for the stack (TunFlow; the Xray
	// bridge has no such queue). Default 1 MiB.
	InQueueBytes int `json:"inQueueBytes"`
	// MaxFlows caps the TCP connections the bridge's stack hands to the core at once (TunFlow). A connection
	// beyond the cap is closed at once (TCP reset) and counted in TunCounters.FlowsRejected. UDP is not
	// capped here: the stack hands UDP to the core packet by packet, and the core's UDP sessions end 60 s
	// after the last packet from the remote side (tunnel/tunnel.go udpTimeout). 0 = no cap; the mobile
	// profile sets MobileMaxFlows.
	MaxFlows int `json:"maxFlows"`
}

// ParseOptions decodes an options document. Empty input yields defaults. Unknown fields are rejected so that
// a host/bridge version mismatch is noticed instead of silently ignored.
func ParseOptions(data []byte) (Options, *Error) {
	var o Options
	if len(data) > MaxOptionsBytes {
		return o, newError(CodeInvalidArgument, "options exceed %d bytes", MaxOptionsBytes)
	}
	if len(bytes.TrimSpace(data)) != 0 {
		dec := json.NewDecoder(bytes.NewReader(data))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&o); err != nil {
			return o, newError(CodeInvalidArgument, "options: %v", err)
		}
		if dec.More() {
			return o, newError(CodeInvalidArgument, "options: trailing data")
		}
	}
	if err := o.Normalize(); err != nil {
		return o, err
	}
	return o, nil
}

// Normalize validates the options and fills defaults in place.
func (o *Options) Normalize() *Error {
	if o.StartTimeoutMs == 0 {
		o.StartTimeoutMs = 15000
	}
	if o.StopTimeoutMs == 0 {
		o.StopTimeoutMs = 5000
	}
	if o.StartTimeoutMs < 0 || o.StopTimeoutMs < 0 {
		return newError(CodeInvalidArgument, "negative timeout")
	}
	switch o.Memory.Profile {
	case MemoryProfileDefault:
	case MemoryProfileMobile:
		if o.Memory.LimitBytes == 0 {
			o.Memory.LimitBytes = MobileMemoryLimitBytes
		}
		if o.Memory.GCPercent == 0 {
			o.Memory.GCPercent = MobileGCPercent
		}
		if o.Tun.OutQueueBytes == 0 {
			o.Tun.OutQueueBytes = MobileOutQueueBytes
		}
		if o.Tun.MaxFlows == 0 {
			o.Tun.MaxFlows = MobileMaxFlows
		}
		if o.TCPIdleTimeoutMs == 0 {
			o.TCPIdleTimeoutMs = MobileTCPIdleTimeoutMs
		}
		if o.UDPIdleTimeoutMs == 0 {
			o.UDPIdleTimeoutMs = MobileUDPIdleTimeoutMs
		}
		if o.LogQueueSize == 0 {
			o.LogQueueSize = MobileLogQueueSize
		}
	default:
		return newError(CodeInvalidArgument, "unknown memory.profile %q", o.Memory.Profile)
	}
	if o.LogQueueSize == 0 {
		o.LogQueueSize = 512
	}
	if o.LogQueueSize < 1 || o.LogQueueSize > 65536 {
		return newError(CodeInvalidArgument, "logQueueSize out of range [1, 65536]")
	}
	switch o.LogLevel {
	case "", "debug", "info", "warning", "error", "none":
	default:
		return newError(CodeInvalidArgument, "unknown logLevel %q", o.LogLevel)
	}
	if o.Memory.LimitBytes < 0 || o.Memory.FreeOSMemoryIntervalMs < 0 {
		return newError(CodeInvalidArgument, "negative memory option")
	}
	switch o.Tun.Mode {
	case TunNone, TunFlow:
	case "fd":
		return newError(CodeInvalidArgument, "tun.mode \"fd\" is not implemented by the Mihomo bridge")
	default:
		return newError(CodeInvalidArgument, "unknown tun.mode %q", o.Tun.Mode)
	}
	if o.Tun.MTU != 0 && (o.Tun.MTU < 576 || o.Tun.MTU > 65535) {
		return newError(CodeInvalidArgument, "tun.mtu out of range [576, 65535]")
	}
	if o.Tun.OutQueueBytes == 0 {
		o.Tun.OutQueueBytes = 2 << 20
	}
	if o.Tun.OutQueueBytes < 128<<10 || o.Tun.OutQueueBytes > 64<<20 {
		return newError(CodeInvalidArgument, "tun.outQueueBytes out of range [128 KiB, 64 MiB]")
	}
	if o.Tun.InQueueBytes == 0 {
		o.Tun.InQueueBytes = 1 << 20
	}
	if o.Tun.InQueueBytes < 128<<10 || o.Tun.InQueueBytes > 64<<20 {
		return newError(CodeInvalidArgument, "tun.inQueueBytes out of range [128 KiB, 64 MiB]")
	}
	if o.Tun.MaxFlows < 0 || o.Tun.MaxFlows > 1<<20 {
		return newError(CodeInvalidArgument, "tun.maxFlows out of range [0, 1048576]")
	}
	// The lower bounds keep a typo (seconds given as milliseconds) from closing every connection at once.
	if o.TCPIdleTimeoutMs != 0 && (o.TCPIdleTimeoutMs < 1000 || o.TCPIdleTimeoutMs > 86_400_000) {
		return newError(CodeInvalidArgument, "tcpIdleTimeoutMs out of range [1000, 86400000] (0 = off)")
	}
	if o.UDPIdleTimeoutMs != 0 && (o.UDPIdleTimeoutMs < 1000 || o.UDPIdleTimeoutMs > 86_400_000) {
		return newError(CodeInvalidArgument, "udpIdleTimeoutMs out of range [1000, 86400000] (0 = off)")
	}
	return nil
}

func (o *Options) startTimeout() time.Duration {
	return time.Duration(o.StartTimeoutMs) * time.Millisecond
}
func (o *Options) stopTimeout() time.Duration {
	return time.Duration(o.StopTimeoutMs) * time.Millisecond
}
