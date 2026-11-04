package core

import (
	"io"
	"os"
	"testing"
	"time"
)

// The message batcher flushes every interval for the whole test binary, so any
// benchmark longer than one interval would report a send failure for the
// connection no test installed. The discard connection keeps those flushes
// quiet; delivery-failure tests and captureFrames swap their own conn over it.
type discardIPCConn struct{}

func (discardIPCConn) Read([]byte) (int, error)         { return 0, io.EOF }
func (discardIPCConn) Write(p []byte) (int, error)      { return len(p), nil }
func (discardIPCConn) Close() error                     { return nil }
func (discardIPCConn) SetWriteDeadline(time.Time) error { return nil }

func TestMain(m *testing.M) {
	previous := swapConn(discardIPCConn{})
	code := m.Run()
	swapConn(previous)
	os.Exit(code)
}
