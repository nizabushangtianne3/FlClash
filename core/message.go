package main

import (
	"encoding/json"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/constant"
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
	latestDelayMu        sync.Mutex
	latestDelays         = map[delayKey]Delay{}
	pendingDelayDeltas   = map[delayKey]Delay{}
	delayWakeUps         = make(chan struct{}, 1)
	requestMessages      atomic.Bool
	dnsMessages          atomic.Bool
)

type delayKey struct {
	url  string
	name string
}

func init() {
	requestMessages.Store(true)
	dnsMessages.Store(true)
	go runMessageBatcher(
		stateMessageQueue,
		priorityMessageQueue,
		bulkMessageQueue,
		delayWakeUps,
		sendMessageBatch,
	)
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

func sendDelayEvent(delay Delay, proxy constant.Proxy) {
	if !currentProxyMatches(delay.Name, proxy, lookupProxy) {
		return
	}
	generation := proxiesGeneration.Load()
	recordDelayUpdate(delay, generation)
	queueDelayWakeUp()
}

func currentProxyMatches(
	name string,
	proxy constant.Proxy,
	lookup func(string) constant.Proxy,
) bool {
	current := lookup(name)
	return current != nil && current.Adapter() == proxy.Adapter()
}

func recordDelayUpdate(delay Delay, generation uint64) bool {
	latestDelayMu.Lock()
	defer latestDelayMu.Unlock()
	if generation != proxiesGeneration.Load() {
		return false
	}
	key := delayKey{url: delay.Url, name: delay.Name}
	latestDelays[key] = delay
	pendingDelayDeltas[key] = delay
	return true
}

func clearLatestDelays() {
	latestDelayMu.Lock()
	defer latestDelayMu.Unlock()
	latestDelays = map[delayKey]Delay{}
	pendingDelayDeltas = map[delayKey]Delay{}
}

func queueDelayWakeUpTo(wakeUps chan<- struct{}) bool {
	if !hasEventListener() {
		return false
	}
	select {
	case wakeUps <- struct{}{}:
		return true
	default:
		return false
	}
}

func queueDelayWakeUp() bool {
	return queueDelayWakeUpTo(delayWakeUps)
}

func pendingDelayMessages() []Message {
	latestDelayMu.Lock()
	delays := make([]Delay, 0, len(pendingDelayDeltas))
	for _, delay := range pendingDelayDeltas {
		delays = append(delays, delay)
	}
	latestDelayMu.Unlock()

	sort.Slice(delays, func(i, j int) bool {
		if delays[i].Url != delays[j].Url {
			return delays[i].Url < delays[j].Url
		}
		return delays[i].Name < delays[j].Name
	})
	messages := make([]Message, len(delays))
	for index, delay := range delays {
		messages[index] = Message{Type: DelayMessage, Data: delay}
	}
	return messages
}

func delaysFromMessages(messages []Message) []Delay {
	delays := make([]Delay, 0, len(messages))
	for _, message := range messages {
		if delay, ok := message.Data.(Delay); ok {
			delays = append(delays, delay)
		}
	}
	return delays
}

func pendingDelayDelays() []Delay {
	return delaysFromMessages(pendingDelayMessages())
}

// Delay is state, not a notification to preserve verbatim. Coalescing each
// key keeps a node's newest measurement even when the bounded queue is full.
func prepareDelayBatch(messages []Message) (batch []Message, delays []Delay) {
	var hasDelay bool
	for _, message := range messages {
		if message.Type == DelayMessage {
			hasDelay = true
			break
		}
	}
	if !hasDelay {
		return messages, nil
	}

	coalesced := make([]Message, 0, len(messages))
	for _, message := range messages {
		if message.Type != DelayMessage {
			coalesced = append(coalesced, message)
		}
	}
	pending := pendingDelayMessages()
	return append(coalesced, pending...), delaysFromMessages(pending)
}

func coalesceDelayMessages(messages []Message) []Message {
	batch, _ := prepareDelayBatch(messages)
	return batch
}

func commitDeliveredDelays(delays []Delay) {
	latestDelayMu.Lock()
	defer latestDelayMu.Unlock()
	for _, delay := range delays {
		key := delayKey{url: delay.Url, name: delay.Name}
		if pending, exists := pendingDelayDeltas[key]; exists && pending == delay {
			delete(pendingDelayDeltas, key)
		}
	}
}

func restoreMissingPendingDelays(delays []Delay) {
	latestDelayMu.Lock()
	defer latestDelayMu.Unlock()
	for _, delay := range delays {
		key := delayKey{url: delay.Url, name: delay.Name}
		if _, exists := pendingDelayDeltas[key]; !exists {
			pendingDelayDeltas[key] = delay
		}
	}
}

func replayLatestDelays() {
	replayLatestDelaysWithWakeUp(delayWakeUps)
}

func replayLatestDelaysWithWakeUp(wakeUps chan<- struct{}) {
	messages := latestDelayMessages()
	if len(messages) == 0 {
		return
	}
	delays := delaysFromMessages(messages)
	if sendEventBatch(messages) {
		commitDeliveredDelays(delays)
		return
	}
	restoreMissingPendingDelays(delays)
	queueDelayWakeUpTo(wakeUps)
}

func latestDelayMessages() []Message {
	latestDelayMu.Lock()
	delays := make([]Delay, 0, len(latestDelays))
	for _, delay := range latestDelays {
		delays = append(delays, delay)
	}
	latestDelayMu.Unlock()

	sort.Slice(delays, func(i, j int) bool {
		if delays[i].Url != delays[j].Url {
			return delays[i].Url < delays[j].Url
		}
		return delays[i].Name < delays[j].Name
	})
	messages := make([]Message, len(delays))
	for index, delay := range delays {
		messages[index] = Message{Type: DelayMessage, Data: delay}
	}
	return messages
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
	case DnsMessage:
		return yieldingBulkMessageClass
	default:
		return priorityMessageClass
	}
}

