package core

import (
	"net/netip"
	"slices"
	"sync"

	"github.com/gofrs/uuid/v5"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func handleGetTraffic(onlyStatisticsProxy bool) Traffic {
	up, down := statistic.DefaultManager.NowTraffic(onlyStatisticsProxy)
	return Traffic{Up: up, Down: down}
}

func handleGetTotalTraffic(onlyStatisticsProxy bool) Traffic {
	up, down := statistic.DefaultManager.TotalTraffic(onlyStatisticsProxy)
	return Traffic{Up: up, Down: down}
}

func handleGetTrafficStats(onlyStatisticsProxy bool) TrafficStats {
	up, down := statistic.DefaultManager.NowTraffic(onlyStatisticsProxy)
	totalUp, totalDown := statistic.DefaultManager.TotalTraffic(onlyStatisticsProxy)
	return TrafficStats{
		Up:        up,
		Down:      down,
		TotalUp:   totalUp,
		TotalDown: totalDown,
	}
}

func handleResetTraffic() {
	statistic.DefaultManager.ResetStatistic()
}

// The host keeps the rows it was last answered, so a poll answers with what
// moved instead of the whole table again. Encoding 500 rows cost 1.9ms and
// 1.8MB every time, while a row only joins, settles the fields its first
// packet fills in, and leaves.
type ConnectionsQuery struct {
	Resync bool `json:"resync"`
}

type ConnectionDelta struct {
	Added   []*statistic.TrackerInfo `json:"added"`
	Removed []string                 `json:"removed"`
	Count   int                      `json:"count"`
}

type connectionRow struct {
	host        string
	sniffHost   string
	dstIP       netip.Addr
	process     string
	processPath string
	uid         uint32
	inName      string
	inUser      string
	srcGeoIP    []string
	dstGeoIP    []string
	generation  uint64
}

var connectionRows = struct {
	mu         sync.Mutex
	rows       map[uuid.UUID]*connectionRow
	generation uint64
}{rows: map[uuid.UUID]*connectionRow{}}

// stale reports the fields a row can still gain after it was first answered.
// The tunnel settles everything else a row carries before it creates the
// tracker, having matched the rule, resolved the address the rule needed and
// sniffed the host by then; a UDP connection's first packet arrives later.
func (row *connectionRow) stale(info *statistic.TrackerInfo) bool {
	metadata := info.Metadata
	return metadata.Host != row.host ||
		metadata.SniffHost != row.sniffHost ||
		metadata.DstIP != row.dstIP ||
		metadata.Process != row.process ||
		metadata.ProcessPath != row.processPath ||
		metadata.Uid != row.uid ||
		metadata.InName != row.inName ||
		metadata.InUser != row.inUser ||
		!slices.Equal(metadata.SrcGeoIP, row.srcGeoIP) ||
		!slices.Equal(metadata.DstGeoIP, row.dstGeoIP)
}

func newConnectionRow(info *statistic.TrackerInfo) *connectionRow {
	metadata := info.Metadata
	return &connectionRow{
		host:        metadata.Host,
		sniffHost:   metadata.SniffHost,
		dstIP:       metadata.DstIP,
		process:     metadata.Process,
		processPath: metadata.ProcessPath,
		uid:         metadata.Uid,
		inName:      metadata.InName,
		inUser:      metadata.InUser,
		srcGeoIP:    slices.Clone(metadata.SrcGeoIP),
		dstGeoIP:    slices.Clone(metadata.DstGeoIP),
	}
}

func handleGetConnections(query ConnectionsQuery) *ConnectionDelta {
	connectionRows.mu.Lock()
	defer connectionRows.mu.Unlock()

	connectionRows.generation++
	if query.Resync {
		clear(connectionRows.rows)
	}

	delta := &ConnectionDelta{}
	statistic.DefaultManager.Range(func(tracker statistic.Tracker) bool {
		info := tracker.Info()
		row := connectionRows.rows[info.UUID]
		if row == nil {
			row = newConnectionRow(info)
			connectionRows.rows[info.UUID] = row
			delta.Added = append(delta.Added, info)
		} else if row.stale(info) {
			*row = *newConnectionRow(info)
			delta.Added = append(delta.Added, info)
		}
		row.generation = connectionRows.generation
		delta.Count++
		return true
	})
	for id, row := range connectionRows.rows {
		if row.generation != connectionRows.generation {
			delta.Removed = append(delta.Removed, id.String())
			delete(connectionRows.rows, id)
		}
	}
	return delta
}

func collectTrackers() []statistic.Tracker {
	var trackers []statistic.Tracker
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		trackers = append(trackers, c)
		return true
	})
	return trackers
}

func closeTrackers(trackers []statistic.Tracker) {
	for _, c := range trackers {
		_ = c.Close()
	}
}

func handleCloseConnections() bool {
	trackers := collectTrackers()
	safeGo("closeConnections", func() {
		closeTrackers(trackers)
	})
	return true
}

func handleResetConnections() bool {
	resolver.ResetConnection()
	return true
}

// A network change clears rather than waits out the TTLs: mihomo serves an
// expired entry once more before it refreshes it.
func handleClearDnsCache() {
	configMu.Lock()
	defer configMu.Unlock()
	dns.ClearAll()
}

// A connection that went out over a network the device has left hangs until
// TCP gives up on it, and so do the DNS clients' pooled connections.
func resetNetwork(trackers []statistic.Tracker, resetConnections func()) {
	closeTrackers(trackers)
	resetConnections()
}

func handleResetNetwork() {
	resetNetwork(collectTrackers(), func() {
		resolver.ResetConnection()
		handleClearDnsCache()
	})
}

func handleCloseConnection(connectionId string) bool {
	c := statistic.DefaultManager.Get(connectionId)
	if c == nil {
		return false
	}
	_ = c.Close()
	return true
}
