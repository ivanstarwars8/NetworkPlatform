#!/usr/bin/env bash
# Builds one flavour of the app for one platform without signing and checks the product. macOS + Xcode only;
# needs the generated project (cd Apps && xcodegen generate) and the bridge xcframeworks the flavour links.
#
#   Tools/apple-build-flavour.sh <platform> <flavour> [configuration-kind] [derived-data]
#     platform  iOS | iOS-Simulator | macOS | tvOS | visionOS
#     flavour   XrayOnly | MihomoOnly | Dual
#     kind      Debug (default) | Release
#
# Checks of the product (ADR-0001 rules 1 and 2, ADR-0009):
#  - the app embeds exactly the flavour's extensions (PacketTunnelXray.appex, PacketTunnelMihomo.appex);
#  - each extension's Info.plist: bundle identifier, extension point, principal class;
#  - each extension links only its own engine: the bridge's npb_* symbols are present, the Go package path of
#    its core is present and the other core's is absent, and so is the other engine's Swift adapter module;
#  - the app binary links no Go and no bridge (no npb_* symbols, no Go core package paths);
#  - LC_BUILD_VERSION platform and minimum OS of each extension binary.
#  - App Intents metadata of the five Shortcuts actions in the app bundle (not tvOS).
# Runs with the bash 3.2 of macOS (no mapfile, no associative arrays).
# Logs: <derived-data>/<flavour>.log. Prints a summary line "RESULT <platform> <flavour> OK|FAILED <reason>".
set -euo pipefail
platform="$1"; flavour="$2"; kind="${3:-Debug}"; dd="${4:-${RUNNER_TEMP:-/tmp}/dd-$platform}"
root="$(cd "$(dirname "$0")/.." && pwd)"
config="$kind-$flavour"
case "$platform" in
  iOS) scheme_platform=iOS; destination="generic/platform=iOS"; suffix="-iphoneos" ;;
  iOS-Simulator) scheme_platform=iOS; destination="generic/platform=iOS Simulator"; suffix="-iphonesimulator" ;;
  macOS) scheme_platform=macOS; destination="generic/platform=macOS"; suffix="" ;;
  tvOS) scheme_platform=tvOS; destination="generic/platform=tvOS"; suffix="-appletvos" ;;
  visionOS) scheme_platform=visionOS; destination="generic/platform=visionOS"; suffix="-xros" ;;
  *) echo "unknown platform $platform" >&2; exit 2 ;;
esac
case "$flavour" in
  XrayOnly) extensions="PacketTunnelXray" ;;
  MihomoOnly) extensions="PacketTunnelMihomo" ;;
  Dual) extensions="PacketTunnelMihomo PacketTunnelXray" ;;
  *) echo "unknown flavour $flavour" >&2; exit 2 ;;
esac
scheme="NetworkPlatform-$flavour-$scheme_platform"
mkdir -p "$dd"
log="$dd/$flavour-$kind.log"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

result() {
  echo "RESULT $platform $config $1"
  echo "- $platform $config: $1" >>"$summary"
  [ "$1" = OK ] || exit 1
  exit 0
}

set +e
xcodebuild -project "$root/Apps/NetworkPlatform.xcodeproj" -scheme "$scheme" -configuration "$config" \
  -destination "$destination" -derivedDataPath "$dd" CODE_SIGNING_ALLOWED=NO build >"$log" 2>&1
rc=$?
set -e
grep -E '(error|warning):|\*\* BUILD' "$log" | grep -vE '^\s*$' | sort -u | head -60 || true
if [ "$rc" -ne 0 ] || ! grep -q '\*\* BUILD SUCCEEDED \*\*' "$log"; then
  reason="$(grep -m1 -E 'error:' "$log" | sed 's/^.*error: //' | cut -c1-300)"
  result "FAILED xcodebuild rc=$rc: ${reason:-see $log}"
fi
echo "--- warnings in project sources"
grep -E '/(Apps|Extensions|Packages)/[^ ]+:[0-9]+:[0-9]+: warning:' "$log" | sort -u | head -50 || true

products="$dd/Build/Products/$config$suffix"
app="$products/NetworkPlatform.app"
[ -d "$app" ] || result "FAILED no app at $app"
if [ -d "$app/Contents" ]; then plugins="$app/Contents/PlugIns"; app_bin="$app/Contents/MacOS/NetworkPlatform"
else plugins="$app/PlugIns"; app_bin="$app/NetworkPlatform"; fi

embedded="$(cd "$plugins" 2>/dev/null && ls -d -- *.appex 2>/dev/null | sed 's/\.appex$//' | sort | tr '\n' ' ' | sed 's/ $//')"
echo "embedded extensions: ${embedded:-none}"
[ "$embedded" = "$extensions" ] || result "FAILED embedded extensions '${embedded}', expected '$extensions'"

# Binaries of a bundle: the executable and, in Debug, the debug dylib (ENABLE_DEBUG_DYLIB) next to it. `file` prints
# one extra line per slice of a universal binary ("path (for architecture x): ..."); those are folded into the path.
bundle_binaries() {
  find "$1" -type f \( -perm -u+x -o -name '*.dylib' \) ! -name '*.plist' -print0 \
    | xargs -0 file | grep 'Mach-O' | cut -d: -f1 | sed -E 's/ \(for architecture [^)]*\)$//' | sort -u
}
count() { # pattern files...
  local p="$1" n=0 f c; shift
  for f in "$@"; do c=$(LC_ALL=C grep -a -c -- "$p" "$f" || true); n=$((n + c)); done
  echo "$n"
}
npb_symbols() {
  local f n=0 c
  for f in "$@"; do c=$(nm -m "$f" 2>/dev/null | grep -c -E '_npb_(abi_version|version|start|tun_read)$' || true); n=$((n + c)); done
  echo "$n"
}

