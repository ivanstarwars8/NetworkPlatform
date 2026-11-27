#!/usr/bin/env bash
# End-to-end lab for the bridge's packet path on Linux: client namespace -> kernel TUN -> bridge -> Xray
# outbound -> stock xray server -> targets, all inside two throw-away network namespaces. Nothing in the
# default namespace (interfaces, routes, firewall) is touched.
#
# Needs root, iproute2, curl, Go (go.mod's toolchain). Run from the repository root on a Linux dev host:
#   Cores/BuildScripts/bridge-tunlab.sh build            release builds of nplab and stock xray
#   Cores/BuildScripts/bridge-tunlab.sh e2e              functional matrix (TCP/UDP, v4/v6, DNS, MTU, DF, loop, backpressure)
#   Cores/BuildScripts/bridge-tunlab.sh bench [reps]     throughput / latency / CPU / memory vs direct and stock xray
#   Cores/BuildScripts/bridge-tunlab.sh batch [reps]     packet-path cost per npb_tun_write batch size
#   Cores/BuildScripts/bridge-tunlab.sh profile          pprof CPU and heap profiles under load
#   Cores/BuildScripts/bridge-tunlab.sh soak [minutes]   long run with periodic memory/goroutine samples
#   Cores/BuildScripts/bridge-tunlab.sh memcmp [reps]    default vs mobile memory profile: cold start, throughput, 200-flow burst
# MOBILE=1 runs the bridge with memory.profile=mobile and gives the client config the policy level of the
# compiler's mobile profile (XrayMemoryProfile.mobile); CONNIDLE / BUFSIZE override its connIdle / bufferSize.
#   Cores/BuildScripts/bridge-tunlab.sh teardown         kill lab processes, delete the namespaces
# Results go to $NP_LAB_OUT (default Logs/tunlab, git-ignored), one JSON object per line.
#
# Topology (documentation-range addresses only):
#   ns C: nptun0 10.66.0.2/30 fd00:66::2/64, default routes -> nptun0;  vc 10.200.0.1/30 fd00:200::1/64
#         exclusion route 203.0.113.1/32 via vc (the proxy server: the analogue of excludedRoutes)
#   ns S: vs 10.200.0.2/30 fd00:200::2/64; dummy "tg": 203.0.113.1 (xray server), 198.18.0.10 / 198.18.0.53,
#         2001:db8:1::10 / 2001:db8:1::53 (targets: echo 7, discard 9, sink 10, source 19, DNS 53 and 5353)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BRIDGE="$ROOT/Cores/Bridge"
OUT="${NP_LAB_OUT:-$ROOT/Logs/tunlab}"
BIN="$OUT/bin"
CFG="$OUT/cfg"
# NP_LAB_NS prefixes the two namespace names (default npbl), so parallel workspaces do not collide
NC=${NP_LAB_NS:-npbl}-c
NS=${NP_LAB_NS:-npbl}-s
SERVER4=203.0.113.1
T4=198.18.0.10
T6=2001:db8:1::10
D4=198.18.0.53
D6=2001:db8:1::53
CTL=127.0.0.1:6060
# policy level 0 of the compiler's mobile profile (seconds; bufferSize in KiB)
MOBILE_CONNIDLE=30
MOBILE_HANDSHAKE=10
MOBILE_BUFSIZE=4
mkdir -p "$OUT" "$CFG"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
inc() { ip netns exec "$NC" "$@"; }
ins() { ip netns exec "$NS" "$@"; }
nplab() { "$BIN/nplab" "$@"; }

# ---------------------------------------------------------------------------------------------- build
do_build() {
	mkdir -p "$BIN"
	cd "$BRIDGE"
	log "building nplab and stock xray (release: -trimpath -ldflags='-s -w')"
	if [ -n "${NP_LAB_RACE:-}" ]; then
		# race-detector build of the lab tool (and so of the engine); the e2e run then doubles as a race test
		go build -buildvcs=false -race -trimpath -o "$BIN/nplab" ./cmd/nplab
	else
		go build -buildvcs=false -trimpath -ldflags='-s -w' -o "$BIN/nplab" ./cmd/nplab
	fi
	# the core's own main package, from the module cache at the pinned version; -mod=mod lets go add the
	# go.sum lines of main's extra imports in this build copy only
	go build -buildvcs=false -mod=mod -trimpath -ldflags='-s -w' -o "$BIN/xray" github.com/xtls/xray-core/main
	go version >"$BIN/go-version.txt"
	"$BIN/xray" version | head -1 >>"$BIN/go-version.txt"
	cat "$BIN/go-version.txt" >&2
	cd "$ROOT"
}

