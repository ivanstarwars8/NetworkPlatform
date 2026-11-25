#!/usr/bin/env bash
# Interoperability run: real traffic through the configurations the compiler produced.
#
# One Xray process plays the server (server.json, every inbound on 127.0.0.1:47001-47016),
# a throwaway HTTP server on port 47100 is the destination, and for every compiled
# <name>.xray.json a second Xray process is started as the client. A token and a 1 MiB
# random file are fetched through the client's SOCKS inbound (127.0.0.1:10808) and
# compared byte for byte.
#
# The script re-executes itself inside a private, anonymous network namespace
# (`unshare -n`, needs root): nothing listens in the host namespace, and the namespace
# disappears with the last process. Inside it the destination gets the documentation
# address 192.0.2.1 on `lo`: a WireGuard tunnel cannot be tested against 127.0.0.1,
# because the userspace IP stack of the client treats that address as its own loopback.
#
# Usage: Tests/Fixtures/Interop/run-interop.sh /path/to/xray
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
XRAY="${1:-${XRAY_BIN:-xray}}"
SOCKS=10808
TARGET=47100
TARGET_IP=192.0.2.1
if [ "${NP_INTEROP_NS:-}" != "1" ]; then
  command -v unshare >/dev/null 2>&1 || { echo "unshare is required" >&2; exit 2; }
  XRAY="$(command -v "$XRAY")" || { echo "xray binary not found" >&2; exit 2; }
  NP_INTEROP_NS=1 exec unshare -n -- "$0" "$XRAY"
fi
ip link set lo up && ip addr add "$TARGET_IP/32" dev lo || { echo "cannot configure the namespace" >&2; exit 2; }
command -v "$XRAY" >/dev/null 2>&1 || { echo "xray binary not found: $XRAY" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 2; }

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

WORK="$(mktemp -d)"
PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir "$WORK/www"
TOKEN="np-interop-$RANDOM-$RANDOM"
echo "$TOKEN" > "$WORK/www/token.txt"
head -c 1048576 /dev/urandom > "$WORK/www/blob.bin"
SUM="$(sha256sum "$WORK/www/blob.bin" | cut -d' ' -f1)"
python3 -m http.server "$TARGET" --bind "$TARGET_IP" --directory "$WORK/www" >"$WORK/http.log" 2>&1 &
PIDS+=($!)
"$XRAY" run -c "$DIR/server.json" >"$WORK/server.log" 2>&1 &
SERVER=$!
PIDS+=($SERVER)
for _ in $(seq 1 50); do port_open 47001 && (exec 3<>"/dev/tcp/$TARGET_IP/$TARGET") 2>/dev/null && break; sleep 0.2; done
if ! kill -0 "$SERVER" 2>/dev/null; then
  echo "server did not start:" >&2; tail -n 5 "$WORK/server.log" >&2; exit 2
fi
echo "# $("$XRAY" version | head -n 1)"

pass=0; fail=0
for config in "$DIR"/*.xray.json; do
  name="$(basename "$config" .xray.json)"
  "$XRAY" run -c "$config" >"$WORK/client.log" 2>&1 &
  client=$!
  for _ in $(seq 1 50); do port_open "$SOCKS" && break; sleep 0.1; done
  start=$(date +%s%N)
  token="$(curl -s --max-time 20 --socks5-hostname "127.0.0.1:$SOCKS" "http://$TARGET_IP:$TARGET/token.txt")"
  sum="$(curl -s --max-time 30 --socks5-hostname "127.0.0.1:$SOCKS" "http://$TARGET_IP:$TARGET/blob.bin" | sha256sum | cut -d' ' -f1)"
  elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
  kill "$client" 2>/dev/null; wait "$client" 2>/dev/null
  for _ in $(seq 1 50); do port_open "$SOCKS" || break; sleep 0.1; done
  if [ "$token" = "$TOKEN" ] && [ "$sum" = "$SUM" ]; then
    pass=$((pass + 1)); echo "PASS  $name (${elapsed} ms)"
  else
    fail=$((fail + 1)); echo "FAIL  $name (token ok: $([ "$token" = "$TOKEN" ] && echo yes || echo no), 1 MiB ok: $([ "$sum" = "$SUM" ] && echo yes || echo no))"
    grep -v "^$" "$WORK/client.log" | tail -n 4 | sed 's/^/      client: /'
    grep -v "^$" "$WORK/server.log" | tail -n 2 | sed 's/^/      server: /'
  fi
done
echo "# traffic passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
