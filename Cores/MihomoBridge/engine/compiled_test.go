package engine

import (
	"net/netip"
	"os"
	"path/filepath"
	"testing"
)

// TestCompiledFixturesNeedNoOverride: every configuration the Swift compiler (ConfigurationEngine
// MihomoConfigCompiler) wrote into the fixture corpus is accepted by the bridge in flow mode and the bridge
// changes nothing in it (Documentation/Architecture/mihomo-config.md §2: anything the bridge rewrites the
// compiler should not have written). The tun section must give the bridge's stack the addresses of
// DomainModels.TunnelAddressing.standard and hijack port 53 of any address.
func TestCompiledFixturesNeedNoOverride(t *testing.T) {
	files, err := filepath.Glob(filepath.Join("..", "..", "..", "Tests", "Fixtures", "*", "*.mihomo.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if len(files) < 50 {
		t.Fatalf("expected the compiled corpus (at least 50 *.mihomo.yaml), found %d", len(files))
	}
	for _, file := range files {
		data, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		p, perr := prep(t, string(data), Options{Tun: TunOptions{Mode: TunFlow}})
		if perr != nil {
			t.Errorf("%s: %v", file, perr)
			continue
		}
		if len(p.summary.Overridden) != 0 {
			t.Errorf("%s: bridge overrode %v", file, p.summary.Overridden)
		}
		if p.tun == nil {
			t.Errorf("%s: no tun section", file)
			continue
		}
		if p.tun.mtu != 1500 {
			t.Errorf("%s: mtu %d", file, p.tun.mtu)
		}
		want := map[string]bool{"198.18.0.2": false, "fd66:6e70::2": false}
		for _, ip := range p.tun.dnsServerIPs {
			if _, ok := want[ip]; ok {
				want[ip] = true
			}
		}
		for ip, seen := range want {
			if !seen {
				t.Errorf("%s: resolver %s is not a tun DNS address (%v)", file, ip, p.tun.dnsServerIPs)
			}
		}
		if len(p.tun.inet4) != 1 || p.tun.inet4[0] != netip.MustParsePrefix("198.18.0.1/30") {
			t.Errorf("%s: inet4 %v", file, p.tun.inet4)
		}
		anyHijack := false
		for _, ap := range p.tun.dnsHijack {
			if ap.Addr().IsUnspecified() && ap.Port() == 53 {
				anyHijack = true
			}
		}
		if !anyHijack {
			t.Errorf("%s: no hijack of port 53 on any address: %v", file, p.tun.dnsHijack)
		}
	}
}