# ---------------------------------------------------------------------------------------------- topology
setup() {
	teardown quiet
	log "creating namespaces $NC $NS"
	ip netns add "$NC"
	ip netns add "$NS"
	ip link add vc netns "$NC" type veth peer name vs netns "$NS"
	inc ip link set lo up
	ins ip link set lo up
	inc ip addr add 10.200.0.1/30 dev vc
	inc ip -6 addr add fd00:200::1/64 dev vc nodad
	ins ip addr add 10.200.0.2/30 dev vs
	ins ip -6 addr add fd00:200::2/64 dev vs nodad
	inc ip link set vc up
	ins ip link set vs up
	ins ip link add tg type dummy
	for a in $SERVER4/32 $T4/32 $D4/32; do ins ip addr add "$a" dev tg; done
	for a in $T6/128 $D6/128; do ins ip -6 addr add "$a" dev tg nodad; done
	ins ip link set tg up
	ins ip route add 10.66.0.0/30 via 10.200.0.1
	inc ip tuntap add dev nptun0 mode tun
	inc ip addr add 10.66.0.2/30 dev nptun0
	inc ip -6 addr add fd00:66::2/64 dev nptun0 nodad
	inc ip link set nptun0 mtu 1500 up
	routes_tunnel
	gen_configs
}

# Full tunnel: everything goes to nptun0 except the proxy server, which is excluded via the veth.
routes_tunnel() {
	inc ip route replace default dev nptun0
	inc ip -6 route replace default dev nptun0
	inc ip route replace $SERVER4/32 via 10.200.0.2 dev vc
}

set_mtu() { inc ip link set nptun0 mtu "$1"; }

teardown() {
	for ns in "$NC" "$NS"; do
		if ip netns list | grep -qw "$ns"; then
			for pid in $(ip netns pids "$ns" 2>/dev/null); do kill -TERM "$pid" 2>/dev/null || true; done
			sleep 0.5
			for pid in $(ip netns pids "$ns" 2>/dev/null); do kill -KILL "$pid" 2>/dev/null || true; done
			ip netns del "$ns"
		fi
	done
	[ "${1:-}" = quiet ] || log "namespaces removed; leftover lab processes: $(pgrep -fc "$BIN/" || true)"
}

# ---------------------------------------------------------------------------------------------- configs
gen_configs() {
	local keys priv pub uuid sskey
	keys="$("$BIN/xray" x25519)"
	priv="$(awk -F': *' 'tolower($1) ~ /private/ {print $2}' <<<"$keys")"
	pub="$(awk -F': *' 'tolower($1) ~ /password|public/ {print $2; exit}' <<<"$keys")"
	uuid="$("$BIN/xray" uuid)"
	sskey="$(head -c 16 /dev/urandom | base64)"
	[ -n "$priv" ] && [ -n "$pub" ] || { echo "cannot parse xray x25519 output: $keys" >&2; exit 1; }
	cat >"$CFG/server.json" <<EOF
{"log":{"loglevel":"warning"},
 "inbounds":[
  {"tag":"reality","listen":"$SERVER4","port":443,"protocol":"vless",
   "settings":{"clients":[{"id":"$uuid","flow":"xtls-rprx-vision"}],"decryption":"none"},
   "streamSettings":{"network":"raw","security":"reality","realitySettings":{
     "target":"127.0.0.1:8443","serverNames":["np.test"],"privateKey":"$priv","shortIds":["0123abcd"]}}},
  {"tag":"ss","listen":"$SERVER4","port":444,"protocol":"shadowsocks",
   "settings":{"method":"2022-blake3-aes-128-gcm","password":"$sskey","network":"tcp,udp"}}],
 "outbounds":[{"tag":"direct","protocol":"freedom","settings":{"finalRules":[{"action":"allow"}]}}]}
EOF
	printf '%s' "$uuid" >"$CFG/uuid"
	printf '%s' "$pub" >"$CFG/pub"
	printf '%s' "$sskey" >"$CFG/sskey"
}

