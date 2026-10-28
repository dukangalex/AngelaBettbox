package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/config"
)

func runtimeConfigFor(t *testing.T, name, content string, patch *PatchParams) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	params := &SetupParams{ProfilePath: path, Patch: patch}
	if strings.HasSuffix(name, ".json") {
		params = &SetupParams{ScriptedConfig: path, Patch: patch}
	}
	out, err := handleGetRuntimeConfig(params)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := config.UnmarshalRawConfig([]byte(out)); err != nil {
		t.Fatalf("output is not a valid config: %v\n%s", err, out)
	}
	return out
}

func TestRuntimeConfigKeepsProfileShape(t *testing.T) {
	profile := `# comment
mixed-port: 7890
proxies:
  - {name: "🇭🇰 HK", type: ss, server: a.com, port: 1, cipher: aes-128-gcm, password: x}
proxy-groups:
  - name: G
    type: select
    proxies: ["🇭🇰 HK"]
rules:
  - MATCH,G
`
	out := runtimeConfigFor(t, "p.yaml", profile, nil)
	want := `mixed-port: 7890
proxies:
  - name: 🇭🇰 HK
    type: ss
    server: a.com
    port: 1
    cipher: aes-128-gcm
    password: x
proxy-groups:
  - name: G
    type: select
    proxies:
      - 🇭🇰 HK
rules:
  - MATCH,G
`
	if out != want {
		t.Fatalf("got:\n%s\nwant:\n%s", out, want)
	}
}

func TestRuntimeConfigAppendsPatchedFields(t *testing.T) {
	profile := `proxies:
  - name: A
    type: ss
    server: a.com
    port: 1
    cipher: aes-128-gcm
    password: x
mode: global
rules:
  - MATCH,DIRECT
`
	patch := &PatchParams{
		General:            []byte(`{"mode":"rule","mixed-port":7891,"log-level":"info"}`),
		HealthCheckTimeout: defaultHealthCheckTimeout,
		PrependRules:       []string{"DOMAIN,a.com,DIRECT"},
	}
	out := runtimeConfigFor(t, "p.yaml", profile, patch)
	if !strings.HasPrefix(out, "proxies:\n  - name: A\n    type: ss\n") {
		t.Fatalf("profile order changed:\n%s", out)
	}
	if !strings.Contains(out, "\nmode: rule\nrules:\n  - DOMAIN,a.com,DIRECT\n  - MATCH,DIRECT\n") {
		t.Fatalf("patched fields not in place:\n%s", out)
	}
	for _, line := range []string{"\nmixed-port: 7891\n", "\nlog-level: info\n"} {
		if !strings.Contains(out, line) {
			t.Fatalf("forced field %q missing:\n%s", line, out)
		}
	}
	for _, line := range []string{"tuic-server:", "iptables:", "ss-config:", "socks-port:"} {
		if strings.Contains(out, line) {
			t.Fatalf("untouched default %q leaked:\n%s", line, out)
		}
	}
}

func TestRuntimeConfigExpandsAliases(t *testing.T) {
	profile := `base: &base
  type: select
  proxies: [DIRECT]
proxy-groups:
  - name: G
    <<: *base
  - name: H
    <<: *base
    type: fallback
rules:
  - MATCH,G
`
	out := runtimeConfigFor(t, "p.yaml", profile, nil)
	if strings.Contains(out, "*base") || strings.Contains(out, "&base") || strings.Contains(out, "<<") {
		t.Fatalf("aliases kept:\n%s", out)
	}
	if !strings.Contains(out, "  - name: H\n    proxies:\n      - DIRECT\n    type: fallback\n") {
		t.Fatalf("merge key not expanded:\n%s", out)
	}
}

func TestRuntimeConfigScriptedUsesBlockStyle(t *testing.T) {
	scripted := `{"mixed-port":7890,"proxies":[{"name":"A","type":"ss","server":"a.com","port":1,"cipher":"aes-128-gcm","password":"0123"}],"rules":["MATCH,DIRECT"]}`
	out := runtimeConfigFor(t, "s.json", scripted, nil)
	want := `mixed-port: 7890
proxies:
  - name: A
    type: ss
    server: a.com
    port: 1
    cipher: aes-128-gcm
    password: "0123"
rules:
  - MATCH,DIRECT
`
	if out != want {
		t.Fatalf("got:\n%s\nwant:\n%s", out, want)
	}
}

// The runtime overlay must win over matching script rules without changing the
// original subscription or erasing unrelated rules. ScriptedConfig is a
// disposable generated intermediate that loadPatchedConfig removes after reading.
func TestRuntimeConfigScriptedExplicitPriorityAndSourceUnchanged(t *testing.T) {
	const source = `{"rules":["DOMAIN-SUFFIX,service.example,Proxy","GEOIP,CN,Proxy,no-resolve","IP-CIDR,8.8.8.8/32,Proxy,no-resolve","MATCH,Proxy"]}`
	dir := t.TempDir()
	path := filepath.Join(dir, "script.json")
	profilePath := filepath.Join(dir, "profile.yaml")
	const originalProfile = "rules:\n  - MATCH,DIRECT\n"
	if err := os.WriteFile(profilePath, []byte(originalProfile), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	params := &SetupParams{ProfilePath: profilePath, ScriptedConfig: path, Patch: &PatchParams{
		PrependRules:        []string{"GEOIP,CN,REJECT,no-resolve", "DOMAIN-SUFFIX,other.example,DIRECT"},
		SystemExplicitRules: []string{"GEOSITE,geolocation-cn,DIRECT", "GEOIP,CN,DIRECT,no-resolve"},
	}}
	out, err := handleGetRuntimeConfig(params)
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.UnmarshalRawConfig([]byte(out))
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"DOMAIN-SUFFIX,other.example,DIRECT", "GEOSITE,geolocation-cn,DIRECT", "GEOIP,CN,DIRECT,no-resolve", "DOMAIN-SUFFIX,service.example,Proxy", "IP-CIDR,8.8.8.8/32,Proxy,no-resolve", "MATCH,Proxy"}
	if !reflect.DeepEqual(cfg.Rule, want) {
		t.Fatalf("rules = %#v; want %#v", cfg.Rule, want)
	}
	stored, err := os.ReadFile(profilePath)
	if err != nil {
		t.Fatal(err)
	}
	if string(stored) != originalProfile {
		t.Fatal("original subscription was modified")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("generated scripted config should be removed, got %v", err)
	}
}
