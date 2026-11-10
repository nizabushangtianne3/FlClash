package core

import (
	"context"
	"net"
	"net/netip"
	"testing"
	"time"

	"github.com/metacubex/mihomo/constant"
	"github.com/stretchr/testify/require"
)

// A proxy group carries UDP as well as TCP: the rule picks the group, the
// group selects a member, and the member answers the datagram. A real Selector
// over a compatible provider of direct members carries one here, so the group's
// own packet path is what the round trip walks.
func TestAProxyGroupCarriesADatagramToItsSelectedMember(t *testing.T) {
	server, err := net.ListenPacket("udp", "127.0.0.1:0")
	require.NoError(t, err)
	serverPort := server.LocalAddr().(*net.UDPAddr).Port
	t.Cleanup(func() { _ = server.Close() })
	go func() {
		buf := make([]byte, 2048)
		for {
			n, addr, err := server.ReadFrom(buf)
			if err != nil {
				return
			}
			_, _ = server.WriteTo(append([]byte("group:"), buf[:n]...), addr)
		}
	}()

	group := selectorGroup(t, "group", "node-a", "node-b")

	metadata := &constant.Metadata{
		NetWork: constant.UDP,
		Type:    constant.INNER,
		DstIP:   netip.MustParseAddr("127.0.0.1"),
		DstPort: uint16(serverPort),
	}
	pc, err := group.ListenPacketContext(context.Background(), metadata)
	require.NoError(t, err, "a group answers its member's packet listener")
	t.Cleanup(func() { _ = pc.Close() })

	_, err = pc.WriteTo([]byte("query"), net.UDPAddrFromAddrPort(netip.AddrPortFrom(
		netip.MustParseAddr("127.0.0.1"),
		uint16(serverPort),
	)))
	require.NoError(t, err)

	deadline := time.Now().Add(5 * time.Second)
	require.NoError(t, pc.SetReadDeadline(deadline))
	buf := make([]byte, 2048)
	n, _, err := pc.ReadFrom(buf)
	require.NoError(t, err, "the member the group selected answered the datagram")
	require.Equal(t, "group:query", string(buf[:n]))
}
