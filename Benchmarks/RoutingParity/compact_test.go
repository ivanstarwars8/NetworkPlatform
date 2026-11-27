package parity

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/xtls/xray-core/common/geodata"
)

// The engine picks its domain matcher by operating system: iOS and Android
// builds use CompactMphDomainMatcherFactory (linear matcher for inline
// rules), everything else MphDomainMatcherFactory
// (common/geodata/domain_matcher.go, newDomainMatcherFactory). TestParity
// runs on Linux and therefore exercises only the second one. This test
// builds every domain list of the corpus with both factories and compares
// their answers for every request domain, so that the Linux result also
// holds for the matcher an Apple build uses.
func TestCompactDomainMatcherAgrees(t *testing.T) {
	path := os.Getenv("PARITY_CORPUS")
	if path == "" {
		path = "testdata/corpus.json"
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var c corpus
	if err := json.Unmarshal(raw, &c); err != nil {
		t.Fatal(err)
	}

	lists, checks, differences := 0, 0, 0
	for _, tb := range c.Tables {
		names := map[string]bool{}
		for _, q := range tb.Requests {
			if q.Domain != nil {
				names[strings.ToLower(*q.Domain)] = true
			}
		}
		for _, r := range tb.Rules {
			if len(r.Domains) == 0 {
				continue
			}
			values := xrayRule(r)["domain"].([]string)
			rules, err := geodata.ParseDomainRules(values, geodata.Domain_Substr)
			if err != nil {
				t.Fatalf("table %s rule %s: %v", tb.Name, r.Tag, err)
			}
			standard, err := (&geodata.MphDomainMatcherFactory{}).BuildMatcher(rules)
			if err != nil {
				t.Fatalf("table %s rule %s: standard matcher: %v", tb.Name, r.Tag, err)
			}
			compact, err := (&geodata.CompactMphDomainMatcherFactory{}).BuildMatcher(rules)
			if err != nil {
				t.Fatalf("table %s rule %s: compact matcher: %v", tb.Name, r.Tag, err)
			}
			lists++
			for name := range names {
				checks++
				if a, b := standard.MatchAny(name), compact.MatchAny(name); a != b {
					differences++
					if differences <= 20 {
						t.Errorf("table %s rule %s domain %q: standard=%v compact=%v (values %v)", tb.Name, r.Tag, name, a, b, values)
					}
				}
			}
		}
	}
	t.Logf("domain lists=%d checks=%d differences=%d", lists, checks, differences)
	if lists == 0 {
		t.Fatal("corpus has no domain rules")
	}
}