// Request and DNS events fire per connection and per query for as long as the
// Android service runs, engine or not; unheard, they are not worth encoding.
func sendMessage(message Message) {
	if !hasEventListener() || !messageInterestEnabled(message.Type) {
		return
	}
	switch classOfMessage(message) {
	case stateMessageClass:
		enqueueState(stateMessageQueue, message)
	case bulkMessageClass:
		enqueueLatest(bulkMessageQueue, message)
	case yieldingBulkMessageClass:
		enqueueState(bulkMessageQueue, message)
	default:
		enqueueLatest(priorityMessageQueue, message)
	}
}

func enqueueState(queue chan Message, message Message) {
	select {
	case queue <- message:
	default:
	}
}

func enqueueLatest(queue chan Message, message Message) {
	for attempt := 0; attempt < messageEvictAttempts; attempt++ {
		select {
		case queue <- message:
			return
		default:
		}

		select {
		case <-queue:
		default:
		}
	}
}

func runMessageBatcher(
	stateMessages <-chan Message,
	priorityMessages <-chan Message,
	bulkMessages <-chan Message,
	delayWakeUps <-chan struct{},
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
	appendMessage := func(message Message) {
		if len(batch) == 0 {
			timer.Reset(messageBatchInterval)
			deadline = timer.C
		}
		batch = append(batch, message)
		if len(batch) >= messageBatchSize {
			flush()
		}
	}

	priorityBurst := 0
	for stateMessages != nil ||
		priorityMessages != nil ||
		bulkMessages != nil ||
		delayWakeUps != nil {
		select {
		case message, ok := <-stateMessages:
			if !ok {
				stateMessages = nil
			} else {
				appendMessage(message)
			}
			continue
		default:
		}

		if delayWakeUps != nil {
			select {
			case _, ok := <-delayWakeUps:
				if !ok {
					delayWakeUps = nil
				} else {
					appendMessage(Message{Type: DelayMessage})
				}
				continue
			default:
			}
		}

		// Give bulk events one guaranteed opportunity after a bounded priority
		// burst, while retaining priority preference under ordinary load.
		if priorityBurst >= messagePriorityBurst && bulkMessages != nil {
			select {
			case message, ok := <-bulkMessages:
				if !ok {
					bulkMessages = nil
				} else {
					appendMessage(message)
				}
				priorityBurst = 0
				continue
			default:
				priorityBurst = 0
			}
		}

		select {
		case message, ok := <-priorityMessages:
			if !ok {
				priorityMessages = nil
			} else {
				appendMessage(message)
				priorityBurst++
			}
			continue
		default:
		}

		select {
		case message, ok := <-stateMessages:
			if !ok {
				stateMessages = nil
			} else {
				appendMessage(message)
			}
		case message, ok := <-priorityMessages:
			if !ok {
				priorityMessages = nil
			} else {
				appendMessage(message)
				priorityBurst++
			}
		case message, ok := <-bulkMessages:
			if !ok {
				bulkMessages = nil
			} else {
				appendMessage(message)
			}
			priorityBurst = 0
		case _, ok := <-delayWakeUps:
			if !ok {
				delayWakeUps = nil
			} else {
				appendMessage(Message{Type: DelayMessage})
			}
		case <-deadline:
			flush()
		}
	}
	flush()
}

type messageBatchCall struct {
	Method    CoreMethod `json:"method"`
	Arguments []Message  `json:"arguments"`
}

func sendMessageBatch(messages []Message) {
	sendMessageBatchWithWakeUp(messages, delayWakeUps)
}

func sendMessageBatchWithWakeUp(messages []Message, wakeUps chan<- struct{}) {
	batch, delays := prepareDelayBatch(messages)
	if len(batch) == 0 {
		return
	}
	if sendEventBatch(batch) {
		commitDeliveredDelays(delays)
		return
	}
	if len(delays) > 0 {
		queueDelayWakeUpTo(wakeUps)
	}
}

func sendEventBatch(messages []Message) bool {
	if len(messages) == 0 {
		return true
	}
	data, err := json.Marshal(messageBatchCall{
		Method:    messageMethod,
		Arguments: messages,
	})
	if err != nil {
		logError("Message batch marshal error: %v", err)
		return false
	}
	return deliverEvent(data)
}
