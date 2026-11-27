#!/usr/bin/env bash
# Prepares the patched modules that every Apple (darwin/ios) build of the Mihomo bridge must use and prints the
# go flag that selects them. Run on a machine with Go; the module cache must hold the pinned modules.
#   flag=$(Cores/BuildScripts/mihomo-apple-patch.sh)      # e.g. -modfile=/tmp/x/apple.mod
#   cd Cores/MihomoBridge && GOOS=ios ... go build $flag -buildmode=c-archive ./cabi
# go build -overlay cannot be used: Go refuses overlays of files beneath GOMODCACHE. Instead each module is
# copied, patched, and wired in with a replace directive in a copy of go.mod (go.mod itself is untouched).
# The patch (see Cores/MihomoBridge/README.md, "Apple patches"):
#   mihomo   component/memory/memory_darwin.go              -> Cores/MihomoBridge/apple/patch/memory_darwin.go
#   mihomo   component/memory/memory_darwin_{amd64,arm64}.s -> removed (they jump to proc_pidinfo)
#   sing-tun internal/rawfile_darwin/rawfile.go: the two raw system calls SYS_RECVMSG_X and SYS_SENDMSG_X
#            (private Darwin calls, reachable only through the core's own utun device with recvmsgx/sendmsgx,
#            which the bridge never opens and forces off) are replaced by an ENOSYS result. The edit is made
#            by this script on the copy; no source of sing-tun is stored in this repository.
# NP_PATCH_DIR selects the work directory (default: a new temporary directory, left for the caller).
set -euo pipefail
bridge="$(cd "$(dirname "$0")/../MihomoBridge" && pwd)"
cd "$bridge"

module_dir() {
  local dir
  # .Dir is empty for a module that is not downloaded yet.
  go mod download "$1"
  dir="$(go list -mod=readonly -m -f '{{.Dir}}' "$1")"
  [ -n "$dir" ] && [ -d "$dir" ] || { echo "module $1 not in the module cache: $dir" >&2; exit 1; }
  echo "$dir"
}

work="${NP_PATCH_DIR:-$(mktemp -d)}"
mkdir -p "$work"

# --- mihomo: component/memory without proc_pidinfo
src="$(module_dir github.com/metacubex/mihomo)"
mem="component/memory"
grep -q 'proc_pidinfo' "$src/$mem/memory_darwin.go" || { echo "core changed: memory_darwin.go no longer uses proc_pidinfo; review the patch" >&2; exit 1; }
rm -rf "$work/mihomo"
cp -r "$src" "$work/mihomo"
chmod -R u+w "$work/mihomo"
cp "$bridge/apple/patch/memory_darwin.go" "$work/mihomo/$mem/memory_darwin.go"
rm -f "$work/mihomo/$mem/memory_darwin_amd64.s" "$work/mihomo/$mem/memory_darwin_arm64.s"

# --- sing-tun: no SYS_RECVMSG_X / SYS_SENDMSG_X
tun_src="$(module_dir github.com/metacubex/sing-tun)"
raw="internal/rawfile_darwin/rawfile.go"
rm -rf "$work/sing-tun"
cp -r "$tun_src" "$work/sing-tun"
chmod -R u+w "$work/sing-tun"
for call in SYS_RECVMSG_X SYS_SENDMSG_X; do
  n=$(grep -c "n, _, e := unix.RawSyscall6(unix.$call," "$work/sing-tun/$raw" || true)
  [ "$n" -eq 1 ] || { echo "sing-tun changed: expected one RawSyscall6($call) in $raw, found $n; review the patch" >&2; exit 1; }
  # The replacement keeps the variables the surrounding code uses (n, e) and returns ENOSYS.
  sed -i.orig "s|n, _, e := unix.RawSyscall6(unix.$call,.*|n, e := uintptr(0), unix.Errno(unix.ENOSYS) // NetworkPlatform Apple patch: private system call removed|" \
    "$work/sing-tun/$raw"
done
rm -f "$work/sing-tun/$raw.orig"
if grep -rn --include='*.go' -E 'SYS_(RECVMSG|SENDMSG)_X' "$work/sing-tun" | grep -v '_test.go:' >&2; then
  echo "sing-tun still references SYS_RECVMSG_X/SYS_SENDMSG_X after the patch" >&2
  exit 1
fi

cp go.mod "$work/apple.mod"
cp go.sum "$work/apple.sum"
go mod edit -modfile="$work/apple.mod" \
  -replace "github.com/metacubex/mihomo=$work/mihomo" \
  -replace "github.com/metacubex/sing-tun=$work/sing-tun"
echo "-modfile=$work/apple.mod"
