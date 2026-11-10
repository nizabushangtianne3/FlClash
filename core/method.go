package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"runtime"
	"sync/atomic"

	"github.com/metacubex/mihomo/common/jsonutil"
)

type MethodCall struct {
	ID        string          `json:"id,omitempty"`
	Method    CoreMethod      `json:"method"`
	Arguments json.RawMessage `json:"arguments"`
	seq       uint64
}

type MethodError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Details any    `json:"details"`
}

func (e *MethodError) Error() string {
	return e.Message
}

type MethodResponse struct {
	ID     string       `json:"id,omitempty"`
	Result any          `json:"result"`
	Error  *MethodError `json:"error,omitempty"`
	File   string       `json:"file,omitempty"`
}

var methodCallSeq atomic.Uint64

// Each call runs on its own goroutine, so a handler that must honour the
// host's latest intent compares seq, stamped here in arrival order; every
// transport has to deliver calls in the order the host sent them.
func dispatchMethodCall(call *MethodCall, reply func(answer frame)) {
	call.seq = methodCallSeq.Add(1)
	// A developer-only fatal-path test. It runs outside every recovery so the
	// core process terminates; on Android that is the whole application.
	if call.Method == coreCrashMethod {
		go handleCrash()
		return
	}
	safeGo(string(call.Method), func() {
		reply(handleMethodCall(call))
	})
}

// frame is one answer as the transport writes it: the pieces in order, with a
// document the result already encoded riding as its own piece. Keeping the
// envelope apart lets a large document reach the host beside it instead of
// being copied into it.
//
// A document-carrying answer names the call in id rather than carrying the
// envelope as bytes: that shape is the one the answer path hands back over
// and over, and an envelope built once per answer is one allocation plus one
// copy the transport immediately repeats. It is built where the answer is
// consumed, into a buffer already sized for it.
type frame struct {
	head     []byte
	document []byte
	tail     []byte
	id       string
}

func (answer frame) size() int {
	if len(answer.head) == 0 {
		return envelopeLen(answer.id) + len(answer.document) + len(answer.tail)
	}
	return len(answer.head) + len(answer.document) + len(answer.tail)
}

// bytes is the answer as one slice, for the callers that need it whole.
func (answer frame) bytes() []byte {
	buf := make([]byte, 0, answer.size())
	if len(answer.head) == 0 {
		buf = appendEnvelope(buf, answer.id)
	} else {
		buf = append(buf, answer.head...)
	}
	buf = append(buf, answer.document...)
	return append(buf, answer.tail...)
}

// maxPooledFrameSize bounds what a pooled buffer is allowed to keep: a buffer
// that outgrew it once is dropped instead of pinned for the rest of the run.
const maxPooledFrameSize = 1 << 20

var (
	anonymousEnvelope = []byte(`{"result":`)
	responseTail      = []byte(`}`)
)

// envelopeLen reports the bytes the envelope for id takes, for a buffer sized
// to the envelope itself rather than to the room it may take.
func envelopeLen(id string) int {
	if id == "" {
		return len(anonymousEnvelope)
	}
	return len(`{"id":`) + jsonutil.StringLen(id) + len(`,"result":`)
}

// appendEnvelope writes the envelope for id into dst, which the caller has
// already sized.
func appendEnvelope(dst []byte, id string) []byte {
	if id == "" {
		return append(dst, anonymousEnvelope...)
	}
	dst = append(dst, `{"id":`...)
	dst = jsonutil.AppendString(dst, id)
	return append(dst, `,"result":`...)
}

// envelope opens the response a frame document is wrapped in, as bytes a
// caller keeps.
func envelope(id string) []byte {
	return appendEnvelope(make([]byte, 0, envelopeLen(id)), id)
}

// frameWriter is a result that carries its document already encoded, so an
// answer does not pay for a second reflection pass over the whole table.
type frameWriter interface {
	// document returns the result document. One that only changes when the
	// values it encodes move is reused between answers, so the steady state
	// builds nothing.
	document() []byte
}

func handleCrash() {
	panic("handle invoke crash")
}

func handleMethodCall(call *MethodCall) (answer frame) {
	defer func() {
		if r := recover(); r != nil {
			logError("panic in %s: %v\n%s", call.Method, r, stackTrace())
			answer = frame{head: encodeResponse(MethodResponse{ID: call.ID, Error: &MethodError{
				Code:    "internal_error",
				Message: fmt.Sprintf("internal panic: %v", r),
			}})}
		}
	}()

	handler, exists := methodHandlers[call.Method]
	if !exists {
		return frame{head: encodeResponse(MethodResponse{ID: call.ID, Error: &MethodError{
			Code:    "not_implemented",
			Message: fmt.Sprintf("unknown method: %s", call.Method),
		}})}
	}
	result, err := handler(call)
	if err != nil {
		return frame{head: encodeResponse(MethodResponse{ID: call.ID, Error: asMethodError(err)})}
	}
	if writer, ok := result.(frameWriter); ok {
		answer = frame{
			document: writer.document(),
			tail:     responseTail,
			id:       call.ID,
		}
	} else {
		answer = frame{head: encodeResponse(MethodResponse{ID: call.ID, Result: result})}
	}
	if answer.size() > spillThreshold {
		return spillFrame(call.ID, answer)
	}
	return answer
}

func encodeResponse(response MethodResponse) []byte {
	data, err := json.Marshal(response)
	if err == nil {
		return data
	}
	logError("MethodResponse marshal error: id=%s err=%v", response.ID, err)
	data, _ = json.Marshal(MethodResponse{ID: response.ID, Error: &MethodError{
		Code:    "internal_error",
		Message: "encode response: " + err.Error(),
	}})
	return data
}

