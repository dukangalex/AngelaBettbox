package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"go4.org/netipx"
)

func parsePatchProfile(t *testing.T, content string) *config.RawConfig {
	t.Helper()
	rawCfg, err := config.UnmarshalRawConfig([]byte(content))
	if err != nil {
		t.Fatal(err)
	}
	return rawCfg
}

func patchParams(t *testing.T, content string) *PatchParams {
	t.Helper()
	params := &PatchParams{HealthCheckTimeout: defaultHealthCheckTimeout}
	if err := UnmarshalJson([]byte(content), params); err != nil {
		t.Fatal(err)
	}
	return params
}

func TestParseRule(t *testing.T) {
	cases := []struct {
		rule   string
		target string
		pass   string
	}{
		{"DOMAIN-SUFFIX,netflix.com,Streaming", "Streaming", "DOMAIN-SUFFIX,netflix.com,PASS"},
		{" IP-CIDR, 10.0.0.0/8 , Streaming ,no-resolve", "Streaming", "IP-CIDR,10.0.0.0/8,PASS,no-resolve"},
		{"RULE-SET,inline,Streaming,src,no-resolve", "Streaming", "RULE-SET,inline,PASS,src,no-resolve"},
		{"DOMAIN,a.com,Streaming,no-resolve", "Streaming", "DOMAIN,a.com,PASS"},
		{"AND,((NETWORK,UDP),(DST-PORT,443)),Streaming", "Streaming", "AND,((NETWORK,UDP),(DST-PORT,443)),PASS"},
		{"MATCH,Streaming", "Streaming", "MATCH,PASS"},
		{"DOMAIN-WILDCARD,*.a.com,Streaming", "Streaming", "DOMAIN-WILDCARD,*.a.com,PASS"},
		{"SUB-RULE,(NETWORK,tcp),sub1", "", ""},
		{"MATCH", "", ""},
	}
	for _, item := range cases {
		parsed := parseRule(item.rule)
		if parsed.target != item.target {
			t.Errorf("parseRule(%q).target = %q, want %q", item.rule, parsed.target, item.target)
		}
		if item.pass == "" {
			if parsed.hasTarget {
				t.Errorf("parseRule(%q) should not have a target", item.rule)
			}
			continue
		}
		parsed.target = "PASS"
		if got := parsed.String(); got != item.pass {
			t.Errorf("parseRule(%q) with PASS = %q, want %q", item.rule, got, item.pass)
		}
	}
}

func TestApplyPatchGeneral(t *testing.T) {
	rawCfg := parsePatchProfile(t, "mode: direct\nglobal-ua: profile-ua\nsecret: keep\ntun:\n  device: utun9\n  mtu: 1400\n")
	params := patchParams(t, `{"general":{"mode":"global","log-level":"debug","find-process-mode":"always","mixed-port":7891,"authentication":[],"skip-auth-prefixes":null,"global-ua":null,"tun":{"enable":true,"stack":"system","dns-hijack":["any:53"],"route-address":["0.0.0.0/1"]}}}`)
	if _, err := applyPatch(rawCfg, params); err != nil {
		t.Fatal(err)
	}
	defaults := config.DefaultRawConfig()
	if rawCfg.Mode != tunnel.Global || rawCfg.LogLevel != log.DEBUG || rawCfg.MixedPort != 7891 {
		t.Errorf("general values were not applied: %v %v %d", rawCfg.Mode, rawCfg.LogLevel, rawCfg.MixedPort)
	}
	if rawCfg.GlobalUA != defaults.GlobalUA {
		t.Errorf("null global-ua should fall back to the default, got %q", rawCfg.GlobalUA)
	}
	if rawCfg.Secret != "keep" {
		t.Errorf("secret should be kept, got %q", rawCfg.Secret)
	}
	if !rawCfg.Tun.Enable || rawCfg.Tun.Device != "utun9" || rawCfg.Tun.MTU != 1400 || len(rawCfg.Tun.RouteAddress) != 1 {
		t.Errorf("tun should be merged: %+v", rawCfg.Tun)
	}
}

func TestApplyPatchProvidersAndGroups(t *testing.T) {
	rawCfg := parsePatchProfile(t, `
proxy-providers:
  remote: {type: http, url: "https://example.com/sub", path: ./a.yaml}
  local: {type: file, path: ./b.yaml}
proxies:
  - {name: A, type: trojan, server: a.example.com, port: 443, password: p}
  - {name: B, type: vless, server: b.example.com, port: 443, uuid: u, tls: true, reality-opts: {public-key: k, short-id: 123}}
proxy-groups:
  - {name: GLOBAL, type: select, proxies: [Main]}
  - {name: Main, type: select, proxies: [A, B, DIRECT], tolerance: 50.0}
  - {name: Off, type: select, proxies: [A]}
rules:
  - DOMAIN,a.com,Off
  - MATCH,Main
`)
	base := filepath.Join("data", "providers", "p1")
	params := patchParams(t, `{"node-exclude-filter":"^A$","disabled-groups":["Off"],"select-global":true,"prepend-rules":["DOMAIN,q.com,REJECT"]}`)
	params.ProvidersPath = base
	global, err := applyPatch(rawCfg, params)
	if err != nil {
		t.Fatal(err)
	}
	if global != "Main" {
		t.Errorf("global = %q, want Main", global)
	}
	wantPath := filepath.Join(base, "proxies", "3dd403f32a12bab6123243ae838133fb")
	if got := rawCfg.ProxyProvider["remote"]["path"]; got != wantPath {
		t.Errorf("remote path = %v, want %s", got, wantPath)
	}
	if rawCfg.ProxyProvider["local"]["path"] != "./b.yaml" {
		t.Errorf("file provider path should be kept")
	}
	if got := rawCfg.ProxyProvider["remote"]["exclude-filter"]; got != "^A$" {
		t.Errorf("provider exclude-filter = %v", got)
	}
	if len(rawCfg.ProxyGroup) != 1 || rawCfg.ProxyGroup[0]["name"] != "Main" {
		t.Fatalf("groups = %v", rawCfg.ProxyGroup)
	}
	if got := rawCfg.ProxyGroup[0]["proxies"]; !reflect.DeepEqual(got, []any{"B", "DIRECT"}) {
		t.Errorf("filtered proxies = %v", got)
	}
	if got := rawCfg.ProxyGroup[0]["tolerance"]; got != 50 {
		t.Errorf("tolerance = %v (%T)", got, got)
	}
	wantRules := []string{"DOMAIN,q.com,REJECT", "DOMAIN,a.com,PASS", "MATCH,Main"}
	if !reflect.DeepEqual(rawCfg.Rule, wantRules) {
		t.Errorf("rules = %v", rawCfg.Rule)
	}
	if got := rawCfg.Proxy[1]["reality-opts"].(map[string]any)["short-id"]; got != "123" {
		t.Errorf("short-id = %v (%T)", got, got)
	}
	if _, exist := rawCfg.Proxy[0]["client-fingerprint"]; !exist {
		t.Errorf("client-fingerprint should be filled for trojan")
	}
}

func TestApplyPatchAndroidDns(t *testing.T) {
	previous := patchForAndroid
	patchForAndroid = true
	defer func() { patchForAndroid = previous }()

	cases := []struct {
		dns    string
		listen string
	}{
		{"dns: {enable: true, listen: '0.0.0.0:53'}", "0.0.0.0:10053"},
		{"dns: {enable: true, listen: '0.0.0.0:1053'}", "0.0.0.0:1053"},
		{"dns: {enable: true, listen: '0.0.0.0:53', proxy-server-nameserver: ['127.0.0.1:5353']}", "127.0.0.1:53"},
		{"dns: {enable: true, listen: '0.0.0.0:1053', proxy-server-nameserver: ['127.0.0.1:5353']}\nrule-providers: {}", "0.0.0.0:1053"},
	}
	for _, item := range cases {
		rawCfg := parsePatchProfile(t, item.dns+"\nntp: {enable: true, write-to-system: true}\n")
		if _, err := applyPatch(rawCfg, patchParams(t, `{}`)); err != nil {
			t.Fatal(err)
		}
		if rawCfg.DNS.Listen != item.listen {
			t.Errorf("%s: listen = %q, want %q", item.dns, rawCfg.DNS.Listen, item.listen)
		}
		if rawCfg.NTP.WriteToSystem {
			t.Errorf("write-to-system should be disabled on Android")
		}
	}
}

