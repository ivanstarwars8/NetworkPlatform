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
	// TunNone: no packet interface; a "tun" inbound in the config is rejected.
	TunNone TunMode = ""
	// TunFlow: the host hands over batches of packets (TunWrite/TunRead). The config's "tun" inbound is
	// replaced by the bridge's own inbound that feeds the core's userspace TCP/IP stack.
	TunFlow TunMode = "flow"
	// TunFD: the core's own "tun" inbound reads the given file descriptor (passed via xray.tun.fd).
	TunFD TunMode = "fd"
)

// Options configures one engine run. The zero value is valid; Normalize fills the defaults.
type Options struct {
	// StartTimeoutMs / StopTimeoutMs bound Start and Stop. Defaults: 15000 / 5000.
	StartTimeoutMs int `json:"startTimeoutMs"`
	StopTimeoutMs  int `json:"stopTimeoutMs"`

	// AssetDir is exported to the core as xray.location.asset (geoip.dat / geosite.dat). Optional.
	AssetDir string `json:"assetDir"`

	// LogLevel overrides the config's log level: "debug", "info", "warning", "error", "none". Empty keeps the config's.
	LogLevel string `json:"logLevel"`
	// AccessLog delivers the core's access log through the same queue. Default false.
	AccessLog bool `json:"accessLog"`
	// LogQueueSize is the capacity of the bounded log queue in records. Default 512.
	LogQueueSize int `json:"logQueueSize"`

	// DisableStats leaves the config's stats/policy sections untouched. By default the bridge enables the
	// stats feature and the per-inbound/per-outbound traffic counters.
	DisableStats bool `json:"disableStats"`

	Memory MemoryOptions `json:"memory"`
	Tun    TunOptions    `json:"tun"`
}

// MemoryProfile selects a set of defaults for memory-related options.
type MemoryProfile string

const (
	// MemoryProfileDefault leaves every unset option at its ordinary default.
	MemoryProfileDefault MemoryProfile = ""
	// MemoryProfileMobile fills unset options with the values measured for a process with a memory budget of
	// about 50 MiB (an iOS packet tunnel provider; Documentation/Performance/memory-budget.md) and refuses
	// geodata files. Options set explicitly are kept. It does not change the configuration: the policy levels
	// (connIdle, bufferSize) and QUIC windows of the mobile profile are emitted by the configuration compiler.
	MemoryProfileMobile MemoryProfile = "mobile"
)

// Defaults of the mobile profile. Project choices from measurements on Linux, not platform limits.
const (
	MobileMemoryLimitBytes = 40 << 20
	MobileGCPercent        = 25
	MobileOutQueueBytes    = 512 << 10
	MobileMaxFlows         = 512
	MobileLogQueueSize     = 128
)

// MemoryOptions are process-wide Go runtime settings applied on Start and restored on Stop.
type MemoryOptions struct {
	// Profile fills the options below (and tun.outQueueBytes, tun.maxFlows, logQueueSize) that are left at
	// zero. See MemoryProfileMobile.
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
	// FD is the tun file descriptor for TunFD mode. The core duplicates it; the caller keeps ownership.
	FD int `json:"fd"`
	// MTU overrides the MTU of the config's tun inbound in TunFlow mode. 0 keeps the config's (default 1500).
	MTU int `json:"mtu"`
	// OutQueueBytes bounds the queue of packets waiting for TunRead (TunFlow). Default 2 MiB.
	OutQueueBytes int `json:"outQueueBytes"`
	// MaxFlows caps the TCP connections and UDP flows the bridge's stack hands to the core at once (TunFlow).
	// A flow beyond the cap is closed at once (TCP: reset) and counted in TunCounters.FlowsRejected.
	// 0 = no cap; the mobile profile sets MobileMaxFlows.
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
		if o.AssetDir != "" {
			return newError(CodeInvalidArgument, "memory.profile=mobile does not load geodata files: assetDir must be empty")
		}
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
	case TunFD:
		if o.Tun.FD < 3 {
			return newError(CodeInvalidArgument, "tun.fd must be >= 3 in fd mode")
		}
	default:
		return newError(CodeInvalidArgument, "unknown tun.mode %q", o.Tun.Mode)
	}
	if o.Tun.MTU != 0 && (o.Tun.MTU < 576 || o.Tun.MTU > 65535) {
		return newError(CodeInvalidArgument, "tun.mtu out of range [576, 65535]")
	}
	if o.Tun.MaxFlows < 0 || o.Tun.MaxFlows > 1<<20 {
		return newError(CodeInvalidArgument, "tun.maxFlows out of range [0, 1048576]")
	}
	if o.Tun.OutQueueBytes == 0 {
		o.Tun.OutQueueBytes = 2 << 20
	}
	if o.Tun.OutQueueBytes < 128<<10 || o.Tun.OutQueueBytes > 64<<20 {
		return newError(CodeInvalidArgument, "tun.outQueueBytes out of range [128 KiB, 64 MiB]")
	}
	return nil
}

func (o *Options) startTimeout() time.Duration {
	return time.Duration(o.StartTimeoutMs) * time.Millisecond
}
func (o *Options) stopTimeout() time.Duration {
	return time.Duration(o.StopTimeoutMs) * time.Millisecond
}
