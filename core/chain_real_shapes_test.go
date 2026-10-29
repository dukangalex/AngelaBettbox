package main

// Real-shape regression cases for the chain patcher, modelled on
// real-world shapes reported on 2026-10-27: the entry is a
// provider-backed url-test group named 自动选择 in the active profile,
// and the exit is a group from another profile imported with the
// overlay rename prefix. Synthetic shapes only (structure and scale,
// no real subscription data).

import (
	"fmt"
	"strings"
	"testing"
)

func rsExitGroup() ([]map[string]any, []map[string]any) {
	groups := []map[string]any{{
		"name":    "[chain 2] 自动选择",
		"type":    "url-test",
		"proxies": []any{"[chain 2] exit-1", "[chain 2] exit-2"},
		"url":     "http://127.0.0.1:1",
	}}
	proxies := []map[string]any{
		{"name": "[chain 2] exit-1", "type": "http", "server": "127.0.0.1", "port": 1},
		{"name": "[chain 2] exit-2", "type": "http", "server": "127.0.0.1", "port": 1},
	}
	return groups, proxies
}

func rsParams(entry string, groups []map[string]any, proxies []map[string]any) *PatchParams {
	return &PatchParams{ChainPolicy: &PatchChainPolicy{
		Enabled: true, Entry: entry, EntryKind: "group",
		Landing: "[chain 2] 自动选择", LandingKind: "group",
		ExternalProfile: "2", ExternalTarget: "[chain 2] 自动选择",
		ExternalKind: "group", ExternalGroups: groups, ExternalProxies: proxies,
	}}
}

// RS1: Lucas's main shape — provider-backed url-test entry group with a
// filter, manual selector present, external url-test exit group.
func TestChainRealShapeProviderAutoEntryExternalGroupExit(t *testing.T) {
	raw := parsePatchProfile(t, `
proxy-providers:
  sub: {type: inline, payload: [{name: hk-1, type: http, server: 127.0.0.1, port: 1}, {name: hk-2, type: http, server: 127.0.0.1, port: 1}]}
proxy-groups:
  - {name: 自动选择, type: url-test, use: [sub], filter: '^hk', url: 'http://127.0.0.1:1', interval: 300}
  - {name: Main, type: select, proxies: [自动选择, DIRECT]}
rules: ['MATCH,Main']
`)
	groups, proxies := rsExitGroup()
	if _, err := applyPatch(raw, rsParams("自动选择", groups, proxies)); err != nil {
		t.Fatalf("applyPatch: %v", err)
	}
	entry := findGroup(raw.ProxyGroup, "自动选择")
	if entry["empty-fallback"] != "REJECT" {
		t.Fatalf("entry group not hardened: %v", entry["empty-fallback"])
	}
	et, _ := entry["exclude-type"].(string)
	for _, want := range []string{"Direct", "Compatible", "Pass"} {
		if !strings.Contains(et, want) {
			t.Fatalf("entry exclude-type %q missing %s", et, want)
		}
	}
	for _, p := range proxies {
		if p["dialer-proxy"] != "自动选择" {
			t.Fatalf("exit proxy %v dialer-proxy = %v", p["name"], p["dialer-proxy"])
		}
	}
	parseChainConfig(t, raw)
}

// RS2: large inline entry group (120 members) + external single-proxy exit.
func TestChainRealShapeLargeInlineEntryGroup(t *testing.T) {
	var members []string
	var lines []string
	for i := 0; i < 120; i++ {
		name := fmt.Sprintf("node-%03d", i)
		members = append(members, name)
		lines = append(lines, fmt.Sprintf("  - {name: %s, type: http, server: 127.0.0.1, port: 1}", name))
	}
	raw := parsePatchProfile(t, fmt.Sprintf(`
proxies:
%s
proxy-groups:
  - {name: 自动选择, type: url-test, proxies: [%s], url: 'http://127.0.0.1:1', interval: 300}
  - {name: Main, type: select, proxies: [自动选择, DIRECT]}
rules: ['MATCH,Main']
`, strings.Join(lines, "\n"), strings.Join(members, ", ")))
	proxies := []map[string]any{{"name": "[chain 2] exit", "type": "http", "server": "127.0.0.1", "port": 1}}
	params := &PatchParams{ChainPolicy: &PatchChainPolicy{
		Enabled: true, Entry: "自动选择", EntryKind: "group",
		Landing: "[chain 2] exit", LandingKind: "proxy",
		ExternalProfile: "2", ExternalTarget: "[chain 2] exit",
		ExternalKind: "proxy", ExternalProxies: proxies,
	}}
	if _, err := applyPatch(raw, params); err != nil {
		t.Fatalf("applyPatch: %v", err)
	}
	parseChainConfig(t, raw)
}