func TestApplyPatchLinuxRouteExclude(t *testing.T) {
	previous := patchForLinux
	defer func() { patchForLinux = previous }()

	general := `{"general":{"tun":{"enable":true,"auto-route":true,"auto-redirect":true,"route-exclude-address":["192.168.0.0/16","fd00::/8"]}}}`
	cases := []struct {
		linux   bool
		profile string
		general string
		useSet  bool
	}{
		{true, "mode: rule\n", general, true},
		{false, "mode: rule\n", general, false},
		{true, "routing-mark: 6666\n", general, false},
		{true, "mode: rule\n", `{"general":{"tun":{"enable":true,"auto-redirect":true,"route-exclude-address":[]}}}`, false},
		{true, "mode: rule\n", `{"general":{"tun":{"enable":true,"auto-redirect":false,"route-exclude-address":["192.168.0.0/16"]}}}`, false},
	}
	for index, item := range cases {
		patchForLinux = item.linux
		rawCfg := parsePatchProfile(t, item.profile)
		if _, err := applyPatch(rawCfg, patchParams(t, item.general)); err != nil {
			t.Fatal(err)
		}
		_, hasProvider := rawCfg.RuleProvider[tunRouteExcludeSet]
		hasSet := len(rawCfg.Tun.RouteExcludeAddressSet) == 1 && rawCfg.Tun.RouteExcludeAddressSet[0] == tunRouteExcludeSet
		if hasProvider != item.useSet || hasSet != item.useSet {
			t.Errorf("case %d: provider = %v, set = %v, want %v", index, hasProvider, hasSet, item.useSet)
		}
		if item.useSet && len(rawCfg.Tun.RouteExcludeAddress) != 0 {
			t.Errorf("case %d: route-exclude-address should move into the rule set", index)
		}
	}

	patchForLinux = true
	rawCfg := parsePatchProfile(t, "mode: rule\n")
	if _, err := applyPatch(rawCfg, patchParams(t, general)); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.ParseRawConfig(rawCfg)
	if err != nil {
		t.Fatal(err)
	}
	provider, exist := cfg.RuleProviders[tunRouteExcludeSet]
	if !exist {
		t.Fatal("route exclude rule set should be parsed")
	}
	strategy, ok := provider.Strategy().(interface{ ToIpCidr() *netipx.IPSet })
	if !ok || strategy.ToIpCidr() == nil {
		t.Fatal("route exclude rule set should expose ip cidr")
	}
	if !strategy.ToIpCidr().Contains(netip.MustParseAddr("192.168.1.1")) {
		t.Errorf("route exclude rule set should contain the private range")
	}
}

func TestApplyPatchDnsInjection(t *testing.T) {
	rawCfg := parsePatchProfile(t, "dns: {enable: false, nameserver: ['10.0.0.1']}\n")
	dns, _ := json.Marshal(map[string]any{
		"enable":            true,
		"nameserver":        []string{"1.1.1.1"},
		"nameserver-policy": map[string]any{"+.a.com": []string{"8.8.8.8", "8.8.4.4"}},
	})
	params := patchParams(t, `{}`)
	params.Dns = dns
	params.DnsNodeOverride = true
	if _, err := applyPatch(rawCfg, params); err != nil {
		t.Fatal(err)
	}
	if !rawCfg.DNS.Enable || !reflect.DeepEqual(rawCfg.DNS.NameServer, []string{"1.1.1.1", "system://"}) {
		t.Errorf("dns = %+v", rawCfg.DNS.NameServer)
	}
	if !reflect.DeepEqual(rawCfg.DNS.ProxyServerNameserver, []string{"10.0.0.1"}) {
		t.Errorf("private dns should become proxy-server-nameserver: %v", rawCfg.DNS.ProxyServerNameserver)
	}

	enabled := parsePatchProfile(t, "dns: {enable: true, nameserver: ['10.0.0.1']}\n")
	if _, err := applyPatch(enabled, params); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(enabled.DNS.NameServer, []string{"10.0.0.1"}) {
		t.Errorf("enabled dns without override should be kept: %v", enabled.DNS.NameServer)
	}
}

