package engine

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"testing"
	"time"
)

const testUUID = "5783a3e7-e373-51cd-8642-c83782b807c5"

// proxyCase is one protocol pairing: a stock Xray server inbound and the matching Mihomo proxy entry.
type proxyCase struct {
	name  string
	build func(t testing.TB, port int) (xrayInbound obj, mihomoProxy string)
}

func proxyCases() []proxyCase {
	return []proxyCase{
		// support-x25519mlkem768 is required: the core strips the X25519MLKEM768 key share by default, and the
		// REALITY server of Xray 26.11.9 (xtls/reality 4bb46b2afd8b, tls.go) rejects a Client Hello without it
		// ("authentication failed or validation criteria not met"; seen on the first run of this test).
		{"VLESS+REALITY+Vision", func(t testing.TB, port int) (obj, string) {
			private, public := newX25519(t)
			target := startTLSTarget(t, "reality.test")
			in := obj{"protocol": "vless",
				"settings": obj{"clients": arr{obj{"id": testUUID, "flow": "xtls-rprx-vision"}}, "decryption": "none"},
				"streamSettings": obj{"network": "raw", "security": "reality", "realitySettings": obj{
					"target": fmt.Sprintf("127.0.0.1:%d", target), "serverNames": arr{"reality.test"},
					"privateKey": private, "shortIds": arr{"0123abcd"},
				}}}
			proxy := fmt.Sprintf(`  - name: p
    type: vless
    server: 127.0.0.1
    port: %d
    uuid: %s
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: reality.test
    client-fingerprint: chrome
    reality-opts:
      public-key: %s
      short-id: 0123abcd
      support-x25519mlkem768: true
`, port, testUUID, public)
			return in, proxy
		}},
		{"Shadowsocks-2022", func(t testing.TB, port int) (obj, string) {
			key := make([]byte, 16)
			_, _ = rand.Read(key)
			psk := base64.StdEncoding.EncodeToString(key)
			in := obj{"protocol": "shadowsocks", "settings": obj{
				"method": "2022-blake3-aes-128-gcm", "password": psk, "network": "tcp,udp"}}
			proxy := fmt.Sprintf(`  - name: p
    type: ss
    server: 127.0.0.1
    port: %d
    cipher: 2022-blake3-aes-128-gcm
    password: %q
    udp: true
`, port, psk)
			return in, proxy
		}},
	}
}

// startProxyServer runs a stock Xray server for c whose freedom outbound sends everything to echo.
func startProxyServer(t testing.TB, c proxyCase, echo int) (mihomoProxy string) {
	t.Helper()
	port := freePort(t)
	in, proxy := c.build(t, port)
	in["listen"], in["port"], in["tag"] = "127.0.0.1", port, "in"
	server := mustJSON(t, obj{
		"log":      obj{"loglevel": "debug"}, // printed only when the test fails
		"inbounds": arr{in},
		// finalRules: the server's freedom refuses private and loopback targets by default.
		"outbounds": arr{obj{"protocol": "freedom",
			"settings": obj{"redirect": fmt.Sprintf("127.0.0.1:%d", echo), "finalRules": arr{obj{"action": "allow"}}}}},
	})
	startXray(t, server, port)
	return proxy
}

func clientYAML(socksPort int, proxy string, tun bool) string {
	s := fmt.Sprintf("mode: rule\nlog-level: info\nallow-lan: false\nsocks-port: %d\nproxies:\n%srules:\n  - MATCH,p\n", socksPort, proxy)
	if tun {
		s += "tun:\n  enable: true\n  stack: mips\n  mtu: 1500\n"
	}
	return s
}

// TestProtocolsOverLoopback: Mihomo client against a stock Xray server, once through the SOCKS inbound and
// once through the batched packet interface (TCP 1 MiB echo plus UDP datagrams, the larger ones fragmented
// on the packet side).
func TestProtocolsOverLoopback(t *testing.T) {
	if stockXray == "" {
		t.Skip("NP_STOCK_XRAY not set")
	}
	for _, c := range proxyCases() {
		t.Run(c.name, func(t *testing.T) {
			echo := echoServer(t, "127.0.0.1")
			proxy := startProxyServer(t, c, echo)
			socks := freePort(t)
			e := New()
			mustStart(t, e, clientYAML(socks, proxy, true), Options{Tun: TunOptions{Mode: TunFlow}})
			waitTCP(t, socks)

			began := time.Now()
			sc := socksConnect(t, socks, "10.9.0.1", 7000)
			echoTCP(t, sc, 1<<20)
			sc.Close()
			t.Logf("SOCKS TCP 1 MiB echo: %v", time.Since(began))

			p := newOSPeer(t, e, 1500)
			began = time.Now()
			pc := p.dialTCP("10.9.0.1:7000")
			echoTCP(t, pc, 1<<20)
			pc.Close()
			t.Logf("packet path TCP 1 MiB echo: %v", time.Since(began))

			u := p.dialUDP("10.9.0.1:7000")
			echoUDP(t, u, 1, 512, 1400, 3000)
			u.Close()

			st, err := e.Stats()
			if err != nil {
				t.Fatal(err)
			}
			t.Logf("stats: total up=%d down=%d connections=%d tun=%+v", st.Total.Uplink, st.Total.Downlink, st.Connections, *st.Tun)
			if st.Total.Uplink < 2<<20 || st.Total.Downlink < 2<<20 {
				t.Errorf("traffic totals below the 2 MiB echoed each way: %+v", st.Total)
			}
			if st.Tun.RxPackets == 0 || st.Tun.TxPackets == 0 || st.Tun.RxMalformed != 0 {
				t.Errorf("tun counters %+v", *st.Tun)
			}
		})
	}
}
