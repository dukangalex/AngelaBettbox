package config

import (
	"testing"
)

func TestTunDNSModeParsingAndPreservingDefaults(t *testing.T) {
	for _, mode := range []string{"", "disabled", "native", "hijack"} {
		t.Run("mode="+mode, func(t *testing.T) {
			raw := DefaultRawConfig()
			raw.Tun.DNSMode = mode
			raw.Tun.DNSHijack = []string{"any:53"}
			raw.Tun.AutoRoute = true
			var general General
			if err := parseTun(raw.Tun, &DNS{}, &general); err != nil {
				t.Fatal(err)
			}
			if got := general.Tun.DNSMode; got != mode {
				t.Fatalf("mode = %q, want %q", got, mode)
			}
			if len(general.Tun.DNSHijack) != 1 || general.Tun.DNSHijack[0] != "any:53" || !general.Tun.AutoRoute {
				t.Fatalf("other settings changed: %#v", general.Tun)
			}
			same := general.Tun
			if !general.Tun.Equal(same) {
				t.Fatal("identical tun options should match")
			}
			same.DNSMode = "different"
			if general.Tun.Equal(same) {
				t.Fatal("dns-mode change must cause tun options to differ")
			}
		})
	}
}