func TestPrepareSetupReuse(t *testing.T) {
	dir := t.TempDir()
	profile := filepath.Join(dir, "profile.yaml")
	content := "proxies:\n  - {name: A, type: ss, server: a.example.com, port: 1, cipher: aes-128-gcm, password: p}\nproxy-groups:\n  - {name: Main, type: select, proxies: [A]}\nrules:\n  - MATCH,Main\n"
	if err := os.WriteFile(profile, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	params := func(patch string) *SetupParams {
		setup := defaultSetupParams()
		setup.ProfilePath = profile
		setup.Patch = patchParams(t, patch)
		return setup
	}

	validated, err := prepareSetup(params(`{"select-global":true}`))
	if err != nil {
		t.Fatal(err)
	}
	if validated.reused || validated.global != "Main" {
		t.Fatalf("first prepare: reused=%t global=%q", validated.reused, validated.global)
	}
	storePreparedSetup(validated)

	applied, err := prepareSetup(params(`{"select-global":true}`))
	if err != nil {
		t.Fatal(err)
	}
	if applied != validated || !applied.reused {
		t.Errorf("identical params should reuse the validated config")
	}

	storePreparedSetup(validated)
	changed, err := prepareSetup(params(`{"select-global":false}`))
	if err != nil {
		t.Fatal(err)
	}
	if changed == validated || changed.reused {
		t.Errorf("different params must not reuse the validated config")
	}
	if again, _ := prepareSetup(params(`{"select-global":true}`)); again == validated {
		t.Errorf("a missed lookup should clear the cached config")
	}

	storePreparedSetup(validated)
	if err := os.WriteFile(profile, []byte(content+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if edited, _ := prepareSetup(params(`{"select-global":true}`)); edited == validated {
		t.Errorf("a changed profile must not reuse the validated config")
	}
}

func TestMarshalProxies(t *testing.T) {
	previousHome := constant.Path.HomeDir()
	constant.SetHomeDir(t.TempDir())
	defer constant.SetHomeDir(previousHome)
	rawCfg := parsePatchProfile(t, `
proxies:
  - {name: A, type: ss, server: a.example.com, port: 1, cipher: aes-128-gcm, password: p}
  - {name: B, type: ss, server: b.example.com, port: 1, cipher: aes-128-gcm, password: p}
proxy-groups:
  - {name: Main, type: select, proxies: [Auto, Balance, A, DIRECT], icon: main.png}
  - {name: Auto, type: url-test, proxies: [A, B], url: "https://example.com/204", interval: 300, lazy: true, hidden: true}
  - {name: Balance, type: load-balance, proxies: [A, B], url: "https://example.com/204", interval: 300, lazy: true}
rules:
  - MATCH,Main
`)
	cfg, err := config.ParseRawConfig(rawCfg)
	if err != nil {
		t.Fatal(err)
	}
	compact, err := marshalProxies(cfg.Proxies)
	if err != nil {
		t.Fatal(err)
	}
	payload := struct {
		Names  []string                  `json:"names"`
		Types  []string                  `json:"types"`
		Groups map[string]map[string]any `json:"groups"`
	}{}
	if err := json.Unmarshal(compact, &payload); err != nil {
		t.Fatal(err)
	}
	full, _ := json.Marshal(cfg.Proxies)
	expected := map[string]map[string]any{}
	_ = json.Unmarshal(full, &expected)
	if len(payload.Names) != len(expected) || len(payload.Names) != len(payload.Types) {
		t.Fatalf("names %d, types %d, expected %d", len(payload.Names), len(payload.Types), len(expected))
	}
	for i, name := range payload.Names {
		if expected[name]["type"] != payload.Types[i] {
			t.Errorf("%s type = %s, want %v", name, payload.Types[i], expected[name]["type"])
		}
	}
	groups := 0
	for name, item := range expected {
		if _, isGroup := item["all"]; !isGroup {
			continue
		}
		groups++
		group := payload.Groups[name]
		if group == nil {
			t.Fatalf("group %s is missing", name)
		}
		var members []any
		for _, member := range group["all"].([]any) {
			members = append(members, payload.Names[int(member.(float64))])
		}
		if !reflect.DeepEqual(members, item["all"]) {
			t.Errorf("%s members = %v, want %v", name, members, item["all"])
		}
		for _, key := range []string{"name", "type", "now", "testUrl", "hidden", "icon"} {
			if !reflect.DeepEqual(group[key], item[key]) {
				t.Errorf("%s.%s = %v, want %v", name, key, group[key], item[key])
			}
		}
	}
	if groups != len(payload.Groups) || groups < 4 {
		t.Errorf("groups = %d, payload groups = %d", groups, len(payload.Groups))
	}
}

func TestDecodeScriptedConfig(t *testing.T) {
	rawCfg, err := decodeScriptedConfig([]byte(`{"mixed-port":7891,"mode":"global","rules":["MATCH,Main"],"proxies":[{"name":"A","type":"ss","port":443,"ratio":1.5,"opts":{"mtu":1400,"ids":[1,2]}}],"proxy-groups":[{"name":"Main","type":"select","proxies":["A"],"tolerance":50}],"proxy-providers":{},"dns":{"enable":true,"nameserver-policy":{"+.b.com":"1.1.1.1","+.a.com":["8.8.8.8"]}}}`))
	if err != nil {
		t.Fatal(err)
	}
	if rawCfg.MixedPort != 7891 || rawCfg.Mode != tunnel.Global || !reflect.DeepEqual(rawCfg.Rule, []string{"MATCH,Main"}) {
		t.Errorf("typed fields: %d %v %v", rawCfg.MixedPort, rawCfg.Mode, rawCfg.Rule)
	}
	proxy := rawCfg.Proxy[0]
	if proxy["port"] != 443 || proxy["ratio"] != 1.5 {
		t.Errorf("numbers: port %v (%T), ratio %v (%T)", proxy["port"], proxy["port"], proxy["ratio"], proxy["ratio"])
	}
	opts := proxy["opts"].(map[string]any)
	if opts["mtu"] != 1400 || !reflect.DeepEqual(opts["ids"], []any{1, 2}) {
		t.Errorf("nested numbers: %v", opts)
	}
	if rawCfg.ProxyGroup[0]["tolerance"] != 50 {
		t.Errorf("group number: %v", rawCfg.ProxyGroup[0]["tolerance"])
	}
	if rawCfg.ProxyProvider == nil {
		t.Errorf("an empty proxy-providers object should stay non-nil")
	}
	policy := rawCfg.DNS.NameServerPolicy
	if policy == nil || policy.Oldest().Key != "+.b.com" {
		t.Errorf("nameserver-policy order should be kept")
	}
	if !rawCfg.DNS.UseHosts {
		t.Errorf("defaults should apply to keys the script left out")
	}
}

func TestDisabledGroupsCascade(t *testing.T) {
	rawCfg, err := config.UnmarshalRawConfig([]byte(`proxies:
  - {name: A, type: ss, server: a.com, port: 1, cipher: aes-128-gcm, password: x}
proxy-providers:
  p1: {type: http, url: "https://example.com/p1", path: ./p1.yaml}
proxy-groups:
  - {name: Main, type: select, proxies: [HK, Media, A, DIRECT]}
  - {name: Media, type: select, proxies: [HK]}
  - {name: Stream, type: select, proxies: [Media], use: [p1]}
  - {name: Auto, type: url-test, proxies: [HK], include-all: true}
  - {name: HK, type: select, proxies: [A]}
rules:
  - DOMAIN,hk.com,HK
  - DOMAIN,media.com,Media
  - DOMAIN,stream.com,Stream
  - MATCH,Main
`))
	if err != nil {
		t.Fatal(err)
	}
	params := patchParams(t, `{"disabled-groups":["HK"]}`)
	if _, err := applyPatch(rawCfg, params); err != nil {
		t.Fatal(err)
	}
	groups := map[string][]any{}
	for _, group := range rawCfg.ProxyGroup {
		name, _ := groupName(group)
		proxies, _ := group["proxies"].([]any)
		groups[name] = proxies
	}
	if _, ok := groups["HK"]; ok {
		t.Fatal("HK should be removed")
	}
	if _, ok := groups["Media"]; ok {
		t.Fatal("Media should cascade off")
	}
	if !reflect.DeepEqual(groups["Main"], []any{"A", "DIRECT"}) {
		t.Fatalf("Main proxies: %v", groups["Main"])
	}
	if _, ok := groups["Stream"]; !ok || len(groups["Auto"]) != 0 {
		t.Fatalf("source groups should stay: %v", groups)
	}
	want := []string{"DOMAIN,hk.com,PASS", "DOMAIN,media.com,PASS", "DOMAIN,stream.com,Stream", "MATCH,Main"}
	if !reflect.DeepEqual(rawCfg.Rule, want) {
		t.Fatalf("rules: %v", rawCfg.Rule)
	}
	if _, err := config.ParseRawConfig(rawCfg); err != nil {
		t.Fatal(err)
	}
}

func TestGetConfigDisabledGroups(t *testing.T) {
	path := filepath.Join(t.TempDir(), "p.yaml")
	if err := os.WriteFile(path, []byte(`proxies:
  - {name: A, type: ss, server: a.com, port: 1, cipher: aes-128-gcm, password: x}
proxy-groups:
  - {name: Main, type: select, proxies: [Media, A]}
  - {name: Media, type: select, proxies: [HK]}
  - {name: HK, type: select, proxies: [A]}
rules:
  - MATCH,Main
`), 0o644); err != nil {
		t.Fatal(err)
	}
	rawCfg, err := handleGetConfig(&GetConfigParams{Path: path, DisabledGroups: []string{"HK"}})
	if err != nil {
		t.Fatal(err)
	}
	if len(rawCfg.ProxyGroup) != 1 || !reflect.DeepEqual(rawCfg.ProxyGroup[0]["proxies"], []any{"A"}) {
		t.Fatalf("groups: %v", rawCfg.ProxyGroup)
	}
	if !reflect.DeepEqual(rawCfg.Rule, []string{"MATCH,Main"}) {
		t.Fatalf("rules: %v", rawCfg.Rule)
	}
}

func chainTestProfile() string {
	return `
proxies:
  - {name: Entry, type: ss, server: e.example.com, port: 8388, cipher: aes-128-gcm, password: p}
  - {name: Landing, type: ss, server: l.example.com, port: 8388, cipher: aes-128-gcm, password: p}
proxy-groups:
  - {name: Auto, type: url-test, proxies: [Entry, Landing, DIRECT], url: "https://example.com", interval: 300}
  - {name: OnlyDirect, type: fallback, proxies: [DIRECT]}
  - {name: Manual, type: select, proxies: [Auto, DIRECT]}
rules:
  - MATCH,Manual
`
}

func findGroup(groups []map[string]any, name string) map[string]any {
	for _, group := range groups {
		if group == nil {
			continue
		}
		if groupName, _ := group["name"].(string); groupName == name {
			return group
		}
	}
	return nil
}

func findProxy(t *testing.T, proxies []map[string]any, name string) map[string]any {
	t.Helper()
	for _, proxy := range proxies {
		if proxy == nil {
			continue
		}
		if proxyName, _ := proxy["name"].(string); proxyName == name {
			return proxy
		}
	}
	t.Fatalf("proxy %q not found", name)
	return nil
}

func TestApplyPatchDropAutomaticDirect(t *testing.T) {
	rawCfg := parsePatchProfile(t, chainTestProfile())
	params := patchParams(t, `{"drop-automatic-direct": true}`)
	if _, err := applyPatch(rawCfg, params); err != nil {
		t.Fatal(err)
	}
	if got := findGroup(rawCfg.ProxyGroup, "Auto")["proxies"]; !reflect.DeepEqual(got, []any{"Entry", "Landing"}) {
		t.Errorf("Auto proxies = %v, want [Entry Landing]", got)
	}
	// A group left with nothing must keep DIRECT (same as the Dart original).
	if got := findGroup(rawCfg.ProxyGroup, "OnlyDirect")["proxies"]; !reflect.DeepEqual(got, []any{"DIRECT"}) {
		t.Errorf("OnlyDirect proxies = %v, want [DIRECT]", got)
	}
	// Manual select groups are not automatic groups: untouched.
	if got := findGroup(rawCfg.ProxyGroup, "Manual")["proxies"]; !reflect.DeepEqual(got, []any{"Auto", "DIRECT"}) {
		t.Errorf("Manual proxies = %v, want [Auto DIRECT]", got)
	}
}

func TestApplyPatchChainInline(t *testing.T) {
	rawCfg := parsePatchProfile(t, chainTestProfile())
	params := patchParams(t, `{"chain-policy": {"enabled": true, "entry": "Entry", "landing": "Landing"}}`)
	if _, err := applyPatch(rawCfg, params); err != nil {
		t.Fatal(err)
	}
	if got := findProxy(t, rawCfg.Proxy, "Landing")["dialer-proxy"]; got != "Entry" {
		t.Errorf("Landing dialer-proxy = %v, want Entry", got)
	}
	if findGroup(rawCfg.ProxyGroup, "链式落地") != nil {
		t.Errorf("relay group should not be created when both nodes are inline")
	}
}

// Use the actual bundled Mihomo parser, not just the patched YAML structure.
// The previous relay implementation passed map assertions but could not start.
func parseChainConfig(t *testing.T, raw *config.RawConfig) *config.Config {
	t.Helper()
	parsed, err := config.ParseRawConfig(raw)
	if err != nil {
		t.Fatalf("patched chain is not a valid Mihomo config: %v", err)
	}
	t.Cleanup(func() {
		for _, pd := range parsed.Providers {
			if closer, ok := pd.(interface{ Close() error }); ok {
				_ = closer.Close()
			}
		}
	})
	return parsed
}

func TestApplyPatchChainProviderNodes(t *testing.T) {
	for _, entryInline := range []bool{false, true} {
		for _, landingInline := range []bool{false, true} {
			t.Run(fmt.Sprintf("entryInline=%v/landingInline=%v", entryInline, landingInline), func(t *testing.T) {
				raw := parsePatchProfile(t, `
proxy-providers:
  subscription:
    type: inline
    override:
      udp: true
      additional-prefix: "[S] "
      override-expr:
        - '.name += "!"'
    payload:
      - {name: Entry, type: ss, server: e.example.com, port: 8388, cipher: aes-128-gcm, password: p}
      - {name: Landing, type: ss, server: l.example.com, port: 8388, cipher: aes-128-gcm, password: p}
      - {name: Other, type: ss, server: o.example.com, port: 8388, cipher: aes-128-gcm, password: p}
proxy-groups:
  - {name: Manual, type: select, use: [subscription]}
  - {name: Auto, type: url-test, use: [subscription], url: "https://example.com", interval: 0}
rules:
  - MATCH,Manual
`)
				for _, node := range []struct {
					name   string
					inline bool
				}{{"Entry", entryInline}, {"Landing", landingInline}} {
					if node.inline {
						raw.Proxy = append(raw.Proxy, map[string]any{"name": "[S] " + node.name + "!", "type": "ss", "server": "example.com", "port": 8388, "cipher": "aes-128-gcm", "password": "p"})
					}
				}
				params := patchParams(t, `{"chain-policy": {"enabled": true, "entry": "[S] Entry!", "landing": "[S] Landing!"}}`)
				if _, err := applyPatch(raw, params); err != nil {
					t.Fatal(err)
				}
				parsed := parseChainConfig(t, raw)
				dialer := "[S] Entry!"
				if !entryInline {
					dialer = "链式入口"
					entryGroup := parsed.Proxies[dialer].Adapter().(outboundgroup.ProxyGroup)
					if got := entryGroup.Proxies(); len(got) != 1 || got[0].Name() != "[S] Entry!" {
						t.Fatalf("entry filter: %v", got)
					}
				}
				if landingInline {
					if got := parsed.Proxies["[S] Landing!"].ProxyInfo().DialerProxy; got != dialer {
						t.Fatalf("inline exit dialer = %q", got)
					}
				} else {
					for _, proxy := range parsed.Providers["subscription"].Proxies() {
						want := ""
						if proxy.Name() == "[S] Landing!" {
							want = dialer
						}
						if got := proxy.ProxyInfo().DialerProxy; got != want {
							t.Errorf("%s dialer = %q, want %q", proxy.Name(), got, want)
						}
						if !proxy.SupportUDP() {
							t.Errorf("existing UDP override lost: %s", proxy.Name())
						}
					}
					exitGroup := parsed.Proxies[explicitChainGroup].Adapter().(outboundgroup.ProxyGroup)
					if got := exitGroup.Proxies(); len(got) != 1 || got[0].Name() != "[S] Landing!" {
						t.Fatalf("exit filter: %v", got)
					}
					if got := findGroup(raw.ProxyGroup, "Manual")["proxies"]; !reflect.DeepEqual(got, []any{explicitChainGroup}) {
						t.Errorf("manual choices: %v", got)
					}
				}
				if _, exists := findGroup(raw.ProxyGroup, "Auto")["proxies"]; exists {
					t.Error("automatic group must stay untouched")
				}
			})
		}
	}
}

func TestApplyPatchChainMissingNode(t *testing.T) {
	raw := parsePatchProfile(t, chainTestProfile())
	params := patchParams(t, `{"chain-policy": {"enabled": true, "entry": "Entry", "landing": "Missing"}}`)
	if _, err := applyPatch(raw, params); err == nil || !strings.Contains(err.Error(), "not found") {
		t.Fatalf("missing exit error = %v", err)
	}
}

func TestApplyPatchChainProviderFilterAndCollision(t *testing.T) {
	raw := parsePatchProfile(t, `
proxy-providers:
  subscription:
    type: inline
    payload:
      - {name: 'a.+[1]`+"`"+`', type: ss, server: e.example.com, port: 8388, cipher: aes-128-gcm, password: p}
      - {name: Other, type: ss, server: o.example.com, port: 8388, cipher: aes-128-gcm, password: p}
proxy-groups:
  - {name: 链式入口, type: select, proxies: [DIRECT]}
  - {name: 链式落地, type: select, proxies: [DIRECT]}
rules:
  - MATCH,链式落地
`)
	params := &PatchParams{ChainPolicy: &PatchChainPolicy{Enabled: true, Entry: "a.+[1]`", Landing: "Missing"}}
	if _, err := applyPatch(raw, params); err != nil {
		t.Fatal(err)
	}
	parsed := parseChainConfig(t, raw)
	entry := parsed.Proxies["链式入口 2"].Adapter().(outboundgroup.ProxyGroup).Proxies()
	if len(entry) != 1 || entry[0].Name() != params.ChainPolicy.Entry {
		t.Fatalf("literal node filter: %v", entry)
	}
	exit := parsed.Proxies["链式落地 2"].Adapter().(outboundgroup.ProxyGroup).Proxies()
	if len(exit) != 1 || exit[0].Name() != "REJECT" {
		t.Fatalf("missing exit must fail closed: %v", exit)
	}
	if got := findGroup(raw.ProxyGroup, "链式入口")["proxies"].([]any)[0]; got != "DIRECT" {
		t.Fatalf("existing group overwritten: %v", got)
	}
}

func TestApplyPatchChainDisabled(t *testing.T) {
	for _, policy := range []string{
		`{"enabled": false, "entry": "Entry", "landing": "Landing"}`,
	} {
		rawCfg := parsePatchProfile(t, chainTestProfile())
		params := patchParams(t, `{"chain-policy": `+policy+`}`)
		if _, err := applyPatch(rawCfg, params); err != nil {
			t.Fatal(err)
		}
		if _, exist := findProxy(t, rawCfg.Proxy, "Landing")["dialer-proxy"]; exist {
			t.Errorf("policy %s: dialer-proxy should not be set", policy)
		}
		if findGroup(rawCfg.ProxyGroup, "链式落地") != nil {
			t.Errorf("policy %s: relay group should not be created", policy)
		}
	}
	// nil chain-policy is a no-op too.
	rawCfg := parsePatchProfile(t, chainTestProfile())
	params := patchParams(t, `{}`)
	if _, err := applyPatch(rawCfg, params); err != nil {
		t.Fatal(err)
	}
	if findGroup(rawCfg.ProxyGroup, "链式落地") != nil {
		t.Errorf("nil policy: relay group should not be created")
	}
}

// Prove the data path as well as configuration parsing using only loopback
// servers: app -> entry CONNECT -> exit CONNECT -> HTTP target.
func TestApplyPatchChainProviderConnect(t *testing.T) {
	var entryHops, exitHops atomic.Int32
	connectProxy := func(hops *atomic.Int32) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodConnect {
				http.Error(w, "CONNECT required", http.StatusMethodNotAllowed)
				return
			}
			upstream, err := net.DialTimeout("tcp", r.Host, 3*time.Second)
			if err != nil {
				http.Error(w, err.Error(), http.StatusBadGateway)
				return
			}
			defer upstream.Close()
			client, _, err := w.(http.Hijacker).Hijack()
			if err != nil {
				return
			}
			defer client.Close()
			hops.Add(1)
			_, _ = io.WriteString(client, "HTTP/1.1 200 Connection Established\r\n\r\n")
			go func() { _, _ = io.Copy(upstream, client); _ = upstream.Close() }()
			_, _ = io.Copy(client, upstream)
		}))
	}
	entry := connectProxy(&entryHops)
	defer entry.Close()
	exit := connectProxy(&exitHops)
	defer exit.Close()
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "chained response")
	}))
	defer origin.Close()
	proxyConfig := func(name string, server *httptest.Server) map[string]any {
		host, port, _ := net.SplitHostPort(server.Listener.Addr().String())
		return map[string]any{"name": name, "type": "http", "server": host, "port": port}
	}
	raw := parsePatchProfile(t, "rules: ['MATCH,链式落地']\n")
	raw.ProxyProvider = map[string]map[string]any{
		"local": {"type": "inline", "payload": []map[string]any{proxyConfig("Entry", entry), proxyConfig("Landing", exit)}},
	}
	params := patchParams(t, `{"chain-policy":{"enabled":true,"entry":"Entry","landing":"Landing"}}`)
	if _, err := applyPatch(raw, params); err != nil {
		t.Fatal(err)
	}
	parsed := parseChainConfig(t, raw)
	oldProxies, oldProviders := tunnel.Proxies(), tunnel.Providers()
	tunnel.UpdateProxies(parsed.Proxies, parsed.Providers)
	defer tunnel.UpdateProxies(oldProxies, oldProviders)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	host, port, _ := net.SplitHostPort(origin.Listener.Addr().String())
	portNumber, _ := strconv.Atoi(port)
	conn, err := parsed.Proxies[explicitChainGroup].DialContext(ctx, &constant.Metadata{
		NetWork: constant.TCP, DstIP: netip.MustParseAddr(host), DstPort: uint16(portNumber),
	})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	_, err = fmt.Fprintf(conn, "GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", origin.Listener.Addr())
	if err != nil {
		t.Fatal(err)
	}
	response, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "chained response" || entryHops.Load() != 1 || exitHops.Load() != 1 {
		t.Fatalf("body=%q entry hops=%d exit hops=%d", body, entryHops.Load(), exitHops.Load())
	}
}

