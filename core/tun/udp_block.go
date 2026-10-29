package tun

import (
	"github.com/metacubex/mihomo/constant"
)

// udpBlockTunnel wraps the core tunnel for the Android system-explicit
// "block all UDP inside the VPN" option. Every UDP packet the TUN listener
// hands up is dropped at ingress, before rule evaluation, so the block
// holds in rule, global and direct modes alike. TCP connections and the
// NAT table delegate to the wrapped tunnel unchanged. UDP DNS queries
// hijacked by the TUN listener itself are relayed to the core resolver
// before packets reach this handler, so name resolution through the app's
// own DNS keeps working; UDP toward any other destination, including
// external DNS resolvers, is dropped.
type udpBlockTunnel struct {
	constant.Tunnel
}

func (udpBlockTunnel) HandleUDPPacket(packet constant.UDPPacket, _ *constant.Metadata) {
	packet.Drop()
}
