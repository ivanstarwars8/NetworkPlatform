#!/usr/bin/env bash
# Prepares the patched core that every Apple (darwin/ios) build of the Mihomo bridge must use and prints the
# go flag that selects it. Run on a machine with Go; the module cache must hold the pinned core.
#   flag=$(Cores/BuildScripts/mihomo-apple-patch.sh)      # e.g. -modfile=/tmp/x/apple.mod
#   cd Cores/MihomoBridge && GOOS=ios ... go build $flag -buildmode=c-archive ./cabi
# go build -overlay cannot be used: Go refuses overlays of files beneath GOMODCACHE. Instead the core is
# copied, patched, and wired in with a replace directive in a copy of go.mod (go.mod itself is untouched).
# The patch (see Cores/MihomoBridge/README.md, "Apple patches"):
#   component/memory/memory_darwin.go              -> Cores/MihomoBridge/apple/patch/memory_darwin.go
#   component/memory/memory_darwin_{amd64,arm64}.s -> removed (they jump to proc_pidinfo)
# NP_PATCH_DIR selects the work directory (default: a new temporary directory, left for the caller).
set -euo pipefail
bridge="$(cd "$(dirname "$0")/../MihomoBridge" && pwd)"
cd "$bridge"
src="$(go list -mod=readonly -m -f '{{.Dir}}' github.com/metacubex/mihomo)"
mem="component/memory"
[ -n "$src" ] && [ -f "$src/$mem/memory_darwin.go" ] || { echo "mihomo module not in the module cache: $src" >&2; exit 1; }
grep -q 'proc_pidinfo' "$src/$mem/memory_darwin.go" || { echo "core changed: memory_darwin.go no longer uses proc_pidinfo; review the patch" >&2; exit 1; }
work="${NP_PATCH_DIR:-$(mktemp -d)}"
rm -rf "$work/mihomo"
cp -r "$src" "$work/mihomo"
chmod -R u+w "$work/mihomo"
cp "$bridge/apple/patch/memory_darwin.go" "$work/mihomo/$mem/memory_darwin.go"
rm -f "$work/mihomo/$mem/memory_darwin_amd64.s" "$work/mihomo/$mem/memory_darwin_arm64.s"
cp go.mod "$work/apple.mod"
cp go.sum "$work/apple.sum"
go mod edit -modfile="$work/apple.mod" -replace "github.com/metacubex/mihomo=$work/mihomo"
echo "-modfile=$work/apple.mod"
