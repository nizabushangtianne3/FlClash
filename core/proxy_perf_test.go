//go:build !cgo && !android

package core

import (
	"fmt"
	"io"
	"testing"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

// The host re-reads the whole proxy table when a selection changes, and every
// group view travels with it, so this is what one of those round trips costs.
// The nodes=1000 case stands in for a large subscription, where the table is
// mostly leaf nodes rather than groups. The kind suffixes cover the group
// types a real profile mixes in; the kindless cases stay Selector so their
// names and numbers keep pairing across rounds.
func BenchmarkHandleGetProxies(b *testing.B) {
	for _, tc := range []struct {
		groups int
		member int
		nodes  int
		kind   string
	}{
		{groups: 20, member: 20},
		{groups: 200, member: 20},
		{groups: 200, member: 20, nodes: 1000},
		{groups: 200, member: 20, kind: "urltest"},
		{groups: 200, member: 20, nodes: 1000, kind: "urltest"},
		{groups: 200, member: 20, kind: "fallback"},
		{groups: 200, member: 20, kind: "loadbalance"},
	} {
		name := fmt.Sprintf("groups=%d/members=%d/nodes=%d", tc.groups, tc.member, tc.nodes)
		if tc.kind != "" {
			name += "/" + tc.kind
		}
		b.Run(name, func(b *testing.B) {
			members := make([]string, tc.member)
			for index := range members {
				members[index] = fmt.Sprintf("member-%03d", index)
			}

			names := make([]string, 0, tc.groups)
			proxies := make(map[string]C.Proxy, tc.groups+tc.nodes)
			for index := range tc.groups {
				name := fmt.Sprintf("group-%03d", index)
				names = append(names, name)
				proxies[name] = proxyGroup(b, name, tc.kind, members...)
			}
			for index := range tc.nodes {
				name := fmt.Sprintf("node-%04d", index)
				proxies[name] = namedProxy(name)
			}
			tunnel.UpdateProxies(proxies, nil)
			config.SetProxyNameList(names)
			b.Cleanup(func() {
				tunnel.UpdateProxies(nil, nil)
				config.SetProxyNameList(nil)
			})

			b.ReportAllocs()
			b.ResetTimer()
			call := &MethodCall{ID: "benchmark", Method: proxyListMethod}
			for i := 0; i < b.N; i++ {
				writeFrame(io.Discard, handleMethodCall(call))
			}
		})
	}
}

// The steady state answers from the cached document, so this is what a
// changed table pays: every group revalidated, one document rebuilt, the
// whole document reassembled and written beside its envelope.
func BenchmarkHandleGetProxiesMiss(b *testing.B) {
	for _, tc := range []struct {
		groups int
		member int
		nodes  int
		kind   string
	}{
		{groups: 200, member: 20, kind: "urltest"},
		{groups: 200, member: 20},
	} {
		name := fmt.Sprintf("groups=%d/members=%d/nodes=%d", tc.groups, tc.member, tc.nodes)
		if tc.kind != "" {
			name += "/" + tc.kind
		}
		b.Run(name, func(b *testing.B) {
			members := make([]string, tc.member)
			for index := range members {
				members[index] = fmt.Sprintf("member-%03d", index)
			}

			names := make([]string, 0, tc.groups)
			proxies := make(map[string]C.Proxy, tc.groups+tc.nodes)
			for index := range tc.groups {
				name := fmt.Sprintf("group-%03d", index)
				names = append(names, name)
				proxies[name] = proxyGroup(b, name, tc.kind, members...)
			}
			for index := range tc.nodes {
				name := fmt.Sprintf("node-%04d", index)
				proxies[name] = namedProxy(name)
			}
			tunnel.UpdateProxies(proxies, nil)
			config.SetProxyNameList(names)
			b.Cleanup(func() {
				tunnel.UpdateProxies(nil, nil)
				config.SetProxyNameList(nil)
			})

			ids := make([]string, b.N)
			for index := range ids {
				ids[index] = fmt.Sprintf("call-%d", index)
			}
			selectable, ok := adapterAs[outboundgroup.SelectAble](proxies[names[0]])
			if !ok {
				b.Fatal("the first group is not selectable")
			}

			call := MethodCall{ID: ids[0], Method: proxyListMethod}
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				// One moved selection is the smallest real change: the group
				// it names rebuilds its document, and the answer reassembles
				// the table around it.
				if err := selectable.Set(members[i%len(members)]); err != nil {
					b.Fatalf("select %s: %v", members[i%len(members)], err)
				}
				writeFrame(io.Discard, handleMethodCall(&call))
			}
		})
	}
}
