package main

import (
	"sync"
	"testing"
	"time"

	adapter "github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/constant"
)

type batchCollector struct {
	mu      sync.Mutex
	batches [][]Message
}

func (collector *batchCollector) send(messages []Message) {
	collector.mu.Lock()
	defer collector.mu.Unlock()
	collector.batches = append(
		collector.batches,
		append([]Message(nil), messages...),
	)
}

func (collector *batchCollector) snapshot() [][]Message {
	collector.mu.Lock()
	defer collector.mu.Unlock()
	return append([][]Message(nil), collector.batches...)
}

func (collector *batchCollector) flattened() []Message {
	var messages []Message
	for _, batch := range collector.snapshot() {
		messages = append(messages, batch...)
	}
	return messages
}

func closedMessages() chan Message {
	queue := make(chan Message)
	close(queue)
	return queue
}

func drainDelayWakeUps() {
	for {
		select {
		case <-delayWakeUps:
		default:
			return
		}
	}
}

func resetDelayDeliveryState() {
	clearLatestDelays()
	drainDelayWakeUps()
}

func recordCurrentDelay(delay Delay) bool {
	return recordDelayUpdate(delay, proxiesGeneration.Load())
}

func runBatcherUntilDrained(t *testing.T, state, priority, bulk chan Message) *batchCollector {
	t.Helper()
	return runBatcherUntilDrainedWithDelayWakeUps(t, state, priority, bulk, nil)
}

func runBatcherUntilDrainedWithDelayWakeUps(
	t *testing.T,
	state, priority, bulk chan Message,
	delayWakeUps chan struct{},
) *batchCollector {
	t.Helper()
	collector := &batchCollector{}
	done := make(chan struct{})
	go func() {
		defer close(done)
		runMessageBatcher(state, priority, bulk, delayWakeUps, collector.send)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("runMessageBatcher did not return after every queue closed")
	}
	return collector
}

func TestClassOfMessageRoutesEachTier(t *testing.T) {
	for messageType, want := range map[MessageType]messageClass{
		LoadedMessage:       stateMessageClass,
		GeoUpdateMessage:    stateMessageClass,
		RouteChangedMessage: stateMessageClass,
		DelayMessage:        priorityMessageClass,
		LogMessage:          bulkMessageClass,
		RequestMessage:      bulkMessageClass,
		DnsMessage:          yieldingBulkMessageClass,
	} {
		if got := classOfMessage(Message{Type: messageType}); got != want {
			t.Errorf("classOfMessage(%s) = %d, want %d", messageType, got, want)
		}
	}
}

func TestMessageInterestTogglesRequestAndDnsEvents(t *testing.T) {
	handleStartRequestMessages()
	handleStartDnsMessages()
	if !messageInterestEnabled(RequestMessage) || !messageInterestEnabled(DnsMessage) {
		t.Fatal("starting request and DNS messages did not enable their events")
	}

	handleStopRequestMessages()
	handleStopDnsMessages()
	if messageInterestEnabled(RequestMessage) || messageInterestEnabled(DnsMessage) {
		t.Fatal("stopping request and DNS messages did not disable their events")
	}
	if !messageInterestEnabled(LogMessage) || !messageInterestEnabled(DelayMessage) {
		t.Fatal("request and DNS interests must not affect other event types")
	}
}

func TestEnqueueStateNeverEvictsAQueuedEvent(t *testing.T) {
	queue := make(chan Message, 2)
	for i := 0; i < 5; i++ {
		enqueueState(queue, Message{Type: GeoUpdateMessage, Data: i})
	}

	if len(queue) != 2 {
		t.Fatalf("queue length = %d, want 2", len(queue))
	}
	for _, want := range []int{0, 1} {
		if got := (<-queue).Data.(int); got != want {
			t.Errorf("retained Data = %d, want %d; a state event was evicted", got, want)
		}
	}
}

func TestEnqueueStateNeverBlocks(t *testing.T) {
	queue := make(chan Message, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 1000; i++ {
			enqueueState(queue, Message{Type: LoadedMessage, Data: i})
		}
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("enqueueState blocked on a full queue")
	}
}

