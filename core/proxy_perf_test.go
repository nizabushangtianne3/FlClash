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
func BenchmarkHandleGetProxies(b *testing.B) {
	for _, groupCount := range []int{20, 200} {
		for _, memberCount := range []int{20} {
			b.Run(fmt.Sprintf("groups=%d/members=%d", groupCount, memberCount), func(b *testing.B) {
				members := make([]string, memberCount)
				for index := range members {
					members[index] = fmt.Sprintf("member-%03d", index)
				}

				names := make([]string, 0, groupCount)
				proxies := make(map[string]C.Proxy, groupCount)
				for index := range groupCount {
					name := fmt.Sprintf("group-%03d", index)
					names = append(names, name)
					proxies[name] = selectorGroup(b, name, members...)
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
					_ = handleGetProxies()
				}
			})
		}
	}
}
