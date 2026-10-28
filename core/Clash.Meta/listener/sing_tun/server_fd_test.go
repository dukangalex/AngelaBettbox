//go:build linux

package sing_tun

import (
	"errors"
	"testing"

	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/tunnel"
	"golang.org/x/sys/unix"
)

func TestNewClosesUnclaimedDescriptorOnValidationError(t *testing.T) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	fd := fds[0]
	fds[0] = -1
	t.Cleanup(func() {
		if fds[0] >= 0 {
			_ = unix.Close(fds[0])
		}
		_ = unix.Close(fds[1])
	})

	listener, err := New(LC.Tun{FileDescriptor: fd, DNSMode: "invalid"}, tunnel.Tunnel)
	if err == nil {
		if listener != nil {
			_ = listener.Close()
		}
		t.Fatal("expected invalid DNS mode to fail")
	}
	if listener != nil {
		_ = listener.Close()
		t.Fatal("listener should not be returned for invalid DNS mode")
	}

	if _, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); !errors.Is(err, unix.EBADF) {
		t.Fatalf("descriptor %d should be closed after construction failed, got %v", fd, err)
	}
}
