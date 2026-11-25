#!/usr/bin/env python3
"""Mutation check for the Xray compiler's refusal rules.

Takes accepted fixture configurations, breaks one thing the compiler refuses to emit
(or normalises), and asks the real binary. Every mutation except the controls must be
REJECTED: that shows `xray run -test` is a real check and that the compiler's
`.error` rules mirror the engine instead of being invented.

Usage: python3 Tests/Fixtures/negative-mutations.py /path/to/xray
Exit code 1 when an expectation does not hold.
"""
import json, subprocess, sys, tempfile, os
X = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("XRAY_BIN", "xray")
F = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ShareLinks", "")
EXPECT_ACCEPTED = ("accepted by design", "control:")
bad = 0
def run(name, base, mutate):
    c=json.load(open(F+base+".xray.json")); mutate(c["outbounds"][0])
    global bad
    fd,p=tempfile.mkstemp(suffix=".json"); os.write(fd,json.dumps(c).encode()); os.close(fd)
    r=subprocess.run([X,"run","-test","-c",p],capture_output=True,text=True); os.unlink(p)
    last=[l for l in (r.stdout+r.stderr).strip().splitlines() if l.strip()][-1][-170:]
    verdict = "REJECTED" if r.returncode else "ACCEPTED"
    expected = "ACCEPTED" if any(m in name for m in EXPECT_ACCEPTED) else "REJECTED"
    if verdict != expected:
        bad += 1
    print(verdict, "" if verdict == expected else "(UNEXPECTED)", name, "|", last)
def s(o,k,v): o["streamSettings"][k]=v
run("allowInsecure=true","vless-ws-tls",lambda o:o["streamSettings"]["tlsSettings"].__setitem__("allowInsecure",True))
run("unknown fingerprint","vless-ws-tls",lambda o:o["streamSettings"]["tlsSettings"].__setitem__("fingerprint","netscape"))
run("vless plaintext public","vless-ws-tls",lambda o:(s(o,"security","none"),o["streamSettings"].pop("tlsSettings")))
run("trojan plaintext public","trojan-tcp-tls",lambda o:(s(o,"security","none"),o["streamSettings"].pop("tlsSettings")))
run("network h2","vless-ws-tls",lambda o:s(o,"network","h2"))
run("network quic","vless-ws-tls",lambda o:s(o,"network","quic"))
run("reality over ws","vless-reality-vision-tcp",lambda o:s(o,"network","ws"))
run("reality bad key","vless-reality-vision-tcp",lambda o:o["streamSettings"]["realitySettings"].__setitem__("password","AAAA"))
run("reality std-base64 key (padded)","vless-reality-vision-tcp",lambda o:o["streamSettings"]["realitySettings"].__setitem__("password",o["streamSettings"]["realitySettings"]["password"].replace("-","+").replace("_","/")+"="))
run("reality odd shortId","vless-reality-vision-tcp",lambda o:o["streamSettings"]["realitySettings"].__setitem__("shortId","abc"))
run("reality spiderX no slash","vless-reality-vision-tcp",lambda o:o["streamSettings"]["realitySettings"].__setitem__("spiderX","x"))
run("vless flow direct","vless-reality-vision-tcp",lambda o:o["settings"].__setitem__("flow","xtls-rprx-direct"))
run("ss method none","ss-sip002-aes256gcm",lambda o:o["settings"].__setitem__("method","none"))
run("ss method aes-192-gcm","ss-sip002-aes256gcm",lambda o:o["settings"].__setitem__("method","aes-192-gcm"))
run("ss2022 short key","ss-2022-aes256-ipsk",lambda o:o["settings"].__setitem__("password","CyPSbbFD0c3iKaL9MAqCQw=="))
run("ss2022 chacha with ipsk","ss-2022-chacha20",lambda o:o["settings"].__setitem__("password",o["settings"]["password"]+":"+o["settings"]["password"]))
run("xhttp bad mode","vless-xhttp-tls",lambda o:o["streamSettings"]["xhttpSettings"].__setitem__("mode","bogus"))
run("xhttp stream-one + downloadSettings","vless-xhttp-reality-download",lambda o:o["streamSettings"]["xhttpSettings"].__setitem__("mode","stream-one"))
run("kcp tti 5","vless-kcp-seed",lambda o:o["streamSettings"]["kcpSettings"].__setitem__("tti",5))
run("wireguard bad key","wireguard-basic",lambda o:o["settings"].__setitem__("secretKey","not-a-key!"))
run("wireguard reserved 2 bytes","wireguard-reserved-psk",lambda o:o["settings"].__setitem__("reserved",[1,2]))
run("hysteria brutalUp bare 50","hysteria2-bandwidth",lambda o:o["streamSettings"]["finalmask"]["quicParams"].__setitem__("brutalUp","50"))
run("hysteria hop interval 2","hysteria2-salamander-hop",lambda o:o["streamSettings"]["finalmask"]["udp"][1]["settings"].__setitem__("interval",2))
run("hysteria reality","hysteria2-basic",lambda o:s(o,"security","reality"))
run("protocol tuic","trojan-tcp-tls",lambda o:o.__setitem__("protocol","tuic"))
run("pin not hex","trojan-grpc-pinned",lambda o:o["streamSettings"]["tlsSettings"].__setitem__("pinnedPeerCertSha256","zz"))
run("vless id 40 chars","vless-ws-tls",lambda o:o["settings"].__setitem__("id","x"*40))
run("vless id short text (accepted by design)","vless-ws-tls",lambda o:o["settings"].__setitem__("id","hello"))
run("socks unknown field is ignored silently, hence SOCKS4 is blocked in the compiler (accepted by design)","socks5-noauth",lambda o:o["settings"].__setitem__("version","4"))
run("control: unmodified","vless-ws-tls",lambda o:None)
sys.exit(1 if bad else 0)