func TestApplyPatchChainRejectsInvalidEnabledSelection(t *testing.T) {
	for _, policy := range []string{
		`{"enabled":true,"entry":"","landing":"Landing"}`,
		`{"enabled":true,"entry":"Entry","landing":"   "}`,
		`{"enabled":true,"entry":"Entry","landing":"Entry"}`,
	} {
		raw := parsePatchProfile(t, chainTestProfile())
		if _, err := applyPatch(raw, patchParams(t, `{"chain-policy":`+policy+`}`)); err == nil {
			t.Errorf("enabled invalid chain must not silently run without a chain: %s", policy)
		}
	}
}

func TestApplyPatchChainCircularDialerIsRejectedByMihomo(t *testing.T) {
	raw := parsePatchProfile(t, chainTestProfile())
	findProxy(t, raw.Proxy, "Entry")["dialer-proxy"] = "Landing"
	_, err := applyPatch(raw, patchParams(t, `{"chain-policy":{"enabled":true,"entry":"Entry","landing":"Landing"}}`))
	if err != nil {
		t.Fatal(err)
	}
	_, err = config.ParseRawConfig(raw)
	if err == nil || !strings.Contains(err.Error(), "circular dialer-proxy") {
		t.Fatalf("cycle must be reported by actual kernel validation: %v", err)
	}
}

