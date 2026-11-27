#!/usr/bin/env bash
# Linux-side check of the Apple patch of the Mihomo bridge (no SDK, no cgo):
#  1. every package compiles for GOOS=ios/arm64, darwin/arm64 and darwin/amd64 with the patch;
#  2. a darwin/arm64 Mach-O linked from the engine imports proc_pidinfo without the patch and not with it.
# It does not prove the c-archive links against the iOS SDK; that needs macOS (bridge-apple-xcframework.sh).
set -euo pipefail
cd "$(dirname "$0")/../MihomoBridge"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
patch="$(NP_PATCH_DIR="$tmp" ../BuildScripts/mihomo-apple-patch.sh)"
for target in ios/arm64 darwin/arm64 darwin/amd64; do
  GOOS=${target%/*} GOARCH=${target#*/} CGO_ENABLED=0 go build "$patch" ./engine
  echo "compiled ./engine for $target with the patch"
done
# The engine never calls the core's memory statistic, so the linker already drops proc_pidinfo from a binary
# of the engine alone; the control program below calls statistic.DefaultManager.Memory() to keep it alive.
probe="$PWD/applecheckprobe"
trap 'rm -rf "$tmp" "$probe"' EXIT
mkdir -p "$probe"
cat > "$probe/main.go" <<'GO'
package main

import (
	"fmt"

	"github.com/metacubex/mihomo/tunnel/statistic"
	_ "networkplatform/mihomobridge/engine"
)

func main() { fmt.Println(statistic.DefaultManager.Memory()) }
GO
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go test -c -o "$tmp/engine.test" ./engine
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -o "$tmp/plain" ./applecheckprobe
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build "$patch" -o "$tmp/patched" ./applecheckprobe
engine=$(grep -c proc_pidinfo "$tmp/engine.test" || true)
plain=$(grep -c proc_pidinfo "$tmp/plain" || true)
patched=$(grep -c proc_pidinfo "$tmp/patched" || true)
echo "proc_pidinfo in darwin/arm64 binaries: engine test binary (unpatched)=$engine, probe without patch=$plain, probe with patch=$patched"
[ "$plain" -gt 0 ] || { echo "FAIL: control binary has no proc_pidinfo; the check proves nothing" >&2; exit 1; }
[ "$patched" -eq 0 ] || { echo "FAIL: proc_pidinfo still linked with the patch" >&2; exit 1; }
echo "APPLE PATCH CHECK PASSED"
