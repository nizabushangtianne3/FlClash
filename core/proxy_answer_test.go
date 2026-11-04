package core

import (
	"encoding/json"
	"testing"

	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/stretchr/testify/require"
)

// The proxies answer is hand encoded, so its shape is pinned the way the
// connections answer is: the host decodes proxies[name] into group views and
// reads all as the display order.
func TestProxiesAnswerAnswersWhatTheHostReads(t *testing.T) {
	proxies := map[string]C.Proxy{
		"member-a": namedProxy("member-a"),
		"group-1":  selectorGroup(t, "group-1", "member-a", "member-b"),
	}
	tunnel.UpdateProxies(proxies, nil)
	config.SetProxyNameList([]string{globalProxyName, "group-1"})
	t.Cleanup(func() {
		tunnel.UpdateProxies(nil, nil)
		config.SetProxyNameList(nil)
	})

	frame := struct {
		ID     string `json:"id"`
		Result struct {
			Proxies map[string]map[string]any `json:"proxies"`
			All     []string                  `json:"all"`
		} `json:"result"`
	}{}
	require.NoError(t, json.Unmarshal(handleGetProxies().frameFor("call-1"), &frame))
	require.Equal(t, "call-1", frame.ID)

	group := frame.Result.Proxies["group-1"]
	require.Equal(t, "Selector", group["type"])
	require.Equal(t, "group-1", group["name"])
	require.Contains(t, group, "now")
	require.Contains(t, group, "all")

	node := frame.Result.Proxies["member-a"]
	require.Equal(t, "member-a", node["name"])
	require.Equal(t, "Direct", node["type"])
	require.NotContains(t, node, "provider-name")

	require.Equal(t, []string{"group-1"}, frame.Result.All)

	// The sorted name list is cached on the tunnel snapshot's identity, so a
	// table that changes identity answers with the new members, not the cached
	// list of the snapshot it replaced.
	proxies["member-b"] = namedProxy("member-b")
	tunnel.UpdateProxies(proxies, nil)
	frame.Result.Proxies = nil
	require.NoError(t, json.Unmarshal(handleGetProxies().frameFor("call-2"), &frame))
	require.Contains(t, frame.Result.Proxies, "member-b",
		"the answer carries the snapshot it was built from, not a stale name list")

	// One answer, one buffer: the hand written encoder costs a slice of names,
	// the answer itself, and little else.
	allocations := testing.AllocsPerRun(20, func() {
		if data := handleGetProxies().frameFor("call-1"); len(data) == 0 {
			t.Fatal("empty answer")
		}
	})
	require.LessOrEqual(t, allocations, float64(4))
}