func TestExternalChainIsReachableFromActiveManualSelector(t *testing.T) {
	raw := parsePatchProfile(t, `
proxies:
  - {name: Entry, type: http, server: entry.example, port: 80}
proxy-groups:
  - {name: Manual, type: select, proxies: [Entry]}
  - {name: Auto, type: url-test, proxies: [Entry], url: "https://example.invalid", interval: 60}
rules:
  - MATCH,Manual
`)
	params := &PatchParams{ChainPolicy: &PatchChainPolicy{
		Enabled: true, Entry: "Entry", EntryKind: "proxy",
		Landing: "[ext] Exit Group", LandingKind: "group",
		ExternalProfile: "other", ExternalTarget: "[ext] Exit Group", ExternalKind: "group",
		ExternalProxies: []map[string]any{{"name": "[ext] Exit", "type": "http", "server": "exit.example", "port": 80}},
		ExternalGroups:  []map[string]any{{"name": "[ext] Exit Group", "type": "select", "proxies": []any{"[ext] Exit"}}},
	}}
	if _, err := applyPatch(raw, params); err != nil {
		t.Fatal(err)
	}
	chain := findGroup(raw.ProxyGroup, explicitChainGroup)
	if chain == nil || !reflect.DeepEqual(chain["proxies"], []any{"[ext] Exit Group"}) {
		t.Fatalf("generated chain must point at selected exit graph: %#v", chain)
	}
	manual := findGroup(raw.ProxyGroup, "Manual")["proxies"]
	if !reflect.DeepEqual(manual, []any{"Entry", explicitChainGroup}) {
		t.Fatalf("manual selector must preserve original choice and expose chain: %#v", manual)
	}
	if got := findGroup(raw.ProxyGroup, "Auto")["proxies"]; !reflect.DeepEqual(got, []any{"Entry"}) {
		t.Fatalf("non-manual group must remain unchanged: %#v", got)
	}
	if _, err := config.ParseRawConfig(raw); err != nil {
		t.Fatalf("patched external chain invalid: %v", err)
	}
}

// An entry selector cannot contain the generated exit, directly or through a nested group.
func TestExternalChainAvoidsEntryGroupCycle(t *testing.T) {
	raw := parsePatchProfile(t, `
proxies:
  - {name: Entry, type: http, server: entry.example, port: 80}
proxy-groups:
  - {name: Inner, type: select, proxies: [Entry]}
  - {name: EntryGroup, type: select, proxies: [Inner]}
  - {name: Main, type: select, proxies: [Entry]}
rules: ['MATCH,Main']
`)
	params := &PatchParams{ChainPolicy: &PatchChainPolicy{
		Enabled: true, Entry: "EntryGroup", EntryKind: "group", Landing: "exit", LandingKind: "proxy",
		ExternalProfile: "other", ExternalTarget: "exit", ExternalKind: "proxy",
		ExternalProxies: []map[string]any{{"name": "exit", "type": "http", "server": "exit.example", "port": 80}},
	}}
	if _, err := applyPatch(raw, params); err != nil {
		t.Fatal(err)
	}
	if got := findGroup(raw.ProxyGroup, "EntryGroup")["proxies"]; !reflect.DeepEqual(got, []any{"Inner"}) {
		t.Fatalf("entry changed: %#v", got)
	}
	if got := findGroup(raw.ProxyGroup, "Inner")["proxies"]; !reflect.DeepEqual(got, []any{"Entry"}) {
		t.Fatalf("nested entry changed: %#v", got)
	}
	if got := findGroup(raw.ProxyGroup, "Main")["proxies"]; !reflect.DeepEqual(got, []any{"Entry", explicitChainGroup}) {
		t.Fatalf("main: %#v", got)
	}
	if _, err := config.ParseRawConfig(raw); err != nil {
		t.Fatalf("kernel rejected chain: %v", err)
	}
}

func TestChainEntryGroupRejectsImplicitProviderFallback(t *testing.T) {
	raw := parsePatchProfile(t, `
proxy-providers:
  remote: {type: http, url: 'https://example.invalid/provider', path: './unused.yaml'}
proxy-groups:
  - {name: EntryGroup, type: select, use: [remote]}
  - {name: Main, type: select, proxies: [REJECT]}
rules: ['MATCH,Main']
`)
	err := validateChainEntryGroup(raw, "EntryGroup")
	if err == nil || !strings.Contains(err.Error(), "empty-fallback") {
		t.Fatalf("unsafe fallback accepted: %v", err)
	}
}

func TestChainEntryGroupRejectsEmptyOrFilteredFallback(t *testing.T) {
	for _, group := range []map[string]any{
		{"name": "entry", "type": "select", "proxies": []any{}},
		{"name": "entry", "type": "select", "proxies": []any{"node"}, "filter": "does-not-match"},
	} {
		raw := config.DefaultRawConfig()
		raw.Proxy = []map[string]any{{"name": "node", "type": "http", "server": "example.invalid", "port": 80}}
		raw.ProxyGroup = []map[string]any{group}
		if err := validateChainEntryGroup(raw, "entry"); err == nil {
			t.Fatal("unsafe default fallback must be rejected")
		}
	}
}

func TestChainEntryGroupRejectsDirectEscape(t *testing.T) {
	raw := parsePatchProfile(t, `
proxy-groups:
  - {name: Entry Group, type: select, proxies: [Entry, DIRECT]}
proxies:
  - {name: Entry, type: http, server: entry.example, port: 80}
rules: ['MATCH,Entry Group']
`)
	params := &PatchParams{ChainPolicy: &PatchChainPolicy{
		Enabled: true, Entry: "Entry Group", EntryKind: "group", Landing: "[ext] Exit", LandingKind: "proxy",
		ExternalProfile: "other", ExternalTarget: "[ext] Exit", ExternalKind: "proxy",
		ExternalProxies: []map[string]any{{"name": "[ext] Exit", "type": "http", "server": "exit.example", "port": 80}},
	}}
	if _, err := applyPatch(raw, params); err == nil || !strings.Contains(err.Error(), "bypass") {
		t.Fatalf("entry group with DIRECT must be rejected, got %v", err)
	}
}

func TestSystemExplicitOverridesOnlyHomologousRuleCategories(t *testing.T) {
	rules := []string{
		"DOMAIN-SUFFIX,service.example,Proxy",
		"GEOSITE,geolocation-cn,Proxy",
		"GEOIP,CN,REJECT,no-resolve",
		"GEOIP,CN,REJECT-DROP,no-resolve",
		"IP-CIDR,223.5.5.5/32,Proxy,no-resolve",
		"DOMAIN,doh.pub,Proxy",
		"IP-CIDR,8.8.8.8/32,DIRECT,no-resolve",
		"IP-CIDR,192.168.0.0/16,REJECT,no-resolve",
		"IP-CIDR,10.0.0.0/8,REJECT-DROP,no-resolve",
		"DOMAIN-SUFFIX,lan,Proxy",
		"AND,((NETWORK,UDP),(DST-PORT,3478)),Proxy",
		"AND,((NETWORK,UDP),(DST-PORT,5353)),Proxy",
		"MATCH,Proxy",
	}
	additions := []string{
		"AND,((NETWORK,UDP),(DST-PORT,5353)),REJECT",
		"GEOSITE,geolocation-cn,DIRECT",
		"GEOIP,CN,DIRECT,no-resolve",
		"IP-CIDR,223.5.5.5/32,DIRECT,no-resolve",
		"DOMAIN-SUFFIX,doh.pub,DIRECT",
		"IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
		"DOMAIN-SUFFIX,lan,DIRECT",
		"AND,((NETWORK,UDP),(DST-PORT,3478)),REJECT",
	}
	got := replaceExplicitRuleCategories(rules, additions)
	want := []string{
		// Matching source safety blocks stay ahead of generated direct routes.
		"GEOIP,CN,REJECT,no-resolve",
		"GEOIP,CN,REJECT-DROP,no-resolve",
		"IP-CIDR,192.168.0.0/16,REJECT,no-resolve",
		"IP-CIDR,10.0.0.0/8,REJECT-DROP,no-resolve",
		// Same-function positive profile routes are replaced by explicit settings.
		"AND,((NETWORK,UDP),(DST-PORT,5353)),REJECT",
		"GEOSITE,geolocation-cn,DIRECT",
		"GEOIP,CN,DIRECT,no-resolve",
		"IP-CIDR,223.5.5.5/32,DIRECT,no-resolve",
		"DOMAIN-SUFFIX,doh.pub,DIRECT",
		"IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
		"DOMAIN-SUFFIX,lan,DIRECT",
		"AND,((NETWORK,UDP),(DST-PORT,3478)),REJECT",
		// Unrelated source rules retain their relative order after additions.
		"DOMAIN-SUFFIX,service.example,Proxy",
		"IP-CIDR,8.8.8.8/32,DIRECT,no-resolve",
		"MATCH,Proxy",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("rules after explicit priority:\n got: %#v\nwant: %#v", got, want)
	}
	if category := explicitRuleCategory("IP-CIDR,8.8.8.8/32,Proxy,no-resolve"); category != "" {
		t.Fatalf("unrelated host route misclassified as public DNS: %q", category)
	}
}

