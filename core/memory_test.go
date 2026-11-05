package core

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestMemoryStatsFrameMatchesTheEnvelope(t *testing.T) {
	stats := MemoryStats{
		Rss:          1,
		HeapInuse:    2,
		HeapIdle:     3,
		StackInuse:   4,
		RuntimeOther: 5,
	}

	withID, err := json.Marshal(MethodResponse{ID: "memory", Result: &stats})
	require.NoError(t, err)
	require.Equal(t, withID, stats.frameFor("memory"))

	withoutID, err := json.Marshal(MethodResponse{Result: &stats})
	require.NoError(t, err)
	require.Equal(t, withoutID, stats.frameFor(""))
}
