package core

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/component/resource"
	cp "github.com/metacubex/mihomo/constant/provider"
	rp "github.com/metacubex/mihomo/rules/provider"
	"github.com/stretchr/testify/require"
)

func TestProviderViewJSONMatchesEncoding(t *testing.T) {
	updateAt := time.Date(2026, 11, 6, 3, 4, 5, 123456789, time.UTC)
	views := []ExternalProvider{
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

	for _, view := range views {
		want, err := json.Marshal(view)
		require.NoError(t, err)
		require.Equal(t, want, appendExternalProviderJSON(nil, view))
	}
}

func TestProviderListFrameMatchesTheEnvelope(t *testing.T) {
	newRuleProvider := func(name string) cp.Provider {
		return rp.NewRuleSetProvider(
			name,
			cp.Domain,
			cp.TextRule,
			0,
			resource.NewFileVehicle(name+`.yaml`),
			[]string{"MATCH,DIRECT"},
			nil,
			nil,
		)
	}
	list := externalProviderEntryList{
		{name: `quote"path`, provider: newRuleProvider(`quote"path`)},
		{name: "rules", provider: newRuleProvider("rules")},
	}
	views := make([]ExternalProvider, 0, len(list))
	for _, entry := range list {
		view, err := toExternalProvider(entry.provider)
		require.NoError(t, err)
		views = append(views, view)
	}

	withID, err := json.Marshal(MethodResponse{ID: `quote"id`, Result: views})
	require.NoError(t, err)
	require.Equal(t, withID, list.frameFor(`quote"id`))

	withoutID, err := json.Marshal(MethodResponse{Result: views})
	require.NoError(t, err)
	require.Equal(t, withoutID, list.frameFor(""))
}

func TestEmptyProviderListFrameMatchesTheEnvelope(t *testing.T) {
	list := externalProviderEntryList{}

	want, err := json.Marshal(MethodResponse{ID: "providers", Result: []ExternalProvider{}})
	require.NoError(t, err)
	require.Equal(t, want, list.frameFor("providers"))
}
