package core

import (
	"net/netip"
	"strconv"
	"slices"
	"sync"

	"github.com/gofrs/uuid/v5"
	"github.com/metacubex/mihomo/common/jsonutil"
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

// MarshalJSON implements json.Marshaler.
//
// Reflection called a marshaler for the uuid, the addresses and the enums of
// every answered row, and each handed back a fresh slice, so the one answer a
// page open gets cost three thousand allocations. The rows now go out the way
// the Core's own connection table encoder writes them, straight into one
// buffer. The field set and their escaping stay pinned by
// TestConnectionDeltaAnswersWhatTheHostReads.
func (d *ConnectionDelta) MarshalJSON() ([]byte, error) {
	return d.appendJSON(make([]byte, 0, d.answerSize())), nil
}

// answerSize counts the bytes the answer takes: the row scaffold once and the
// long fields on top of it, so appending a row grows nothing; a longer escape
// than any here costs one reallocation.
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

// frameFor writes the response envelope around the answer, so the one buffer
// that holds the table is also the frame the transport sends. The json writer
// would build the envelope around the answer and then copy the whole document
// a second time on its way out.
func (d *ConnectionDelta) frameFor(id string) []byte {
	buf := make([]byte, 0, d.answerSize()+len(id)+24)
	buf = append(buf, `{"id":`...)
	buf = jsonutil.AppendString(buf, id)
	buf = append(buf, `,"result":`...)
	buf = d.appendJSON(buf)
	return append(buf, '}')
}

// rowAnswerSize reports the bytes one row takes in the answer: the scaffold of
// its fixed fields, plus the fields a subscription can make long.
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