func TestSystemExplicitPatchKeepsSourceSafetyBlocks(t *testing.T) {
	raw := parsePatchProfile(t, `rules:
  - DOMAIN-SUFFIX,service.example,Proxy
  - GEOIP,CN,Proxy,no-resolve
  - GEOIP,CN,REJECT,no-resolve
  - IP-CIDR,192.168.0.0/16,Proxy,no-resolve
  - IP-CIDR,192.168.0.0/16,REJECT-DROP,no-resolve
  - DOMAIN-SUFFIX,corp.example,REJECT
  - DOMAIN,blocked.corp.example,REJECT
  - RULE-SET,blocked-corp,REJECT
  - MATCH,Proxy
`)
	params := &PatchParams{
		SystemExplicitRules: []string{
			"GEOSITE,geolocation-cn,DIRECT",
			"GEOIP,CN,DIRECT,no-resolve",
			"IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
		},
	}
	original := append([]string{}, raw.Rule...)
	if _, err := applyPatch(raw, params); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(original, []string{
		"DOMAIN-SUFFIX,service.example,Proxy",
		"GEOIP,CN,Proxy,no-resolve",
		"GEOIP,CN,REJECT,no-resolve",
		"IP-CIDR,192.168.0.0/16,Proxy,no-resolve",
		"IP-CIDR,192.168.0.0/16,REJECT-DROP,no-resolve",
		"DOMAIN-SUFFIX,corp.example,REJECT",
		"DOMAIN,blocked.corp.example,REJECT",
		"RULE-SET,blocked-corp,REJECT",
		"MATCH,Proxy",
	}) {
		t.Fatal("test fixture did not contain the expected source profile rules")
	}
	want := []string{
		// All profile-authored denies precede broad generated routes, including
		// matchers whose overlap needs geosite/provider data to determine.
		"GEOIP,CN,REJECT,no-resolve",
		"IP-CIDR,192.168.0.0/16,REJECT-DROP,no-resolve",
		"DOMAIN-SUFFIX,corp.example,REJECT",
		"DOMAIN,blocked.corp.example,REJECT",
		"RULE-SET,blocked-corp,REJECT",
		"GEOSITE,geolocation-cn,DIRECT",
		"GEOIP,CN,DIRECT,no-resolve",
		"IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
		"DOMAIN-SUFFIX,service.example,Proxy",
		"MATCH,Proxy",
	}
	if !reflect.DeepEqual(raw.Rule, want) {
		t.Fatalf("patched profile rules = %#v, want %#v", raw.Rule, want)
	}
}

func TestSystemExplicitNewCategoriesReplaceHomologousRules(t *testing.T) {
	rules := []string{
		"DOMAIN-KEYWORD,stun,Proxy",
		"DOMAIN-SUFFIX,stun.l.google.com,DIRECT",
		"GEOSITE,category-ads-all,Proxy",
		"IP-CIDR,114.114.114.114/32,Proxy,no-resolve",
		"DOMAIN-SUFFIX,alidns.com,Proxy",
		"AND,((NETWORK,UDP),(DST-PORT,3478-3480)),Proxy",
		"DOMAIN-SUFFIX,service.example,Proxy",
		"MATCH,Proxy",
	}
	additions := []string{
		"GEOSITE,category-ads-all,REJECT",
		"DOMAIN-KEYWORD,stun,REJECT",
		"DOMAIN-KEYWORD,turn,REJECT",
		"DOMAIN-SUFFIX,stun.l.google.com,REJECT",
		"AND,((NETWORK,UDP),(DST-PORT,3478-3480)),REJECT",
		"AND,((NETWORK,UDP),(DST-PORT,5349-5355)),REJECT",
		"AND,((NETWORK,UDP),(DST-PORT,19302-19305)),REJECT",
		"IP-CIDR,114.114.114.114/32,DIRECT,no-resolve",
		"DOMAIN-SUFFIX,alidns.com,DIRECT",
	}
	got := replaceExplicitRuleCategories(rules, additions)
	want := append(append([]string{}, additions...),
		"DOMAIN-SUFFIX,service.example,Proxy",
		"MATCH,Proxy",
	)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("rules after explicit priority:\n got: %#v\nwant: %#v", got, want)
	}
	for rule, category := range map[string]string{
		"DOMAIN-KEYWORD,turn,Proxy":                    "webrtc-domain",
		"DOMAIN,stun.l.google.com,Proxy":               "webrtc-domain",
		"GEOSITE,category-ads-all,REJECT":              "ads",
		"IP-CIDR6,2404:c2c0:85d8:901::8/128,DIRECT":    "china-public-dns-ip",
		"DOMAIN-SUFFIX,onedns.net,DIRECT":              "china-public-dns-domain",
		"AND,((NETWORK,UDP),(DST-PORT,19302-19305)),X": "webrtc-common-ports",
	} {
		if got := explicitRuleCategory(rule); got != category {
			t.Fatalf("explicitRuleCategory(%q) = %q, want %q", rule, got, category)
		}
	}
}

func TestApplyPatchAppChainReplacesOnlySelectedNativeChain(t *testing.T) {
	raw := parsePatchProfile(t, `
proxies:
  - {name: Entry, type: http, server: entry.example, port: 80}
  - {name: Landing, type: http, server: landing.example, port: 80, dialer-proxy: Native Entry}
  - {name: Other, type: http, server: other.example, port: 80, dialer-proxy: Native Entry}
  - {name: Native Entry, type: http, server: native.example, port: 80}
proxy-groups:
  - {name: Proxy, type: select, proxies: [Entry]}
rules:
  - DOMAIN-SUFFIX,keep.example,Proxy
  - MATCH,Proxy
`)
	beforeRules := append([]string{}, raw.Rule...)
	params := patchParams(t, `{"chain-policy":{"enabled":true,"entry":"Entry","entry-kind":"proxy","landing":"Landing","landing-kind":"proxy"}}`)
	if _, err := applyPatch(raw, params); err != nil {
		t.Fatal(err)
	}
	if got := findProxy(t, raw.Proxy, "Landing")["dialer-proxy"]; got != "Entry" {
		t.Fatalf("selected exit dialer = %v, want explicit app chain Entry", got)
	}
	if got := findProxy(t, raw.Proxy, "Other")["dialer-proxy"]; got != "Native Entry" {
		t.Fatalf("unrelated native chain changed: %v", got)
	}
	if !reflect.DeepEqual(raw.Rule, beforeRules) {
		t.Fatalf("unrelated routing rules changed: %#v", raw.Rule)
	}
	if _, err := config.ParseRawConfig(raw); err != nil {
		t.Fatalf("explicit chain must remain a valid Mihomo config: %v", err)
	}
}

func TestApplyPatchExternalGroupChainReplacesOnlyImportedChainSettings(t *testing.T) {
	raw := parsePatchProfile(t, `
proxies:
  - {name: Entry, type: http, server: entry.example, port: 80}
  - {name: Unrelated, type: http, server: unrelated.example, port: 80, dialer-proxy: Native Entry}
  - {name: Native Entry, type: http, server: native.example, port: 80}
proxy-groups:
  - {name: Proxy, type: select, proxies: [Entry]}
rules:
  - DOMAIN-SUFFIX,keep.example,Proxy
  - MATCH,Proxy
`)
	params := &PatchParams{ChainPolicy: &PatchChainPolicy{
		Enabled:         true,
		Entry:           "Entry",
		EntryKind:       "proxy",
		Landing:         "[external] Exit group",
		LandingKind:     "group",
		ExternalProfile: "other-profile",
		ExternalTarget:  "[external] Exit group",
		ExternalKind:    "group",
		ExternalProxies: []map[string]any{
			{"name": "[external] Exit", "type": "http", "server": "exit.example", "port": 80, "dialer-proxy": "[external] Old entry"},
			{"name": "[external] Other", "type": "http", "server": "other.example", "port": 80},
		},
		ExternalGroups: []map[string]any{{
			"name":    "[external] Exit group",
			"type":    "select",
			"proxies": []any{"[external] Exit", "[external] Other"},
		}},
	}}
	if _, err := applyPatch(raw, params); err != nil {
		t.Fatal(err)
	}
	if got := findProxy(t, raw.Proxy, "[external] Exit")["dialer-proxy"]; got != "Entry" {
		t.Fatalf("app chain did not replace selected external chain: %v", got)
	}
	if got := findProxy(t, raw.Proxy, "[external] Other")["dialer-proxy"]; got != "Entry" {
		t.Fatalf("app chain did not apply to selected external group member: %v", got)
	}
	if got := findProxy(t, raw.Proxy, "Unrelated")["dialer-proxy"]; got != "Native Entry" {
		t.Fatalf("unrelated active native chain changed: %v", got)
	}
	if _, err := config.ParseRawConfig(raw); err != nil {
		t.Fatalf("external group chain must remain a valid Mihomo config: %v", err)
	}
}