# client_config KIND MTU -> path. KIND: reality (VLESS+REALITY+Vision) | ss (Shadowsocks 2022). The same file is given to the bridge and to stock xray.
client_config() {
	local kind=$1 mtu=$2 uuid pub out levels=''
	# CONNIDLE=<s> sets the core's connIdle for user level 0 (default 300 s), used by the soak comparison.
	# MOBILE=1: the level the compiler emits for XrayMemoryProfile.mobile (keep in sync with
	# XrayConfigCompiler.mobilePolicy; asserted there by XrayConfigCompilerTests).
	if [ -n "${MOBILE:-}" ]; then
		levels=',"levels":{"0":{"connIdle":'"${CONNIDLE:-$MOBILE_CONNIDLE}"',"handshake":'$MOBILE_HANDSHAKE',"uplinkOnly":1,"downlinkOnly":1,"bufferSize":'"${BUFSIZE:-$MOBILE_BUFSIZE}"'}}'
	elif [ -n "${CONNIDLE:-}" ]; then levels=',"levels":{"0":{"connIdle":'"$CONNIDLE"'}}'; fi
	uuid="$(cat "$CFG/uuid")"
	pub="$(cat "$CFG/pub")"
	out="$CFG/client-$kind-$mtu${MOBILE:+-mobile}${CONNIDLE:+-idle$CONNIDLE}${BUFSIZE:+-buf$BUFSIZE}.json"
	local proxy
	if [ "$kind" = reality ]; then
		proxy='{"tag":"proxy","protocol":"vless","settings":{"address":"'$SERVER4'","port":443,"id":"'$uuid'","flow":"xtls-rprx-vision","encryption":"none"},"streamSettings":{"network":"raw","security":"reality","realitySettings":{"serverName":"np.test","fingerprint":"chrome","password":"'$pub'","shortId":"0123abcd"}}}'
	else
		proxy='{"tag":"proxy","protocol":"shadowsocks","settings":{"address":"'$SERVER4'","port":444,"method":"2022-blake3-aes-128-gcm","password":"'"$(cat "$CFG/sskey")"'"}}'
	fi
	cat >"$out" <<EOF
{"log":{"loglevel":"warning"},
 "dns":{"servers":["$D4"],"tag":"dns-internal"},
 "stats":{},
 "policy":{"system":{"statsInboundUplink":true,"statsInboundDownlink":true,"statsOutboundUplink":true,"statsOutboundDownlink":true}$levels},
 "inbounds":[{"tag":"tun-in","protocol":"tun","settings":{"name":"nptun0","mtu":$mtu}}],
 "outbounds":[
  $proxy,
  {"tag":"direct","protocol":"freedom"},
  {"tag":"dns-out","protocol":"dns"}],
 "routing":{"rules":[
  {"inboundTag":["tun-in"],"network":"udp","port":"53","outboundTag":"dns-out"},
  {"inboundTag":["dns-internal"],"outboundTag":"proxy"}]}}
EOF
	echo "$out"
}

# ---------------------------------------------------------------------------------------------- processes
start_far() {
	ip netns exec "$NS" "$BIN/nplab" target >"$OUT/target.log" 2>&1 &
	ip netns exec "$NS" "$BIN/xray" run -c "$CFG/server.json" >"$OUT/server.log" 2>&1 &
	sleep 1
	ins ss -ltn | grep -q "$SERVER4:443" || { cat "$OUT/server.log" >&2; exit 1; }
}

CLIENT_PID=
# start_client MODE CONFIG [bridge flags...]; MODE: flow | fd | stock
start_client() {
	local mode=$1 config=$2
	shift 2
	routes_tunnel
	local logf="$OUT/client-$mode.log"
	echo "=== $(date +%T) start $mode $config $*" >>"$logf"
	# ip netns exec execs the command, so $! is the pid of nplab / xray itself (not of a subshell)
	if [ "$mode" = stock ]; then
		ip netns exec "$NC" "$BIN/nplab" tunexec -tun nptun0 "$BIN/xray" run -c "$config" >>"$logf" 2>&1 &
	else
		ip netns exec "$NC" "$BIN/nplab" bridge -mode "$mode" -config "$config" -ctl $CTL -loop-addrs $SERVER4 "$@" >>"$logf" 2>&1 &
	fi
	CLIENT_PID=$!
	local i
	for i in $(seq 1 100); do
		if inc "$BIN/nplab" client -test tcp-rr -addr $T4:7 -n 1 -timeout 10s 2>/dev/null | grep -q '"ok":true'; then
			return 0
		fi
		kill -0 "$CLIENT_PID" 2>/dev/null || break
		sleep 0.2
	done
	log "client $mode did not come up"
	cat "$logf" >&2
	return 1
}

