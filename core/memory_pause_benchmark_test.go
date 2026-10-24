package core

import (
	"runtime"
	"testing"
)

// Both pauses sit on paths the host drives: ReadMemStats on the dashboard's
// two-second poll, GC on every config switch. Measuring them is what settles
// whether either is worth trading latency for memory.

// heapLikeAConfig stands in for what a large subscription holds while it is
// parsed: thousands of small maps and strings, most of them live.
func heapLikeAConfig() [][]map[string]any {
	const proxies = 4000
	const fields = 12
	heap := make([][]map[string]any, 0, proxies)
	for i := 0; i < proxies; i++ {
		row := make([]map[string]any, 0, fields)
		for j := 0; j < fields; j++ {
			row = append(row, map[string]any{
				"name":   "node-name-that-is-unique",
				"type":   "vless",
				"server": "server.example.com",
				"uuid":   "2a70e3a9-b4ce-4f20-908d-e99950a0a611",
			})
		}
		heap = append(heap, row)
	}
	return heap
}

func BenchmarkReadMemStatsPause(b *testing.B) {
	heap := heapLikeAConfig()
	defer runtime.KeepAlive(heap)

	b.ResetTimer()
	var stats runtime.MemStats
	for i := 0; i < b.N; i++ {
		runtime.ReadMemStats(&stats)
	}
}

func BenchmarkRuntimeGCPause(b *testing.B) {
	heap := heapLikeAConfig()
	defer runtime.KeepAlive(heap)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		runtime.GC()
	}
}
