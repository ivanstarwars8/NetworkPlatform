#!/usr/bin/env bash
# Runs the tun.mode "fd" test of the bridge against a real kernel tun device inside a throw-away network
# namespace, so that nothing in the default namespace (interfaces, routes, firewall) is touched.
# Needs root, iproute2 and Go. Run from the repository root:
#   Cores/BuildScripts/bridge-linux-netns-test.sh
set -euo pipefail
cd "$(dirname "$0")/../Bridge"
ns="npbridge-$$"
bin="$(mktemp -d)"
cleanup() { ip netns del "$ns" 2>/dev/null || true; rm -rf "$bin"; }
trap cleanup EXIT
go test -c -o "$bin/engine.test" ./engine
ip netns add "$ns"
ip netns exec "$ns" env NP_NETNS_TEST=1 "$bin/engine.test" -test.run '^TestFDModeKernelTun$' -test.v -test.count=1
