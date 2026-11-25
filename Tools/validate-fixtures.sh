#!/usr/bin/env bash
# Feeds every compiled fixture configuration to a real Xray binary (`xray run -test`),
# which parses and builds the configuration without opening any listener.
#
# Usage: Tools/validate-fixtures.sh [path-to-xray]
#   The binary is taken from the argument, then $XRAY_BIN, then PATH.
#   Expected version: the one in XrayConfigCompiler.engineVersion (26.11.9).
#
# Output: one line per fixture.
#   PASS     the binary accepted the configuration
#   FAIL     the binary rejected it (the script exits 1)
#   BLOCKED  the compiler refused to emit a configuration; the reason from the
#            stored conversion report is printed. These are not sent to Xray.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XRAY="${1:-${XRAY_BIN:-xray}}"
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
[ "$fail" -eq 0 ]