func asMethodError(err error) *MethodError {
	var methodErr *MethodError
	if errors.As(err, &methodErr) {
		return methodErr
	}
	return &MethodError{Code: "core_error", Message: err.Error()}
}

func stackTrace() []byte {
	buf := make([]byte, 4096)
	return buf[:runtime.Stack(buf, false)]
}

func safeGo(name string, run func()) {
	go func() {
		defer func() {
			if r := recover(); r != nil {
				logError("panic in %s: %v\n%s", name, r, stackTrace())
			}
		}()
		run()
	}()
}

func (call MethodCall) decodeArguments(target any) error {
	if len(call.Arguments) == 0 || string(call.Arguments) == "null" {
		return errors.New("missing arguments")
	}
	return json.Unmarshal(call.Arguments, target)
}

func decodeArguments[P any](call *MethodCall) (params P, err error) {
	if decodeErr := call.decodeArguments(&params); decodeErr != nil {
		return params, &MethodError{
			Code:    "invalid_arguments",
			Message: fmt.Sprintf("invalid arguments for %s: %v", call.Method, decodeErr),
		}
	}
	return params, nil
}

type methodHandler func(call *MethodCall) (any, error)

func withArguments[P, R any](run func(P) R) methodHandler {
	return withFallible(func(params P) (R, error) {
		return run(params), nil
	})
}

func withFallible[P, R any](run func(P) (R, error)) methodHandler {
	return func(call *MethodCall) (any, error) {
		params, err := decodeArguments[P](call)
		if err != nil {
			return nil, err
		}
		return run(params)
	}
}

func withoutArguments[R any](run func() R) methodHandler {
	return func(*MethodCall) (any, error) {
		return run(), nil
	}
}

// command answers null, or the error run returns.
func command[P any](run func(P) error) methodHandler {
	return func(call *MethodCall) (any, error) {
		params, err := decodeArguments[P](call)
		if err != nil {
			return nil, err
		}
		return nil, run(params)
	}
}

func action(run func()) methodHandler {
	return func(*MethodCall) (any, error) {
		run()
		return nil, nil
	}
}

var methodHandlers = map[CoreMethod]methodHandler{
	coreInitMethod:        command(handleInit),
	coreInitializedMethod: withoutArguments(handleInitialized),
	coreGCMethod:          action(handleForceGC),
	coreMemoryMethod: withoutArguments(func() *MemoryStats {
		stats := handleGetMemoryStats()
		return &stats
	}),

	configSetupMethod:    command(handleSetupConfig),
	configUpdateMethod:   command(updateConfig),
	configValidateMethod: withArguments(handleValidateConfig),
	configDecryptMethod:  withFallible(handleDecryptConfig),
	configReadMethod:     withFallible(handleReadConfig),

	profileBaseMethod:        withFallible(handleGetProfileBase),
	profileOutboundsMethod:   withFallible(handleGetProfileOutbounds),
	profileBuildMethod:       withFallible(handleBuildProfile),
	profileClearEffectMethod: command(handleClearEffect),

	proxyListMethod:       withoutArguments(handleGetProxies),
	proxySelectMethod:     withArguments(handleChangeProxy),
	proxyDefinitionMethod: withFallible(handleGetProxyDefinition),
	proxyTestDelayMethod:  withArguments(handleTestDelay),
	proxyValidateMethod:   withArguments(handleValidateProxies),
	proxyConvertMethod:    withFallible(handleConvertProxies),
	shareLinkEncodeMethod: withArguments(handleEncodeShareLinks),
	shareLinkDecodeMethod: withArguments(handleDecodeShareLinks),
	filterValidateMethod:  withArguments(handleValidateFilters),

	providerListMethod:     withoutArguments(handleGetExternalProviders),
	providerGetMethod:      withArguments(handleGetExternalProvider),
	providerUpdateMethod:   command(handleUpdateExternalProvider),
	providerSideLoadMethod: command(handleSideLoadExternalProvider),
	ruleSetDumpMethod:      withFallible(handleDumpRuleSet),
	ruleSetCompileMethod:   withFallible(handleCompileRuleSet),
	geoUpdateMethod:        command(handleUpdateGeoData),

	trafficStatsMethod:       withArguments(handleGetTrafficStats),
	trafficResetMethod:       action(handleResetTraffic),
	connectionListMethod:     withArguments(handleGetConnections),
	connectionCountMethod:    withoutArguments(handleGetConnectionCount),
	connectionCloseMethod:    command(handleCloseConnection),
	connectionCloseAllMethod: action(handleCloseConnections),
	connectionResetMethod:    action(handleResetConnections),
	dnsClearCacheMethod:      action(handleClearDnsCache),
	networkChangedMethod:     action(handleNetworkChanged),

	logStartMethod:      action(handleStartLog),
	logStopMethod:       action(handleStopLog),
	listenerStartMethod: action(handleStartListener),
	listenerStopMethod:  action(handleStopListener),
	routeWatchMethod:    watchRouteHandler,
	routeCheckMethod:    withArguments(handleCheckRoutes),

	probeOutboundIPMethod: withArguments(handleOutboundIp),
	probeServicesMethod:   withArguments(handleServiceCheck),
}

func watchRouteHandler(call *MethodCall) (any, error) {
	params, err := decodeArguments[WatchParams](call)
	if err != nil {
		return nil, err
	}
	return handleWatchRoute(params.Watch, call.seq), nil
}
