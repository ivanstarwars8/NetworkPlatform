#!/usr/bin/env bash
# Checks a signed iOS IPA before it is uploaded (.github/workflows/testflight.yml). macOS only.
#
#   Tools/verify-ipa.sh <ipa> <app-bundle-id> <extension-bundle-id> <app-group> <build-number> <marketing-version>
#
# For the app and its Packet Tunnel extension: the code signature (codesign --verify --strict), the signing
# authority (Apple Distribution), the bundle identifier and versions, the signed entitlements (packet-tunnel-provider,
# the App Group, no get-task-allow) and the embedded App Store provisioning profile (same entitlements, no device
# list, beta-reports-active). The app: display name, icon, and no ITSAppUsesNonExemptEncryption key (export
# compliance is answered by the owner, not by this build). Prints the entitlements; the team identifier in them is
# masked by GitHub Actions because it is a repository secret.
set -euo pipefail
ipa="$1"; app_id="$2"; ext_id="$3"; group="$4"; build="$5"; version="$6"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
unzip -q "$ipa" -d "$work"
app="$(ls -d "$work"/Payload/*.app)"
fail() { echo "VERIFY FAILED: $*" >&2; exit 1; }

check_bundle() { # bundle expected-id kind
  local b="$1" id="$2" kind="$3" ent prof got
  echo "== $kind: $(basename "$b")"
  codesign --verify --strict --verbose=2 "$b" 2>&1 | sed 's/^/  /'
  codesign -dvv "$b" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Format)=' | sed 's/^/  /'
  codesign -dvv "$b" 2>&1 | grep -q '^Authority=Apple Distribution:' || fail "$kind is not signed with an Apple Distribution certificate"
  got="$(plutil -extract CFBundleIdentifier raw "$b/Info.plist")"; [ "$got" = "$id" ] || fail "$kind bundle id $got, expected $id"
  got="$(plutil -extract CFBundleVersion raw "$b/Info.plist")"; [ "$got" = "$build" ] || fail "$kind CFBundleVersion $got, expected $build"
  got="$(plutil -extract CFBundleShortVersionString raw "$b/Info.plist")"; [ "$got" = "$version" ] || fail "$kind version $got, expected $version"
  ent="$work/$kind.entitlements.plist"
  codesign -d --entitlements - --xml "$b" >"$ent" 2>/dev/null
  echo "  signed entitlements:"; plutil -p "$ent" | sed 's/^/    /'
  plutil -extract com.apple.developer.networking.networkextension xml1 -o - "$ent" | grep -q '<string>packet-tunnel-provider</string>' \
    || fail "$kind entitlements lack packet-tunnel-provider"
  plutil -extract com.apple.security.application-groups xml1 -o - "$ent" | grep -q "<string>$group</string>" \
    || fail "$kind entitlements lack the App Group $group"
  if plutil -extract get-task-allow raw "$ent" 2>/dev/null | grep -q true; then fail "$kind has get-task-allow"; fi
  prof="$work/$kind.profile.plist"
  [ -f "$b/embedded.mobileprovision" ] || fail "$kind has no embedded.mobileprovision"
  security cms -D -i "$b/embedded.mobileprovision" >"$prof"
  echo "  profile: $(plutil -extract Name raw "$prof"), expires $(plutil -extract ExpirationDate raw "$prof")"
  if plutil -extract ProvisionedDevices xml1 -o - "$prof" >/dev/null 2>&1; then fail "$kind profile lists devices (not an App Store profile)"; fi
  plutil -extract Entitlements.beta-reports-active raw "$prof" | grep -q true || fail "$kind profile lacks beta-reports-active"
  plutil -extract Entitlements.com.apple.developer.networking.networkextension xml1 -o - "$prof" | grep -q '<string>packet-tunnel-provider</string>' \
    || fail "$kind profile does not allow packet-tunnel-provider"
  plutil -extract Entitlements.com.apple.security.application-groups xml1 -o - "$prof" | grep -q "<string>$group</string>" \
    || fail "$kind profile does not allow the App Group $group"
  plutil -extract Entitlements.application-identifier raw "$prof" | grep -q "\.$id\$" || fail "$kind profile is not for $id"
}

check_bundle "$app" "$app_id" app
ext="$app/PlugIns/PacketTunnelXray.appex"
[ -d "$ext" ] || fail "no PacketTunnelXray.appex in the app"
[ "$(ls -d "$app"/PlugIns/*.appex | wc -l | tr -d ' ')" = 1 ] || fail "the app embeds more than one extension"
check_bundle "$ext" "$ext_id" extension
[ "$(plutil -extract NSExtension.NSExtensionPointIdentifier raw "$ext/Info.plist")" = com.apple.networkextension.packet-tunnel ] \
  || fail "extension point is not packet-tunnel"

name="$(plutil -extract CFBundleDisplayName raw "$app/Info.plist")"
echo "== app display name: $name"
[ "$name" = "Бык" ] || fail "CFBundleDisplayName is '$name'"
plutil -extract CFBundleIcons.CFBundlePrimaryIcon xml1 -o - "$app/Info.plist" >/dev/null 2>&1 || fail "no CFBundleIcons in the app"
[ -f "$app/Assets.car" ] || fail "no compiled asset catalog (icon)"
if plutil -extract ITSAppUsesNonExemptEncryption raw "$app/Info.plist" >/dev/null 2>&1; then
  fail "ITSAppUsesNonExemptEncryption is set; export compliance is the owner's declaration"
fi
echo "== orientations iPad: $(plutil -extract UISupportedInterfaceOrientations~ipad json -o - "$app/Info.plist" 2>/dev/null || echo none)"
echo "VERIFY OK: $app_id ($version, $build) + $ext_id, group $group"