func TestRunMessageBatcherDrainsStateAheadOfADelayBacklog(t *testing.T) {
	state := make(chan Message, 1)
	priority := make(chan Message, messageBatchSize*2)
	for i := 0; i < messageBatchSize*2; i++ {
		priority <- Message{Type: DelayMessage, Data: i}
	}
	state <- Message{Type: GeoUpdateMessage, Data: "finished"}
	close(state)
	close(priority)

	batches := runBatcherUntilDrained(t, state, priority, closedMessages()).snapshot()

	if len(batches) == 0 {
		t.Fatal("the batcher delivered nothing")
	}
	first := batches[0]
	if len(first) == 0 || first[0].Type != GeoUpdateMessage {
		t.Fatalf("first delivered message = %+v, want the geo update ahead of the delay backlog", first)
	}
}

func TestEnqueueLatestEvictsOldestOfItsOwnQueue(t *testing.T) {
	queue := make(chan Message, 2)
	for i := 0; i < 4; i++ {
		enqueueLatest(queue, Message{Type: DelayMessage, Data: i})
	}

	if len(queue) != 2 {
		t.Fatalf("queue length = %d, want 2", len(queue))
	}
	for _, want := range []int{2, 3} {
		got := (<-queue).Data.(int)
		if got != want {
			t.Errorf("retained Data = %d, want %d", got, want)
		}
	}
}

func TestEnqueueLatestNeverBlocks(t *testing.T) {
	queue := make(chan Message, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 1000; i++ {
			enqueueLatest(queue, Message{Type: LogMessage, Data: i})
		}
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("enqueueLatest blocked on a full queue")
	}
}

func TestDelayBatchCarriesLatestStateForEveryNode(t *testing.T) {
	resetDelayDeliveryState()
	t.Cleanup(resetDelayDeliveryState)

	recordCurrentDelay(Delay{Url: "https://example.test", Name: "node-a", Value: 10})
	recordCurrentDelay(Delay{Url: "https://example.test", Name: "node-b", Value: 15})
	recordCurrentDelay(Delay{Url: "https://example.test", Name: "node-a", Value: 20})

	got := coalesceDelayMessages([]Message{
		{Type: LogMessage, Data: "log"},
		{Type: DelayMessage, Data: Delay{
			Url:   "https://example.test",
			Name:  "node-a",
			Value: 10,
		}},
	})

	want := []Message{
		{Type: LogMessage, Data: "log"},
		{Type: DelayMessage, Data: Delay{
			Url:   "https://example.test",
			Name:  "node-a",
			Value: 20,
		}},
		{Type: DelayMessage, Data: Delay{
			Url:   "https://example.test",
			Name:  "node-b",
			Value: 15,
		}},
	}
	if len(got) != len(want) {
		t.Fatalf("coalesced batch length = %d, want %d: %+v", len(got), len(want), got)
	}
	for index := range want {
		if got[index].Type != want[index].Type || got[index].Data != want[index].Data {
			t.Fatalf(
				"message %d = {%s %v}, want {%s %v}",
				index,
				got[index].Type,
				got[index].Data,
				want[index].Type,
				want[index].Data,
			)
		}
	}
}

func TestManyDelayUpdatesShareOneWakeUp(t *testing.T) {
	resetDelayDeliveryState()
	t.Cleanup(resetDelayDeliveryState)

	delayWakeUps := make(chan struct{}, 1)
	if !queueDelayWakeUpTo(delayWakeUps) {
		t.Fatal("the first delay update did not queue a wake-up")
	}
	if queueDelayWakeUpTo(delayWakeUps) {
		t.Fatal("a second delay update queued another wake-up while one was pending")
	}

	select {
	case <-delayWakeUps:
	default:
		t.Fatal("the pending wake-up was not retained for the batcher")
	}

	if !queueDelayWakeUpTo(delayWakeUps) {
		t.Fatal("a wake-up was not available after the previous batch was delivered")
	}
}

func TestRunMessageBatcherDeliversDelayWakeUp(t *testing.T) {
	resetDelayDeliveryState()
	t.Cleanup(resetDelayDeliveryState)
	recordCurrentDelay(Delay{
		Url:   "https://example.test",
		Name:  "node-a",
		Value: 20,
	})

	delayWakeUps := make(chan struct{}, 1)
	delayWakeUps <- struct{}{}
	close(delayWakeUps)
	batches := runBatcherUntilDrainedWithDelayWakeUps(
		t,
		closedMessages(),
		closedMessages(),
		closedMessages(),
		delayWakeUps,
	).snapshot()

	if len(batches) != 1 || len(batches[0]) != 1 || batches[0][0].Type != DelayMessage {
		t.Fatalf("delivered batches = %+v, want one delay wake-up", batches)
	}
	got := coalesceDelayMessages(batches[0])
	want := []Message{{
		Type: DelayMessage,
		Data: Delay{
			Url:   "https://example.test",
			Name:  "node-a",
			Value: 20,
		},
	}}
	if len(got) != len(want) || got[0].Data != want[0].Data {
		t.Fatalf("coalesced delay = %+v, want %+v", got, want)
	}
}

