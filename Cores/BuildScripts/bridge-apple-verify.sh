#!/usr/bin/env bash
# Checks the output of bridge-apple-xcframework.sh on macOS (Xcode command line tools):
#  1. the xcframework records the expected library identifiers, platforms, variants and architectures;
#  2. every Mach-O object of every slice archive carries the LC_BUILD_VERSION platform of its slice and the
#     architectures of the slice;
#  3. no slice references proc_pidinfo, recvmsg_x or sendmsg_x as a symbol (defined or undefined, nm) and
#     none of these names occurs in the archive bytes at all. One exception, for the Xray bridge only:
#     proc_pidinfo in the macOS slices. libproc (proc_pidinfo) is public API in the macOS SDK, not in the iOS,
#     tvOS or visionOS SDKs; Xray-core's process lookup (common/net/find_process_darwin.go, build tag
#     "darwin && !ios") uses it on macOS only. It is reported in verify.tsv, not hidden. The Mihomo bridge has no
#     exception: its Apple patch removes the call and this check guards against a regression.
# recvmsg_x/sendmsg_x can also be reached as raw system calls by number, which no symbol table shows; that
# part is checked on the sources by mihomo-apple-check.sh (go list of every file compiled for Apple).
#
#   NP_BRIDGE_ENGINE=mihomo Cores/BuildScripts/bridge-apple-verify.sh      # default engine: xray
#
# Writes verify.tsv next to build.tsv and exits non-zero on the first kind of failure it reports.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
engine="${NP_BRIDGE_ENGINE:-xray}"
case "$engine" in
  xray) bridge="$root/Cores/Bridge"; lib=libnpbridge; framework=NPXrayBridge; macos_public="proc_pidinfo" ;;
  mihomo) bridge="$root/Cores/MihomoBridge"; lib=libnpmihomo; framework=NPMihomoBridge; macos_public="" ;;
  *) echo "NP_BRIDGE_ENGINE must be xray or mihomo" >&2; exit 2 ;;
esac
out="${NP_APPLE_OUT:-$bridge/build/apple}"
xcf="$out/$framework.xcframework"
[ -d "$xcf" ] || { echo "missing $xcf" >&2; exit 1; }

# slice -> expected LC_BUILD_VERSION platform (numbers from <mach-o/loader.h>) and architecture.
expected_platform() {
  case "$1" in
    ios-arm64) echo 2 ;;
    ios-simulator-*) echo 7 ;;
    macos-*) echo 1 ;;
    tvos-arm64) echo 3 ;;
    tvos-simulator-*) echo 8 ;;
    xros-arm64) echo 11 ;;
    xros-simulator-*) echo 12 ;;
    *) echo "?" ;;
  esac
}
expected_arch() { case "$1" in *x86_64) echo x86_64 ;; *) echo arm64 ;; esac; }
# otool prints the platform as a number or, in newer versions, as a name.
platform_number() {
  case "$(echo "$1" | tr '[:lower:]' '[:upper:]')" in
    1|MACOS) echo 1 ;; 2|IOS) echo 2 ;; 3|TVOS) echo 3 ;; 7|IOSSIMULATOR) echo 7 ;; 8|TVOSSIMULATOR) echo 8 ;;
    11|XROS|VISIONOS) echo 11 ;; 12|XROSSIMULATOR|VISIONOSSIMULATOR) echo 12 ;; *) echo "$1" ;;
  esac
}

fail=0
: >"$out/verify.tsv"

echo "--- 1. $framework.xcframework/Info.plist"
plutil -convert json -o "$out/xcframework-info.json" "$xcf/Info.plist"
python3 -I - "$out/xcframework-info.json" "$lib" <<'PY' || fail=1
import json, sys
info = json.load(open(sys.argv[1]))
lib = sys.argv[2]
want = {
    ("ios", None): {"arm64"},
    ("ios", "simulator"): {"arm64", "x86_64"},
    ("macos", None): {"arm64", "x86_64"},
    ("tvos", None): {"arm64"},
    ("tvos", "simulator"): {"arm64", "x86_64"},
    ("xros", None): {"arm64"},
    ("xros", "simulator"): {"arm64"},
}
seen = {}
for entry in info["AvailableLibraries"]:
    key = (entry["SupportedPlatform"], entry.get("SupportedPlatformVariant"))
    seen[key] = set(entry["SupportedArchitectures"])
    print(f'{entry["LibraryIdentifier"]:<28} platform={key[0]:<6} variant={key[1] or "-":<10} archs={",".join(sorted(seen[key]))} path={entry["LibraryPath"]}')
    if entry["LibraryPath"] != f"{lib}.a":
        print(f"FAIL: unexpected library path {entry['LibraryPath']}")
        sys.exit(1)
