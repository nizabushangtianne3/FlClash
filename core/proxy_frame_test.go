package core

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/jsonutil"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/stretchr/testify/require"
)

// liveGroup is a group type whose adapter is not an outbound group, which is
// the one row no slot can key: its document is encoded live on every answer.
type liveGroup struct {
	name string
	now  string
}

func (g *liveGroup) Name() string        { return g.name }
func (g *liveGroup) Type() C.AdapterType { return C.Selector }
func (g *liveGroup) Addr() string        { return "" }
func (g *liveGroup) SupportUDP() bool    { return false }
func (g *liveGroup) SupportUOT() bool    { return false }
func (g *liveGroup) ProxyInfo() C.ProxyInfo {
	return C.ProxyInfo{}
}
func (g *liveGroup) MarshalJSON() ([]byte, error) {
	return g.AppendJSON(nil), nil
}
func (g *liveGroup) AppendJSON(dst []byte) []byte {
	dst = append(dst, `{"type":"Selector","name":`...)
	dst = jsonutil.AppendString(dst, g.name)
	dst = append(dst, `,"now":`...)
	dst = jsonutil.AppendString(dst, g.now)
	return append(dst, '}')
}
func (g *liveGroup) DialContext(context.Context, *C.Metadata) (C.Conn, error) {
	return nil, errors.New("live group is not dialable")
}
func (g *liveGroup) ListenPacketContext(context.Context, *C.Metadata) (C.PacketConn, error) {
	return nil, errors.New("live group is not dialable")
}
func (g *liveGroup) IsL3Protocol(*C.Metadata) bool { return false }
func (g *liveGroup) Unwrap(*C.Metadata, bool) C.Proxy {
	return nil
}
func (g *liveGroup) Close() error { return nil }

func proxyViewOf(t *testing.T, frame []byte, name string) map[string]any {
	t.Helper()
	var decoded proxiesFrame
	require.NoError(t, json.Unmarshal(frame, &decoded))
	raw, exist := decoded.Result.Proxies[name]
	require.True(t, exist, "the answer carries %s", name)
	view := map[string]any{}
	require.NoError(t, json.Unmarshal(raw, &view))
	return view
}

// The answer is a pure function of the table and the documents, so an
// unchanged one answers with the frame it answered last time instead of
// reassembling it, and every mutation the answer carries rebuilds it.
func TestProxiesFrameAnswersTheSameBytesUntilSomethingMoves(t *testing.T) {
	provider := newCachingProvider("subscription", "member-a", "member-b")
	group := proxyGroupOver(t, "group", "selector", []cp.ProxyProvider{provider})

	tunnel.UpdateProxies(map[string]C.Proxy{"group": group}, nil)
	config.SetProxyNameList([]string{"group"})
	t.Cleanup(func() {
		tunnel.UpdateProxies(nil, nil)
		config.SetProxyNameList(nil)
	})

	first := answerFrame(handleGetProxies(), "call")
	require.Contains(t, string(first), `"now":"member-a"`)

	second := answerFrame(handleGetProxies(), "call")
	if string(second) != string(first) {
		t.Fatalf("an unchanged table answered %s, want the document it answered with", second)
	}
	// The steady state builds nothing but the answer struct and the envelope:
	// the document rides the cache, and the transport writes it beside the
	// envelope rather than joined with it.
	call := &MethodCall{ID: "call", Method: proxyListMethod}
	steadyAllocations := testing.AllocsPerRun(20, func() {
		if answer := handleMethodCall(call); len(answer.document) == 0 {
			t.Fatal("empty answer")
		}
	})
	require.LessOrEqual(t, steadyAllocations, float64(2))

	// Another call id asks for another envelope around the same table.
	other := answerFrame(handleGetProxies(), "other")
	require.Contains(t, string(other), `"id":"other"`)
	require.Contains(t, string(other), `"now":"member-a"`)
	// The host names every call afresh, so the cached document is keyed on the
	// table and not on the call: another id carries the same table bytes.
	require.Equal(t, decodeProxiesFrame(t, first).Result, decodeProxiesFrame(t, other).Result)
	require.NotEqual(t, string(first), string(other))

	selectable, ok := adapterAs[outboundgroup.SelectAble](group)
	require.True(t, ok)
	require.NoError(t, selectable.Set("member-b"))
	moved := answerFrame(handleGetProxies(), "call")
	require.Contains(t, string(moved), `"now":"member-b"`,
		"a moved selection has to reach the answer even though it changed no name list")

	provider.setProxies("member-a", "member-c")
	reloaded := answerFrame(handleGetProxies(), "call")
	require.Contains(t, string(reloaded), `"member-c"`,
		"a provider reload rewrites the member list behind the same document")

	// A rebuilt table carries new rows, so the cached frame is not it.
	node := namedProxy("member-a")
	sibling := proxyGroupOver(t, "group-2", "selector", []cp.ProxyProvider{provider})
	tunnel.UpdateProxies(map[string]C.Proxy{"group": group, "group-2": sibling, "member-a": node}, nil)
	config.SetProxyNameList([]string{"group", "group-2"})
	grown := answerFrame(handleGetProxies(), "call")
	require.Contains(t, string(grown), `"name":"group-2"`)
	require.Contains(t, string(grown), `"name":"member-a"`)
	require.Contains(t, proxyViewOf(t, grown, "group"), "all")
	all := decodeProxiesFrame(t, grown).Result.All
	require.Equal(t, []string{"group", "group-2"}, all)
}

