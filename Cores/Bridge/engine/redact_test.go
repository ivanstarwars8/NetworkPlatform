package engine

import (
	"bytes"
	"context"
	"strings"
	"testing"

	xlog "github.com/xtls/xray-core/common/log"
	confserial "github.com/xtls/xray-core/infra/conf/serial"
)

const (
	redactUUID   = "1cc9207f-5dda-4274-bb0d-9d105c95c6e8"
	redactServer = "203.0.113.97"
)

// secretCases are configs the pinned core rejects with a message that quotes the offending value.
var secretCases = []struct {
	name, secret, config string
}{
	{"vless id", "secret-not-a-uuid-but-much-longer-than-thirty-bytes",
		`{"outbounds":[{"protocol":"vless","settings":{"address":"` + redactServer + `","port":443,"id":"secret-not-a-uuid-but-much-longer-than-thirty-bytes","encryption":"none"},"streamSettings":{"security":"tls"}}]}`},
	{"reality password", "SecretKeyNotBase64!!",
		`{"outbounds":[{"protocol":"vless","settings":{"address":"` + redactServer + `","port":443,"id":"` + redactUUID + `","encryption":"none"},"streamSettings":{"security":"reality","realitySettings":{"serverName":"np.test","password":"SecretKeyNotBase64!!","shortId":"0a1b"}}}]}`},
	{"reality shortId", "zzsecretzz",
		`{"outbounds":[{"protocol":"vless","settings":{"address":"` + redactServer + `","port":443,"id":"` + redactUUID + `","encryption":"none"},"streamSettings":{"security":"reality","realitySettings":{"serverName":"np.test","password":"VZhM7y7_-UFCl2zNHcAGmpbH_cJyhFV3yXneqhjbwC4","shortId":"zzsecretzz"}}}]}`},
	{"vless encryption", "mlkem768x25519plus.secretjunkvalue",
		`{"outbounds":[{"protocol":"vless","settings":{"address":"` + redactServer + `","port":443,"id":"` + redactUUID + `","encryption":"mlkem768x25519plus.secretjunkvalue"},"streamSettings":{"security":"tls"}}]}`},
}

// rawBuildError is the core's own message, before the bridge redacts it.
func rawBuildError(t *testing.T, config string) string {
	t.Helper()
	jc, err := confserial.DecodeJSONConfigStrict(bytes.NewReader([]byte(config)))
	if err != nil {
		return err.Error()
	}
	_, err = jc.Build()
	if err == nil {
		t.Fatalf("the core accepted the config")
	}
	return err.Error()
}

func TestConfigErrorsAreRedacted(t *testing.T) {
	for _, c := range secretCases {
		t.Run(c.name, func(t *testing.T) {
			// The case is meaningful only if the core really quotes the value.
			if raw := rawBuildError(t, c.config); !strings.Contains(raw, c.secret) {
				t.Fatalf("the core no longer quotes the value; pick another case: %s", raw)
			}
			opts := Options{}
			_ = opts.Normalize()
			_, err := prepareConfig([]byte(c.config), &opts)
			if err == nil || err.Code != CodeConfigBuild {
				t.Fatalf("prepareConfig: %v", err)
			}
			for _, s := range []string{c.secret, redactUUID, redactServer} {
				if strings.Contains(err.Message, s) {
					t.Fatalf("message quotes %q: %s", s, err.Message)
				}
			}
			if !strings.Contains(err.Message, redactedPlaceholder) {
				t.Fatalf("nothing redacted: %s", err.Message)
			}

			// The same through the engine: Validate, Start and the health's last error.
			e := New()
			if _, verr := e.Validate([]byte(c.config), Options{}); verr == nil || strings.Contains(verr.Message, c.secret) {
				t.Fatalf("Validate: %v", verr)
			}
			serr := e.Start(context.Background(), []byte(c.config), Options{})
			if serr == nil || strings.Contains(serr.Message, c.secret) {
				t.Fatalf("Start: %v", serr)
			}
			if h := e.Health(); strings.Contains(h.LastError, c.secret) || h.LastError == "" {
				t.Fatalf("health: %q", h.LastError)
			}
		})
	}
}

