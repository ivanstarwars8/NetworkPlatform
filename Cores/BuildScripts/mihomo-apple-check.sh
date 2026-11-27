#!/usr/bin/env bash
# Linux-side check of the Apple patch of the Mihomo bridge (no SDK, no cgo):
#  1. every package compiles for GOOS=ios/arm64, darwin/arm64 and darwin/amd64 with the patch;
#  2. a darwin/arm64 Mach-O linked from the engine imports proc_pidinfo without the patch and not with it;
#  3. no Go or assembly file of a non-standard package compiled into the Apple c-archive (go list -deps of
#     ./cabi for ios/arm64, ios/amd64, darwin/arm64, darwin/amd64 with cgo, with the patch) references
#     proc_pidinfo, SYS_RECVMSG_X or SYS_SENDMSG_X (recvmsg_x/sendmsg_x are raw system calls by number, so a
#     symbol table cannot show them; the macOS-side symbol check is bridge-apple-verify.sh).
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

# 3. Source files of every non-standard package the Apple c-archive compiles.
# references <goos/goarch> [go flag]: prints the lines that reference the private calls.
references() {
  local target="$1" flag="${2:-}" files
  files="$tmp/files-${target%/*}-${target#*/}${flag:+-patched}"
  # shellcheck disable=SC2086
  GOOS=${target%/*} GOARCH=${target#*/} CGO_ENABLED=1 go list $flag -deps \
    -f '{{if not .Standard}}{{$d := .Dir}}{{range .GoFiles}}{{$d}}/{{.}}{{"\n"}}{{end}}{{range .CgoFiles}}{{$d}}/{{.}}{{"\n"}}{{end}}{{range .SFiles}}{{$d}}/{{.}}{{"\n"}}{{end}}{{end}}' \
    ./cabi | sort -u >"$files"
  echo "$target${flag:+ (patched)}: $(wc -l <"$files") source files compiled" >&2
  # golang.org/x/sys/unix only defines the numbers (zsysnum_*); a definition or a comment is not a reference.
  xargs grep -nE 'proc_pidinfo|SYS_RECVMSG_X|SYS_SENDMSG_X' <"$files" | grep -vE '/zsysnum_[a-z0-9_]+\.go:' \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true
}
control=$(references darwin/arm64 | grep -c . || true)
echo "references to proc_pidinfo/SYS_RECVMSG_X/SYS_SENDMSG_X without the patch (darwin/arm64): $control"
[ "$control" -gt 0 ] || { echo "FAIL: the unpatched build has no reference; the check proves nothing" >&2; exit 1; }
srcfail=0
for target in ios/arm64 ios/amd64 darwin/arm64 darwin/amd64; do
  hits=$(references "$target" "$patch")
  echo "$target with the patch: references $(printf '%s' "$hits" | grep -c . || true)"
  if [ -n "$hits" ]; then echo "$hits" | head -20; srcfail=1; fi
done
[ "$srcfail" -eq 0 ] || { echo "FAIL: private Darwin calls are still referenced by the Apple build" >&2; exit 1; }
echo "APPLE PATCH CHECK PASSED"
