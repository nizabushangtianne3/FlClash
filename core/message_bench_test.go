package core

import (
	"fmt"
	"testing"
	"time"

	"github.com/metacubex/mihomo/log"
)

// benchmarkBatchMessages assembles the event mix a busy host streams: logs
// dominate, every established connection adds a full row, DNS queries and
// traffic counters ride the same queues.
func benchmarkBatchMessages(b *testing.B, count int) []Message {
	trackers := benchmarkConnectionTrackers(b, count/8+1)
	messages := make([]Message, 0, count)
	for i := 0; i < count; i++ {
		switch i % 8 {
		case 0, 1, 2, 3, 4:
			messages = append(messages, Message{Type: LogMessage, Data: log.Event{
				LogLevel: log.INFO,
				Payload:  fmt.Sprintf("[TCP] connected to %d.example.com:%d", i, 40000+i),
			}})
		case 5:
			messages = append(messages, Message{Type: RequestMessage, Data: trackers[i/8]})
		case 6:
			messages = append(messages, Message{Type: DnsMessage, Data: DnsQuery{
				Domain: "www.example.com", Type: "A", Initiator: "192.168.1.2",
				Upstream: "8.8.8.8", Answers: []string{"1.2.3.4", "5.6.7.8"},
				Delay: 21, Time: time.Unix(1730000000, 0).UnixMicro(),
			}})
		case 7:
			messages = append(messages, Message{Type: RequestTrafficMessage, Data: []RequestTraffic{
				{Id: "01000000-0000-4000-8000-000000000000", Upload: 1024, Download: 4096},
			}})
		}
	}
	return messages
}

// BenchmarkSendMessageBatch is what every 16ms flush of the event queues
// costs the core process.
func BenchmarkSendMessageBatch(b *testing.B) {
	for _, count := range []int{16, 64} {
		b.Run(fmt.Sprintf("messages=%d", count), func(b *testing.B) {
			messages := benchmarkBatchMessages(b, count)
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				sendMessageBatch(messages)
			}
		})
	}
}