xray_core="github.com/xtls/xray-core"
mihomo_core="github.com/metacubex/mihomo"
for ext in $extensions; do
  appex="$plugins/$ext.appex"
  plist="$appex/Info.plist"; [ -f "$plist" ] || plist="$appex/Contents/Info.plist"
  id="$(plutil -extract CFBundleIdentifier raw "$plist")"
  point="$(plutil -extract NSExtension.NSExtensionPointIdentifier raw "$plist")"
  principal="$(plutil -extract NSExtension.NSExtensionPrincipalClass raw "$plist")"
  group="$(plutil -extract NPAppGroupIdentifier raw "$plist")"
  echo "$ext: id=$id point=$point principal=$principal group=$group"
  [ "$id" = "org.example.networkplatform.$ext" ] || result "FAILED $ext bundle identifier $id"
  [ "$point" = "com.apple.networkextension.packet-tunnel" ] || result "FAILED $ext extension point $point"
  [ "$principal" = "$ext.PacketTunnelProvider" ] || result "FAILED $ext principal class $principal"
  bins=()
  while IFS= read -r f; do bins+=("$f"); done < <(bundle_binaries "$appex")
  [ "${#bins[@]}" -gt 0 ] || result "FAILED $ext has no Mach-O binary"
  if [ "$ext" = PacketTunnelXray ]; then own="$xray_core"; other="$mihomo_core"; own_swift=10EngineXray; other_swift=12EngineMihomo
  else own="$mihomo_core"; other="$xray_core"; own_swift=12EngineMihomo; other_swift=10EngineXray; fi
  syms=$(npb_symbols "${bins[@]}"); own_n=$(count "$own/" "${bins[@]}"); other_n=$(count "$other/" "${bins[@]}")
  own_s=$(count "$own_swift" "${bins[@]}"); other_s=$(count "$other_swift" "${bins[@]}")
  echo "$ext: npb symbols=$syms, '$own/' x$own_n, '$other/' x$other_n, Swift $own_swift x$own_s, $other_swift x$other_s"
  [ "$syms" -gt 0 ] || result "FAILED $ext: no npb_* symbols (bridge not linked)"
  [ "$own_n" -gt 0 ] || result "FAILED $ext: its core ($own) is not linked"
  [ "$other_n" -eq 0 ] || result "FAILED $ext links the other core ($other)"
  [ "$own_s" -gt 0 ] || result "FAILED $ext: its adapter ($own_swift) is not linked"
  [ "$other_s" -eq 0 ] || result "FAILED $ext links the other adapter ($other_swift)"
  main="$(dirname "$plist")"; [ "$(basename "$main")" = Contents ] && main="$main/MacOS"
  exe="$main/$ext"
  file "$exe"
  build="$(vtool -show-build "$exe" | grep -E 'platform|minos' | tr -s ' ' | tr '\n' ' ')"
  echo "$ext: $build"
  du -sh "$appex" | sed "s|^|$ext size: |"
  { echo "  - $ext: \`$build\`, $(du -sh "$appex" | cut -f1), npb=$syms, own core x$own_n, other core x$other_n"; } >>"$summary"
done

app_bins=()
while IFS= read -r f; do app_bins+=("$f"); done < <(find "$app" -path "$plugins" -prune -o -type f -print0 | xargs -0 file | grep 'Mach-O' | cut -d: -f1 | sed -E 's/ \(for architecture [^)]*\)$//' | sort -u)
app_npb=$(npb_symbols "${app_bins[@]}"); app_go=$(( $(count "$xray_core/" "${app_bins[@]}") + $(count "$mihomo_core/" "${app_bins[@]}") ))
app_engine=$(( $(count 10EngineXray "${app_bins[@]}") + $(count 12EngineMihomo "${app_bins[@]}") ))
echo "app binaries (${#app_bins[@]}): npb symbols=$app_npb, Go core paths=$app_go, engine adapters=$app_engine"
[ "$app_npb" -eq 0 ] && [ "$app_go" -eq 0 ] && [ "$app_engine" -eq 0 ] || result "FAILED the app links engine code"
# Shortcuts actions (Apps/SharedApp/Features/Automation/TunnelIntents.swift): Xcode writes their metadata into the
# bundle only when the app links AppIntents. Without it the system never learns about the actions. Not built for tvOS.
if [ "$platform" != tvOS ]; then
  meta="$(find "$app" -path "$plugins" -prune -o -type d -name Metadata.appintents -print | head -1)"
  [ -n "$meta" ] && [ -f "$meta/extract.actionsdata" ] || result "FAILED no App Intents metadata (Metadata.appintents/extract.actionsdata) in the app"
  intents="$(grep -a -o -E '"(Connect|Disconnect|Toggle)TunnelIntent"|"SelectProfileIntent"|"TunnelStatusIntent"' "$meta/extract.actionsdata" | sort -u | tr -d '"' | tr '\n' ' ')"
  echo "app intents metadata: ${intents:-none}"
  [ "$(echo "$intents" | wc -w | tr -d ' ')" -eq 5 ] || result "FAILED App Intents metadata lists '${intents}', expected 5 actions"
fi
du -sh "$app" "$app_bin"
result OK
