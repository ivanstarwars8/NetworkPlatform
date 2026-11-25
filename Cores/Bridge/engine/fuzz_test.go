package engine

import (
	"context"
	"testing"
	"time"
)

// FuzzPrepareConfig feeds arbitrary bytes to the configuration entry point shared by Validate, Start and
// Reload. The property: it returns a result or a normalised error, never panics out, never hangs.
func FuzzPrepareConfig(f *testing.F) {
	seeds := []string{
		minimalConfig,
		tunConfig(""),
		`{"outbounds":[{"protocol":"vless","settings":{"address":"example.com","port":443,"id":"` + testUUID + `","encryption":"none","flow":"xtls-rprx-vision"},"streamSettings":{"network":"raw","security":"reality","realitySettings":{"serverName":"a.test","fingerprint":"chrome","password":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","shortId":"01"}}}]}`,
		`{"outbounds":[{"protocol":"trojan","settings":{"address":"1.2.3.4","port":443,"password":"p"},"streamSettings":{"security":"tls","tlsSettings":{"serverName":"a.test","alpn":["h2"]}}}]}`,
		`{"outbounds":[{"protocol":"shadowsocks","settings":{"address":"1.2.3.4","port":1,"method":"2022-blake3-aes-128-gcm","password":"AAAAAAAAAAAAAAAAAAAAAA=="}}]}`,
		`{"outbounds":[{"protocol":"vmess","settings":{"address":"1.2.3.4","port":1,"id":"` + testUUID + `"}}],"routing":{"rules":[{"type":"field","port":"53,1000-2000","outboundTag":"x"}]}}`,
		`{"outbounds":[{"protocol":"vless","settings":{"address":"h","port":1,"id":"` + testUUID + `","encryption":"none"},"streamSettings":{"network":"xhttp","xhttpSettings":{"path":"/p","mode":"packet-up"}}}]}`,
		`{"dns":{"servers":["1.1.1.1",{"address":"https://dns.test/dns-query","domains":["domain:a.test"]}],"hosts":{"a.test":"1.2.3.4"}},"policy":{"levels":{"0":{"handshake":4}},"system":{"statsInboundUplink":true}}}`,
		`{"env":{"a":"b"}}`, `{"api":{}}`, `{"inbounds":[{"protocol":"tun"},{"protocol":"tun"}]}`,
		`{"log":{"loglevel":"debug","access":"/x","maskAddress":"quarter"}}`,
		`[]`, `null`, `{"inbounds":{}}`, `{"outbounds":[null]}`, `{"outbounds":[{"protocol":"freedom","settings":null,"streamSettings":{"sockopt":{"mark":1,"interface":"en0"}}}]}`,
	}
	for _, s := range seeds {
		for _, mode := range []byte{0, 1, 2} {
			f.Add([]byte(s), mode)
		}
	}
	f.Fuzz(func(t *testing.T, data []byte, mode byte) {
		opts := Options{}
		switch mode % 3 {
		case 1:
			opts.Tun.Mode = TunFlow
		case 2:
			opts.Tun.Mode, opts.Tun.FD = TunFD, 1000
		}
		if err := opts.Normalize(); err != nil {
			t.Fatal(err)
		}
		p, err := prepareConfig(data, &opts)
		if (p == nil) == (err == nil) {
			t.Fatalf("prepareConfig returned p=%v err=%v", p != nil, err)
		}
		if err != nil {
			switch err.Code {
			case CodeInvalidArgument, CodeConfigParse, CodeConfigBuild, CodeConfigUnsupport:
			default:
				t.Fatalf("unexpected code %s: %s", err.Code, err.Message)
			}
			return
		}
		if opts.Tun.Mode == TunFlow && p.tun == nil {
			t.Fatal("flow mode accepted a config without a tun spec")
		}
		for _, in := range p.config.Inbound {
			if opts.Tun.Mode == TunFlow && in.GetProxySettings().GetType() == tunConfigType {
				t.Fatal("flow mode left a tun inbound for the core")
			}
		}
	})
}

// FuzzParseOptions: arbitrary option documents are accepted or rejected with invalid_argument.
func FuzzParseOptions(f *testing.F) {
	for _, s := range []string{``, `{}`, `{"tun":{"mode":"flow","mtu":1400}}`, `{"memory":{"limitBytes":1,"gcPercent":-1}}`,
		`{"startTimeoutMs":1e99}`, `{"tun":{"mode":"fd","fd":3}}`, `{"logLevel":"debug","accessLog":true,"logQueueSize":1}`, `nul`} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		o, err := ParseOptions(data)
		if err != nil {
			if err.Code != CodeInvalidArgument {
				t.Fatalf("unexpected code %s", err.Code)
			}
			return
		}
		if o.StartTimeoutMs <= 0 || o.StopTimeoutMs <= 0 || o.LogQueueSize < 1 || o.Tun.OutQueueBytes < 128<<10 {
			t.Fatalf("accepted options are not normalised: %+v", o)
		}
		if o.Tun.Mode == TunFD && o.Tun.FD < 3 {
			t.Fatalf("fd mode with fd %d", o.Tun.FD)
		}
	})
}

// fuzzEngine is one running engine shared by all FuzzTunWrite inputs of a worker process.
var fuzzEngine *Engine

// FuzzTunWrite throws arbitrary batches at the packet entry point of a running engine: the frame parser and
// behind it the core's IP/TCP/UDP/ICMP parsing. The outbound is a blackhole, nothing leaves the process.
func FuzzTunWrite(f *testing.F) {
	ip4 := []byte{0x45, 0, 0, 28, 0, 1, 0, 0, 64, 17, 0, 0, 10, 8, 0, 2, 10, 9, 0, 1, 0x30, 0x39, 0, 53, 0, 8, 0, 0}
	syn := []byte{0x45, 0, 0, 40, 0, 1, 0, 0, 64, 6, 0, 0, 10, 8, 0, 2, 10, 9, 0, 1, 0x30, 0x39, 0, 80, 0, 0, 0, 1, 0, 0, 0, 0, 0x50, 0x02, 0xff, 0xff, 0, 0, 0, 0}
	ip6 := append([]byte{0x60, 0, 0, 0, 0, 8, 17, 64}, make([]byte, 40)...)
	f.Add(frame(ip4))
	f.Add(frame(syn))
	f.Add(frame(ip6))
	f.Add(append(frame(ip4), frame(syn)...))
	f.Add([]byte{0xff, 0xff, 0x45})
	f.Add([]byte{0, 0})
	f.Add([]byte{1})
	f.Fuzz(func(t *testing.T, batch []byte) {
		if fuzzEngine == nil {
			e := New()
			cfg := `{"log":{"loglevel":"none"},"inbounds":[{"tag":"tun-in","protocol":"tun"}],"outbounds":[{"protocol":"blackhole"}]}`
			if err := e.Start(context.Background(), []byte(cfg), Options{Tun: TunOptions{Mode: TunFlow, OutQueueBytes: 128 << 10}}); err != nil {
				t.Fatal(err)
			}
			fuzzEngine = e
		}
		n, err := fuzzEngine.TunWrite(append([]byte(nil), batch...))
		if err != nil && err.Code != CodeInvalidArgument {
			t.Fatalf("unexpected code %s", err.Code)
		}
		if n < 0 || n > len(batch)/3+1 {
			t.Fatalf("consumed %d packets from %d bytes", n, len(batch))
		}
		// keep the bounded queue from saturating so that replies keep being generated
		var sink [64 << 10]byte
		for {
			if k, _ := fuzzEngine.TunRead(sink[:], 0); k == 0 {
				break
			}
		}
		_ = time.Now
	})
}