stop_client() {
	[ -n "$CLIENT_PID" ] || return 0
	kill -TERM "$CLIENT_PID" 2>/dev/null || true
	local i
	for i in $(seq 1 100); do
		kill -0 "$CLIENT_PID" 2>/dev/null || break
		sleep 0.1
	done
	if kill -0 "$CLIENT_PID" 2>/dev/null; then
		log "client $CLIENT_PID did not stop in 10 s; killing"
		kill -KILL "$CLIENT_PID" 2>/dev/null || true
	fi
	wait "$CLIENT_PID" 2>/dev/null || true
	# the tun must be free again before the next client attaches
	for i in $(seq 1 50); do
		inc ip link show nptun0 | grep -q NO-CARRIER && break
		sleep 0.1
	done
	CLIENT_PID=
}

# c LABEL TEST ADDR [flags]: run one client test in ns C, append the JSON line to $RES and echo it.
c() {
	local label=$1 test=$2 addr=$3
	shift 3
	local extra=()
	[ -n "$CLIENT_PID" ] && extra+=(-pid "$CLIENT_PID")
	[ -n "${WITH_CTL:-}" ] && extra+=(-ctl $CTL)
	inc "$BIN/nplab" client -label "$label" -test "$test" -addr "$addr" "${extra[@]}" "$@" | tee -a "$RES"
}

# ---------------------------------------------------------------------------------------------- e2e
do_e2e() {
	RES="$OUT/e2e.jsonl"
	: >"$RES"
	setup
	rm -f "$OUT"/client-*.log
	trap 'stop_client; teardown' EXIT
	start_far
	local mtu cfg
	for mtu in 1280 1400 1500; do
		set_mtu "$mtu"
		cfg="$(client_config reality "$mtu")"
		log "flow mode, MTU $mtu"
		start_client flow "$cfg" -mtu "$mtu"
		WITH_CTL=1
		c "flow-$mtu" tcp-echo $T4:7 -bytes $((16 << 20))
		c "flow-$mtu" tcp-echo "[$T6]:7" -bytes $((16 << 20))
		c "flow-$mtu" tcp-down $T4:19 -bytes $((64 << 20))
		c "flow-$mtu" tcp-up "[$T6]:10" -bytes $((64 << 20))
		c "flow-$mtu" udp-echo $T4:7 -sizes "1,512,$((mtu - 28)),$((mtu - 27)),4000,7500"
		c "flow-$mtu" udp-echo "[$T6]:7" -sizes "1,512,$((mtu - 48)),$((mtu - 47)),4000,7500"
		c "flow-$mtu" pmtu $T4:7
		c "flow-$mtu" pmtu "[$T6]:7"
		c "flow-$mtu" dns $D4:53 -qtype A -n 20 -expect $T4
		c "flow-$mtu" dns $D4:53 -qtype AAAA -n 20 -expect $T6
		c "flow-$mtu" dns "[$D6]:53" -qtype AAAA -n 20 -expect $T6
		c "flow-$mtu" dns $D4:5353 -qtype A -n 20 -expect $T4
		inc curl -s "http://$CTL/sample" | sed "s/^/{\"label\":\"flow-$mtu\",\"test\":\"final-sample\",\"sample\":/; s/\$/}/" | tee -a "$RES"
		stop_client
		unset WITH_CTL
	done

	log "MTU mismatch: kernel tun 1500, bridge stack 1280"
	set_mtu 1500
	start_client flow "$(client_config reality 1500)" -mtu 1280
	WITH_CTL=1
	c mismatch-1500-1280 tcp-echo $T4:7 -bytes $((16 << 20))
	c mismatch-1500-1280 tcp-echo "[$T6]:7" -bytes $((16 << 20))
	c mismatch-1500-1280 udp-echo $T4:7 -sizes "1,1252,1253,1472,4000"
	c mismatch-1500-1280 udp-echo "[$T6]:7" -sizes "1,1232,1233,1452,4000"
	stop_client
	unset WITH_CTL

	log "fd mode and stock xray, MTU 1500 (same config)"
	for mode in fd stock; do
		start_client "$mode" "$(client_config reality 1500)"
		c "$mode-1500" tcp-echo $T4:7 -bytes $((16 << 20))
		c "$mode-1500" tcp-echo "[$T6]:7" -bytes $((16 << 20))
		c "$mode-1500" tcp-up $T4:10 -bytes $((64 << 20))
		c "$mode-1500" udp-echo $T4:7 -sizes "1,512,1472,4000,7500"
		c "$mode-1500" udp-echo "[$T6]:7" -sizes "1,512,1452,4000,7500"
		c "$mode-1500" dns $D4:53 -qtype A -n 20 -expect $T4
		stop_client
	done

	log "core limits, same config for flow and stock: TCP half-close, largest UDP datagram"
	inc "$BIN/nplab" client -label direct-halfclose -test tcp-halfclose -addr 10.200.0.2:9 -bytes $((1 << 20)) | tee -a "$RES"
	for mode in flow stock; do
		start_client "$mode" "$(client_config reality 1500)"
		c "$mode-halfclose" tcp-halfclose $T4:9 -bytes $((1 << 20)) -timeout 30s || true
		c "$mode-udp-limit" udp-echo $T4:7 -sizes "7500,7600,7700,7800,7900,8000,16000,65000" || true
		c "$mode-udp-limit" udp-echo "[$T6]:7" -sizes "7500,7600,7700,7800,7900,8000,16000,65000" || true
		stop_client
	done

	log "loop: the core's own outbound connections must leave via the veth, not the tunnel"
	start_client flow "$(client_config reality 1500)"
	WITH_CTL=1
	inc ip route get $SERVER4 | head -1 | sed 's/^/route to server: /' >&2
	local vtx0 vtx1
	vtx0=$(inc cat /sys/class/net/vc/statistics/tx_bytes)
	c loop-excluded tcp-echo $T4:7 -bytes $((8 << 20))
	vtx1=$(inc cat /sys/class/net/vc/statistics/tx_bytes)
	echo "{\"label\":\"loop-excluded\",\"test\":\"veth-tx\",\"ok\":true,\"values\":{\"vethTxBytes\":$((vtx1 - vtx0))}}" | tee -a "$RES"
	log "negative control: exclusion route removed, server reachable only through the tunnel"
	inc ip route del $SERVER4/32
	inc ip route get $SERVER4 | head -1 | sed 's/^/route to server: /' >&2
	c loop-no-exclusion tcp-setup $T4:7 -n 1 -timeout 8s || true
	inc ip route replace $SERVER4/32 via 10.200.0.2 dev vc
	c loop-restored tcp-echo $T4:7 -bytes $((1 << 20))
	inc curl -s "http://$CTL/sample" | sed 's/^/{"label":"loop","test":"final-sample","sample":/; s/$/}/' | tee -a "$RES"
	stop_client
	unset WITH_CTL

	log "backpressure: slow host reader (16 KiB per npb_tun_read, 2 ms pause), 128 KiB queue"
	start_client flow "$(client_config reality 1500)" -outq $((128 << 10)) -readbuf $((16 << 10)) -read-delay 2ms
	WITH_CTL=1
	c backpressure-slow-reader tcp-down $T4:19 -bytes $((64 << 20)) -conns 8 -timeout 300s
	c backpressure-slow-reader tcp-rr $T4:7 -n 200
	stop_client
	log "backpressure: slow host writer (batch 8, 2 ms pause after each npb_tun_write)"
	local drop0 drop1
	drop0=$(inc cat /sys/class/net/nptun0/statistics/tx_dropped)
	start_client flow "$(client_config reality 1500)" -batch 8 -write-delay 2ms
	c backpressure-slow-writer tcp-up $T4:10 -bytes $((32 << 20)) -conns 8 -timeout 300s
	stop_client
	drop1=$(inc cat /sys/class/net/nptun0/statistics/tx_dropped)
	echo "{\"label\":\"backpressure-slow-writer\",\"test\":\"kernel-tun-txdrop\",\"ok\":true,\"values\":{\"txDropped\":$((drop1 - drop0))}}" | tee -a "$RES"
	unset WITH_CTL
	log "e2e done: $RES"
}

