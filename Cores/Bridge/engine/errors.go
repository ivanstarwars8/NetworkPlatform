// Package engine wraps one Xray-core instance behind a small, host-neutral API:
// lifecycle, statistics, logs, memory control and a batched packet interface.
// The C ABI in ../cabi is a thin layer over this package.
package engine

import "fmt"

// Code is a normalised error code. Values are part of the C ABI and must not be renumbered.
type Code int32

const (
	CodeOK              Code = 0
	CodeInvalidArgument Code = 1  // malformed call: nil/oversized input, bad options
	CodeInvalidState    Code = 2  // call not allowed in the current lifecycle state
	CodeConfigParse     Code = 3  // config is not valid JSON for the core's schema
	CodeConfigBuild     Code = 4  // config parsed but the core rejected its content
	CodeConfigUnsupport Code = 5  // config uses a section the bridge refuses (env, api, metrics, ...)
	CodeStartFailed     Code = 6  // the core failed to create or start the instance
	CodeTimeout         Code = 7  // start or stop exceeded its deadline
	CodeCancelled       Code = 8  // start was cancelled by a concurrent stop
	CodeStopFailed      Code = 9  // the core reported an error while closing
	CodeInternal        Code = 10 // recovered panic or broken invariant
	CodeNotRunning      Code = 11 // data-plane call without a running engine
	CodeBufferTooSmall  Code = 12 // caller buffer cannot hold a single item
	CodeClosed          Code = 13 // the packet device was closed while waiting
)

var codeNames = map[Code]string{
	CodeOK: "ok", CodeInvalidArgument: "invalid_argument", CodeInvalidState: "invalid_state",
	CodeConfigParse: "config_parse", CodeConfigBuild: "config_build", CodeConfigUnsupport: "config_unsupported",
	CodeStartFailed: "start_failed", CodeTimeout: "timeout", CodeCancelled: "cancelled",
	CodeStopFailed: "stop_failed", CodeInternal: "internal", CodeNotRunning: "not_running",
	CodeBufferTooSmall: "buffer_too_small", CodeClosed: "closed",
}

func (c Code) String() string {
	if s, ok := codeNames[c]; ok {
		return s
	}
	return fmt.Sprintf("code_%d", int32(c))
}

// Error is the only error type returned by exported functions of this package.
type Error struct {
	Code    Code
	Message string
}

func (e *Error) Error() string { return e.Code.String() + ": " + e.Message }

func newError(code Code, format string, args ...any) *Error {
	return &Error{Code: code, Message: fmt.Sprintf(format, args...)}
}

// CodeOf extracts the code of err; nil maps to CodeOK and foreign errors to CodeInternal.
func CodeOf(err error) Code {
	if err == nil {
		return CodeOK
	}
	if e, ok := err.(*Error); ok {
		return e.Code
	}
	return CodeInternal
}
