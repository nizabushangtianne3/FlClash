package core

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/netip"
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
	require.Equal(t, connectionCount(2), handleGetConnectionCount())
	require.Empty(t, opened.Removed)

	unchanged := handleGetConnections(ConnectionsQuery{})
	require.Empty(t, unchanged.Added, "a poll that changes nothing answers with nothing")
	require.Empty(t, unchanged.Removed)
	require.Equal(t, 2, unchanged.Count)

	// A steady poll answers what the last walk proved: the tracker table has
	// neither gained nor lost a member, so the walk does not run again. The
	// answer a row carries is the snapshot its tracker was created with, which
	// nothing in the tunnel rewrites, so there is nothing to re-compare.
	allocations := testing.AllocsPerRun(20, func() {
		steady := handleGetConnections(ConnectionsQuery{})
		if len(steady.Added) != 0 || len(steady.Removed) != 0 || steady.Count != 2 {
			t.Fatal("a poll on a table nothing joined or left answers the same delta")
		}
	})
	require.LessOrEqual(t, allocations, float64(1))

	// A resync answers the whole table again, whatever the last walk proved.
	allocations = testing.AllocsPerRun(20, func() {
		resynced := handleGetConnections(ConnectionsQuery{Resync: true})
		if len(resynced.Added) != 2 || resynced.Count != 2 {
			t.Fatal("a resync answers every live row")
		}
	})
	require.LessOrEqual(t, allocations, float64(8))

	// A field written straight into a live tracker's snapshot after the fact is
	// not a movement the poll watches for: the snapshot is created once and the
	// row is answered from whatever the next walk reads.
	first.Info().Metadata.Process = "resolved"
	require.Empty(t, handleGetConnections(ConnectionsQuery{}).Added)
	resynced := handleGetConnections(ConnectionsQuery{Resync: true})
	require.Len(t, resynced.Added, 2, "a resync re-sends every live row")
	for _, row := range resynced.Added {
		if row.UUID == first.Info().UUID {
			require.Equal(t, "resolved", row.Metadata.Process,
				"a resync carries what the tracker holds at read time")
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
	require.Equal(t, string(response), string(answerFrame(delta, "call-1")))
	anonymous, err := json.Marshal(MethodResponse{Result: delta})
	require.NoError(t, err)
	require.Equal(t, string(anonymous), string(answerFrame(delta, "")))
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

// A row's answer is preallocated from rowAnswerSize, so the hint has to cover
// every field the row encoder writes. GeoIP carries the most: a rule that
// matched a GEOIP rule fills two string slices the estimate must count.
func TestRowAnswerSizeCoversEveryFieldTheEncoderWrites(t *testing.T) {
	tracker := newConnectionDeltaTracker(t, &C.Metadata{
		NetWork:      C.TCP,
		Type:         C.HTTP,
		Host:         "sized.example.com",
		SrcIP:        netip.MustParseAddr("203.0.113.7"),
		DstIP:        netip.MustParseAddr("198.51.100.9"),
		SrcPort:      41234,
		DstPort:      443,
		InIP:         netip.MustParseAddr("127.0.0.1"),
		InPort:       1234,
		InName:       "http",
		InUser:       "user",
		Process:      "curl",
		ProcessPath:  "/usr/bin/curl",
		Uid:          10234,
		SpecialProxy: "GLOBAL",
		SpecialRules: "GEOIP,CN",
		RemoteDst:    "cn.example.net:443",
		SniffHost:    "sniffed.example.com",
		SrcGeoIP:     []string{"CN", "HK"},
		DstGeoIP:     []string{"US"},
		SrcIPASN:     "AS4134 Chinanet",
		DstIPASN:     "AS15169 Google",
		DNSMode:      C.DNSNormal,
	})
	defer func() { _ = tracker.Close() }()

	info := tracker.Info()
	info.Rule = "GEOIP"
	info.RulePayload = "CN"
	info.Chain = []string{"DIRECT", "GLOBAL"}
	info.UploadTotal.Store(2048)
	info.DownloadTotal.Store(4096)

	encoded := info.AppendJSON(nil)
	require.GreaterOrEqual(t, rowAnswerSize(info), len(encoded),
		"an under-estimate grows the answer buffer on every resync")
	require.Contains(t, string(encoded), `"sourceGeoIP":["CN","HK"]`)
	require.Contains(t, string(encoded), `"destinationGeoIP":["US"]`)
}

// A row the manager could not describe is answered as null rather than
// dropped, so the host keeps the row's place in the table.
func TestConnectionDeltaAnswersANilRowAsNull(t *testing.T) {
	delta := &ConnectionDelta{Added: []*statistic.TrackerInfo{nil}, Count: 1}

	answer := answerFrame(delta, "call")
	require.Contains(t, string(answer), `"added":[null]`)
	require.Contains(t, string(answer), `"count":1`)
}

// The Android path joins the two resets into one call; the tunnel has to end
// up with no rows and a cleared DNS cache.
func TestHandleResetNetworkClosesTheRowsItAnswers(t *testing.T) {
	tracker := newConnectionDeltaTracker(t, &C.Metadata{NetWork: C.TCP, Host: "reset.example.com"})
	require.Equal(t, 1, statistic.DefaultManager.Size())
	rowID := tracker.ID()

	handleResetNetwork()

	require.Zero(t, statistic.DefaultManager.Size(),
		"a network change closes the connections that went out over the old one")
	require.Nil(t, statistic.DefaultManager.Get(rowID),
		"the closed row is gone from the manager, not just closed")
}

// Two rows leaving in one poll answer both ids, so the host clears both
// without waiting for a second poll.
func TestConnectionDeltaAnswersEveryRowThatLeft(t *testing.T) {
	first := newConnectionDeltaTracker(t, &C.Metadata{NetWork: C.TCP, Host: "first.example.com"})
	second := newConnectionDeltaTracker(t, &C.Metadata{NetWork: C.TCP, Host: "second.example.com"})

	require.Len(t, handleGetConnections(ConnectionsQuery{Resync: true}).Added, 2)

	_ = first.Close()
	_ = second.Close()
	delta := handleGetConnections(ConnectionsQuery{})
	// The manager walks a map, so which id comes first is not deterministic.
	require.ElementsMatch(t,
		[]string{first.Info().UUID.String(), second.Info().UUID.String()},
		delta.Removed, "both ids leave in the answer that follows")
	require.Zero(t, delta.Count)

	answer := answerFrame(delta, "call")
	require.Contains(t, string(answer), `"removed":["`)
	require.Contains(t, string(answer), `","`)
}

// Closing one row by id is the row the connection list's close button sends.
func TestHandleCloseConnectionClosesTheNamedRow(t *testing.T) {
	tracker := newConnectionDeltaTracker(t, &C.Metadata{NetWork: C.TCP, Host: "closable.example.com"})
	id := tracker.Info().UUID.String()

	require.NoError(t, handleCloseConnection(IDParams{ID: id}))

	require.Nil(t, statistic.DefaultManager.Get(id), "the named row is closed")
	// A second close of the same id is a no-op, not an error.
	require.NoError(t, handleCloseConnection(IDParams{ID: id}))
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
				// The answer reaches the host as its own frame, so the
				// benchmark measures the frame path, not the reflection
				// envelope the shape test decodes it with.
				call := MethodCall{
					ID:        "benchmark",
					Method:    connectionListMethod,
					Arguments: json.RawMessage(`{}`),
				}
				if data := answerBytes(call); len(data) == 0 {
					b.Fatal("empty answer")
				}
			}
		})
	}
}

