package core

import (
	"testing"

	"github.com/metacubex/mihomo/log"
)

// The class an event is queued under decides its latency, and classification
// runs once per event rather than once per batch.
func BenchmarkClassOfMessage(b *testing.B) {
	types := []MessageType{
		LogMessage,
		RequestMessage,
		DnsMessage,
		RequestTrafficMessage,
		DelayMessage,
		LoadedMessage,
		GeoUpdateMessage,
		RouteChangedMessage,
	}
	messages := make([]Message, len(types))
	for index, messageType := range types {
		var data any
		if messageType == LogMessage {
			data = log.Event{LogLevel: log.INFO, Payload: "benchmark"}
		}
		messages[index] = Message{Type: messageType, Data: data}
	}
	classes := make([]messageClass, len(types))

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		for index, message := range messages {
			classes[index] = classOfMessage(message)
		}
	}
	_ = classes
}
