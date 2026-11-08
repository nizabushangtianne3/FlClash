package core

import "testing"

func BenchmarkTrafficPoll(b *testing.B) {
	call := &MethodCall{ID: "benchmark", Method: trafficStatsMethod, Arguments: []byte(`{"only-proxy":true}`)}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		call.ID = "traffic"
		if data := answerBytes(*call); len(data) == 0 {
			b.Fatal("empty traffic answer")
		}
	}
}