// The walk path is what a poll pays when the table moved: one connection left
// and another joined between two polls. Re-joining pre-built trackers keeps
// the churn itself out of what is measured.
func BenchmarkGetConnectionsDeltaWalk(b *testing.B) {
	for _, count := range []int{100, 500} {
		b.Run(fmt.Sprintf("connections=%d", count), func(b *testing.B) {
			trackers := benchmarkConnectionTrackers(b, count)
			b.Cleanup(func() {
				for _, tracker := range trackers {
					_ = tracker.Close()
				}
			})
			handleGetConnections(ConnectionsQuery{Resync: true})

			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				statistic.DefaultManager.Leave(trackers[i%count])
				statistic.DefaultManager.Join(trackers[(i+1)%count])
				answerBytes(MethodCall{
					ID:        "benchmark",
					Method:    connectionListMethod,
					Arguments: json.RawMessage(`{}`),
				})
			}
		})
	}
}

func BenchmarkGetConnectionCount(b *testing.B) {
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
				if got := int(handleGetConnectionCount()); got != count {
					b.Fatalf("count = %d, want %d", got, count)
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
				call := MethodCall{
					ID:        "benchmark",
					Method:    connectionListMethod,
					Arguments: json.RawMessage(`{"resync":true}`),
				}
				if data := answerBytes(call); len(data) == 0 {
					b.Fatal("empty answer")
				}
			}
		})
	}
}

func TestConnectionCountFrameMatchesTheEnvelope(t *testing.T) {
	first := newConnectionDeltaTracker(t, &C.Metadata{NetWork: C.TCP, Host: "count.example.com"})
	defer func() { _ = first.Close() }()

	count := handleGetConnectionCount()
	withID, err := json.Marshal(MethodResponse{ID: "call-1", Result: count})
	require.NoError(t, err)
	require.Equal(t, string(withID), string(answerFrame(count, "call-1")))
	anonymous, err := json.Marshal(MethodResponse{Result: count})
	require.NoError(t, err)
	require.Equal(t, string(anonymous), string(answerFrame(count, "")))
}

func BenchmarkConnectionCountDispatch(b *testing.B) {
	for _, count := range []int{100, 500} {
		b.Run(fmt.Sprintf("connections=%d", count), func(b *testing.B) {
			trackers := benchmarkConnectionTrackers(b, count)
			b.Cleanup(func() {
				for _, tracker := range trackers {
					_ = tracker.Close()
				}
			})
			call := &MethodCall{ID: "benchmark", Method: connectionCountMethod}

			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if data := answerBytes(*call); len(data) == 0 {
					b.Fatal("empty count answer")
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
