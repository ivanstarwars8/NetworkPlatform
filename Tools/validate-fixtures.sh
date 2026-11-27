#!/usr/bin/env bash
# Feeds every compiled fixture configuration to a real Xray binary (`xray run -test`),
# which parses and builds the configuration without opening any listener.
#
# Then, when a Mihomo binary is given, feeds every compiled Mihomo configuration (`*.mihomo.yaml`, same
# corpus plus Tests/Fixtures/Routing) to it (`mihomo -t`), which parses the document and builds every proxy,
# group and rule without dialing or listening. Each run gets a throw-away home directory.
#
# Usage: Tools/validate-fixtures.sh [path-to-xray] [path-to-mihomo]
#   Xray: the first argument, then $XRAY_BIN, then PATH. Expected version: XrayConfigCompiler.engineVersion.
#   Mihomo: the second argument, then $MIHOMO_BIN; without one the Mihomo pass is not run (and says so).
#   Expected version: MihomoConfigCompiler.engineVersion (the module pinned by Cores/MihomoBridge/go.mod).
#
# Output: one line per fixture.
#   PASS     the binary accepted the configuration
#   FAIL     the binary rejected it (the script exits 1)
#   BLOCKED  the compiler refused to emit a configuration; the reason from the
#            stored conversion report is printed. These are not sent to Xray.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XRAY="${1:-${XRAY_BIN:-xray}}"
MIHOMO="${2:-${MIHOMO_BIN:-}}"
if ! command -v "$XRAY" >/dev/null 2>&1; then
  echo "xray binary not found: $XRAY" >&2
  exit 2
fi
echo "# $("$XRAY" version | head -n 1)"
pass=0; fail=0; blocked=0
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
for source in "$ROOT"/Tests/Fixtures/ShareLinks/*.link "$ROOT"/Tests/Fixtures/Interop/*.link "$ROOT"/Tests/Fixtures/Profiles/*.profile.json; do
  [ -e "$source" ] || continue
  base="${source%.link}"; base="${base%.profile.json}"
  name="$(basename "$(dirname "$base")")/$(basename "$base")"
  if [ -f "$base.xray.json" ]; then
    if "$XRAY" run -test -c "$base.xray.json" >"$log" 2>&1; then
      pass=$((pass + 1)); echo "PASS    $name"
    else
      fail=$((fail + 1)); echo "FAIL    $name"
      sed 's/^/        /' "$log" | tail -n 6
    fi
  else
    blocked=$((blocked + 1))
    reason="$(python3 - "$base.report.json" <<'PY' 2>/dev/null
import json, sys
report = json.load(open(sys.argv[1]))["conversion"]
errors = [i["path"] + ": " + i["detail"] for i in report["issues"]
          if i["severity"] == "error" and not i["path"].startswith("profile.")]
print("; ".join(errors))
PY
)"
    echo "BLOCKED $name — ${reason:-see $base.report.json}"
  fi
done
echo "# accepted: $pass, rejected: $fail, blocked by the compiler: $blocked"

blocked_reason() {
  python3 - "$1" <<'PY' 2>/dev/null
import json, sys
report = json.load(open(sys.argv[1]))
report = report.get("conversion", report)
errors = [i["path"] + ": " + i["detail"] for i in report["issues"]
          if i["severity"] == "error" and not i["path"].startswith("profile.")]
print("; ".join(errors))
PY
}

mfail=0
if [ -z "$MIHOMO" ]; then
  echo "# mihomo: no binary given (second argument or MIHOMO_BIN); Mihomo configurations NOT validated"
elif ! command -v "$MIHOMO" >/dev/null 2>&1; then
  echo "mihomo binary not found: $MIHOMO" >&2
  exit 2
else
  echo "# $("$MIHOMO" -v | head -n 1)"
  mpass=0; mblocked=0
  home="$(mktemp -d)"
  trap 'rm -f "$log"; rm -rf "$home"' EXIT
  for report in "$ROOT"/Tests/Fixtures/{ShareLinks,Interop,Profiles,Routing}/*.mihomo-report.json; do
    [ -e "$report" ] || continue
    base="${report%.mihomo-report.json}"
    name="$(basename "$(dirname "$base")")/$(basename "$base")"
    if [ -f "$base.mihomo.yaml" ]; then
      rm -rf "$home"/*
      if "$MIHOMO" -t -d "$home" -f "$base.mihomo.yaml" >"$log" 2>&1; then
        mpass=$((mpass + 1)); echo "PASS    mihomo $name"
      else
        mfail=$((mfail + 1)); echo "FAIL    mihomo $name"
        sed 's/^/        /' "$log" | tail -n 6
      fi
    else
      mblocked=$((mblocked + 1))
      reason="$(blocked_reason "$report")"
      echo "BLOCKED mihomo $name — ${reason:-see $report}"
    fi
  done
  echo "# mihomo accepted: $mpass, rejected: $mfail, blocked by the compiler: $mblocked"
fi
[ "$fail" -eq 0 ] && [ "$mfail" -eq 0 ]
