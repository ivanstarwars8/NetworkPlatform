#!/usr/bin/env bash
# Builds a bridge as C archives for Apple platforms and packs them into an xcframework. Runs on macOS with
# Xcode and Go (the version the bridge's go.mod asks for; GOTOOLCHAIN=auto).
#
#   Cores/BuildScripts/bridge-apple-xcframework.sh [slice ...]                       # Xray bridge
#   NP_BRIDGE_ENGINE=mihomo Cores/BuildScripts/bridge-apple-xcframework.sh [slice ...]  # Mihomo bridge
#
# Engines (same C ABI, same slices, same steps):
#   xray    Cores/Bridge/cabi        -> Cores/Bridge/build/apple/NPXrayBridge.xcframework (libnpbridge.a)
#   mihomo  Cores/MihomoBridge/cabi  -> Cores/MihomoBridge/build/apple/NPMihomoBridge.xcframework (libnpmihomo.a),
#           always built with the Apple patch of mihomo-apple-patch.sh (-modfile; no proc_pidinfo, no
#           recvmsg_x/sendmsg_x system calls). GPL-3.0: only the MihomoOnly and Dual flavours link it.
#
# Without arguments every slice is attempted. A slice that fails does not stop the others: the script
# reports per slice (build.tsv in the output directory) and exits non-zero only when a slice listed in
# NP_REQUIRED_SLICES failed (default: the iOS, iOS simulator and macOS slices). The xcframework holds every
# slice that built.
#
# Output (git-ignored): <bridge>/build/apple/
#   slices/<slice>/<lib>.a            one archive per slice
#   <Framework>.xcframework           headers in Headers/<Framework>/ with a module map (import <Framework>)
#   build.tsv                         slice, status, size, sha256, platform of the archive
#   versions.txt                      Go, Xcode, SDKs, core pin
#
# Slices: GOOS=ios is the only Go port for iOS, tvOS and visionOS; the target platform comes from the C
# toolchain (clang -target ...). Go copies the platform of the cgo objects into its own object in an
# external link, which is what makes tvOS and visionOS slices possible at all; whether the Go runtime then
# works on those systems is not proven by building (never run).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
engine="${NP_BRIDGE_ENGINE:-xray}"
goflags=()
case "$engine" in
  xray)
    bridge="$root/Cores/Bridge"; lib=libnpbridge; framework=NPXrayBridge; core_module=github.com/xtls/xray-core ;;
  mihomo)
    bridge="$root/Cores/MihomoBridge"; lib=libnpmihomo; framework=NPMihomoBridge; core_module=github.com/metacubex/mihomo ;;
  *)
    echo "NP_BRIDGE_ENGINE must be xray or mihomo, not '$engine'" >&2; exit 2 ;;
esac
out="${NP_APPLE_OUT:-$bridge/build/apple}"
if [ "$engine" = mihomo ]; then
  # The patched module copies live outside the output directory (which CI caches).
  patch_dir="${NP_PATCH_DIR:-$(mktemp -d)}"
  goflags+=("$(NP_PATCH_DIR="$patch_dir" "$root/Cores/BuildScripts/mihomo-apple-patch.sh")")
fi
required="${NP_REQUIRED_SLICES:-ios-arm64 ios-simulator-arm64 ios-simulator-x86_64 macos-arm64 macos-x86_64}"

# slice  GOOS  GOARCH  SDK  clang target
all_slices=(
  "ios-arm64             ios    arm64 iphoneos          arm64-apple-ios17.0"
  "ios-simulator-arm64   ios    arm64 iphonesimulator   arm64-apple-ios17.0-simulator"
  "ios-simulator-x86_64  ios    amd64 iphonesimulator   x86_64-apple-ios17.0-simulator"
  "macos-arm64           darwin arm64 macosx            arm64-apple-macos14.0"
  "macos-x86_64          darwin amd64 macosx            x86_64-apple-macos14.0"
  "tvos-arm64            ios    arm64 appletvos         arm64-apple-tvos17.0"
  "tvos-simulator-arm64  ios    arm64 appletvsimulator  arm64-apple-tvos17.0-simulator"
  "tvos-simulator-x86_64 ios    amd64 appletvsimulator  x86_64-apple-tvos17.0-simulator"
  "xros-arm64            ios    arm64 xros              arm64-apple-xros1.0"
  "xros-simulator-arm64  ios    arm64 xrsimulator       arm64-apple-xros1.0-simulator"
)

want=("$@")
mkdir -p "$out/slices"
rm -rf "$out/$framework.xcframework" "$out/lipo" "$out/include"
: >"$out/build.tsv"

{
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "go: $(cd "$bridge" && go version)"
  echo "xcode: $(xcodebuild -version | tr '\n' ' ')"
  echo "engine: $engine"
  echo "core: $(cd "$bridge" && go list -m -f '{{.Path}} {{.Version}}' "$core_module")"
  [ "${#goflags[@]}" -eq 0 ] || echo "go flags: ${goflags[*]}"
  xcodebuild -showsdks 2>/dev/null | grep -E -- '-sdk ' | sed 's/^[[:space:]]*/sdk: /'
} >"$out/versions.txt"
cat "$out/versions.txt"

