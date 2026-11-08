package core

import (
	"net/netip"
	"slices"
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
	return d.appendJSON(make([]byte, 0, d.answerSize())), nil
}

// frameFor implements frameWriter. It writes the response envelope around the
// rows in the buffer that already encoded them, instead of copying the answer
// through MethodResponse reflection a second time.
func (d *ConnectionDelta) frameFor(id string) []byte {
	if id == "" {
		buf := append(make([]byte, 0, d.answerSize()+24), `{"result":`...)
		return append(d.appendJSON(buf), '}')
	}
	buf := make([]byte, 0, d.answerSize()+len(id)+32)
	buf = append(buf, `{"id":`...)
	buf = jsonutil.AppendString(buf, id)
	buf = append(buf, `,"result":`...)
	buf = d.appendJSON(buf)
	return append(buf, '}')
}

func (d *ConnectionDelta) answerSize() int {
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

func (d *ConnectionDelta) appendJSON(dst []byte) []byte {
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
	tracker     statistic.Tracker
	id          string
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
	rows       map[statistic.Tracker]*connectionRow
	order      []*connectionRow
	generation uint64
}{rows: map[statistic.Tracker]*connectionRow{}}

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

func newConnectionRow(tracker statistic.Tracker, info *statistic.TrackerInfo) *connectionRow {
	metadata := info.Metadata
	return &connectionRow{
		tracker:     tracker,
		id:          info.UUID.String(),
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

	delta := &ConnectionDelta{}
	statistic.DefaultManager.Range(func(tracker statistic.Tracker) bool {
		info := tracker.Info()
		row := connectionRows.rows[tracker]
		if row == nil {
			row = newConnectionRow(tracker, info)
			connectionRows.rows[tracker] = row
			connectionRows.order = append(connectionRows.order, row)
			delta.Added = append(delta.Added, info)
		} else if row.stale(info) {
			*row = *newConnectionRow(tracker, info)
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
	return delta
}

// connectionCount writes its own one-value envelope, so a dashboard that only
// polls the number of live rows skips MethodResponse reflection.
type connectionCount int

func (count connectionCount) frameFor(id string) []byte {
	buf := make([]byte, 0, len(id)+32)
	if id != "" {
		buf = append(buf, `{"id":`...)
		buf = jsonutil.AppendString(buf, id)
		buf = append(buf, `,"result":`...)
	} else {
		buf = append(buf, `{"result":`...)
	}
	buf = strconv.AppendInt(buf, int64(count), 10)
	return append(buf, '}')
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