# ---------------------------------------------------------------------------------------------- bench
bench_round() { # label-prefix kind mode
	local p=$1 kind=$2 mode=$3
	case $mode in
	direct-veth)
		c "$p" tcp-down 10.200.0.2:19 -bytes "$BYTES"
		c "$p" tcp-up 10.200.0.2:10 -bytes "$BYTES"
		c "$p-4c" tcp-down 10.200.0.2:19 -bytes "$BYTES" -conns 4
		c "$p" tcp-rr 10.200.0.2:7 -n 2000
		c "$p" udp-rr 10.200.0.2:7 -n 2000 -size 64
		c "$p" tcp-setup 10.200.0.2:7 -n 100
		;;
	direct-loopback)
		local s=(ins "$BIN/nplab" client)
		"${s[@]}" -label "$p" -test tcp-down -addr 127.0.0.1:19 -bytes "$BYTES" | tee -a "$RES"
		"${s[@]}" -label "$p" -test tcp-up -addr 127.0.0.1:10 -bytes "$BYTES" | tee -a "$RES"
		"${s[@]}" -label "$p-4c" -test tcp-down -addr 127.0.0.1:19 -bytes "$BYTES" -conns 4 | tee -a "$RES"
		"${s[@]}" -label "$p" -test tcp-rr -addr 127.0.0.1:7 -n 2000 | tee -a "$RES"
		"${s[@]}" -label "$p" -test udp-rr -addr 127.0.0.1:7 -n 2000 -size 64 | tee -a "$RES"
		"${s[@]}" -label "$p" -test tcp-setup -addr 127.0.0.1:7 -n 100 | tee -a "$RES"
		;;
	*)
		[ "$mode" = flow ] && WITH_CTL=1
		start_client "$mode" "$(client_config "$kind" 1500)" "${BRIDGE_FLAGS[@]}"
		# warm-up: first REALITY handshake, page faults, GC sizing
		c "$p-warmup" tcp-down $T4:19 -bytes $((16 << 20)) >/dev/null
		c "$p" tcp-down $T4:19 -bytes "$BYTES"
		c "$p" tcp-up $T4:10 -bytes "$BYTES"
		c "$p-4c" tcp-down $T4:19 -bytes "$BYTES" -conns 4
		c "$p" tcp-rr $T4:7 -n 2000
		c "$p" udp-rr $T4:7 -n 2000 -size 64
		c "$p" tcp-setup $T4:7 -n 100
		stop_client
		unset WITH_CTL
		;;
	esac
}

