package core

import (
	"io"
	"net"
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"

	"github.com/stretchr/testify/require"
)

func TestProxyOnlyTrafficLeavesOutADirectProxyOfAnyName(t *testing.T) {
	direct := outbound.NewDirectWithOption(outbound.DirectOption{Name: "直连"})
	reject := outbound.NewRejectWithOption(outbound.RejectOption{Name: "HK"})
	tunnel.UpdateProxies(map[string]C.Proxy{
		"直连": adapter.NewProxy(direct),
		"HK": adapter.NewProxy(reject),
	}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })

	for _, test := range []struct {
		outbound C.ProxyAdapter
		proxied  int64
	}{
		{direct, 0},
		{reject, 5},
	} {
		statistic.DefaultManager.ResetStatistic()
		local, remote := net.Pipe()
		go func() { _, _ = io.Copy(io.Discard, remote) }()
		tracker := statistic.NewTCPTracker(
			outbound.NewConn(local, test.outbound),
			statistic.DefaultManager,
			&C.Metadata{},
			nil,
			0,
			0,
			true,
		)

		if _, err := tracker.Write([]byte("hello")); err != nil {
			t.Fatalf("write through %s: %v", test.outbound.Name(), err)
		}
		_ = tracker.Close()
		_ = remote.Close()

		all, _ := statistic.DefaultManager.TotalTraffic(false)
		proxied, _ := statistic.DefaultManager.TotalTraffic(true)
		if all != 5 || proxied != test.proxied {
			t.Errorf("%s: total %d, proxied %d; want 5 and %d", test.outbound.Name(), all, proxied, test.proxied)
		}
	}
	statistic.DefaultManager.ResetStatistic()
}

type blockedCloseTracker struct {
	statistic.Tracker
	id    string
	order chan string
}

func (t *blockedCloseTracker) ID() string { return t.id }

func (t *blockedCloseTracker) Info() *statistic.TrackerInfo {
	return &statistic.TrackerInfo{Metadata: &C.Metadata{}}
}

func (t *blockedCloseTracker) Close() error {
	t.order <- "close"
	return nil
}

func TestResetNetworkClosesConnectionsBeforeResettingPools(t *testing.T) {
	order := make(chan string, 2)
	tracker := &blockedCloseTracker{
		id:    "network-change-connection",
		order: order,
	}
	resetNetwork([]statistic.Tracker{tracker}, func() {
		order <- "reset"
	})

	require.Equal(t, "close", <-order)
	require.Equal(t, "reset", <-order)
}