func TestExternalProfileGroupChainTwoHopConnect(t *testing.T) {
	var entryHops, exitHops atomic.Int32
	connectProxy := func(hops *atomic.Int32) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodConnect {
				http.Error(w, "CONNECT required", http.StatusMethodNotAllowed)
				return
			}
			upstream, err := net.DialTimeout("tcp", r.Host, 3*time.Second)
			if err != nil {
				http.Error(w, err.Error(), http.StatusBadGateway)
				return
			}
			defer upstream.Close()
			client, _, err := w.(http.Hijacker).Hijack()
			if err != nil {
				return
			}
			defer client.Close()
			hops.Add(1)
			_, _ = io.WriteString(client, "HTTP/1.1 200 Connection Established\r\n\r\n")
			go func() { _, _ = io.Copy(upstream, client); _ = upstream.Close() }()
			_, _ = io.Copy(client, upstream)
		}))
	}
	entry := connectProxy(&entryHops)
	defer entry.Close()
	exit := connectProxy(&exitHops)
	defer exit.Close()
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "chained response")
	}))
	defer origin.Close()
	proxyConfig := func(name string, server *httptest.Server) map[string]any {
		host, port, _ := net.SplitHostPort(server.Listener.Addr().String())
		return map[string]any{"name": name, "type": "http", "server": host, "port": port}
	}
	raw := parsePatchProfile(t, "rules: ['MATCH,Main']\n")
	raw.Proxy = []map[string]any{proxyConfig("Entry", entry)}
	raw.ProxyGroup = []map[string]any{
		{"name": "EntryGroup", "type": "select", "proxies": []any{"Entry"}},
		{"name": "Main", "type": "select", "proxies": []any{"Entry"}},
	}
	params := &PatchParams{ChainPolicy: &PatchChainPolicy{
		Enabled: true, Entry: "EntryGroup", EntryKind: "group", Landing: "ExitGroup", LandingKind: "group",
		ExternalProfile: "other", ExternalTarget: "[other] ExitGroup", ExternalKind: "group",
		ExternalProxies: []map[string]any{proxyConfig("[other] Exit", exit)},
		ExternalGroups: []map[string]any{
			{"name": "[other] Inner", "type": "select", "proxies": []any{"[other] Exit"}, "empty-fallback": "REJECT"},
			{"name": "[other] ExitGroup", "type": "select", "proxies": []any{"[other] Inner"}, "empty-fallback": "REJECT"},
		},
	}}
	if _, err := applyPatch(raw, params); err != nil {
		t.Fatal(err)
	}
	parsed := parseChainConfig(t, raw)
	oldProxies, oldProviders := tunnel.Proxies(), tunnel.Providers()
	tunnel.UpdateProxies(parsed.Proxies, parsed.Providers)
	defer tunnel.UpdateProxies(oldProxies, oldProviders)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	host, port, _ := net.SplitHostPort(origin.Listener.Addr().String())
	portNumber, _ := strconv.Atoi(port)
	conn, err := parsed.Proxies[explicitChainGroup].DialContext(ctx, &constant.Metadata{
		NetWork: constant.TCP, DstIP: netip.MustParseAddr(host), DstPort: uint16(portNumber),
	})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	_, err = fmt.Fprintf(conn, "GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", origin.Listener.Addr())
	if err != nil {
		t.Fatal(err)
	}
	response, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "chained response" || entryHops.Load() != 1 || exitHops.Load() != 1 {
		t.Fatalf("body=%q entry hops=%d exit hops=%d", body, entryHops.Load(), exitHops.Load())
	}
}

// LAN-direct must not intercept loopback traffic before the existing built-in
// port protection, while a matching LAN rule is still replaced.
func TestSystemExplicitKeepsBuiltinLoopbackProtection(t *testing.T) {
	raw := parsePatchProfile(t, "rules: ['MATCH,DIRECT']\n")
	safety := "AND,((DST-PORT,7890),(IP-CIDR,127.0.0.0/8,no-resolve)),REJECT"
	params := &PatchParams{
		PrependRules:        []string{safety, "IP-CIDR,127.0.0.0/8,Proxy,no-resolve"},
		SystemExplicitRules: []string{"IP-CIDR,127.0.0.0/8,DIRECT,no-resolve"},
	}
	if _, err := applyPatch(raw, params); err != nil {
		t.Fatal(err)
	}
	want := []string{safety, "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve", "MATCH,DIRECT"}
	if !reflect.DeepEqual(raw.Rule, want) {
		t.Fatalf("rules = %#v, want %#v", raw.Rule, want)
	}
}

func TestQuicBlockAndChinaDirectCoexistWithoutDuplication(t *testing.T) {
	raw := parsePatchProfile(t, `rules:
  - GEOSITE,geolocation-cn,Proxy
  - GEOIP,CN,Proxy,no-resolve
  - DOMAIN-SUFFIX,service.example,Proxy
  - MATCH,Proxy
`)
	quic := "AND,((NETWORK,UDP),(DST-PORT,443),(NOT,((OR,((GEOSITE,geolocation-cn),(GEOIP,CN,no-resolve)))))),REJECT"
	params := &PatchParams{
		PrependRules: []string{quic},
		SystemExplicitRules: []string{
			"GEOSITE,geolocation-cn,DIRECT",
			"GEOIP,CN,DIRECT,no-resolve",
		},
	}
	if _, err := applyPatch(raw, params); err != nil {
		t.Fatal(err)
	}
	counts := map[string]int{}
	for _, rule := range raw.Rule {
		counts[rule]++
	}
	for _, rule := range []string{
		quic,
		"GEOSITE,geolocation-cn,DIRECT",
		"GEOIP,CN,DIRECT,no-resolve",
	} {
		if counts[rule] != 1 {
			t.Fatalf("rule %q appears %d times in %#v", rule, counts[rule], raw.Rule)
		}
	}
	for _, rule := range []string{
		"GEOSITE,geolocation-cn,Proxy",
		"GEOIP,CN,Proxy,no-resolve",
	} {
		if counts[rule] != 0 {
			t.Fatalf("superseded profile rule %q survived in %#v", rule, raw.Rule)
		}
	}
}

func TestExternalProfileProviderGroupTwoHopConnect(t *testing.T) {
	var entryHops, exitHops atomic.Int32
	connectProxy := func(hops *atomic.Int32) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodConnect {
				http.Error(w, "CONNECT required", http.StatusMethodNotAllowed)
				return
			}
			upstream, err := net.DialTimeout("tcp", r.Host, 3*time.Second)
			if err != nil {
				http.Error(w, err.Error(), http.StatusBadGateway)
				return
			}
			defer upstream.Close()
			client, _, err := w.(http.Hijacker).Hijack()
			if err != nil {
				return
			}
			defer client.Close()
			hops.Add(1)
			_, _ = io.WriteString(client, "HTTP/1.1 200 Connection Established\r\n\r\n")
			go func() { _, _ = io.Copy(upstream, client); _ = upstream.Close() }()
			_, _ = io.Copy(client, upstream)
		}))
	}
	entry := connectProxy(&entryHops)
	defer entry.Close()
	exit := connectProxy(&exitHops)
	defer exit.Close()
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "chained response")
	}))
	defer origin.Close()
	proxyConfig := func(name string, server *httptest.Server) map[string]any {
		host, port, _ := net.SplitHostPort(server.Listener.Addr().String())
		return map[string]any{"name": name, "type": "http", "server": host, "port": port}
	}
	raw := parsePatchProfile(t, "rules: ['MATCH,Main']\n")
	raw.Proxy = []map[string]any{proxyConfig("Entry", entry)}
	raw.ProxyGroup = []map[string]any{
		{"name": "EntryGroup", "type": "select", "proxies": []any{"Entry"}},
		{"name": "Main", "type": "select", "proxies": []any{"Entry"}},
	}
	params := &PatchParams{ChainPolicy: &PatchChainPolicy{
		Enabled: true, Entry: "EntryGroup", EntryKind: "group", Landing: "ExitGroup", LandingKind: "group",
		ExternalProfile: "other", ExternalTarget: "[other] ExitGroup", ExternalKind: "group",
		ExternalProviders: map[string]map[string]any{
			"[other] provider": {"type": "inline", "payload": []map[string]any{proxyConfig("Exit", exit)}, "override": map[string]any{"override-expr": []any{`.name = "[AngelaMihomo chain other/provider] " + .name`}}},
		},
		ExternalGroups: []map[string]any{
			{"name": "[other] ExitGroup", "type": "select", "use": []any{"[other] provider"}, "empty-fallback": "REJECT", "exclude-type": "Direct|Compatible|Pass"},
		},
	}}
	if _, err := applyPatch(raw, params); err != nil {
		t.Fatal(err)
	}
	parsed := parseChainConfig(t, raw)
	oldProxies, oldProviders := tunnel.Proxies(), tunnel.Providers()
	tunnel.UpdateProxies(parsed.Proxies, parsed.Providers)
	defer tunnel.UpdateProxies(oldProxies, oldProviders)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	host, port, _ := net.SplitHostPort(origin.Listener.Addr().String())
	portNumber, _ := strconv.Atoi(port)
	conn, err := parsed.Proxies[explicitChainGroup].DialContext(ctx, &constant.Metadata{
		NetWork: constant.TCP, DstIP: netip.MustParseAddr(host), DstPort: uint16(portNumber),
	})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	_, err = fmt.Fprintf(conn, "GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", origin.Listener.Addr())
	if err != nil {
		t.Fatal(err)
	}
	response, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "chained response" || entryHops.Load() != 1 || exitHops.Load() != 1 {
		t.Fatalf("body=%q entry hops=%d exit hops=%d", body, entryHops.Load(), exitHops.Load())
	}
}

