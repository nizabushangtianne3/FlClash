package core

import (
	"fmt"
	"io"
	"net"
	"testing"

	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
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