# Prints the LC_BUILD_VERSION platform of the Go object inside an archive (what Xcode will check).
platform_of() {
  local a="$1" tmp
  tmp="$(mktemp -d)"
  (cd "$tmp" && ar x "$a" go.o 2>/dev/null || true)
  if [ -f "$tmp/go.o" ]; then
    otool -l "$tmp/go.o" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}'
  else
    echo "?"
  fi
  rm -rf "$tmp"
}

build_slice() {
  local name="$1" goos="$2" goarch="$3" sdk="$4" target="$5"
  local dir="$out/slices/$name" sdk_path cc
  rm -rf "$dir"
  mkdir -p "$dir"
  if ! sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path 2>/dev/null)"; then
    echo "SDK $sdk is not installed" >"$dir/build.log"
    return 1
  fi
  cc="$(xcrun --sdk "$sdk" --find clang)"
  local flags="-isysroot $sdk_path -target $target"
  (
    cd "$bridge"
    env GOOS="$goos" GOARCH="$goarch" CGO_ENABLED=1 \
      CC="$cc" CXX="$(xcrun --sdk "$sdk" --find clang++)" \
      CGO_CFLAGS="$flags -O2" CGO_CXXFLAGS="$flags -O2" CGO_LDFLAGS="$flags" \
      go build -mod=readonly ${goflags[@]+"${goflags[@]}"} -buildvcs=false -trimpath -ldflags "-s -w -buildid=" \
      -buildmode=c-archive -o "$dir/$lib.a" ./cabi
  ) >"$dir/build.log" 2>&1
}

failed_required=0
for row in "${all_slices[@]}"; do
  # shellcheck disable=SC2086
  set -- $row
  name="$1"
  if [ "${#want[@]}" -gt 0 ] && [[ " ${want[*]} " != *" $name "* ]]; then
    continue
  fi
  echo "::group::slice $name"
  start=$(date +%s)
  if build_slice "$@"; then
    a="$out/slices/$name/$lib.a"
    printf '%s\tok\t%s\t%s\t%s\t%ss\n' "$name" "$(stat -f %z "$a")" "$(shasum -a 256 "$a" | cut -d' ' -f1)" \
      "$(platform_of "$a")" "$(( $(date +%s) - start ))" | tee -a "$out/build.tsv"
  else
    printf '%s\tFAILED\t-\t-\t-\t%ss\n' "$name" "$(( $(date +%s) - start ))" | tee -a "$out/build.tsv"
    tail -n 40 "$out/slices/$name/build.log"
    if [[ " $required " == *" $name "* ]]; then failed_required=1; fi
  fi
  echo "::endgroup::"
done

ok() { awk -F'\t' -v n="$1" '$1==n && $2=="ok"{f=1} END{exit !f}' "$out/build.tsv"; }

# Headers: the generated header (identical across slices; checked) plus a module map, in a subdirectory so
# that several xcframeworks never put two module.modulemap files at the same include root.
first="$(awk -F'\t' '$2=="ok"{print $1; exit}' "$out/build.tsv")"
if [ -z "$first" ]; then
  echo "no slice built" >&2
  exit 1
fi
inc="$out/include/$framework"
mkdir -p "$inc"
cp "$out/slices/$first/$lib.h" "$inc/$lib.h"
for d in "$out"/slices/*/; do
  if [ -f "$d/$lib.h" ] && ! cmp -s "$d/$lib.h" "$inc/$lib.h"; then
    echo "warning: header of $(basename "$d") differs from $first" >&2
  fi
done
cat >"$inc/module.modulemap" <<EOF
module $framework {
  header "$lib.h"
  link "resolv"
  link framework "CoreFoundation"
  link framework "Security"
  export *
}
EOF

# Fat archives per platform variant (lipo), then the xcframework.
args=()
group() {
  local key="$1"; shift
  local parts=()
  for s in "$@"; do
    if ok "$s"; then parts+=("$out/slices/$s/$lib.a"); fi
  done
  [ "${#parts[@]}" -gt 0 ] || return 0
  mkdir -p "$out/lipo/$key"
  lipo -create "${parts[@]}" -output "$out/lipo/$key/$lib.a"
  args+=(-library "$out/lipo/$key/$lib.a" -headers "$out/include")
}
group ios ios-arm64
group ios-simulator ios-simulator-arm64 ios-simulator-x86_64
group macos macos-arm64 macos-x86_64
group tvos tvos-arm64
group tvos-simulator tvos-simulator-arm64 tvos-simulator-x86_64
group xros xros-arm64
group xros-simulator xros-simulator-arm64

xcodebuild -create-xcframework "${args[@]}" -output "$out/$framework.xcframework"
echo "--- $framework.xcframework"
plutil -p "$out/$framework.xcframework/Info.plist" | grep -E 'LibraryIdentifier|SupportedPlatform"|SupportedPlatformVariant'
echo "--- slices"
column -t -s $'\t' "$out/build.tsv"
exit "$failed_required"
