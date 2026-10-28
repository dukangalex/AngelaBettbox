//go:build linux

package route

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strings"
	"testing"

	"github.com/metacubex/http/httptest"
)

// Run only as root in a disposable network namespace. Checks interface creation
// and removal, not traffic, DNS, Android VpnService, or leak prevention.
func TestFullConfigReloadLinuxTunIntegration(t *testing.T) {
	if os.Getenv("G5_ISOLATED_TUN_TEST") != "1" {
		t.Skip("requires isolated Linux network namespace with CAP_NET_ADMIN")
	}
	if os.Geteuid() != 0 {
		t.Fatal("requires root in a disposable network namespace")
	}
	self, err := os.Readlink("/proc/self/ns/net")
	if err != nil {
		t.Fatal(err)
	}
	initNS, err := os.Readlink("/proc/1/ns/net")
	if err != nil {
		t.Fatal(err)
	}
	if self == initNS {
		t.Fatal("refusing to modify initial network namespace")
	}
	old := embedMode
	SetEmbedMode(false)
	defer SetEmbedMode(old)
	if _, err := net.InterfaceByName("g5reloadtun"); err == nil {
		t.Fatal("test interface already exists")
	}
	apply := func(enabled bool) {
		payload := fmt.Sprintf("mode: rule\ntun:\n  enable: %t\n  device: g5reloadtun\n  stack: system\n  auto-route: false\n  auto-detect-interface: false\nproxies: []\nproxy-groups: []\nrules:\n  - MATCH,DIRECT\n", enabled)
		body, _ := json.Marshal(map[string]string{"payload": payload})
		req := httptest.NewRequest("PUT", "/?force=true", strings.NewReader(string(body)))
		req.Header.Set("Content-Type", "application/json")
		rec := httptest.NewRecorder()
		configRouter().ServeHTTP(rec, req)
		if rec.Code != 204 {
			t.Fatalf("reload enabled=%t status=%d body=%s", enabled, rec.Code, rec.Body.String())
		}
	}
	defer apply(false)
	apply(true)
	if _, err := net.InterfaceByName("g5reloadtun"); err != nil {
		t.Fatalf("enabled reload did not create TUN: %v", err)
	}
	apply(false)
	if _, err := net.InterfaceByName("g5reloadtun"); err == nil {
		t.Fatal("disabled reload did not remove TUN")
	}
}