// A group type no slot can key stays on the live path: its document changes
// without the table or the name list moving, which no key can carry.
func TestProxiesAnswerEncodesALiveGroupOnEveryAnswer(t *testing.T) {
	group := &liveGroup{name: "group", now: "member-a"}
	tunnel.UpdateProxies(map[string]C.Proxy{"group": adapter.NewProxy(group)}, nil)
	config.SetProxyNameList([]string{"group"})
	t.Cleanup(func() {
		tunnel.UpdateProxies(nil, nil)
		config.SetProxyNameList(nil)
	})

	first := answerFrame(handleGetProxies(), "call")
	require.Equal(t, "member-a", proxyViewOf(t, first, "group")["now"])

	group.now = "member-b"
	second := answerFrame(handleGetProxies(), "call")
	require.Equal(t, "member-b", proxyViewOf(t, second, "group")["now"],
		"a live document is not served from the frame cache")
}

// A selection that moves away and back has to reach the answer both times: the
// key is a counter that only ever moves forward, so a counter alone cannot tell
// "back to where it was" from "never left".
func TestProxiesFrameFollowsASelectionThatMovesBack(t *testing.T) {
	provider := newCachingProvider("subscription", "member-a", "member-b")
	group := proxyGroupOver(t, "group", "selector", []cp.ProxyProvider{provider})

	tunnel.UpdateProxies(map[string]C.Proxy{"group": group}, nil)
	config.SetProxyNameList([]string{"group"})
	t.Cleanup(func() {
		tunnel.UpdateProxies(nil, nil)
		config.SetProxyNameList(nil)
	})

	selectable, ok := adapterAs[outboundgroup.SelectAble](group)
	require.True(t, ok)

	readNow := func() string {
		t.Helper()
		return proxyViewOf(t, answerFrame(handleGetProxies(), "call"), "group")["now"].(string)
	}

	require.Equal(t, "member-a", readNow())

	require.NoError(t, selectable.Set("member-b"))
	require.Equal(t, "member-b", readNow())

	// Back to the first member: the counter moved twice, the document has to
	// have moved with it, not be served as the one that was cached first.
	require.NoError(t, selectable.Set("member-a"))
	require.Equal(t, "member-a", readNow())

	// And once more, so a single stale slot cannot pass for a steady state.
	require.NoError(t, selectable.Set("member-b"))
	require.Equal(t, "member-b", readNow())
}
