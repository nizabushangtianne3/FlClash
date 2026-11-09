//go:build !cgo && !android

package core

import (
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/log"
)

func writtenText(fake *fakeConn) string {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	return fake.written.String()
}

func waitForWrittenPayload(t *testing.T, fake *fakeConn, payload string) bool {
	t.Helper()
	// The batcher flushes on its own interval, so a loaded host can take a few
	// windows to see the frame; the bound is the one the flood tests use.
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if strings.Contains(writtenText(fake), payload) {
			return true
		}
		time.Sleep(2 * time.Millisecond)
	}
	return false
}

// The subscription is fed directly rather than through mihomo's logger because
// the pump's own level check only matters once the threshold has moved past an
// event the logger had already accepted; racing that transition against the
// pump would let scheduling decide the outcome instead of the code.
func TestLogPumpDropsWhatTheLevelNoLongerAllowsAndKeepsReading(t *testing.T) {
	previous := log.Level()
	log.SetLevel(log.INFO)
	t.Cleanup(func() { log.SetLevel(previous) })

	fake := &fakeConn{}
	conn := swapConn(fake)
	defer swapConn(conn)

	events := make(chan log.Event)
	pump := &logPump{subscription: events}
	go pump.run()
	t.Cleanup(func() {
		pump.stopped.Store(true)
		close(events)
	})

	events <- log.Event{LogLevel: log.DEBUG, Payload: "event below the level"}
	events <- log.Event{LogLevel: log.INFO, Payload: "event at the level"}

	if !waitForWrittenPayload(t, fake, "event at the level") {
		t.Fatal("the pump withheld an event the host's level allows")
	}
	time.Sleep(4 * messageBatchInterval)
	if strings.Contains(writtenText(fake), "event below the level") {
		t.Error("an event below the level reached the host")
	}

	pump.stopped.Store(true)
	events <- log.Event{LogLevel: log.INFO, Payload: "event after the stop"}

	time.Sleep(4 * messageBatchInterval)
	if strings.Contains(writtenText(fake), "event after the stop") {
		t.Error("a stopped pump kept forwarding events")
	}
}
