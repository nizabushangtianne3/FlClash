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

	// A resync answers the whole table again, but the field snapshots it keeps
	// per row stay valid, so only a row whose metadata moved pays for a rebuild.
	allocations := testing.AllocsPerRun(20, func() {
		resynced := handleGetConnections(ConnectionsQuery{Resync: true})
		if len(resynced.Added) != 2 || resynced.Count != 2 {
			t.Fatal("a resync answers every live row")
		}
	})
	require.LessOrEqual(t, allocations, float64(8))

	first.Info().Metadata.Process = "wget"
	resynced := handleGetConnections(ConnectionsQuery{Resync: true})
	require.Len(t, resynced.Added, 2, "a resync re-sends every live row")
	for _, row := range resynced.Added {
		if row.UUID == first.Info().UUID {
			require.Equal(t, "wget", row.Metadata.Process,
				"a row whose metadata moved is re-sent with the new fields")
		}
	}

	_ = first.Close()
	removed := handleGetConnections(ConnectionsQuery{})
	require.Equal(t, []string{first.Info().UUID.String()}, removed.Removed)
	require.Equal(t, 1, removed.Count)
}

// The host reads the answer as a delta map: the rows it has not been sent,
// the ids that left and the total. The reflection writer used to produce that
// document, so the keys and the row shape are the contract this test keeps.
func TestConnectionDeltaAnswersWhatTheHostReads(t *testing.T) {
	first := newConnectionDeltaTracker(t, &C.Metadata{NetWork: C.TCP, Host: "first.example.com"})
	defer func() { _ = first.Close() }()
	second := newConnectionDeltaTracker(t, &C.Metadata{NetWork: C.TCP, Host: "second.example.com"})
	defer func() { _ = second.Close() }()

	delta := handleGetConnections(ConnectionsQuery{Resync: true})

	// The answer reaches the host as its own frame, so the envelope and the
	// row shape are both what this decodes.
	var frame struct {
		ID     string `json:"id"`
		Result struct {
			Added   []map[string]any `json:"added"`
			Removed []string         `json:"removed"`
			Count   int              `json:"count"`
		} `json:"result"`
	}
	response, err := json.Marshal(MethodResponse{ID: "call-1", Result: delta})
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal(response, &frame))
	require.Equal(t, response, delta.frameFor("call-1"))
	anonymous, err := json.Marshal(MethodResponse{Result: delta})
	require.NoError(t, err)
	require.Equal(t, anonymous, delta.frameFor(""))
	require.Equal(t, "call-1", frame.ID)

	document := struct {
		Added   []map[string]any `json:"added"`
		Removed []string         `json:"removed"`
		Count   int              `json:"count"`
	}{frame.Result.Added, frame.Result.Removed, frame.Result.Count}
	require.Len(t, document.Added, 2)
	require.Empty(t, document.Removed)
	require.Equal(t, 2, document.Count)

	hosts := make([]string, 0, len(document.Added))
	for _, row := range document.Added {
		metadata, ok := row["metadata"].(map[string]any)
		require.True(t, ok, "a row carries its metadata: %v", row)
		require.Equal(t, "tcp", metadata["network"])
		hosts = append(hosts, metadata["host"].(string))
		for _, key := range []string{"id", "start", "upload", "download", "chains", "rule", "rulePayload"} {
			require.Contains(t, row, key)
		}
	}
	require.ElementsMatch(t, []string{"first.example.com", "second.example.com"}, hosts)

	_ = first.Close()
	gone := handleGetConnections(ConnectionsQuery{})
	require.Equal(t, []string{first.Info().UUID.String()}, gone.Removed)

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
				data, err := json.Marshal(handleGetConnections(ConnectionsQuery{}))
				if err != nil || len(data) == 0 {
					b.Fatalf("answer: %v", err)
				}
			}
		})
	}
}

func BenchmarkGetConnectionsResyncFrame(b *testing.B) {
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
				data := handleGetConnections(ConnectionsQuery{Resync: true}).frameFor("benchmark")
				if len(data) == 0 {
					b.Fatal("empty answer")
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
