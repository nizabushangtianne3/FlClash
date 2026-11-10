package core

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// The poll leaves the moment its context is cancelled: a caller that stops the
// core does not wait out the next tick to be answered.
func TestPollRouteLeavesWhenItsContextIsCancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	left := make(chan struct{})
	go func() {
		defer close(left)
		pollRoute(ctx)
	}()

	select {
	case <-left:
	case <-time.After(2 * time.Second):
		t.Fatal("the poll did not leave after its context was cancelled")
	}
}

// A poll whose context is still live keeps polling, and a cancel ends it.
func TestPollRouteKeepsPollingUntilItIsCancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	isRunning.Store(true)
	t.Cleanup(func() { isRunning.Store(false) })

	left := make(chan struct{})
	go func() {
		defer close(left)
		pollRoute(ctx)
	}()

	// Let it pass at least one tick boundary before cancelling.
	require.Never(t, func() bool {
		select {
		case <-left:
			return true
		default:
			return false
		}
	}, 100*time.Millisecond, 20*time.Millisecond,
		"a live poll must not leave on its own")

	// Cross one tick boundary: the poll runs its refresh and stays up.
	time.Sleep(routePollInterval + 200*time.Millisecond)
	require.Never(t, func() bool {
		select {
		case <-left:
			return true
		default:
			return false
		}
	}, 50*time.Millisecond, 10*time.Millisecond,
		"a poll that crossed a tick must still be running")

	cancel()
	select {
	case <-left:
	case <-time.After(2 * time.Second):
		t.Fatal("the poll did not leave after a cancel")
	}
}