// RS3 (negative control): entry select group containing DIRECT must fail.
func TestChainRealShapeDirectMemberStillRejected(t *testing.T) {
	raw := parsePatchProfile(t, `
proxies:
  - {name: n1, type: http, server: 127.0.0.1, port: 1}
proxy-groups:
  - {name: 自动选择, type: select, proxies: [n1, DIRECT]}
  - {name: Main, type: select, proxies: [自动选择]}
rules: ['MATCH,Main']
`)
	groups, proxies := rsExitGroup()
	if _, err := applyPatch(raw, rsParams("自动选择", groups, proxies)); err == nil {
		t.Fatal("expected bypass validation error, got nil")
	}
}

// RS4: entry group with include-all-proxies must fail as dynamic.
func TestChainRealShapeIncludeAllStillRejected(t *testing.T) {
	raw := parsePatchProfile(t, `
proxies:
  - {name: n1, type: http, server: 127.0.0.1, port: 1}
proxy-groups:
  - {name: 自动选择, type: url-test, include-all-proxies: true, url: 'http://127.0.0.1:1'}
  - {name: Main, type: select, proxies: [自动选择]}
rules: ['MATCH,Main']
`)
	groups, proxies := rsExitGroup()
	if _, err := applyPatch(raw, rsParams("自动选择", groups, proxies)); err == nil {
		t.Fatal("expected dynamic-include validation error, got nil")
	}
}

// RS5: fallback-type entry group, provider-backed, with exclude-filter.
func TestChainRealShapeFallbackEntryWithExcludeFilter(t *testing.T) {
	raw := parsePatchProfile(t, `
proxy-providers:
  sub: {type: inline, payload: [{name: jp-1, type: http, server: 127.0.0.1, port: 1}]}
proxy-groups:
  - {name: 自动选择, type: fallback, use: [sub], exclude-filter: '^dead', url: 'http://127.0.0.1:1', interval: 300}
  - {name: Main, type: select, proxies: [自动选择, DIRECT]}
rules: ['MATCH,Main']
`)
	groups, proxies := rsExitGroup()
	if _, err := applyPatch(raw, rsParams("自动选择", groups, proxies)); err != nil {
		t.Fatalf("applyPatch: %v", err)
	}
	parseChainConfig(t, raw)
}

// RS6: nested entry — select wrapping a provider url-test child that has
// no exclude-type yet; hardening must reach the child.
func TestChainRealShapeNestedProviderChild(t *testing.T) {
	raw := parsePatchProfile(t, `
proxy-providers:
  sub: {type: inline, payload: [{name: us-1, type: http, server: 127.0.0.1, port: 1}]}
proxy-groups:
  - {name: Inner, type: url-test, use: [sub], url: 'http://127.0.0.1:1', interval: 300}
  - {name: 自动选择, type: select, proxies: [Inner]}
  - {name: Main, type: select, proxies: [自动选择, DIRECT]}
rules: ['MATCH,Main']
`)
	groups, proxies := rsExitGroup()
	if _, err := applyPatch(raw, rsParams("自动选择", groups, proxies)); err != nil {
		t.Fatalf("applyPatch: %v", err)
	}
	if findGroup(raw.ProxyGroup, "Inner")["empty-fallback"] != "REJECT" {
		t.Fatal("nested child group not hardened")
	}
	parseChainConfig(t, raw)
}

// RS7: entry group whose provider expansion is filtered to empty at
// runtime (the dangerous window the reject fallback exists for).
func TestChainRealShapeEmptyMemberGroupWithFilter(t *testing.T) {
	raw := parsePatchProfile(t, `
proxy-providers:
  sub: {type: inline, payload: [{name: hk-1, type: http, server: 127.0.0.1, port: 1}]}
proxy-groups:
  - {name: 自动选择, type: url-test, use: [sub], filter: '^zzz-no-match', url: 'http://127.0.0.1:1'}
  - {name: Main, type: select, proxies: [自动选择, DIRECT]}
rules: ['MATCH,Main']
`)
	groups, proxies := rsExitGroup()
	if _, err := applyPatch(raw, rsParams("自动选择", groups, proxies)); err != nil {
		t.Fatalf("applyPatch: %v", err)
	}
	parseChainConfig(t, raw)
}

// RS8 (negative control): entry group referencing a missing provider.
func TestChainRealShapeMissingProviderStillRejected(t *testing.T) {
	raw := parsePatchProfile(t, `
proxy-groups:
  - {name: 自动选择, type: url-test, use: [ghost], url: 'http://127.0.0.1:1'}
  - {name: Main, type: select, proxies: [自动选择]}
rules: ['MATCH,Main']
`)
	groups, proxies := rsExitGroup()
	if _, err := applyPatch(raw, rsParams("自动选择", groups, proxies)); err == nil {
		t.Fatal("expected unavailable-provider validation error, got nil")
	}
}