do_bench() {
	local reps=${1:-7}
	RES="$OUT/bench.jsonl"
	: >"$RES"
	BYTES=$((64 << 20))
	BRIDGE_FLAGS=()
	setup
	trap 'stop_client; teardown' EXIT
	start_far
	set_mtu 1500
	cat /proc/loadavg | sed 's/^/loadavg before: /' >&2
	local r kind mode
	for r in $(seq 1 "$reps"); do
		log "bench round $r/$reps"
		bench_round direct-veth - direct-veth
		bench_round direct-loopback - direct-loopback
		for kind in reality ss; do
			for mode in stock flow fd; do
				bench_round "$kind-$mode" "$kind" "$mode"
			done
		done
		echo "{\"label\":\"round\",\"test\":\"loadavg\",\"values\":{\"round\":$r,\"loadavg\":\"$(cut -d' ' -f1-3 /proc/loadavg)\"}}" >>"$RES"
	done
	log "bench done: $RES"
}

do_batch() {
	local reps=${1:-5}
	RES="$OUT/batch.jsonl"
	: >"$RES"
	BYTES=$((64 << 20))
	setup
	trap 'stop_client; teardown' EXIT
	start_far
	local r b
	for r in $(seq 1 "$reps"); do
		for b in 1 4 16 64; do
			log "batch $b round $r"
			WITH_CTL=1
			start_client flow "$(client_config ss 1500)" -batch "$b"
			c "batch-$b-warmup" tcp-down $T4:19 -bytes $((16 << 20)) >/dev/null
			c "batch-$b" tcp-down $T4:19 -bytes "$BYTES"
			c "batch-$b" tcp-up $T4:10 -bytes "$BYTES"
			c "batch-$b" udp-rr $T4:7 -n 1000 -size 64
			stop_client
			unset WITH_CTL
		done
	done
	log "batch done: $RES"
}

do_profile() {
	local P="$OUT/profiles"
	mkdir -p "$P"
	RES="$OUT/profile.jsonl"
	: >"$RES"
	setup
	trap 'stop_client; teardown' EXIT
	start_far
	WITH_CTL=1
	start_client flow "$(client_config reality 1500)" "${@}"
	c profile-warmup tcp-down $T4:19 -bytes $((16 << 20)) >/dev/null
	inc curl -s -o "$P/cpu.pprof" "http://$CTL/debug/pprof/profile?seconds=20" &
	local cp=$!
	sleep 0.5
	c profile tcp-down $T4:19 -bytes $((512 << 20)) -conns 4 -timeout 60s || true
	c profile tcp-up $T4:10 -bytes $((256 << 20)) -conns 2 -timeout 60s || true
	wait $cp || true
	inc curl -s -o "$P/heap.pprof" "http://$CTL/debug/pprof/heap"
	inc curl -s -o "$P/allocs.pprof" "http://$CTL/debug/pprof/allocs"
	inc curl -s -o "$P/goroutine.txt" "http://$CTL/debug/pprof/goroutine?debug=1"
	stop_client
	unset WITH_CTL
	cd "$BRIDGE"
	go tool pprof -top -nodecount=40 "$BIN/nplab" "$P/cpu.pprof" >"$P/cpu-top.txt" 2>&1 || true
	go tool pprof -top -cum -nodecount=40 "$BIN/nplab" "$P/cpu.pprof" >"$P/cpu-top-cum.txt" 2>&1 || true
	go tool pprof -top -sample_index=inuse_space -nodecount=30 "$BIN/nplab" "$P/heap.pprof" >"$P/heap-inuse-top.txt" 2>&1 || true
	go tool pprof -top -sample_index=alloc_space -nodecount=30 "$BIN/nplab" "$P/allocs.pprof" >"$P/allocs-space-top.txt" 2>&1 || true
	go tool pprof -top -sample_index=alloc_objects -nodecount=30 "$BIN/nplab" "$P/allocs.pprof" >"$P/allocs-objects-top.txt" 2>&1 || true
	cd "$ROOT"
	log "profiles in $P"
}

