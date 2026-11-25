//go:build linux

package engine

import (
	"bytes"
	"crypto/rand"
	"fmt"
	"net"
	"os"
	"os/exec"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// TestFDModeKernelTun exercises tun.mode "fd" against a real kernel: the Linux TCP/IP stack on one side of a
// tun device, the core's own tun inbound reading the device's file descriptor on the other.
//
// It changes interfaces and routes, so it only runs inside a throw-away network namespace:
// Cores/BuildScripts/bridge-linux-netns-test.sh sets NP_NETNS_TEST=1 there.
func TestFDModeKernelTun(t *testing.T) {
	if os.Getenv("NP_NETNS_TEST") != "1" {
		t.Skip("runs only inside a dedicated network namespace (bridge-linux-netns-test.sh)")
	}
	const name = "nptun0"
	fd, err := unix.Open("/dev/net/tun", unix.O_RDWR|unix.O_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	ifr, err := unix.NewIfreq(name)
	if err != nil {
		t.Fatal(err)
	}
	ifr.SetUint16(unix.IFF_TUN | unix.IFF_NO_PI)
	if err := unix.IoctlIfreq(fd, unix.TUNSETIFF, ifr); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{"link", "set", "lo", "up"},
		{"addr", "add", "10.8.0.1/24", "dev", name},
		{"-6", "addr", "add", "fd00:8::1/64", "dev", name, "nodad"},
		{"link", "set", name, "mtu", "1500", "up"},
		{"route", "add", "10.9.0.0/24", "dev", name},
		{"-6", "route", "add", "fd00:9::/64", "dev", name},
	} {
		if out, err := exec.Command("ip", args...).CombinedOutput(); err != nil {
			t.Fatalf("ip %v: %v: %s", args, err, out)
		}
	}

	echo := samePortEcho(t)
	config := mustJSON(t, obj{
		"inbounds": arr{obj{"tag": "tun-in", "protocol": "tun", "settings": obj{"name": name, "mtu": 1500}}},
		"outbounds": arr{obj{"tag": "direct", "protocol": "freedom",
			"settings": obj{"redirect": fmt.Sprintf("127.0.0.1:%d", echo)}}},
	})
	e := New()
	mustStart(t, e, config, Options{Tun: TunOptions{Mode: TunFD, FD: fd}, LogLevel: getenv("NP_TEST_LOGLEVEL")})

	const tcpBytes = 8 << 20
	var payload int64
	for _, target := range []string{"10.9.0.1:80", "[fd00:9::1]:80"} {
		c, err := net.DialTimeout("tcp", target, 5*time.Second)
		if err != nil {
			t.Fatalf("kernel dial %s through the tun: %v", target, err)
		}
		_ = c.SetDeadline(time.Now().Add(60 * time.Second))
		start := time.Now()
		echoTCP(t, c, tcpBytes)
		t.Logf("%s: %d MiB echoed through the kernel tun in %s", target, tcpBytes>>20, time.Since(start).Round(time.Millisecond))
		c.Close()
		payload += tcpBytes

		u, err := net.Dial("udp", target)
		if err != nil {
			t.Fatal(err)
		}
		for _, size := range []int{1, 1200, 1472 - 20*bytesIf6(target), 4000} {
			msg := make([]byte, size)
			_, _ = rand.Read(msg)
			if _, err := u.Write(msg); err != nil {
				t.Fatalf("udp write %d: %v", size, err)
			}
			got := make([]byte, 65536)
			_ = u.SetReadDeadline(time.Now().Add(5 * time.Second))
			n, err := u.Read(got)
			if err != nil || !bytes.Equal(got[:n], msg) {
				t.Fatalf("udp echo of %d bytes to %s: n=%d err=%v", size, target, n, err)
			}
			payload += int64(size)
		}
		u.Close()
	}

	var in TrafficCounter
	deadline := time.Now().Add(5 * time.Second)
	for {
		st, serr := e.Stats()
		if serr != nil {
			t.Fatal(serr)
		}
		in = counterOf(st.Inbounds, "tun-in")
		if st.Tun != nil {
			t.Fatalf("fd mode must not have a flow device: %+v", st.Tun)
		}
		if (in.Uplink == payload && in.Downlink == payload) || time.Now().After(deadline) {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Logf("payload=%d | inbound tun-in up=%d down=%d", payload, in.Uplink, in.Downlink)
	if in.Uplink != payload || in.Downlink != payload {
		t.Errorf("tun inbound counters up=%d down=%d, kernel transferred %d", in.Uplink, in.Downlink, payload)
	}
	if got := os.Getenv("xray.tun.fd"); got == "" {
		t.Error("xray.tun.fd is not set while running")
	}
	if err := e.Stop(10 * time.Second); err != nil {
		t.Fatal(err)
	}
	if got, ok := os.LookupEnv("xray.tun.fd"); ok {
		t.Errorf("xray.tun.fd=%q survived the stop", got)
	}
}

func bytesIf6(target string) int {
	if target[0] == '[' {
		return 1
	}
	return 0
}