func TestReplayLeavesAWakeUpForLaterUpdates(t *testing.T) {
	resetDelayDeliveryState()
	t.Cleanup(resetDelayDeliveryState)
	delayWakeUps := make(chan struct{}, 1)

	recordCurrentDelay(Delay{
		Url:   "https://example.test",
		Name:  "node-a",
		Value: 10,
	})
	if !queueDelayWakeUpTo(delayWakeUps) {
		t.Fatal("the first delay update did not queue a wake-up")
	}

	replayed := latestDelayMessages()
	if len(replayed) != 1 {
		t.Fatalf("replayed delay count = %d, want 1", len(replayed))
	}
	if queueDelayWakeUpTo(delayWakeUps) {
		t.Fatal("replay discarded a wake-up that a later update could reuse")
	}

	recordCurrentDelay(Delay{
		Url:   "https://example.test",
		Name:  "node-a",
		Value: 30,
	})
	got := coalesceDelayMessages([]Message{{Type: DelayMessage}})
	want := []Message{{
		Type: DelayMessage,
		Data: Delay{
			Url:   "https://example.test",
			Name:  "node-a",
			Value: 30,
		},
	}}
	if len(got) != len(want) || got[0].Data != want[0].Data {
		t.Fatalf("coalesced delay = %+v, want %+v", got, want)
	}
}

func TestProxyTreeChangeDropsOldDelayState(t *testing.T) {
	resetDelayDeliveryState()
	t.Cleanup(resetDelayDeliveryState)

	generation := proxiesGeneration.Load()
	if recordDelayUpdate(
		Delay{
			Url:   "https://example.test",
			Name:  "old-node",
			Value: 10,
		},
		generation,
	) {
		bumpProxiesGeneration()
	}

	if messages := latestDelayMessages(); len(messages) != 0 {
		t.Fatalf("old delay state survived a proxy tree change: %+v", messages)
	}
}

func TestStaleDelayResultCannotEnterTheNewProxyTree(t *testing.T) {
	resetDelayDeliveryState()
	t.Cleanup(resetDelayDeliveryState)

	generation := proxiesGeneration.Load()
	bumpProxiesGeneration()
	if recordDelayUpdate(
		Delay{
			Url:   "https://example.test",
			Name:  "same-name",
			Value: 10,
		},
		generation,
	) {
		t.Fatal("a result captured before the proxy tree change entered the new state")
	}
	if messages := latestDelayMessages(); len(messages) != 0 {
		t.Fatalf("stale delay state survived: %+v", messages)
	}
}

func TestCurrentProxyMatchesRejectsAReplacedNode(t *testing.T) {
	adapterProxy := outbound.NewDirectWithOption(
		outbound.DirectOption{Name: "node"},
	)
	current := adapter.NewProxy(adapterProxy)
	measured := adapter.NewProxy(adapterProxy)
	replaced := adapter.NewProxy(
		outbound.NewDirectWithOption(outbound.DirectOption{Name: "node"}),
	)
	lookup := func(name string) constant.Proxy {
		if name == "node" {
			return current
		}
		return nil
	}

	if !currentProxyMatches("node", measured, lookup) {
		t.Fatal("the live proxy object was rejected")
	}
	if currentProxyMatches("node", replaced, lookup) {
		t.Fatal("a replaced proxy object was accepted")
	}
	if currentProxyMatches("missing", measured, lookup) {
		t.Fatal("a missing proxy was accepted")
	}
}

func TestRestoreMissingPendingDelaysKeepsNewerUpdates(t *testing.T) {
	resetDelayDeliveryState()
	t.Cleanup(resetDelayDeliveryState)

	oldDelay := Delay{
		Url:   "https://example.test",
		Name:  "node-a",
		Value: 10,
	}
	newerDelay := Delay{
		Url:   "https://example.test",
		Name:  "node-a",
		Value: 30,
	}
	recordCurrentDelay(oldDelay)
	recordCurrentDelay(newerDelay)

	restoreMissingPendingDelays([]Delay{oldDelay})

	if pending := pendingDelayDelays(); len(pending) != 1 || pending[0] != newerDelay {
		t.Fatalf("pending delays = %+v, want only %+v", pending, newerDelay)
	}

	commitDeliveredDelays([]Delay{newerDelay})
	restoreMissingPendingDelays([]Delay{oldDelay})

	if pending := pendingDelayDelays(); len(pending) != 1 || pending[0] != oldDelay {
		t.Fatalf("restored delays = %+v, want only %+v", pending, oldDelay)
	}
}

