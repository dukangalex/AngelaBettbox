package mieru

import (
	"net"
	"testing"
	"time"

	common "github.com/enfein/mieru/v3/apis/common"
	mc "github.com/enfein/mieru/v3/apis/constant"
	model "github.com/enfein/mieru/v3/apis/model"
	"github.com/metacubex/mihomo/adapter/inbound"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/transport/socks5"
)

type testUserConn struct{ net.Conn }

func (testUserConn) UserName() string { return "alice" }

type captureTunnel struct{ metadata chan *C.Metadata }

func (t *captureTunnel) HandleTCPConn(c net.Conn, m *C.Metadata)      { t.metadata <- m }
func (t *captureTunnel) HandleUDPPacket(p C.UDPPacket, m *C.Metadata) { t.metadata <- m; p.Drop() }
func (t *captureTunnel) NatTable() C.NatTable                         { return nil }

func TestMieruInboundUserAndNameTCPAndUDP(t *testing.T) {
	for _, tc := range []struct {
		name    string
		command byte
	}{{"tcp", mc.Socks5ConnectCmd}, {"udp", mc.Socks5UDPAssociateCmd}} {
		t.Run(tc.name, func(t *testing.T) {
			server, client := net.Pipe()
			defer client.Close()
			defer server.Close()
			client.SetDeadline(time.Now().Add(10 * time.Second))
			tunnel := &captureTunnel{metadata: make(chan *C.Metadata, 1)}
			done := make(chan struct{})
			go func() {
				defer close(done)
				Handle(testUserConn{server}, tunnel, &model.Request{Command: tc.command, DstAddr: model.AddrSpec{FQDN: "example.com", Port: 443}}, inbound.WithInName("listener-a"))
			}()
			if _, err := model.ReadSocks5Response(client); err != nil {
				t.Fatal(err)
			}
			if tc.command == mc.Socks5UDPAssociateCmd {
				payload, err := socks5.EncodeUDPPacket(socks5.ParseAddr("example.com:443"), []byte("test"))
				if err != nil {
					t.Fatal(err)
				}
				if _, err = common.NewPacketOverStreamTunnel(client).Write(payload); err != nil {
					t.Fatal(err)
				}
			}
			select {
			case m := <-tunnel.metadata:
				if m.InUser != "alice" || m.InName != "listener-a" {
					t.Errorf("got inbound user=%q name=%q, want alice and listener-a", m.InUser, m.InName)
				}
			case <-time.After(10 * time.Second):
				t.Fatal("no metadata delivered")
			}
			client.Close()
			select {
			case <-done:
			case <-time.After(10 * time.Second):
				t.Fatal("handler did not stop")
			}
		})
	}
}
