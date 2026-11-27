package engine

import (
	"fmt"
	"io"
	"testing"
	"time"

	apppolicy "github.com/xtls/xray-core/app/policy"
	"github.com/xtls/xray-core/app/proxyman"
)

func TestMobileProfileOptions(t *testing.T) {
	o, err := ParseOptions([]byte(`{"memory":{"profile":"mobile"},"tun":{"mode":"flow"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if o.Memory.LimitBytes != MobileMemoryLimitBytes || o.Memory.GCPercent != MobileGCPercent ||
		o.Tun.OutQueueBytes != MobileOutQueueBytes || o.Tun.MaxFlows != MobileMaxFlows || o.LogQueueSize != MobileLogQueueSize {
		t.Fatalf("mobile defaults not applied: %+v", o)
	}
	// explicit values win over the profile
	o, err = ParseOptions([]byte(`{"memory":{"profile":"mobile","limitBytes":40000000,"gcPercent":80},"logQueueSize":64,"tun":{"mode":"flow","outQueueBytes":1048576,"maxFlows":10}}`))
	if err != nil {
		t.Fatal(err)
	}
	if o.Memory.LimitBytes != 40000000 || o.Memory.GCPercent != 80 || o.Tun.OutQueueBytes != 1<<20 || o.Tun.MaxFlows != 10 || o.LogQueueSize != 64 {
		t.Fatalf("explicit options overridden: %+v", o)
	}
	// no profile: no cap, ordinary defaults
	o, _ = ParseOptions(nil)
	if o.Tun.MaxFlows != 0 || o.Memory.LimitBytes != 0 || o.Memory.GCPercent != 0 {
		t.Fatalf("default options changed: %+v", o)
	}
	for _, bad := range []string{
		`{"memory":{"profile":"tiny"}}`,
		`{"memory":{"profile":"mobile"},"assetDir":"/tmp"}`,
		`{"tun":{"maxFlows":-1}}`,
	} {
		if _, err := ParseOptions([]byte(bad)); CodeOf(err) != CodeInvalidArgument {
			t.Errorf("%s: got %v", bad, err)
		}
	}
}

func TestMobileProfileRefusesGeodata(t *testing.T) {
	mobile := Options{Memory: MemoryOptions{Profile: MemoryProfileMobile}}
	if err := mobile.Normalize(); err != nil {
		t.Fatal(err)
	}
	plain := Options{}
	_ = plain.Normalize()
	for _, c := range []string{
		`{"routing":{"rules":[{"domain":["geosite:category-ads"],"outboundTag":"direct"}]},"outbounds":[{"protocol":"freedom","tag":"direct"}]}`,
		`{"routing":{"rules":[{"ip":["GEOIP:private"],"outboundTag":"direct"}]},"outbounds":[{"protocol":"freedom","tag":"direct"}]}`,
		`{"routing":{"rules":[{"domain":["ext:custom.dat:x"],"outboundTag":"direct"}]},"outbounds":[{"protocol":"freedom","tag":"direct"}]}`,
		`{"dns":{"servers":[{"address":"1.1.1.1","domains":["geosite:google"]}]},"outbounds":[{"protocol":"freedom","tag":"direct"}]}`,
	} {
		if _, err := prepareConfig([]byte(c), &mobile); codeOfPtr(err) != CodeConfigUnsupport {
			t.Errorf("mobile: %s: got %v, want %s", c, err, CodeConfigUnsupport)
		}
		// without the profile the check does not apply (the core reads the file itself, if there is one)
		if _, err := prepareConfig([]byte(c), &plain); codeOfPtr(err) == CodeConfigUnsupport {
			t.Errorf("plain: %s: refused by the profile check", c)
		}
	}
	// explicit lists pass
	ok := `{"routing":{"rules":[{"domain":["domain:example.com","full:a.example"],"ip":["10.0.0.0/8"],"outboundTag":"direct"}]},"outbounds":[{"protocol":"freedom","tag":"direct"}]}`
	if _, err := prepareConfig([]byte(ok), &mobile); err != nil {
		t.Fatalf("explicit rules refused: %v", err)
	}
}

// codeOfPtr is CodeOf for a *Error that may be nil (a nil *Error in an error interface is not nil).
func codeOfPtr(e *Error) Code {
	if e == nil {
		return CodeOK
	}
	return e.Code
}

// TestFlowMaxFlows checks the flow cap end to end: flows over tun.maxFlows are closed without being dispatched,
// counted, and admitted again once earlier flows end.
func TestFlowMaxFlows(t *testing.T) {
	const mtu = 1500
	echo := samePortEcho(t)
	config := mustJSON(t, obj{
		"inbounds": arr{tunInbound(mtu)},
		"outbounds": arr{obj{"tag": "direct", "protocol": "freedom",
			"settings": obj{"redirect": fmt.Sprintf("127.0.0.1:%d", echo)}}},
	})
	e := New()
	mustStart(t, e, config, Options{Tun: TunOptions{Mode: TunFlow, MaxFlows: 2}})
	p := newFlowPeer(t, e, mtu)

	a, b := p.dialTCP("10.9.0.1:7000"), p.dialTCP("10.9.0.1:7001")
	echoTCP(t, a, 4096)
	echoTCP(t, b, 4096)

	// The stack accepts the handshake itself; the third connection is closed when it reaches the bridge.
	c := p.dialTCP("10.9.0.1:7002")
	_ = c.SetDeadline(time.Now().Add(5 * time.Second))
	_, _ = c.Write([]byte("x"))
	var one [1]byte
	if _, err := io.ReadFull(c, one[:]); err == nil {
		t.Fatal("a flow over the cap was served")
	}
	c.Close()
	st, _ := e.Stats()
	if st.Tun.FlowsRejected == 0 || st.Tun.FlowsHighest != 2 {
		t.Fatalf("counters after rejection: %+v", *st.Tun)
	}

	a.Close()
	deadline := time.Now().Add(10 * time.Second)
	for {
		st, _ = e.Stats()
		if st.Tun.FlowsActive <= 1 || time.Now().After(deadline) {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if st.Tun.FlowsActive > 1 {
		t.Fatalf("closed flow not released: %+v", *st.Tun)
	}
	d := p.dialTCP("10.9.0.1:7003")
	echoTCP(t, d, 4096)
	d.Close()
	b.Close()
	t.Logf("tun counters: %+v", *st.Tun)
}

// TestMobileCompilerKeysReachTheCore builds the sections the configuration compiler emits for
// XrayMemoryProfile.mobile (XrayConfigCompiler.mobilePolicy / mobileQUICWindows) and checks that every key
// lands in the core's protobuf: encoding/json ignores unknown keys, so a misspelt key would pass silently.
func TestMobileCompilerKeysReachTheCore(t *testing.T) {
	config := `{"policy":{"levels":{"0":{"connIdle":30,"handshake":10,"uplinkOnly":1,"downlinkOnly":1,"bufferSize":4}}},
	 "outbounds":[{"tag":"hy","protocol":"hysteria","settings":{"version":2,"address":"192.0.2.1","port":443},
	  "streamSettings":{"network":"hysteria","security":"tls","tlsSettings":{"serverName":"hy.test"},
	   "hysteriaSettings":{"version":2,"auth":"a"},
	   "finalmask":{"quicParams":{"initStreamReceiveWindow":524288,"maxStreamReceiveWindow":2097152,
	    "initConnectionReceiveWindow":1048576,"maxConnectionReceiveWindow":4194304}}}}]}`
	opts := Options{Memory: MemoryOptions{Profile: MemoryProfileMobile}, DisableStats: true}
	if err := opts.Normalize(); err != nil {
		t.Fatal(err)
	}
	p, err := prepareConfig([]byte(config), &opts)
	if err != nil {
		t.Fatal(err)
	}
	var level *apppolicy.Policy
	for _, app := range p.config.App {
		if msg, err := app.GetInstance(); err == nil {
			if pc, ok := msg.(*apppolicy.Config); ok {
				level = pc.Level[0]
			}
		}
	}
	if level == nil {
		t.Fatal("no policy level 0 in the built config")
	}
	to := level.Timeout
	if to.ConnectionIdle.GetValue() != 30 || to.Handshake.GetValue() != 10 || to.UplinkOnly.GetValue() != 1 ||
		to.DownlinkOnly.GetValue() != 1 || level.Buffer.GetConnection() != 4<<10 {
		t.Fatalf("policy level 0: %v", level)
	}
	msg, gerr := p.config.Outbound[0].SenderSettings.GetInstance()
	if gerr != nil {
		t.Fatal(gerr)
	}
	q := msg.(*proxyman.SenderConfig).StreamSettings.GetQuicParams()
	if q.GetInitStreamReceiveWindow() != 512<<10 || q.GetMaxStreamReceiveWindow() != 2<<20 ||
		q.GetInitConnReceiveWindow() != 1<<20 || q.GetMaxConnReceiveWindow() != 4<<20 {
		t.Fatalf("quic params: %v", q)
	}
}