func TestRunMessageBatcherPrefersPriorityAndGuaranteesBulkOpportunity(t *testing.T) {
	priority := make(chan Message, 64)
	bulk := make(chan Message, 64)
	for i := 0; i < 20; i++ {
		priority <- Message{Type: DelayMessage, Data: i}
	}
	for i := 0; i < 5; i++ {
		bulk <- Message{Type: LogMessage, Data: i}
	}
	close(priority)
	close(bulk)

	got := runBatcherUntilDrained(t, closedMessages(), priority, bulk).flattened()

	want := make([]Message, 0, 25)
	appendPriority := func(from, to int) {
		for i := from; i < to; i++ {
			want = append(want, Message{Type: DelayMessage, Data: i})
		}
	}
	appendPriority(0, 8)
	want = append(want, Message{Type: LogMessage, Data: 0})
	appendPriority(8, 16)
	want = append(want, Message{Type: LogMessage, Data: 1})
	appendPriority(16, 20)
	want = append(want,
		Message{Type: LogMessage, Data: 2},
		Message{Type: LogMessage, Data: 3},
		Message{Type: LogMessage, Data: 4},
	)

	if len(got) != len(want) {
		t.Fatalf("delivered %d messages, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i].Type != want[i].Type || got[i].Data != want[i].Data {
			t.Fatalf(
				"message %d = {%s %v}, want {%s %v}",
				i, got[i].Type, got[i].Data, want[i].Type, want[i].Data,
			)
		}
	}
}

func TestRunMessageBatcherFlushesAtBatchSize(t *testing.T) {
	total := messageBatchSize*2 + 6
	priority := make(chan Message, total)
	bulk := make(chan Message)
	for i := 0; i < total; i++ {
		priority <- Message{Type: DelayMessage, Data: i}
	}
	close(priority)
	close(bulk)

	batches := runBatcherUntilDrained(t, closedMessages(), priority, bulk).snapshot()

	wantSizes := []int{messageBatchSize, messageBatchSize, 6}
	if len(batches) != len(wantSizes) {
		t.Fatalf("got %d batches, want %d", len(batches), len(wantSizes))
	}
	for i, wantSize := range wantSizes {
		if len(batches[i]) != wantSize {
			t.Errorf("batch %d size = %d, want %d", i, len(batches[i]), wantSize)
		}
	}
}

func TestRunMessageBatcherFlushesOnInterval(t *testing.T) {
	priority := make(chan Message, 4)
	bulk := make(chan Message, 4)
	collector := &batchCollector{}
	done := make(chan struct{})
	go func() {
		defer close(done)
		runMessageBatcher(closedMessages(), priority, bulk, nil, collector.send)
	}()

	for i := 0; i < 3; i++ {
		priority <- Message{Type: DelayMessage, Data: i}
	}

	deadline := time.After(2 * time.Second)
	for {
		if len(collector.flattened()) == 3 {
			break
		}
		select {
		case <-deadline:
			t.Fatal("batcher did not flush a partial batch on the interval tick")
		case <-time.After(5 * time.Millisecond):
		}
	}

	close(priority)
	close(bulk)
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("runMessageBatcher did not return after every queue closed")
	}
}

func TestRunMessageBatcherDrainsBulkAfterPriorityCloses(t *testing.T) {
	priority := make(chan Message)
	bulk := make(chan Message, 4)
	for i := 0; i < 4; i++ {
		bulk <- Message{Type: RequestMessage, Data: i}
	}
	close(priority)
	close(bulk)

	got := runBatcherUntilDrained(t, closedMessages(), priority, bulk).flattened()

	if len(got) != 4 {
		t.Fatalf("delivered %d bulk messages, want 4", len(got))
	}
	for i, message := range got {
		if message.Type != RequestMessage || message.Data != i {
			t.Errorf("message %d = {%s %v}, want {request %d}", i, message.Type, message.Data, i)
		}
	}
}
