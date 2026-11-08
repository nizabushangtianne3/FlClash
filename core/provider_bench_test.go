package core

import (
	"fmt"
	"path/filepath"
	"testing"

	"github.com/metacubex/mihomo/component/resource"
	cp "github.com/metacubex/mihomo/constant/provider"
	rp "github.com/metacubex/mihomo/rules/provider"
	"github.com/metacubex/mihomo/tunnel"
)

func BenchmarkProviderListDispatch(b *testing.B) {
	providers := make(map[string]cp.RuleProvider, 100)
	for index := range 100 {
		providers[fmt.Sprintf("provider-%03d", index)] = rp.NewRuleSetProvider(
			fmt.Sprintf("provider-%03d", index),
			cp.Domain,
			cp.TextRule,
			0,
			resource.NewFileVehicle(filepath.Join(b.TempDir(), fmt.Sprintf("provider-%03d.txt", index))),
			[]string{"MATCH,DIRECT"},
			nil,
			nil,
		)
	}
	tunnel.UpdateRules(nil, nil, providers)
	b.Cleanup(func() { tunnel.UpdateRules(nil, nil, nil) })

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		data := answerBytes(MethodCall{ID: "benchmark", Method: providerListMethod})
		if len(data) == 0 {
			b.Fatal("empty provider answer")
		}
	}
}