func TestParseErrorOfBrokenJSONIsRedacted(t *testing.T) {
	config := `{"outbounds":[{"protocol":"vless","settings":{"id":"` + redactUUID + `" "address":"secret.example.net"}}]}`
	opts := Options{}
	_ = opts.Normalize()
	_, err := prepareConfig([]byte(config), &opts)
	if err == nil || err.Code != CodeConfigParse {
		t.Fatalf("prepareConfig: %v", err)
	}
	if strings.Contains(err.Message, redactUUID) || strings.Contains(err.Message, "secret.example.net") {
		t.Fatalf("message quotes a value: %s", err.Message)
	}
}

func TestRedactorRules(t *testing.T) {
	config := `{"log":{"loglevel":"warning"},
	 "outbounds":[{"tag":"proxy-0000","protocol":"vless",
	   "settings":{"address":"vpn.secret-host.example","port":443,"id":"` + redactUUID + `","flow":"xtls-rprx-vision","encryption":"none"},
	   "streamSettings":{"network":"xhttp","security":"reality","realitySettings":{"serverName":"cdn.front.example","fingerprint":"chrome","password":"VZhM7y7_-UFCl2zNHcAGmpbH_cJyhFV3yXneqhjbwC4","shortId":"0a1b"},
	     "xhttpSettings":{"path":"/hidden-path","mode":"stream-one"}}},
	  {"tag":"ss","protocol":"shadowsocks","settings":{"address":"2001:db8::5","port":8388,"method":"2022-blake3-aes-128-gcm","password":"c2VjcmV0c2VjcmV0c2VjcmV0"}}]}`
	r := newRedactor([]byte(config))
	in := "dial vpn.secret-host.example (VPN.SECRET-HOST.EXAMPLE) id " + redactUUID + " sni cdn.front.example key " +
		"VZhM7y7_-UFCl2zNHcAGmpbH_cJyhFV3yXneqhjbwC4 sid 0a1b path /hidden-path pw c2VjcmV0c2VjcmV0c2VjcmV0 " +
		"v6 2001:db8::5 other 198.51.100.7 and 2001:0db8:0:0:0:0:0:5 uuid 7d7ea5d0-9ec2-432e-82e7-141bada6fc01 " +
		"| kept: proxy-0000 vless xhttp reality xtls-rprx-vision chrome stream-one 2022-blake3-aes-128-gcm at 12:34:56 port 443"
	out := r.redact(in)
	for _, s := range []string{"secret-host", "SECRET-HOST", redactUUID, "cdn.front.example", "VZhM7y7_", " 0a1b ", "hidden-path",
		"c2VjcmV0", "2001:db8::5", "198.51.100.7", "2001:0db8:0:0:0:0:0:5", "7d7ea5d0-"} {
		if strings.Contains(out, s) {
			t.Errorf("%q survived: %s", s, out)
		}
	}
	for _, s := range []string{"proxy-0000", "vless", "xhttp", "reality", "xtls-rprx-vision", "chrome", "stream-one",
		"2022-blake3-aes-128-gcm", "12:34:56", "port 443"} {
		if !strings.Contains(out, s) {
			t.Errorf("structural %q was removed: %s", s, out)
		}
	}

	// Log lines: configuration values and UUIDs go, destinations of the user's traffic stay (logged privately).
	logLine := r.redactLog("tunneling to tcp:198.51.100.7:443 via vpn.secret-host.example id " + redactUUID)
	if strings.Contains(logLine, "secret-host") || strings.Contains(logLine, redactUUID) || !strings.Contains(logLine, "198.51.100.7") {
		t.Errorf("log line: %s", logLine)
	}
}

func TestCoreLogRecordsAreRedacted(t *testing.T) {
	config := `{"outbounds":[{"protocol":"vless","settings":{"address":"` + redactServer + `","port":443,"id":"` + redactUUID + `","encryption":"none"}}]}`
	q := newLogQueue(8)
	prevQueue, prevRedactor := activeLogQueue.Load(), activeRedactor.Load()
	activeLogQueue.Store(q)
	activeRedactor.Store(newRedactor([]byte(config)))
	defer func() {
		activeLogQueue.Store(prevQueue)
		activeRedactor.Store(prevRedactor)
	}()
	coreLogHandler{}.Handle(&xlog.GeneralMessage{Severity: xlog.Severity_Warning,
		Content: "failed to dial " + redactServer + ":443 for user " + redactUUID})
	recs, _ := q.pop(nil, 8, 0)
	if len(recs) != 1 {
		t.Fatalf("records: %v", recs)
	}
	if strings.Contains(recs[0].Message, redactServer) || strings.Contains(recs[0].Message, redactUUID) {
		t.Fatalf("log record quotes a value: %s", recs[0].Message)
	}
}
