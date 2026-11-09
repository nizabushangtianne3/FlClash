//go:build !cgo && !android

package core

import (
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// Every dial through a looping dialer fails, so one report has to stand for
// the whole burst; a host that got one per attempt would read a flood.
func TestReportDialerLoopAnswersOnceForTheBurst(t *testing.T) {
	fake := &fakeConn{}
	previous := swapConn(fake)
	defer swapConn(previous)

	const looping = "loop-report-probe"
	reportDialerLoop(looping)
	reportDialerLoop(looping)

	if !waitForWrittenPayload(t, fake, looping) {
		t.Fatal("a dialer loop was never reported to the host")
	}
	time.Sleep(4 * messageBatchInterval)

	require.Equal(t, 1, strings.Count(writtenText(fake), looping),
		"a second report inside the interval reached the host")
}