# soak MINUTES [MODE]: MODE flow (default) or stock; REALITY, 4 workers each pacing ~1 MiB/s with new
# connections and UDP sessions. Every 30 s one sample into soak-samples-<label>.jsonl: the bridge's /sample in
# flow mode, RSS and thread count from /proc for both. CONNIDLE=<s> lowers the core's connIdle.
do_soak() {
	local minutes=${1:-30} mode=${2:-flow}
	local label="$mode${MOBILE:+-mobile}${CONNIDLE:+-idle$CONNIDLE}${BUFSIZE:+-buf$BUFSIZE}${SOAK_TAG:+-$SOAK_TAG}"
	local flags=()
	[ -n "${MOBILE:-}" ] && [ "$mode" = flow ] && flags+=(-profile mobile)
	# BRIDGE_EXTRA: more bridge flags, e.g. "-memlimit 25165824 -gcpercent 100"
	[ "$mode" = flow ] && read -r -a extra <<<"${BRIDGE_EXTRA:-}" && flags+=("${extra[@]}")
	local samples="$OUT/soak-samples-$label.jsonl"
	RES="$OUT/soak-$label.jsonl"
	: >"$RES"
	: >"$samples"
	setup
	trap 'stop_client; teardown' EXIT
	start_far
	[ "$mode" = flow ] && WITH_CTL=1
	start_client "$mode" "$(client_config reality 1500)" "${flags[@]}"
	grep '"ready"' "$OUT/client-$mode.log" | tail -1 | sed "s/^/{\"label\":\"soak-$label\",\"test\":\"cold-start\",\"ready\":/; s/\$/}/" >>"$RES"
	(
		while kill -0 "$CLIENT_PID" 2>/dev/null; do
			local rss thr bs anon file
			rss=$(($(awk '{print $2}' /proc/$CLIENT_PID/statm) * $(getconf PAGESIZE)))
			thr=$(awk '/^Threads:/ {print $2}' /proc/$CLIENT_PID/status)
			# RssAnon (dirty private memory) is the closer analogue of the phys_footprint iOS enforces;
			# RssFile is mostly the binary's clean text pages
			anon=$(awk '/^RssAnon:/ {print $2 * 1024}' /proc/$CLIENT_PID/status)
			file=$(awk '/^RssFile:/ {print $2 * 1024}' /proc/$CLIENT_PID/status)
			bs='null'
			[ "$mode" = flow ] && bs=$(inc curl -s --max-time 5 "http://$CTL/sample" || echo null)
			echo "{\"timeUnixMs\":$(date +%s%3N),\"rssBytes\":$rss,\"rssAnonBytes\":${anon:-0},\"rssFileBytes\":${file:-0},\"threads\":$thr,\"bridge\":$bs}" >>"$samples"
			sleep 30
		done
	) &
	local sampler=$!
	c "soak-$label" mix "$T4" -conns 4 -rate $((1 << 20)) -duration "${minutes}m" -timeout "$((minutes + 5))m" || true
	if [ "$mode" = flow ]; then
		inc curl -s -o "$OUT/soak-$label-heap-loaded.pprof" "http://$CTL/debug/pprof/heap"
		inc curl -s -o "$OUT/soak-$label-goroutine-loaded.txt" "http://$CTL/debug/pprof/goroutine?debug=1"
	fi
	sleep 35 # one more sample after the load stopped
	if [ "$mode" = flow ]; then
		inc curl -s -o "$OUT/soak-$label-heap.pprof" "http://$CTL/debug/pprof/heap"
		inc curl -s -o "$OUT/soak-$label-goroutine.txt" "http://$CTL/debug/pprof/goroutine?debug=1"
	fi
	stop_client
	kill "$sampler" 2>/dev/null || true
	wait "$sampler" 2>/dev/null || true
	unset WITH_CTL
	log "soak done: $samples"
}

