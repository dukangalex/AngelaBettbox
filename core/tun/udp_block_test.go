package tun

import (
	"net"
	"testing"

	"github.com/metacubex/mihomo/constant"
)

type fakeTunnel struct {
	tcpCalls int
	udpCalls int
	natCalls int
}

func (f *fakeTunnel) HandleTCPConn(net.Conn, *constant.Metadata) { f.tcpCalls++ }

func (f *fakeTunnel) HandleUDPPacket(constant.UDPPacket, *constant.Metadata) {
	f.udpCalls++
}

func (f *fakeTunnel) NatTable() constant.NatTable {
	f.natCalls++
	return nil
}

type fakePacket struct {
	dropped bool
}

func (p *fakePacket) Data() []byte                            { return []byte{1} }
func (p *fakePacket) WriteBack([]byte, net.Addr) (int, error) { return 0, nil }
func (p *fakePacket) Drop()                                   { p.dropped = true }
func (p *fakePacket) LocalAddr() net.Addr                     { return nil }

func TestUDPBlockTunnelDropsUDPOnly(t *testing.T) {
	inner := &fakeTunnel{}
	handler := udpBlockTunnel{inner}

	packet := &fakePacket{}
	handler.HandleUDPPacket(packet, &constant.Metadata{})
	if !packet.dropped {
		t.Error("packet.Drop() was not called")
	}
	if inner.udpCalls != 0 {
		t.Errorf("wrapped tunnel received %d UDP packets, want 0", inner.udpCalls)
	}

	handler.HandleTCPConn(nil, &constant.Metadata{})
	if inner.tcpCalls != 1 {
		t.Errorf("wrapped tunnel received %d TCP connections, want 1", inner.tcpCalls)
	}

	_ = handler.NatTable()
	if inner.natCalls != 1 {
		t.Errorf("NatTable called %d times on wrapped tunnel, want 1", inner.natCalls)
	}
}
