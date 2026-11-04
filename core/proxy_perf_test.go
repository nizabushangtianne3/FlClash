package core

import (
	"fmt"
	"testing"

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
			for i := 0; i < b.N; i++ {
				_ = handleGetProxies().frameFor("benchmark")
			}
		})
	}
}
