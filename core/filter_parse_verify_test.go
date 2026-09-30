package main

import (
	"os"
	"testing"

	"github.com/metacubex/mihomo/config"
)

// Verifies that the shape ProfileFilter produces actually loads. The Dart unit
// tests pin the rewrite rules; this pins that mihomo accepts the result, which
// `validateConfig` alone cannot show: UnmarshalRawConfig never resolves a group
// or rule target, so a dangling name passes validation and only fails when the
// tunnel is built.
//
// build/filtered_dump.yaml is written by a temporary Dart test; the case below
// mirrors it inline so this runs without that file.
const filteredDump = `
mixed-port: 7890
proxies:
  - {name: HK-01, type: ss, server: hk1.example.com, port: 443, cipher: aes-128-gcm, password: x}
  - {name: HK-02, type: ss, server: hk2.example.com, port: 443, cipher: aes-128-gcm, password: x}
proxy-groups:
  - name: Proxy
    type: select
    proxies: [HK-01, HK-02]
  - name: All
    type: select
    proxies: [Proxy]
  - name: Fallback
    type: fallback
    proxies: [HK-01]
rules:
  - DOMAIN-SUFFIX,keep.com,HK-01
  - DOMAIN-SUFFIX,gone.com,DIRECT
  - MATCH,DIRECT
`

func TestFilteredConfigParsesWithMihomo(t *testing.T) {
	if _, err := config.Parse([]byte(filteredDump)); err != nil {
		t.Fatalf("mihomo rejected the filtered config: %v", err)
	}
}

// Pins that the verification above is meaningful: a group naming a proxy that
// does not exist, or one with no `use`/`proxies`, is exactly what mihomo
// rejects, and what the filter exists to prevent.
func TestMihomoRejectsTheShapesTheFilterAvoids(t *testing.T) {
	cases := map[string]string{
		"a group naming a removed proxy": `
mixed-port: 7890
proxies:
  - {name: HK-01, type: ss, server: hk1.example.com, port: 443, cipher: aes-128-gcm, password: x}
proxy-groups:
  - name: Proxy
    type: select
    proxies: [HK-01, GONE-99]
rules:
  - MATCH,Proxy
`,
		"a group with neither use nor proxies": `
mixed-port: 7890
proxies:
  - {name: HK-01, type: ss, server: hk1.example.com, port: 443, cipher: aes-128-gcm, password: x}
proxy-groups:
  - name: Proxy
    type: select
    proxies: []
rules:
  - MATCH,Proxy
`,
		"a rule targeting a removed proxy": `
mixed-port: 7890
proxies:
  - {name: HK-01, type: ss, server: hk1.example.com, port: 443, cipher: aes-128-gcm, password: x}
rules:
  - MATCH,GONE-99
`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := config.Parse([]byte(body)); err == nil {
				t.Fatalf("mihomo accepted a config the filter is meant to prevent: %s", name)
			}
		})
	}
}

// Keeps the checked-in dump honest when one is present.
func TestCheckedInFilteredDumpParses(t *testing.T) {
	const path = "../build/filtered_dump.yaml"
	body, err := os.ReadFile(path)
	if err != nil {
		t.Skipf("no dump at %s; the inline case covers the same shape", path)
	}
	if _, err := config.Parse(body); err != nil {
		t.Fatalf("mihomo rejected the dumped filtered config: %v", err)
	}
}