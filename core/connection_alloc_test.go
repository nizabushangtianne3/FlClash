//go:build !race

package core

import (
	"encoding/json"
	"net"
	"testing"

	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
	"github.com/stretchr/testify/require"
)

func TestConnectionDeltaEncodingAllocatesOnlyTheAnswerBuffer(t *testing.T) {
	local, remote := net.Pipe()
	t.Cleanup(func() {
		_ = local.Close()
		_ = remote.Close()
	})
	tracker := statistic.NewTCPTracker(
		outbound.NewConn(local, outbound.NewDirectWithOption(outbound.DirectOption{Name: "DIRECT"})),
		statistic.DefaultManager,
		&C.Metadata{NetWork: C.TCP, Host: "first.example.com"},
		nil, 0, 0, true,
	)
	t.Cleanup(func() { _ = tracker.Close() })

	_, _ = handleGetConnections(ConnectionsQuery{Resync: true}).Added, 0

	allocations := testing.AllocsPerRun(20, func() {
		data, err := json.Marshal(handleGetConnections(ConnectionsQuery{}))
		if err != nil || len(data) == 0 {
			t.Fatalf("answer: %v", err)
		}
	})
	require.LessOrEqual(t, allocations, float64(3))
}
