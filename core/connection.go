package core

import (
	"strconv"
	"sync"

	"github.com/metacubex/mihomo/common/jsonutil"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func handleGetTrafficStats(params TrafficParams) *TrafficStats {
	up, down := statistic.DefaultManager.NowTraffic(params.OnlyProxy)
	totalUp, totalDown := statistic.DefaultManager.TotalTraffic(params.OnlyProxy)
	return &TrafficStats{Up: up, Down: down, TotalUp: totalUp, TotalDown: totalDown}
}

func handleResetTraffic() {
	statistic.DefaultManager.ResetStatistic()
}

// The host keeps the rows it was last answered, so a poll answers with what
// moved instead of the whole table again.
type ConnectionsQuery struct {
	Resync bool `json:"resync"`
}

type ConnectionDelta struct {
	Added   []*statistic.TrackerInfo `json:"added"`
	Removed []string                 `json:"removed"`
	Count   int                      `json:"count"`
}

// MarshalJSON writes the rows with the Core's own connection table encoder, so
// the answer does not pay for a second reflection pass.
func (d *ConnectionDelta) MarshalJSON() ([]byte, error) {
	return d.appendDocument(make([]byte, 0, d.documentSize())), nil
}

// document implements frameWriter. The rows are encoded with the Core's own
// connection table encoder, so the answer does not pay for a second reflection
// pass over them.
func (d *ConnectionDelta) document() []byte {
	return d.appendDocument(make([]byte, 0, d.documentSize()))
}

func (d *ConnectionDelta) documentSize() int {
	size := 96 + len(d.Removed)*40
	for _, info := range d.Added {
		if info == nil {
			size += 4
			continue
		}
		size += rowAnswerSize(info)
	}
	return size
}

func (d *ConnectionDelta) appendDocument(dst []byte) []byte {
	buf := append(dst, `{"added":[`...)
	for i, info := range d.Added {
		if i > 0 {
			buf = append(buf, ',')
		}
		if info == nil {
			buf = append(buf, 'n', 'u', 'l', 'l')
			continue
		}
		buf = info.AppendJSON(buf)
	}
	buf = append(buf, `],"removed":[`...)
	for i, id := range d.Removed {
		if i > 0 {
			buf = append(buf, ',')
		}
		buf = jsonutil.AppendString(buf, id)
	}
	buf = append(buf, `],"count":`...)
	buf = strconv.AppendInt(buf, int64(d.Count), 10)
	return append(buf, '}')
}

func rowAnswerSize(info *statistic.TrackerInfo) int {
	metadata := info.Metadata
	size := 700 + len(metadata.Host) + len(metadata.Process) + len(metadata.ProcessPath) +
		len(metadata.SrcIPASN) + len(metadata.DstIPASN) + len(metadata.InName) +
		len(metadata.InUser) + len(metadata.RematchName) + len(metadata.SpecialProxy) +
		len(metadata.SpecialRules) + len(metadata.RemoteDst) + len(metadata.SniffHost)
	for _, geo := range metadata.SrcGeoIP {
		size += len(geo) + 4
	}
	for _, geo := range metadata.DstGeoIP {
		size += len(geo) + 4
	}
	for _, chain := range info.Chain {
		size += len(chain) + 4
	}
	for _, chain := range info.ProviderChain {
		size += len(chain) + 4
	}
	return size + len(info.Rule) + len(info.RulePayload)
}

type connectionRow struct {
	tracker    statistic.Tracker
	id         string
	generation uint64
}

var connectionRows = struct {
	mu         sync.Mutex
	rows       map[statistic.Tracker]*connectionRow
	order      []*connectionRow
	generation uint64
	// members is the table generation the last walk saw. A poll whose table
	// has neither gained nor lost a member answers what that walk already
	// proved instead of walking the table again.
	members uint64
}{rows: map[statistic.Tracker]*connectionRow{}}

func newConnectionRow(tracker statistic.Tracker, info *statistic.TrackerInfo) *connectionRow {
	return &connectionRow{
		tracker: tracker,
		id:      info.UUID.String(),
	}
}

func handleGetConnections(query ConnectionsQuery) *ConnectionDelta {
	connectionRows.mu.Lock()
	defer connectionRows.mu.Unlock()

	manager := statistic.DefaultManager
	members := manager.Generation()
	// Steady state: nothing joined or left since the last walk, so the answer
	// is the one that walk already proved. A resync answers the whole table on
	// purpose, and the table size is checked alongside the generation because
	// the bump follows the map operation it reports.
	if !query.Resync && members == connectionRows.members && manager.Size() == len(connectionRows.order) {
		return &ConnectionDelta{Count: len(connectionRows.order)}
	}

	connectionRows.generation++

	delta := &ConnectionDelta{}
	statistic.DefaultManager.Range(func(tracker statistic.Tracker) bool {
		info := tracker.Info()
		row := connectionRows.rows[tracker]
		if row == nil {
			row = newConnectionRow(tracker, info)
			connectionRows.rows[tracker] = row
			connectionRows.order = append(connectionRows.order, row)
			delta.Added = append(delta.Added, info)
		} else if query.Resync {
			delta.Added = append(delta.Added, info)
		}
		row.generation = connectionRows.generation
		delta.Count++
		return true
	})
	// What the poll did not see is gone: the manager is the only witness of a
	// close, and the live order compacts in place rather than walking the map.
	live := connectionRows.order[:0]
	for _, row := range connectionRows.order {
		if row.generation != connectionRows.generation {
			if !query.Resync {
				delta.Removed = append(delta.Removed, row.id)
			}
			delete(connectionRows.rows, row.tracker)
			continue
		}
		live = append(live, row)
	}
	connectionRows.order = live
	connectionRows.members = members
	return delta
}

// connectionCount is a document of one value, so a dashboard that only polls
// the number of live rows skips MethodResponse reflection.
type connectionCount int

// document implements frameWriter.
func (count connectionCount) document() []byte {
	return strconv.AppendInt(make([]byte, 0, 8), int64(count), 10)
}

func handleGetConnectionCount() connectionCount {
	return connectionCount(statistic.DefaultManager.Size())
}

func handleCloseConnections() {
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		_ = c.Close()
		return true
	})
}

func handleResetConnections() {
	resolver.ResetConnection()
}

// A network change clears rather than waits out the TTLs: mihomo serves an
// expired entry once more before it refreshes it.
func handleClearDnsCache() {
	configMu.Lock()
	defer configMu.Unlock()
	dns.ClearAll()
}

// handleNetworkChanged is how the desktop host reports a new network, which
// Android's NetworkObserver reports through handleResetNetwork.
func handleNetworkChanged() {
	handleClearDnsCache()
	// Only a new network can have changed what the system supports, and the
	// cached answer is what the next config parse reads.
	config.ResetIPV6Support()
}

// A connection that went out over a network the device has left hangs until
// TCP gives up on it, and so do the DNS clients' pooled connections.
func handleResetNetwork() {
	handleCloseConnections()
	handleNetworkChanged()
}

// A connection that is already gone is closed as far as the host is concerned.
func handleCloseConnection(params IDParams) error {
	if c := statistic.DefaultManager.Get(params.ID); c != nil {
		_ = c.Close()
	}
	return nil
}
