// Command cabi is the C ABI of the bridge. Build it with -buildmode=c-archive; the generated header declares
// the npb_* functions below. The ABI is deliberately narrow:
//
//   - control plane: JSON in, JSON out, one heap string per call (free with npb_free);
//   - data plane (logs, packets): caller-owned buffers, integer results, no allocation per call.
//
// Every control-plane result is a JSON object with at least {"code": <int>, "error": "<text>"}; code 0 is
// success and the other values are engine.Code. Data-plane functions return a non-negative count or the
// negated engine.Code.
//
// One process hosts exactly one engine. All functions are safe to call from any thread.
package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"runtime"
	"time"
	"unsafe"

	"networkplatform/bridge/engine"
)

// abiVersion changes whenever a function signature or a wire format changes incompatibly.
const abiVersion = 1

var eng = engine.New()

type result struct {
	Code  engine.Code `json:"code"`
	Error string      `json:"error,omitempty"`
	Data  any         `json:"data,omitempty"`
}

func reply(data any, err *engine.Error) *C.char {
	r := result{Data: data}
	if err != nil {
		r.Code, r.Error = err.Code, err.Message
		r.Data = nil
	}
	b, jerr := json.Marshal(r)
	if jerr != nil {
		b = []byte(`{"code":10,"error":"result encoding failed"}`)
	}
	return C.CString(string(b))
}

func bytesOf(p *C.char, n C.int32_t) []byte {
	if p == nil || n <= 0 {
		return nil
	}
	return unsafe.Slice((*byte)(unsafe.Pointer(p)), int(n))
}

func neg(err *engine.Error) C.int32_t { return -C.int32_t(err.Code) }

//export npb_abi_version
func npb_abi_version() C.int32_t { return abiVersion }

// npb_version returns {"code":0,"data":{"abi":1,"core":"26.11.9","go":"go1.27.4"}}.
//
//export npb_version
func npb_version() *C.char {
	return reply(map[string]any{"abi": abiVersion, "core": engine.CoreVersion(), "go": runtime.Version()}, nil)
}

// npb_free releases a string returned by this library.
//
//export npb_free
func npb_free(p *C.char) { C.free(unsafe.Pointer(p)) }

// npb_validate checks a configuration. options may be NULL/0 (defaults). data is engine.ConfigSummary.
//
//export npb_validate
func npb_validate(config *C.char, configLen C.int32_t, options *C.char, optionsLen C.int32_t) *C.char {
	opts, err := engine.ParseOptions(bytesOf(options, optionsLen))
	if err != nil {
		return reply(nil, err)
	}
	summary, err := eng.Validate(bytesOf(config, configLen), opts)
	if err != nil {
		return reply(nil, err)
	}
	return reply(summary, nil)
}

// npb_start starts the engine and returns when it runs, failed, or the start timeout of the options elapsed.
// The config and options buffers are copied; the caller may free them when the call returns.
//
//export npb_start
func npb_start(config *C.char, configLen C.int32_t, options *C.char, optionsLen C.int32_t) *C.char {
	opts, err := engine.ParseOptions(bytesOf(options, optionsLen))
	if err != nil {
		return reply(nil, err)
	}
	return reply(nil, eng.Start(context.Background(), bytesOf(config, configLen), opts))
}

// npb_stop stops the engine. timeoutMs <= 0 uses the stop timeout given at start.
//
//export npb_stop
func npb_stop(timeoutMs C.int32_t) *C.char {
	return reply(nil, eng.Stop(time.Duration(timeoutMs)*time.Millisecond))
}

// npb_reload replaces the running configuration by stop + start; see engine.Engine.Reload for the semantics.
//
//export npb_reload
func npb_reload(config *C.char, configLen C.int32_t) *C.char {
	return reply(nil, eng.Reload(context.Background(), bytesOf(config, configLen)))
}

// npb_stats returns engine.Stats.
//
//export npb_stats
func npb_stats() *C.char {
	st, err := eng.Stats()
	if err != nil {
		return reply(nil, err)
	}
	return reply(st, nil)
}

// npb_observe returns engine.Observation: the groups of the running configuration with the core's own
// health measurements of their members. Added to ABI v1 (additive: no existing function changed).
//
//export npb_observe
func npb_observe() *C.char {
	obs, err := eng.Observe()
	if err != nil {
		return reply(nil, err)
	}
	return reply(obs, nil)
}

