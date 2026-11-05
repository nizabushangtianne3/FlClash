package core

import (
	"net/netip"
	"slices"
	"strconv"
	"sync"

	"github.com/gofrs/uuid/v5"
	"github.com/metacubex/mihomo/common/jsonutil"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func handleGetTraffic(params TrafficParams) Traffic {
	up, down := statistic.DefaultManager.NowTraffic(params.OnlyProxy)
	return Traffic{Up: up, Down: down}
}

func handleGetTotalTraffic(params TrafficParams) Traffic {
	up, down := statistic.DefaultManager.TotalTraffic(params.OnlyProxy)
	return Traffic{Up: up, Down: down}
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
		} else if query.Resync {
			delta.Added = append(delta.Added, info)
		}
		row.generation = connectionRows.generation
		delta.Count++
		return true
	})
	for id, row := range connectionRows.rows {
		if row.generation != connectionRows.generation {
			if !query.Resync {
				delta.Removed = append(delta.Removed, id.String())
			}
			delete(connectionRows.rows, id)
		}
	}
	return delta
}

func handleGetConnectionCount() int {
	count := 0
	statistic.DefaultManager.Range(func(statistic.Tracker) bool {
		count++
		return true
	})
	return count
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
