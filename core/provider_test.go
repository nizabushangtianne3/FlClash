package core

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/stretchr/testify/require"
)

func TestProviderListFrameMatchesTheEnvelope(t *testing.T) {
	updateAt := time.Date(2026, 11, 6, 3, 4, 5, 123456789, time.UTC)
	list := externalProviderList{
		{
			Name:             `quote"path`,
			Type:             "Proxy",
			VehicleType:      "HTTP",
			Count:            12,
			Path:             `D:\providers\node.yaml`,
			UpdateAt:         updateAt,
			SubscriptionInfo: &provider.SubscriptionInfo{Upload: 1, Download: 2, Total: 3, Expire: 4},
		},
		{
			Name:        "rules",
			Type:        "Rule",
			VehicleType: "File",
			Count:       3,
			Path:        "rules.yaml",
			UpdateAt:    updateAt,
		},
	}

	withID, err := json.Marshal(MethodResponse{ID: `quote"id`, Result: list})
	require.NoError(t, err)
	require.Equal(t, withID, list.frameFor(`quote"id`))

	withoutID, err := json.Marshal(MethodResponse{Result: list})
	require.NoError(t, err)
	require.Equal(t, withoutID, list.frameFor(""))
}

func TestEmptyProviderListFrameMatchesTheEnvelope(t *testing.T) {
	list := externalProviderList{}

	want, err := json.Marshal(MethodResponse{ID: "providers", Result: list})
	require.NoError(t, err)
	require.Equal(t, want, list.frameFor("providers"))
}
