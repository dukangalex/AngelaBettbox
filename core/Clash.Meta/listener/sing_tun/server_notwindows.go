//go:build !windows

package sing_tun

import (
	tun "github.com/metacubex/sing-tun"
	"golang.org/x/sys/unix"
)

func tunNew(options tun.Options) (tun.Tun, error) {
	return tun.New(options)
}

// closeTunFD releases a detached Unix file descriptor that was never adopted
// by a TUN listener.
func closeTunFD(fd int) error {
	return unix.Close(fd)
}
