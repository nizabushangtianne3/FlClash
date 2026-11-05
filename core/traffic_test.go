package core

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestTrafficStatsFrameMatchesTheEnvelope(t *testing.T) {
	call := &MethodCall{
		ID:        "traffic",
		Method:    trafficStatsMethod,
		Arguments: []byte(`{"only-proxy":true}`),
	}
	want, err := json.Marshal(MethodResponse{
		ID:     "traffic",
		Result: handleGetTrafficStats(TrafficParams{OnlyProxy: true}),
	})
	require.NoError(t, err)
	require.Equal(t, want, handleMethodCall(call))

	stats := handleGetTrafficStats(TrafficParams{OnlyProxy: true})
	anonymous := &MethodCall{Method: trafficStatsMethod, Arguments: call.Arguments}
	require.Equal(t, stats.frameFor(""), handleMethodCall(anonymous))
}
