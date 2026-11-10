//go:build windows

package core

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/Microsoft/go-winio"
	"github.com/stretchr/testify/require"
)

// The desktop host opens a pipe and hands its name to the core: StartServer
// dials it, answers a method call over it and returns when the host goes away.
// A pipe this test opens itself keeps the host's own instance out of reach.
func TestStartServerAnswersAMethodCallOverThePipe(t *testing.T) {
	path := fmt.Sprintf(`\\.\pipe\flclash-ipc-test-%d-%d`, os.Getpid(), time.Now().UnixNano())
	listener, err := winio.ListenPipe(path, nil)
	require.NoError(t, err)
	t.Cleanup(func() { _ = listener.Close() })

	connMu.Lock()
	previousConn := conn
	connMu.Unlock()
	t.Cleanup(func() {
		connMu.Lock()
		conn = previousConn
		connMu.Unlock()
	})

	var accepted sync.WaitGroup
	accepted.Add(1)
	hosted := make(chan net.Conn, 1)
	go func() {
		defer accepted.Done()
		host, err := listener.Accept()
		if err != nil {
			return
		}
		hosted <- host
	}()

	// The core dials, so it serves the side the host holds; the host's own
	// release path is not what this exercises.
	isInit.Store(false)
	go StartServer(path)
	accepted.Wait()

	var host net.Conn
	select {
	case host = <-hosted:
	case <-time.After(10 * time.Second):
		t.Fatal("the core never dialed the pipe")
	}
	t.Cleanup(func() { _ = host.Close() })

	call, err := json.Marshal(MethodCall{
		ID:        "call-1",
		Method:    connectionCountMethod,
		Arguments: json.RawMessage(`{}`),
	})
	require.NoError(t, err)
	if _, err := writeFrame(host, frame{head: call}); err != nil {
		t.Fatalf("writing the call over the pipe: %v", err)
	}

	answer, err := readFrame(host)
	require.NoError(t, err, "a method call over the pipe is answered")
	var response MethodResponse
	require.NoError(t, json.Unmarshal(answer, &response))
	require.Equal(t, "call-1", response.ID, "the answer names the call that was sent")
	require.Nil(t, response.Error)

	// The host going away is the core's cue to stop serving.
	require.NoError(t, host.Close())
	require.Eventually(t, func() bool {
		connMu.Lock()
		defer connMu.Unlock()
		return conn == nil
	}, 10*time.Second, 10*time.Millisecond, "serve returns with no connection installed")
}
