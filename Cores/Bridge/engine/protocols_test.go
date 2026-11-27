package engine

import (
	"bytes"
	"crypto/rand"
	"io"
	"os"
	"testing"
	"time"
)

const testUUID = "5783a3e7-e373-51cd-8642-c83782b807c5"

// protoCase builds the two halves of one protocol pairing: the server's inbound and the client's outbound.
type protoCase struct {
	name string
	// exactOutbound: the outbound counters are expected to equal the bytes on the wire. True only where the
	// transport adds nothing under the proxy protocol and the core counts every write (see CORE DEVIATION).
	exactOutbound bool
	build         func(t testing.TB, port int) (serverInbound, clientOutbound obj)
}

func protoCases() []protoCase {
	return []protoCase{
		{"VLESS+TCP", false, func(t testing.TB, port int) (obj, obj) {
			in := obj{"protocol": "vless", "settings": obj{"clients": arr{obj{"id": testUUID}}, "decryption": "none"}}
			out := obj{"protocol": "vless", "settings": obj{"address": "127.0.0.1", "port": port, "id": testUUID, "encryption": "none"}}
			return in, out
		}},
		{"VLESS+REALITY+Vision", false, func(t testing.TB, port int) (obj, obj) {
			private, public := newX25519(t)
			target := startTLSTarget(t, "reality.test")
			in := obj{"protocol": "vless",
				"settings": obj{"clients": arr{obj{"id": testUUID, "flow": "xtls-rprx-vision"}}, "decryption": "none"},
				"streamSettings": obj{"network": "raw", "security": "reality", "realitySettings": obj{
					"target": "127.0.0.1:" + itoa(target), "serverNames": arr{"reality.test"},
					"privateKey": private, "shortIds": arr{"0123abcd"},
				}}}
			out := obj{"protocol": "vless",
				"settings": obj{"address": "127.0.0.1", "port": port, "id": testUUID, "encryption": "none", "flow": "xtls-rprx-vision"},
				"streamSettings": obj{"network": "raw", "security": "reality", "realitySettings": obj{
					"serverName": "reality.test", "fingerprint": "chrome", "password": public, "shortId": "0123abcd",
				}}}
			return in, out
		}},
		{"VLESS+XHTTP", false, func(t testing.TB, port int) (obj, obj) {
			stream := obj{"network": "xhttp", "xhttpSettings": obj{"path": "/np-test", "mode": "auto"}}
			in := obj{"protocol": "vless", "settings": obj{"clients": arr{obj{"id": testUUID}}, "decryption": "none"}, "streamSettings": stream}
			out := obj{"protocol": "vless", "settings": obj{"address": "127.0.0.1", "port": port, "id": testUUID, "encryption": "none"}, "streamSettings": stream}
			return in, out
		}},
		{"Trojan+TLS", false, func(t testing.TB, port int) (obj, obj) {
			cert := newTestCert(t, "trojan.test")
			in := obj{"protocol": "trojan", "settings": obj{"clients": arr{obj{"password": "np-test-password"}}},
				"streamSettings": obj{"network": "raw", "security": "tls", "tlsSettings": obj{
					"certificates": arr{obj{"certificate": cert.certPEM, "key": cert.keyPEM}},
				}}}
			out := obj{"protocol": "trojan", "settings": obj{"address": "127.0.0.1", "port": port, "password": "np-test-password"},
				"streamSettings": obj{"network": "raw", "security": "tls", "tlsSettings": obj{
					"serverName": "trojan.test", "pinnedPeerCertSha256": cert.sha256Hex,
				}}}
			return in, out
		}},
		{"Shadowsocks-2022", true, func(t testing.TB, port int) (obj, obj) {
			key := randomBase64(t, 16)
			in := obj{"protocol": "shadowsocks", "settings": obj{"method": "2022-blake3-aes-128-gcm", "password": key, "network": "tcp,udp"}}
			out := obj{"protocol": "shadowsocks", "settings": obj{"address": "127.0.0.1", "port": port, "method": "2022-blake3-aes-128-gcm", "password": key}}
			return in, out
		}},
		{"VMess", false, func(t testing.TB, port int) (obj, obj) {
			in := obj{"protocol": "vmess", "settings": obj{"clients": arr{obj{"id": testUUID}}}}
			out := obj{"protocol": "vmess", "settings": obj{"address": "127.0.0.1", "port": port, "id": testUUID, "security": "auto"}}
			return in, out
		}},
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [12]byte
	i := len(b)
	for ; n > 0; n /= 10 {
		i--
		b[i] = byte('0' + n%10)
	}
	return string(b[i:])
}

// serverConfig wraps an inbound into a server that forwards to wherever the client asked (freedom), or, with
// redirect set, to that fixed address.
func serverConfig(t testing.TB, inbound obj, port int, redirect string) string {
	inbound["listen"], inbound["port"], inbound["tag"] = "127.0.0.1", port, "in"
	// The server's freedom blocks private and loopback targets for proxied clients by default; these tests
	// have nothing but loopback to talk to.
	settings := obj{"finalRules": arr{obj{"action": "allow"}}}
	if redirect != "" {
		settings["redirect"] = redirect
	}
	freedom := obj{"protocol": "freedom", "tag": "direct", "settings": settings}
	return mustJSON(t, obj{
		"log":       obj{"loglevel": "warning"},
		"inbounds":  arr{inbound},
		"outbounds": arr{freedom},
	})
}

// socksClientConfig is a client with a local SOCKS inbound whose traffic all goes through outbound.
func socksClientConfig(t testing.TB, socksPort int, outbound obj) string {
	outbound["tag"] = "proxy"
	return mustJSON(t, obj{
		"log": obj{"loglevel": "warning"},
		"inbounds": arr{obj{"tag": "socks", "listen": "127.0.0.1", "port": socksPort, "protocol": "socks",
			"settings": obj{"udp": true}}},
		"outbounds": arr{outbound, obj{"protocol": "freedom", "tag": "direct"}},
	})
}

func counterOf(list []TrafficCounter, tag string) TrafficCounter {
	for _, c := range list {
		if c.Tag == tag {
			return c
		}
	}
	return TrafficCounter{Tag: tag, Uplink: -1, Downlink: -1}
}

// echoTCP sends size random bytes through c in chunks while reading them back, and verifies the echo.
func echoTCP(t testing.TB, c io.ReadWriter, size int) {
	t.Helper()
	sent := make([]byte, size)
	_, _ = rand.Read(sent)
	errc := make(chan error, 1)
	go func() {
		_, err := c.Write(sent)
		errc <- err
	}()
	got := make([]byte, size)
	if _, err := io.ReadFull(c, got); err != nil {
		t.Fatalf("tcp echo read: %v", err)
	}
	if err := <-errc; err != nil {
		t.Fatalf("tcp echo write: %v", err)
	}
	if !bytes.Equal(sent, got) {
		t.Fatal("tcp echo: data differs")
	}
}

// TestProtocolsOverLoopback runs a real client<->server pair for every protocol: the client is the bridge
// engine with a SOCKS inbound, the server is stock xray (NP_STOCK_XRAY) or an in-process core instance.
func TestProtocolsOverLoopback(t *testing.T) {
	const tcpBytes = 512 << 10
	const udpPackets, udpSize = 8, 1200
	tcpEcho := startTCPEcho(t, "tcp", "127.0.0.1:0")
	udpEcho := startUDPEcho(t)

	for _, pc := range protoCases() {
		t.Run(pc.name, func(t *testing.T) {
			serverPort, socksPort := freePort(t), freePort(t)
			relay := startWireRelay(t, serverPort)
			in, out := pc.build(t, relay.port)
			startServer(t, serverConfig(t, in, serverPort, ""), serverPort)

			e := New()
			mustStart(t, e, socksClientConfig(t, socksPort, out), Options{LogLevel: os.Getenv("NP_TEST_LOGLEVEL")})

			// What the application puts on / takes from the SOCKS sockets, framing included (RFC 1928):
			// greeting 3 + request 10 up, method 2 + reply 10 down, per TCP connection; 10 per UDP datagram.
			var appUp, appDown int64

			// TCP
			c := socksConnect(t, socksPort, "127.0.0.1", tcpEcho)
			echoTCP(t, c, tcpBytes)
			c.Close()
			appUp += 13 + tcpBytes
			appDown += 12 + tcpBytes

			// UDP
			u := socksAssociate(t, socksPort)
			appUp, appDown = appUp+13, appDown+12
			for i := 0; i < udpPackets; i++ {
				payload := make([]byte, udpSize)
				_, _ = rand.Read(payload)
				if err := u.send("127.0.0.1", udpEcho, payload); err != nil {
					t.Fatal(err)
				}
				got, err := u.recv(5 * time.Second)
				if err != nil {
					t.Fatalf("udp echo %d: %v", i, err)
				}
				if !bytes.Equal(got, payload) {
					t.Fatalf("udp echo %d: data differs", i)
				}
				appUp, appDown = appUp+udpSize+10, appDown+udpSize+10
			}
			u.close()

			// Counters settle when the copy loops of the closed connections return.
			payload := int64(tcpBytes + udpPackets*udpSize)
			var st Stats
			var proxy, socks TrafficCounter
			deadline := time.Now().Add(5 * time.Second)
			for {
				var err *Error
				if st, err = e.Stats(); err != nil {
					t.Fatal(err)
				}
				proxy, socks = counterOf(st.Outbounds, "proxy"), counterOf(st.Inbounds, "socks")
				settled := socks.Uplink == appUp && socks.Downlink == appDown &&
					proxy.Uplink == relay.up.Load() && proxy.Downlink == relay.down.Load()
				if settled || time.Now().After(deadline) {
					break
				}
				time.Sleep(50 * time.Millisecond)
			}
			direct := counterOf(st.Outbounds, "direct")
			wireUp, wireDown := relay.up.Load(), relay.down.Load()
			t.Logf("payload=%d app(up=%d down=%d) | inbound socks up=%d down=%d | outbound proxy up=%d down=%d | wire up=%d down=%d",
				payload, appUp, appDown, socks.Uplink, socks.Downlink, proxy.Uplink, proxy.Downlink, wireUp, wireDown)

			// Inbound counters: exactly the bytes exchanged with the application.
			if socks.Uplink != appUp || socks.Downlink != appDown {
				t.Errorf("inbound counters up=%d down=%d, application transferred up=%d down=%d", socks.Uplink, socks.Downlink, appUp, appDown)
			}
			if direct.Uplink > 0 || direct.Downlink > 0 {
				t.Errorf("traffic leaked to the direct outbound: %+v", direct)
			}
			// Outbound counters are the core's: they sit on the transport connection of the outbound, under the
			// proxy protocol and above TLS/REALITY. They can never exceed what the wire carried and never be
			// less than the TCP payload.
			if proxy.Uplink > wireUp || proxy.Downlink > wireDown {
				t.Errorf("outbound counters up=%d down=%d exceed the wire up=%d down=%d", proxy.Uplink, proxy.Downlink, wireUp, wireDown)
			}
			if proxy.Uplink < tcpBytes || proxy.Downlink < payload {
				t.Errorf("outbound counters up=%d down=%d are below the payload (tcp %d, total %d)", proxy.Uplink, proxy.Downlink, tcpBytes, payload)
			}
			if proxy.Uplink > payload+payload/20+8192 || proxy.Downlink > payload+payload/20+8192 {
				t.Errorf("outbound counters up=%d down=%d are far above the payload %d", proxy.Uplink, proxy.Downlink, payload)
			}
			if pc.exactOutbound && (proxy.Uplink != wireUp || proxy.Downlink != wireDown) {
				t.Errorf("outbound counters up=%d down=%d, wire carried up=%d down=%d", proxy.Uplink, proxy.Downlink, wireUp, wireDown)
			}
			if proxy.Uplink < payload {
				// Observed with the pinned core for VLESS over raw TCP and for VMess: the UDP payload sent
				// through the outbound is missing from its uplink counter (the core writes it past the
				// counting connection). Reported, not hidden: the inbound counters above are exact.
				t.Logf("CORE DEVIATION: outbound uplink counter %d misses %d bytes of the %d payload bytes", proxy.Uplink, payload-proxy.Uplink, payload)
			}
		})
	}
}