# memcmp [REPS]: default vs mobile profile on the same lab, alternating within each round (REALITY, flow).
# Per variant: cold-start memory (ready line), TCP 64 MiB down / up / down with 4 connections, 100 new
# connections, then a burst of BURST (default 200) parallel TCP connections + UDP sessions with RSS peaks.
do_memcmp() {
	local reps=${1:-5} burst=${BURST:-200}
	RES="$OUT/memcmp.jsonl"
	: >"$RES"
	BYTES=$((64 << 20))
	setup
	trap 'stop_client; teardown' EXIT
	start_far
	set_mtu 1500
	local r variant cfg
	for r in $(seq 1 "$reps"); do
		for variant in default mobile; do
			log "memcmp round $r/$reps: $variant"
			WITH_CTL=1
			if [ "$variant" = mobile ]; then
				cfg="$(MOBILE=1 client_config reality 1500)"
				start_client flow "$cfg" -profile mobile
			else
				cfg="$(client_config reality 1500)"
				start_client flow "$cfg"
			fi
			grep '"ready"' "$OUT/client-flow.log" | tail -1 | sed "s/^/{\"label\":\"$variant\",\"test\":\"cold-start\",\"round\":$r,\"ready\":/; s/\$/}/" | tee -a "$RES"
			c "$variant-warmup" tcp-down $T4:19 -bytes $((16 << 20)) >/dev/null
			c "$variant" tcp-down $T4:19 -bytes "$BYTES"
			c "$variant" tcp-up $T4:10 -bytes "$BYTES"
			c "$variant-4c" tcp-down $T4:19 -bytes "$BYTES" -conns 4
			c "$variant" tcp-setup $T4:7 -n 100
			c "$variant-burst$burst" burst "$T4" -conns "$burst" -bytes $((burst * (64 << 10))) -timeout 120s || true
			sleep 2
			inc curl -s "http://$CTL/sample" | sed "s/^/{\"label\":\"$variant\",\"test\":\"after-burst\",\"round\":$r,\"sample\":/; s/\$/}/" >>"$RES"
			stop_client
			unset WITH_CTL
		done
	done
	log "memcmp done: $RES"
}

# diag MODE: kernel-side counters around one download, for finding where a throughput cap comes from.
do_diag() {
	local mode=${1:-flow}
	RES="$OUT/diag.jsonl"
	: >"$RES"
	setup
	trap 'stop_client; teardown' EXIT
	start_far
	[ "$mode" = flow ] && WITH_CTL=1
	start_client "$mode" "$(client_config reality 1500)"
	inc nstat -n >/dev/null
	inc ip -s link show nptun0 >&2
	c "diag-$mode" tcp-down $T4:19 -bytes $((64 << 20)) &
	local cp=$!
	sleep 1
	inc ss -tin dst $T4 >&2
	wait $cp
	inc nstat >&2
	if [ -n "${DIAG_QUICKACK:-}" ]; then
		inc ip route replace default dev nptun0 quickack 1
		log "client namespace: quickack on the tunnel route (kernel ACKs every segment)"
		c "diag-$mode-quickack" tcp-down $T4:19 -bytes $((64 << 20))
		c "diag-$mode-quickack-4c" tcp-down $T4:19 -bytes $((64 << 20)) -conns 4
		inc ip route replace default dev nptun0
	fi
	if [ -n "${DIAG_CC:-}" ]; then
		inc sysctl -qw net.ipv4.tcp_congestion_control="$DIAG_CC"
		inc tc qdisc replace dev nptun0 root pfifo
		log "client namespace: congestion control $DIAG_CC, qdisc pfifo on nptun0"
		c "diag-$mode-$DIAG_CC" tcp-down $T4:19 -bytes $((64 << 20))
		c "diag-$mode-$DIAG_CC" tcp-up $T4:10 -bytes $((64 << 20))
	fi
	inc ip -s link show nptun0 >&2
	stop_client
}

case "${1:-}" in
diag) shift; do_diag "$@" ;;
build) do_build ;;
setup) setup ;;
teardown) teardown ;;
e2e) do_e2e ;;
bench) shift; do_bench "$@" ;;
batch) shift; do_batch "$@" ;;
profile) shift; do_profile "$@" ;;
soak) shift; do_soak "$@" ;;
memcmp) shift; do_memcmp "$@" ;;
*) sed -n '2,20p' "$0"; exit 2 ;;
esac
