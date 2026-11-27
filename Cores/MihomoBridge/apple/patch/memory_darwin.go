// Apple build patch for github.com/metacubex/mihomo/component/memory (v1.19.34).
//
// Replaces component/memory/memory_darwin.go, which imports proc_pidinfo from libSystem
// (//go:cgo_import_dynamic) for the RSS figure of the core's statistic manager. proc_pidinfo/libproc is not
// part of the iOS SDK's public API, so the Apple build reports "not implemented" instead, as the core already
// does on platforms without an implementation (memory_falllback.go). The bridge reports memory through
// runtime/metrics (npb_memory) and never uses the core's figure. The assembly trampolines
// memory_darwin_{amd64,arm64}.s reference proc_pidinfo as well and are removed by the same patch.
// Applied by Cores/BuildScripts/mihomo-apple-patch.sh (a patched copy of the module, used through -modfile).

package memory

func GetMemoryInfo(pid int32) (*MemoryInfoStat, error) {
	return nil, ErrNotImplementedError
}