func TestExternalProfileProviderEntryTwoHopConnect(t *testing.T) {
	var entryHops, exitHops atomic.Int32
	connectProxy := func(hops *atomic.Int32) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodConnect {
				http.Error(w, "CONNECT required", http.StatusMethodNotAllowed)
				return
			}
			upstream, err := net.DialTimeout("tcp", r.Host, 3*time.Second)
			if err != nil {
				http.Error(w, err.Error(), http.StatusBadGateway)
				return
			}
			defer upstream.Close()
			client, _, err := w.(http.Hijacker).Hijack()
			if err != nil {
				return
			}
			defer client.Close()
			hops.Add(1)
			_, _ = io.WriteString(client, "HTTP/1.1 200 Connection Established\r\n\r\n")
			go func() { _, _ = io.Copy(upstream, client); _ = upstream.Close() }()
			_, _ = io.Copy(client, upstream)
		}))
	}
	entry := connectProxy(&entryHops)
	defer entry.Close()
	exit := connectProxy(&exitHops)
	defer exit.Close()
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "chained response")
	}))
	defer origin.Close()
	proxyConfig := func(name string, server *httptest.Server) map[string]any {
		host, port, _ := net.SplitHostPort(server.Listener.Addr().String())
		return map[string]any{"name": name, "type": "http", "server": host, "port": port}
	}
	raw := parsePatchProfile(t, "rules: ['MATCH,Main']\n")
	raw.ProxyProvider = map[string]map[string]any{
		"current": {"type": "inline", "payload": []map[string]any{proxyConfig("Entry", entry)}},
	}
	raw.ProxyGroup = []map[string]any{
		{"name": "Main", "type": "select", "use": []any{"current"}},
	}
	params := &PatchParams{ChainPolicy: &PatchChainPolicy{
		Enabled: true, Entry: "Entry", EntryKind: "proxy", Landing: "ExitGroup", LandingKind: "group",
		ExternalProfile: "other", ExternalTarget: "[other] ExitGroup", ExternalKind: "group",
		ExternalProxies: []map[string]any{proxyConfig("[other] Exit", exit)},
		ExternalGroups: []map[string]any{
			{"name": "[other] Inner", "type": "select", "proxies": []any{"[other] Exit"}, "empty-fallback": "REJECT"},
			{"name": "[other] ExitGroup", "type": "select", "proxies": []any{"[other] Inner"}, "empty-fallback": "REJECT"},
		},
	}}
	if _, err := applyPatch(raw, params); err != nil {
		t.Fatal(err)
	}
	parsed := parseChainConfig(t, raw)
	oldProxies, oldProviders := tunnel.Proxies(), tunnel.Providers()
	tunnel.UpdateProxies(parsed.Proxies, parsed.Providers)
	defer tunnel.UpdateProxies(oldProxies, oldProviders)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	host, port, _ := net.SplitHostPort(origin.Listener.Addr().String())
	portNumber, _ := strconv.Atoi(port)
	conn, err := parsed.Proxies[explicitChainGroup].DialContext(ctx, &constant.Metadata{
		NetWork: constant.TCP, DstIP: netip.MustParseAddr(host), DstPort: uint16(portNumber),
	})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	_, err = fmt.Fprintf(conn, "GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", origin.Listener.Addr())
	if err != nil {
		t.Fatal(err)
	}
	response, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "chained response" || entryHops.Load() != 1 || exitHops.Load() != 1 {
		t.Fatalf("body=%q entry hops=%d exit hops=%d", body, entryHops.Load(), exitHops.Load())
	}
}

func TestProviderEntryUsesOnlyOriginalProfileProviders(t *testing.T) {
	raw := parsePatchProfile(t, "rules: ['MATCH,Main']\n")
	raw.ProxyProvider = map[string]map[string]any{"active-provider": {"type": "inline", "payload": []map[string]any{}}}
	raw.ProxyGroup = []map[string]any{{"name": "Main", "type": "select", "proxies": []any{"DIRECT"}}}
	params := &PatchParams{ChainPolicy: &PatchChainPolicy{Enabled: true, Entry: "Live node", EntryKind: "proxy", Landing: "exit", LandingKind: "group", ExternalProfile: "external", ExternalTarget: "external group", ExternalKind: "group", ExternalProviders: map[string]map[string]any{"external-provider": {"type": "inline", "payload": []map[string]any{}}}, ExternalGroups: []map[string]any{{"name": "external group", "type": "select", "use": []any{"external-provider"}}}}}
	if _, err := applyPatch(raw, params); err != nil {
		t.Fatal(err)
	}
	g := findGroup(raw.ProxyGroup, "链式入口")
	if g == nil || !reflect.DeepEqual(g["use"], []string{"active-provider"}) || g["include-all-providers"] != nil || g["empty-fallback"] != "REJECT" {
		t.Fatalf("entry selector: %#v", g)
	}
}

// Reproduce the reported latest-build error with a normal filtered url-test
// entry. The subscription need not include chain-specific safety directives.
func TestChainEntryCompatibilityHardenedInProductionPatch(t *testing.T) {
	for _, typ := range []string{"select", "url-test", "fallback", "load-balance"} {
		t.Run(typ, func(t *testing.T) {
			raw := parsePatchProfile(t, `
proxies:
 - {name: entry-node, type: http, server: 127.0.0.1, port: 1}
proxy-groups:
 - {name: 自动选择, type: `+typ+`, proxies: [entry-node], filter: '^entry', url: 'http://127.0.0.1:1', interval: 86400}
 - {name: Main, type: select, proxies: [entry-node]}
rules: ['MATCH,Main']
`)
			params := &PatchParams{ChainPolicy: &PatchChainPolicy{Enabled: true, Entry: "自动选择", EntryKind: "group", Landing: "[ext] ♻️ 自动选择", LandingKind: "group", ExternalProfile: "synthetic", ExternalTarget: "[ext] ♻️ 自动选择", ExternalKind: "group", ExternalProxies: []map[string]any{{"name": "[ext] exit", "type": "http", "server": "127.0.0.1", "port": 1}}, ExternalGroups: []map[string]any{{"name": "[ext] ♻️ 自动选择", "type": "select", "proxies": []any{"[ext] exit"}, "empty-fallback": "REJECT"}}}}
			if _, err := applyPatch(raw, params); err != nil {
				t.Fatal(err)
			}
			if findGroup(raw.ProxyGroup, "自动选择")["empty-fallback"] != "REJECT" {
				t.Fatal("entry not fail-closed")
			}
			if findGroup(raw.ProxyGroup, "Main")["empty-fallback"] != nil {
				t.Fatal("unrelated selector was hardened")
			}
			parseChainConfig(t, raw)
		})
	}
}

func TestChainEntryCompatibilityProviderAndNested(t *testing.T) {
	raw := parsePatchProfile(t, `
proxy-providers:
 remote: {type: inline, payload: [{name: node, type: http, server: 127.0.0.1, port: 1}]}
proxy-groups:
 - {name: Inner, type: url-test, use: [remote], exclude-type: Shadowsocks, url: 'http://127.0.0.1:1', interval: 86400}
 - {name: 自动选择, type: select, proxies: [Inner]}
`)
	if err := hardenChainEntryGroup(raw, "自动选择"); err != nil {
		t.Fatal(err)
	}
	if err := validateChainEntryGroup(raw, "自动选择"); err != nil {
		t.Fatal(err)
	}
	if got := findGroup(raw.ProxyGroup, "Inner")["exclude-type"]; got != "Shadowsocks|Direct|Compatible|Pass" {
		t.Fatalf("lost user filter %v", got)
	}
	for _, name := range []string{"Inner", "自动选择"} {
		if findGroup(raw.ProxyGroup, name)["empty-fallback"] != "REJECT" {
			t.Fatal(name)
		}
	}
	parseChainConfig(t, raw)
}

// Exercise the real Mihomo group's dialing, not just map fields. A reachable
// destination must not be reached when filtering empties the entry, or its
// chosen proxy fails. A default COMPATIBLE fallback would dial the listener.
func TestChainEntryCompatibilityNeverDialsDirectOnEmptyOrFailure(t *testing.T) {
	for _, filtered := range []bool{true, false} {
		t.Run(fmt.Sprint(filtered), func(t *testing.T) {
			var hits atomic.Int32
			target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits.Add(1); w.WriteHeader(200) }))
			defer target.Close()
			raw := parsePatchProfile(t, `
proxies:
 - {name: dead-node, type: http, server: 127.0.0.1, port: 1}
proxy-groups:
 - {name: 自动选择, type: select, proxies: [dead-node]}
`)
			if filtered {
				findGroup(raw.ProxyGroup, "自动选择")["filter"] = "^does-not-match$"
			}
			if err := hardenChainEntryGroup(raw, "自动选择"); err != nil {
				t.Fatal(err)
			}
			if err := validateChainEntryGroup(raw, "自动选择"); err != nil {
				t.Fatal(err)
			}
			parsed := parseChainConfig(t, raw)
			oldP, oldProviders := tunnel.Proxies(), tunnel.Providers()
			tunnel.UpdateProxies(parsed.Proxies, parsed.Providers)
			defer tunnel.UpdateProxies(oldP, oldProviders)
			host, port, _ := net.SplitHostPort(target.Listener.Addr().String())
			n, _ := strconv.Atoi(port)
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			c, err := parsed.Proxies["自动选择"].DialContext(ctx, &constant.Metadata{NetWork: constant.TCP, DstIP: netip.MustParseAddr(host), DstPort: uint16(n)})
			if c != nil {
				c.Close()
			}
			if err == nil {
				t.Fatal("unsafe direct dial succeeded")
			}
			if hits.Load() != 0 {
				t.Fatal("direct origin contacted")
			}
		})
	}
}

func TestApplyPatchTunDNSMode(t *testing.T) {
	rawCfg := parsePatchProfile(t, "tun:\n  dns-mode: native\n")
	if _, err := applyPatch(rawCfg, patchParams(t, `{"general":{"tun":{"enable":true,"stack":"system"}}}`)); err != nil {
		t.Fatal(err)
	}
	if rawCfg.Tun.DNSMode != "native" {
		t.Errorf("profile dns-mode should be kept, got %q", rawCfg.Tun.DNSMode)
	}
	if _, err := applyPatch(rawCfg, patchParams(t, `{"general":{"tun":{"enable":true,"stack":"system","dns-mode":"hijack"}}}`)); err != nil {
		t.Fatal(err)
	}
	if rawCfg.Tun.DNSMode != "hijack" {
		t.Errorf("patched dns-mode should override, got %q", rawCfg.Tun.DNSMode)
	}
}
