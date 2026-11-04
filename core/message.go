package core

import (
	"encoding/json"
	"strconv"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/common/jsonutil"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

const (
	messageBatchInterval = 48 * time.Millisecond
	messageBatchSize     = 64
	messageQueueSize     = 256
	messagePriorityBurst = 8
	messageEvictAttempts = 4
)

var (
	stateMessageQueue    = make(chan Message, messageQueueSize)
	priorityMessageQueue = make(chan Message, messageQueueSize)
	bulkMessageQueue     = make(chan Message, messageQueueSize)
	requestMessages      atomic.Bool
	dnsMessages          atomic.Bool
)

func init() {
	requestMessages.Store(true)
	dnsMessages.Store(true)
	go runMessageBatcher(stateMessageQueue, priorityMessageQueue, bulkMessageQueue, sendMessageBatch)
}

func handleStartRequestMessages() {
	requestMessages.Store(true)
}

func handleStopRequestMessages() {
	requestMessages.Store(false)
}

func handleStartDnsMessages() {
	dnsMessages.Store(true)
}

func handleStopDnsMessages() {
	dnsMessages.Store(false)
}

func messageInterestEnabled(messageType MessageType) bool {
	switch messageType {
	case RequestMessage:
		return requestMessages.Load()
	case DnsMessage:
		return dnsMessages.Load()
	default:
		return true
	}
}

type messageClass int

const (
	stateMessageClass messageClass = iota
	priorityMessageClass
	bulkMessageClass
	// Shares the bulk queue but never evicts from it: a lookup burst would
	// otherwise push out the request events the connection list is built from.
	yieldingBulkMessageClass
)

func classOfMessage(message Message) messageClass {
	switch message.Type {
	case LoadedMessage, GeoUpdateMessage, RouteChangedMessage:
		return stateMessageClass
	case LogMessage, RequestMessage:
		return bulkMessageClass
	case DnsMessage, RequestTrafficMessage:
		return yieldingBulkMessageClass
	default:
		return priorityMessageClass
	}
}

// Request and DNS events fire per connection and per query for as long as the
// Android service runs, engine or not; unheard, they are not worth encoding.
func sendMessage(messageType MessageType, data any) (queued bool) {
	if !hasEventListener() || !messageInterestEnabled(messageType) {
		return false
	}
	message := Message{Type: messageType, Data: data}
	switch classOfMessage(message) {
	case stateMessageClass:
		return enqueueState(stateMessageQueue, message)
	case bulkMessageClass:
		return enqueueLatest(bulkMessageQueue, message)
	case yieldingBulkMessageClass:
		return enqueueState(bulkMessageQueue, message)
	default:
		return enqueueLatest(priorityMessageQueue, message)
	}
}

func enqueueState(queue chan Message, message Message) bool {
	select {
	case queue <- message:
		return true
	default:
		return false
	}
}

func enqueueLatest(queue chan Message, message Message) bool {
	for attempt := 0; attempt < messageEvictAttempts; attempt++ {
		select {
		case queue <- message:
			return true
		default:
		}

		select {
		case <-queue:
		default:
		}
	}
	return false
}

func runMessageBatcher(
	stateMessages <-chan Message,
	priorityMessages <-chan Message,
	bulkMessages <-chan Message,
	send func([]Message),
) {
	timer := time.NewTimer(messageBatchInterval)
	if !timer.Stop() {
		<-timer.C
	}
	defer timer.Stop()

	var deadline <-chan time.Time
	batch := make([]Message, 0, messageBatchSize)

	flush := func() {
		if len(batch) == 0 {
			return
		}
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		deadline = nil
		// send must consume or copy the batch before returning; the batcher
		// reuses this slice for the next batch.
		send(batch)
		batch = batch[:0]
	}
	// A closed queue is set to nil so it never wins a select again.
	take := func(queue *<-chan Message, message Message, open bool) bool {
		if !open {
			*queue = nil
			return false
		}
		if len(batch) == 0 {
			timer.Reset(messageBatchInterval)
			deadline = timer.C
		}
		batch = append(batch, message)
		if len(batch) >= messageBatchSize {
			flush()
		}
		return true
	}

	priorityBurst := 0
	for stateMessages != nil || priorityMessages != nil || bulkMessages != nil {
		select {
		case message, open := <-stateMessages:
			take(&stateMessages, message, open)
			continue
		default:
		}

		// Give bulk events one guaranteed opportunity after a bounded priority
		// burst, while retaining priority preference under ordinary load.
		if priorityBurst >= messagePriorityBurst && bulkMessages != nil {
			priorityBurst = 0
			select {
			case message, open := <-bulkMessages:
				take(&bulkMessages, message, open)
				continue
			default:
			}
		}

		select {
		case message, open := <-priorityMessages:
			if take(&priorityMessages, message, open) {
				priorityBurst++
			}
			continue
		default:
		}

		select {
		case message, open := <-stateMessages:
			take(&stateMessages, message, open)
		case message, open := <-priorityMessages:
			if take(&priorityMessages, message, open) {
				priorityBurst++
			}
		case message, open := <-bulkMessages:
			take(&bulkMessages, message, open)
			priorityBurst = 0
		case <-deadline:
			flush()
		}
	}
	flush()
}

// The batch is written the way the connections table is: one hand encoder, no
// reflection between the queues and the frame. The wire bytes are pinned by
// TestMessageBatchMatchesReflection.
func encodeMessageBatch(messages []Message) []byte {
	buf := make([]byte, 0, encodedBatchSize(messages)+96)
	buf = append(buf, `{"method":`...)
	buf = jsonutil.AppendString(buf, string(messageMethod))
	buf = append(buf, `,"arguments":[`...)
	for i, message := range messages {
		if i > 0 {
			buf = append(buf, ',')
		}
		buf = appendMessageJSON(buf, message)
	}
	return append(buf, ']', '}')
}

func sendMessageBatch(messages []Message) {
	deliverEvent(encodeMessageBatch(messages))
}

func encodedBatchSize(messages []Message) int {
	size := 16 * len(messages)
	for _, message := range messages {
		switch message.Data.(type) {
		case statistic.Tracker:
			size += 640
		case DnsQuery:
			size += 256
		default:
			size += 128
		}
	}
	return size
}

// appendMessageJSON writes one {"type":...,"data":...} envelope. Every case
// completes its payload; the shared tail closes the envelope, so a case that
// returns early would clip it.
func appendMessageJSON(dst []byte, message Message) []byte {
	dst = append(dst, `{"type":`...)
	dst = jsonutil.AppendString(dst, string(message.Type))
	dst = append(dst, `,"data":`...)
	switch payload := message.Data.(type) {
	case nil:
		dst = append(dst, "null"...)
	case log.Event:
		// mihomo's log.Event carries no json tags and its level marshals
		// through MarshalText, so the capitalized and lowercase names are
		// both the wire contract.
		dst = append(dst, `{"LogLevel":`...)
		dst = jsonutil.AppendString(dst, payload.LogLevel.String())
		dst = append(dst, `,"Payload":`...)
		dst = jsonutil.AppendString(dst, payload.Payload)
		dst = append(dst, '}')
	case statistic.Tracker:
		if payload == nil {
			dst = append(dst, "null"...)
		} else {
			dst = payload.Info().AppendJSON(dst)
		}
	case DnsQuery:
		dst = appendDnsQueryJSON(dst, payload)
	case []RequestTraffic:
		dst = append(dst, '[')
		for i, traffic := range payload {
			if i > 0 {
				dst = append(dst, ',')
			}
			dst = appendRequestTrafficJSON(dst, traffic)
		}
		dst = append(dst, ']')
	case *Delay:
		if payload == nil {
			dst = append(dst, "null"...)
		} else {
			dst = append(dst, `{"url":`...)
			dst = jsonutil.AppendString(dst, payload.Url)
			dst = append(dst, `,"name":`...)
			dst = jsonutil.AppendString(dst, payload.Name)
			dst = append(dst, `,"value":`...)
			dst = strconv.AppendInt(dst, int64(payload.Value), 10)
			dst = append(dst, '}')
		}
	case string:
		dst = jsonutil.AppendString(dst, payload)
	case GeoUpdateStatus:
		dst = append(dst, `{"type":`...)
		dst = jsonutil.AppendString(dst, payload.Type)
		dst = append(dst, `,"updating":`...)
		dst = strconv.AppendBool(dst, payload.Updating)
		if payload.Skipped {
			dst = append(dst, `,"skipped":true`...)
		}
		if payload.Error != "" {
			dst = append(dst, `,"error":`...)
			dst = jsonutil.AppendString(dst, payload.Error)
		}
		dst = append(dst, '}')
	case RouteState:
		dst = append(dst, `{"core-epoch":`...)
		dst = strconv.AppendUint(dst, payload.CoreEpoch, 10)
		dst = append(dst, `,"route-version":`...)
		dst = strconv.AppendUint(dst, payload.RouteVersion, 10)
		dst = append(dst, '}')
	default:
		data, err := json.Marshal(message.Data)
		if err != nil {
			logError("Message payload marshal error: %v", err)
			dst = append(dst, "null"...)
		} else {
			dst = append(dst, data...)
		}
	}
	return append(dst, '}')
}

func appendDnsQueryJSON(dst []byte, query DnsQuery) []byte {
	dst = append(dst, `{"domain":`...)
	dst = jsonutil.AppendString(dst, query.Domain)
	dst = append(dst, `,"type":`...)
	dst = jsonutil.AppendString(dst, query.Type)
	dst = append(dst, `,"initiator":`...)
	dst = jsonutil.AppendString(dst, query.Initiator)
	if query.Upstream != "" {
		dst = append(dst, `,"upstream":`...)
		dst = jsonutil.AppendString(dst, query.Upstream)
	}
	if query.Cached {
		dst = append(dst, `,"cached":true`...)
	}
	dst = append(dst, `,"answers":`...)
	if query.Answers == nil {
		dst = append(dst, "null"...)
	} else {
		dst = append(dst, '[')
		for i, answer := range query.Answers {
			if i > 0 {
				dst = append(dst, ',')
			}
			dst = jsonutil.AppendString(dst, answer)
		}
		dst = append(dst, ']')
	}
	if query.Rcode != "" {
		dst = append(dst, `,"rcode":`...)
		dst = jsonutil.AppendString(dst, query.Rcode)
	}
	if query.Error != "" {
		dst = append(dst, `,"error":`...)
		dst = jsonutil.AppendString(dst, query.Error)
	}
	dst = append(dst, `,"delay":`...)
	dst = strconv.AppendInt(dst, query.Delay, 10)
	dst = append(dst, `,"time":`...)
	dst = jsonutil.AppendTime(dst, query.Time)
	return append(dst, '}')
}

func appendRequestTrafficJSON(dst []byte, traffic RequestTraffic) []byte {
	dst = append(dst, `{"id":`...)
	dst = jsonutil.AppendString(dst, traffic.Id)
	dst = append(dst, `,"upload":`...)
	dst = strconv.AppendInt(dst, traffic.Upload, 10)
	dst = append(dst, `,"download":`...)
	dst = strconv.AppendInt(dst, traffic.Download, 10)
	return append(dst, '}')
}
