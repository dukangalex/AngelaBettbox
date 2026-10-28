package route

import (
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"testing"

	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/tunnel"
)

func TestFullConfigReloadAppliesHTTPPort(t *testing.T) {
	old := embedMode
	SetEmbedMode(false)
	defer SetEmbedMode(old)
	listener.ReCreateHTTP(0, tunnel.Tunnel)
	defer listener.ReCreateHTTP(0, tunnel.Tunnel)
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := l.Addr().(*net.TCPAddr).Port
	l.Close()
	payload := fmt.Sprintf("port: %d\nallow-lan: false\nmode: rule\nproxies: []\nproxy-groups: []\nrules:\n  - MATCH,DIRECT\n", port)
	body, _ := json.Marshal(map[string]string{"payload": payload})
	req := httptest.NewRequest("PUT", "/?force=true", strings.NewReader(string(body)))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	configRouter().ServeHTTP(rec, req)
	if rec.Code != 204 {
		t.Fatalf("PUT status = %d, body=%s", rec.Code, rec.Body.String())
	}
	if got := listener.GetPorts().Port; got != port {
		t.Fatalf("successful force reload left HTTP port at %d, expected %d", got, port)
	}
}

func TestEmbedDisallowsFullConfigReload(t *testing.T) {
	old := embedMode
	SetEmbedMode(true)
	defer SetEmbedMode(old)
	req := httptest.NewRequest("PUT", "/?force=true", strings.NewReader(`{"payload":"port: 12345"}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	configRouter().ServeHTTP(rec, req)
	if rec.Code != 405 {
		t.Fatalf("embedded PUT status = %d, want 405", rec.Code)
	}
}

func TestFullConfigReloadWithoutForceKeepsExistingHTTPPort(t *testing.T) {
	old := embedMode
	SetEmbedMode(false)
	defer SetEmbedMode(old)
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	current := l.Addr().(*net.TCPAddr).Port
	l.Close()
	listener.ReCreateHTTP(current, tunnel.Tunnel)
	defer listener.ReCreateHTTP(0, tunnel.Tunnel)
	if listener.GetPorts().Port != current {
		t.Fatal("could not create initial listener")
	}
	payload := "port: 0\nallow-lan: false\nmode: rule\nproxies: []\nproxy-groups: []\nrules:\n  - MATCH,DIRECT\n"
	body, _ := json.Marshal(map[string]string{"payload": payload})
	req := httptest.NewRequest("PUT", "/", strings.NewReader(string(body)))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	configRouter().ServeHTTP(rec, req)
	if rec.Code != 204 {
		t.Fatalf("PUT status=%d body=%s", rec.Code, rec.Body.String())
	}
	if got := listener.GetPorts().Port; got != current {
		t.Fatalf("unforced reload changed port from %d to %d", current, got)
	}
}

// The app owns embedded listeners/TUN and must not create one during ApplyConfig.
func TestEmbeddedApplyConfigDoesNotRecreateListener(t *testing.T) {
	listener.ReCreateHTTP(0, tunnel.Tunnel)
	defer listener.ReCreateHTTP(0, tunnel.Tunnel)
	cfg, err := executor.ParseWithBytes([]byte("port: 37371\nmode: rule\nproxies: []\nproxy-groups: []\nrules:\n  - MATCH,DIRECT\n"))
	if err != nil {
		t.Fatal(err)
	}
	executor.ApplyConfig(cfg, true)
	if got := listener.GetPorts().Port; got != 0 {
		t.Fatalf("embedded ApplyConfig unexpectedly created listener on %d", got)
	}
}
