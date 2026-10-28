package route

import (
	"testing"

	LC "github.com/metacubex/mihomo/listener/config"
)

func TestPointerOrDefaultTunDNSMode(t *testing.T) {
	defaultTun := LC.Tun{DNSMode: "native"}

	if got := pointerOrDefaultTun(&tunSchema{}, defaultTun); got.DNSMode != "native" {
		t.Fatalf("omitted dns-mode = %q, want default native", got.DNSMode)
	}

	if got := pointerOrDefaultTun(&tunSchema{DNSMode: stringPointer("hijack")}, defaultTun); got.DNSMode != "hijack" {
		t.Fatalf("explicit dns-mode = %q, want hijack", got.DNSMode)
	}
}

func stringPointer(s string) *string { return &s }
