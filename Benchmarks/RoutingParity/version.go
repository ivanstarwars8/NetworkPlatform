package parity

import "runtime/debug"

// xrayModuleVersion reports the engine module version this harness was
// built against.
func xrayModuleVersion() string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return "unknown"
	}
	for _, dep := range info.Deps {
		if dep.Path == "github.com/xtls/xray-core" {
			return dep.Version
		}
	}
	return "unknown"
}
