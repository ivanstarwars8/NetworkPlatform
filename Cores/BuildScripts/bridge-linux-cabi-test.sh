#!/usr/bin/env bash
# Builds the bridge as a C archive for the host (Linux) and runs the C ABI smoke test and the
# crossing-cost measurement against it. Run from the repository root on a machine with Go and a C compiler:
#   Cores/BuildScripts/bridge-linux-cabi-test.sh
# The Apple slices are built the same way with the SDK environment described in README.md, section 4.2.
set -euo pipefail
cd "$(dirname "$0")/../Bridge"
out="${NP_CABI_OUT:-$(mktemp -d)}"
CGO_ENABLED=1 go build -mod=readonly -buildvcs=false -trimpath -ldflags "-s -w -buildid=" -buildmode=c-archive \
  -o "$out/libnpbridge.a" ./cabi
ls -l "$out/libnpbridge.a" "$out/libnpbridge.h"
grep -c '^extern .* npb_' "$out/libnpbridge.h" | sed 's/^/exported functions: /'
cc -O2 -Wall -Wextra -I"$out" -o "$out/abi_test" cabi/ctest/abi_test.c "$out/libnpbridge.a" -lpthread
"$out/abi_test"
[ -n "${NP_CABI_OUT:-}" ] || rm -rf "$out"
