package core

import (
	"fmt"
	"testing"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

func BenchmarkRefreshRouteVersions(b *testing.B) {
	proxies := make(map[string]constant.Proxy, 200)
	for index := range 200 {
		name := fmt.Sprintf("group-%03d", index)
		proxies[name] = selectorOver(b, name, namedProxy(fmt.Sprintf("node-%03d-a", index)), namedProxy(fmt.Sprintf("node-%03d-b", index)))
	}
	names := make([]string, 0, len(proxies))
	for name := range proxies {
		names = append(names, name)
	}
	config.SetProxyNameList(names)
	tunnel.UpdateProxies(proxies, nil)
	b.Cleanup(func() {
		tunnel.UpdateProxies(nil, nil)
		config.SetProxyNameList(nil)
	})
	handleWatchRoute(true, 0)
	b.Cleanup(stopRouteWatch)

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		refreshRouteVersions()
	}
}
