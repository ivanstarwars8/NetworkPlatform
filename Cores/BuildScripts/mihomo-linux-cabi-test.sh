#!/usr/bin/env bash
# Builds the Mihomo bridge as a C archive for the host (Linux) and runs the C ABI smoke test and the
# crossing-cost measurement against it. Run from the repository root on a machine with Go and a C compiler:
#   Cores/BuildScripts/mihomo-linux-cabi-test.sh
set -euo pipefail
cd "$(dirname "$0")/../MihomoBridge"
out="${NP_CABI_OUT:-$(mktemp -d)}"
CGO_ENABLED=1 go build -mod=readonly -buildvcs=false -trimpath -ldflags "-s -w -buildid=" -buildmode=c-archive \
  -o "$out/libnpmihomo.a" ./cabi
ls -l "$out/libnpmihomo.a" "$out/libnpmihomo.h"
grep -c '^extern .* npb_' "$out/libnpmihomo.h" | sed 's/^/exported functions: /'
cc -O2 -Wall -Wextra -I"$out" -o "$out/abi_test" cabi/ctest/abi_test.c "$out/libnpmihomo.a" -lpthread
"$out/abi_test"
[ -n "${NP_CABI_OUT:-}" ] || rm -rf "$out"
