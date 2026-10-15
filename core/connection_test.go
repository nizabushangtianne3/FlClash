package core

import (
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type blockedCloseTracker struct {
	statistic.Tracker
	id     string
	release chan struct{}
	closed  chan struct{}
}

func (t *blockedCloseTracker) ID() string { return t.id }

func (t *blockedCloseTracker) Info() *statistic.TrackerInfo {
	return &statistic.TrackerInfo{Metadata: &C.Metadata{}}
}

func (t *blockedCloseTracker) Close() error {
	<-t.release
	close(t.closed)
	return nil
}

func TestResetNetworkClosesOldConnectionsBeforeItReturns(t *testing.T) {
	tracker := &blockedCloseTracker{
		id:      "network-change-connection",
		release: make(chan struct{}),
		closed:  make(chan struct{}),
	}
	statistic.DefaultManager.Join(tracker)
	t.Cleanup(func() {
		statistic.DefaultManager.Leave(tracker)
	})

	handleResetNetwork()

	closedBeforeRelease := false
	select {
	case <-tracker.closed:
		closedBeforeRelease = true
	default:
	}
	close(tracker.release)
	select {
	case <-tracker.closed:
	case <-time.After(time.Second):
		t.Fatal("old-network connection did not finish closing")
	}
	if !closedBeforeRelease {
		t.Fatal("resetNetwork returned before the old-network connection was closed")
	}
}
