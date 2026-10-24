package core

import (
	"encoding/json"
	"fmt"
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

func newConnectionDeltaTracker(t *testing.T, metadata *C.Metadata) statistic.Tracker {
	t.Helper()

	local, remote := net.Pipe()
	t.Cleanup(func() {
		_ = local.Close()
		_ = remote.Close()
	})
	go func() { _, _ = io.Copy(io.Discard, remote) }()
	return statistic.NewTCPTracker(
		outbound.NewConn(local, outbound.NewDirectWithOption(outbound.DirectOption{Name: "DIRECT"})),
		statistic.DefaultManager,
		metadata,
		nil,
		0,
		0,
		true,
	)
}

func TestConnectionDeltaAnswersWhatMoved(t *testing.T) {
	first := newConnectionDeltaTracker(t, &C.Metadata{NetWork: C.TCP, Host: "first.example.com"})
	defer func() { _ = first.Close() }()
	second := newConnectionDeltaTracker(t, &C.Metadata{NetWork: C.TCP, Host: "second.example.com"})
	defer func() { _ = second.Close() }()

	opened := handleGetConnections(ConnectionsQuery{Resync: true})
	require.Len(t, opened.Added, 2, "a table it has not answered before is answered whole")
	require.Equal(t, 2, opened.Count)
	require.Empty(t, opened.Removed)

	unchanged := handleGetConnections(ConnectionsQuery{})
	require.Empty(t, unchanged.Added, "a poll that changes nothing answers with nothing")
	require.Empty(t, unchanged.Removed)
	require.Equal(t, 2, unchanged.Count)

	// A row gains what its first packet resolves, so it is answered again.
	first.Info().Metadata.Process = "curl"
	changed := handleGetConnections(ConnectionsQuery{})
	require.Len(t, changed.Added, 1)
	require.Equal(t, first.Info().UUID, changed.Added[0].UUID)
	require.Equal(t, 2, changed.Count)

	require.Empty(t, handleGetConnections(ConnectionsQuery{}).Added,
		"a row answered as changed is not answered twice")

	_ = first.Close()
	removed := handleGetConnections(ConnectionsQuery{})
	require.Equal(t, []string{first.Info().UUID.String()}, removed.Removed)
	require.Equal(t, 1, removed.Count)
}

// A resync answers the whole table, which is what the host used to be sent on
// every poll.
func BenchmarkGetConnectionsFull(b *testing.B) {
	for _, count := range []int{100, 500} {
		b.Run(fmt.Sprintf("connections=%d", count), func(b *testing.B) {
			trackers := benchmarkConnectionTrackers(b, count)
			b.Cleanup(func() {
				for _, tracker := range trackers {
					_ = tracker.Close()
				}
			})

			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if _, err := json.Marshal(handleGetConnections(ConnectionsQuery{Resync: true})); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

func benchmarkConnectionTrackers(b *testing.B, count int) []statistic.Tracker {
	b.Helper()

	trackers := make([]statistic.Tracker, count)
	for index := range trackers {
		local, remote := net.Pipe()
		b.Cleanup(func() {
			_ = local.Close()
			_ = remote.Close()
		})
		trackers[index] = statistic.NewTCPTracker(
			outbound.NewConn(local, outbound.NewDirectWithOption(outbound.DirectOption{Name: "DIRECT"})),
			statistic.DefaultManager,
			&C.Metadata{NetWork: C.TCP, Host: fmt.Sprintf("host-%d.example.com", index)},
			nil,
			0,
			0,
			true,
		)
	}
	return trackers
}

func BenchmarkGetConnectionsDelta(b *testing.B) {
	for _, count := range []int{100, 500} {
		b.Run(fmt.Sprintf("connections=%d", count), func(b *testing.B) {
			trackers := benchmarkConnectionTrackers(b, count)
			b.Cleanup(func() {
				for _, tracker := range trackers {
					_ = tracker.Close()
				}
			})
			_ = handleGetConnections(ConnectionsQuery{Resync: true})

			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if _, err := json.Marshal(handleGetConnections(ConnectionsQuery{})); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

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

	if got := <-order; got != "close" {
		t.Fatalf("first reset network action = %q, want close", got)
	}
	if got := <-order; got != "reset" {
		t.Fatalf("second reset network action = %q, want reset", got)
	}
}
