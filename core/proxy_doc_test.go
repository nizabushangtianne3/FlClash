package core

import (
	"encoding/json"
	"testing"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/stretchr/testify/require"
)

type groupDocView struct {
	Type  string   `json:"type"`
	Name  string   `json:"name"`
	Now   string   `json:"now"`
	Fixed string   `json:"fixed"`
	All   []string `json:"all"`
}

type proxiesFrame struct {
	ID     string `json:"id"`
	Result struct {
		Proxies map[string]json.RawMessage `json:"proxies"`
		All     []string                   `json:"all"`
	} `json:"result"`
}

func decodeProxiesFrame(t *testing.T, frame []byte) proxiesFrame {
	t.Helper()
	var decoded proxiesFrame
	require.NoError(t, json.Unmarshal(frame, &decoded))
	return decoded
}

// Every cached kind must answer with the document its group would encode
// live: a steady state copies bytes, and a pinned selection or a provider
// refresh — the two mutations that leave a trace in the document — has to
// reach the next answer even when Now() stays put.
func TestGroupDocsAnswerWhatTheirGroupsChange(t *testing.T) {
	for _, kind := range []string{"selector", "urltest", "fallback", "loadbalance"} {
		t.Run(kind, func(t *testing.T) {
			provider := newCachingProvider("subscription", "member-a", "member-b")
			group := proxyGroupOver(t, "group", kind, []cp.ProxyProvider{provider})

			tunnel.UpdateProxies(map[string]C.Proxy{"group": group}, nil)
			config.SetProxyNameList([]string{"group"})
			t.Cleanup(func() {
				tunnel.UpdateProxies(nil, nil)
				config.SetProxyNameList(nil)
			})

			first := handleGetProxies().frameFor("call")
			second := handleGetProxies().frameFor("call")
			require.Equal(t, string(first), string(second), "the steady state must copy bytes")

			doc := decodeGroupDoc(t, decodeProxiesFrame(t, first), "group")
			require.Equal(t, "group", doc.Name)
			require.Equal(t, []string{"member-a", "member-b"}, doc.All)
			if kind != "loadbalance" {
				require.Equal(t, groupNow(t, group), doc.Now,
					"the answered now must be the group's live selection")
			}

			if kind != "loadbalance" {
				selectable, ok := adapterAs[outboundgroup.SelectAble](group)
				require.True(t, ok)
				require.NoError(t, selectable.Set("member-b"))
				pinned := decodeGroupDoc(t, decodeProxiesFrame(t, handleGetProxies().frameFor("call")), "group")
				require.Equal(t, groupNow(t, group), pinned.Now)
				switch kind {
				case "selector":
					require.Equal(t, "member-b", pinned.Now)
				case "urltest", "fallback":
					require.Equal(t, "member-b", pinned.Fixed,
						"the pin has to reach the fixed field of the next answer")
				}
			}

			// A subscription refresh rewrites the member list behind the same
			// document, with the versions as the only signal it happened.
			provider.setProxies("member-a", "member-c")
			refreshed := decodeGroupDoc(t, decodeProxiesFrame(t, handleGetProxies().frameFor("call")), "group")
			require.Equal(t, []string{"member-a", "member-c"}, refreshed.All,
				"a provider reload must not be answered from the cached document")
			if kind != "loadbalance" {
				require.Equal(t, groupNow(t, group), refreshed.Now)
			}

			allocations := testing.AllocsPerRun(20, func() {
				if data := handleGetProxies().frameFor("call"); len(data) == 0 {
					t.Fatal("empty answer")
				}
			})
			require.LessOrEqual(t, allocations, float64(4))
		})
	}
}

func decodeGroupDoc(t *testing.T, frame proxiesFrame, name string) groupDocView {
	t.Helper()
	raw, exist := frame.Result.Proxies[name]
	require.True(t, exist)
	var doc groupDocView
	require.NoError(t, json.Unmarshal(raw, &doc))
	return doc
}