// npb_select pins the member new connections of a group go to, without a restart; an empty member gives the
// choice back to the group. See engine.Engine.Select. Added to ABI v1 (additive).
//
//export npb_select
func npb_select(group *C.char, groupLen C.int32_t, member *C.char, memberLen C.int32_t) *C.char {
	if groupLen > 256 || memberLen > 256 {
		return reply(nil, &engine.Error{Code: engine.CodeInvalidArgument, Message: "tag exceeds 256 bytes"})
	}
	return reply(nil, eng.Select(string(bytesOf(group, groupLen)), string(bytesOf(member, memberLen))))
}

// npb_connections exists so that both bridges export the same functions (one Swift binding). The Xray core
// keeps no list of connections in-process, so it always answers code 5 (unsupported). Added to ABI v1
// (additive: no existing function changed).
//
//export npb_connections
func npb_connections(limit C.int32_t) *C.char {
	_ = limit
	return reply(nil, &engine.Error{Code: engine.CodeConfigUnsupport, Message: "the Xray core keeps no connection list"})
}

// npb_health returns engine.Health. It works in every state.
//
//export npb_health
func npb_health() *C.char { return reply(eng.Health(), nil) }

// npb_memory returns engine.MemoryStats of the Go runtime.
//
//export npb_memory
func npb_memory() *C.char { return reply(engine.ReadMemoryStats(), nil) }

// npb_state returns the lifecycle state: 0 idle, 1 starting, 2 running, 3 stopping.
//
//export npb_state
func npb_state() C.int32_t { return C.int32_t(eng.State()) }

// npb_log_read writes pending log records into buf as newline-terminated JSON objects (engine.LogRecord) and
// returns the number of bytes written; 0 means the timeout elapsed with nothing to read. It waits up to
// timeoutMs for the first record. Records that do not fit stay queued, except that a single record larger
// than the whole buffer is dropped (give the buffer at least 4 KiB).
//
//export npb_log_read
func npb_log_read(buf *C.char, capacity C.int32_t, timeoutMs C.int32_t) C.int32_t {
	dst := bytesOf(buf, capacity)
	if len(dst) < 4096 {
		return -C.int32_t(engine.CodeBufferTooSmall)
	}
	// One record is at most ~2.2 KiB encoded before escaping; read conservatively so everything popped fits.
	max := len(dst) / 4096
	var stack [8]engine.LogRecord
	recs := eng.ReadLogs(stack[:0], max, time.Duration(timeoutMs)*time.Millisecond)
	n := 0
	for i := range recs {
		line, err := json.Marshal(&recs[i])
		if err != nil || len(line)+1 > len(dst)-n {
			continue
		}
		n += copy(dst[n:], line)
		dst[n] = '\n'
		n++
	}
	return C.int32_t(n)
}

// npb_tun_write hands a batch of IP packets to the engine (tun.mode "flow"). The batch is a sequence of
// frames: uint16 little-endian length, then that many packet bytes. Returns the number of packets consumed.
// The buffer is not retained after the call, but its contents may be modified.
//
//export npb_tun_write
func npb_tun_write(batch *C.uint8_t, length C.int32_t) C.int32_t {
	if batch == nil || length <= 0 {
		return -C.int32_t(engine.CodeInvalidArgument)
	}
	n, err := eng.TunWrite(unsafe.Slice((*byte)(unsafe.Pointer(batch)), int(length)))
	if err != nil && n == 0 {
		return neg(err)
	}
	return C.int32_t(n)
}

// npb_tun_read fills buf with queued packets in the same frame format and returns the number of bytes
// written; 0 means the timeout elapsed. timeoutMs: 0 polls, negative waits until a packet arrives or the
// engine stops (-13, closed). Call it in a loop from one dedicated thread.
//
//export npb_tun_read
func npb_tun_read(buf *C.uint8_t, capacity C.int32_t, timeoutMs C.int32_t) C.int32_t {
	if buf == nil || capacity <= 0 {
		return -C.int32_t(engine.CodeInvalidArgument)
	}
	n, err := eng.TunRead(unsafe.Slice((*byte)(unsafe.Pointer(buf)), int(capacity)), time.Duration(timeoutMs)*time.Millisecond)
	if err != nil {
		return neg(err)
	}
	return C.int32_t(n)
}

func main() {}
