package core

import "testing"

func BenchmarkMemoryStatsDispatch(b *testing.B) {
	call := &MethodCall{ID: "benchmark", Method: coreMemoryMethod}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		call.ID = "memory"
		if data := handleMethodCall(call); len(data) == 0 {
			b.Fatal("empty memory answer")
		}
	}
}