bad = False
for key, archs in want.items():
    if seen.get(key) != archs:
        print(f"FAIL: {key[0]} {key[1] or 'device'}: expected {sorted(archs)}, recorded {sorted(seen.get(key, []))}")
        bad = True
for key in seen:
    if key not in want:
        print(f"FAIL: unexpected library {key}")
        bad = True
sys.exit(1 if bad else 0)
PY

echo "--- 2. platforms and architectures of every object, 3. private symbols"
forbidden='proc_pidinfo|recvmsg_x|sendmsg_x'
for dir in "$out"/slices/*/; do
  name="$(basename "$dir")"
  a="$dir/$lib.a"
  if [ ! -f "$a" ]; then
    printf '%s\tMISSING\n' "$name" | tee -a "$out/verify.tsv"
    fail=1
    continue
  fi
  want_p="$(expected_platform "$name")"
  want_a="$(expected_arch "$name")"
  archs="$(lipo -archs "$a")"
  tmp="$(mktemp -d)"
  (cd "$tmp" && ar x "$a")
  objects=0
  wrong=""
  for o in "$tmp"/*; do
    file -b "$o" | grep -q 'Mach-O' || continue
    objects=$((objects + 1))
    p="$(otool -l "$o" | awk '/LC_BUILD_VERSION/{f=1} f&&$1=="platform"{print $2; exit}')"
    p="$(platform_number "${p:-none}")"
    [ "$p" = "$want_p" ] || wrong="$wrong $(basename "$o")=$p"
  done
  rm -rf "$tmp"
  pattern="$forbidden"
  allowed=""
  if [ -n "$macos_public" ] && [[ "$name" == macos-* ]]; then
    # Public macOS API (see the header): reported, not a failure.
    pattern="$(echo "$forbidden" | tr '|' '\n' | grep -vx "$macos_public" | paste -sd'|' -)"
    allowed="$(nm -A "$a" 2>/dev/null | grep -cE "[[:space:]]_($macos_public)\$" || true)"
  fi
  syms="$(nm -A "$a" 2>/dev/null | grep -E "[[:space:]]_($pattern)\$" || true)"
  bytes="$(LC_ALL=C grep -a -o -E "$pattern" "$a" | sort | uniq -c | tr -s ' ' | tr '\n' ';' || true)"
  status=ok
  if [ "$archs" != "$want_a" ]; then status=FAILED; echo "FAIL: $name: architectures '$archs', expected '$want_a'"; fi
  if [ "$objects" -eq 0 ]; then status=FAILED; echo "FAIL: $name: no Mach-O objects in the archive"; fi
  if [ -n "$wrong" ]; then status=FAILED; echo "FAIL: $name: objects with another platform than $want_p:$wrong"; fi
  if [ -n "$syms" ]; then status=FAILED; echo "FAIL: $name: private symbols:"; echo "$syms" | head -20; fi
  if [ -n "$bytes" ]; then status=FAILED; echo "FAIL: $name: private names in the archive bytes: $bytes"; fi
  [ "$status" = ok ] || fail=1
  printf '%s\t%s\tplatform=%s\tarch=%s\tobjects=%s\tprivate_symbols=%s\tprivate_names=%s%s\n' "$name" "$status" "$want_p" \
    "$archs" "$objects" "$(printf '%s' "$syms" | grep -c . || true)" "${bytes:-0}" \
    "${allowed:+	macos_public_${macos_public}=$allowed}" | tee -a "$out/verify.tsv"
done
[ "$fail" -eq 0 ] && echo "BRIDGE APPLE VERIFY PASSED ($engine)" || echo "BRIDGE APPLE VERIFY FAILED ($engine)"
exit "$fail"
