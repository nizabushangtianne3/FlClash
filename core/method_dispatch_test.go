package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/metacubex/mihomo/component/resource"
	C "github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/rules"
	rp "github.com/metacubex/mihomo/rules/provider"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
	"github.com/stretchr/testify/require"
)

// The method table is the host's whole surface, and a handler that is
// registered but never run answers whatever it happens to do. Each of these
// goes through the dispatcher, as the host does, so the wiring is covered with
// the handler.
func TestDispatchedActionsAnswerWhatTheyDo(t *testing.T) {
	previousInit := isInit.Load()
	t.Cleanup(func() { isInit.Store(previousInit) })
	isInit.Store(true)

	tracker := newConnectionDeltaTracker(t, &C.Metadata{NetWork: C.TCP, Host: "dispatch.example.com"})
	defer func() { _ = tracker.Close() }()
	// The manager is shared with every other test that opened a row, so the
	// witness is the count as this test found it rather than an absolute one.
	live := statistic.DefaultManager.Size()
	require.NotZero(t, live, "the tracker this test opened is live")

	// Only one of these closes the rows; the rest reset a counter, a cache or
	// a network answer, and the live row is the witness that they left it be.
	// closeAll runs last so the row it closes is still there to witness the
	// actions that come before it.
	for _, test := range []struct {
		method CoreMethod
		closes bool
	}{
		{trafficResetMethod, false},
		{connectionResetMethod, false},
		{dnsClearCacheMethod, false},
		{networkChangedMethod, false},
		{connectionCloseAllMethod, true},
	} {
		t.Run(string(test.method), func(t *testing.T) {
			answer := answerBytes(MethodCall{ID: "1", Method: test.method})

			var envelope struct {
				ID     string          `json:"id"`
				Result json.RawMessage `json:"result"`
				Error  *MethodError    `json:"error"`
			}
			require.NoError(t, json.Unmarshal(answer, &envelope))
			require.Equal(t, "1", envelope.ID)
			require.Nil(t, envelope.Error, "answer = %s", answer)
			require.Equal(t, "null", string(envelope.Result), "answer = %s", answer)

			if test.closes {
				require.Zero(t, statistic.DefaultManager.Size(),
					"closing every row leaves nothing for the next poll to report")
			} else {
				require.Equal(t, live, statistic.DefaultManager.Size(),
					"an action that is not closeAll leaves the live rows alone")
			}
		})
	}
}

func TestDispatchedConnectionCloseAnswersNullForAnUnknownRow(t *testing.T) {
	answer := answerBytes(MethodCall{
		ID:        "2",
		Method:    connectionCloseMethod,
		Arguments: json.RawMessage(`{"id":"no-such-row"}`),
	})

	var envelope struct {
		Result json.RawMessage `json:"result"`
		Error  *MethodError    `json:"error"`
	}
	require.NoError(t, json.Unmarshal(answer, &envelope))
	require.Nil(t, envelope.Error)
	require.Equal(t, "null", string(envelope.Result))
}

func TestDispatchedProviderListAnswersEveryListedProvider(t *testing.T) {
	withTunnelProviders(t, nil, map[string]cp.RuleProvider{
		"first":  listedRuleSetProvider(t, "first"),
		"second": listedRuleSetProvider(t, `quote"name`),
	})

	answer := answerBytes(MethodCall{ID: "3", Method: providerListMethod})

	var envelope struct {
		Result []map[string]any `json:"result"`
	}
	require.NoError(t, json.Unmarshal(answer, &envelope))
	require.Len(t, envelope.Result, 2)

	first, second := envelope.Result[0], envelope.Result[1]
	require.Equal(t, "first", first["name"])
	require.Equal(t, "Rule", first["type"])
	require.Equal(t, "File", first["vehicle-type"])
	require.Equal(t, float64(1), first["count"], "the payload rule is counted")
	require.Equal(t, `quote"name`, second["name"], "an escaped name reaches the host as it is")
	require.Contains(t, second, "update-at")
	require.Contains(t, second, "path")
	require.Contains(t, second, "count")
}

func TestDispatchedProviderGetAnswersOneProviderOrAnError(t *testing.T) {
	withTunnelProviders(t, nil, map[string]cp.RuleProvider{
		"subscription": listedRuleSetProvider(t, "subscription"),
	})

	var found struct {
		Result ExternalProvider `json:"result"`
	}
	require.NoError(t, json.Unmarshal(answerBytes(MethodCall{
		ID:        "4",
		Method:    providerGetMethod,
		Arguments: json.RawMessage(`{"name":"subscription"}`),
	}), &found))
	require.Equal(t, "subscription", found.Result.Name)

	var missing struct {
		Result *ExternalProvider `json:"result"`
	}
	require.NoError(t, json.Unmarshal(answerBytes(MethodCall{
		ID:        "5",
		Method:    providerGetMethod,
		Arguments: json.RawMessage(`{"name":"no-such-provider"}`),
	}), &missing))
	require.Nil(t, missing.Result, "a provider the tunnel does not hold answers null")
}

func TestDispatchedProviderSideLoadRejectsAnInlineProvider(t *testing.T) {
	withTunnelProviders(t, map[string]cp.ProxyProvider{
		"inline": &fakeProxyProvider{name: "inline", vehicle: cp.Compatible},
	}, nil)

	answer := answerBytes(MethodCall{
		ID:        "6",
		Method:    providerSideLoadMethod,
		Arguments: json.RawMessage(`{"name":"inline","data":"{}"}`),
	})

	var envelope struct {
		Error *MethodError `json:"error"`
	}
	require.NoError(t, json.Unmarshal(answer, &envelope))
	require.NotNil(t, envelope.Error, "answer = %s", answer)
	require.Equal(t, "provider_not_found", envelope.Error.Code,
		"an inline provider is not an external one, so no side load addresses it")
}

func TestDispatchedProfileClearEffectNeedsAnInitializedCore(t *testing.T) {
	previousInit := isInit.Load()
	t.Cleanup(func() { isInit.Store(previousInit) })
	isInit.Store(false)

	answer := answerBytes(MethodCall{
		ID:        "7",
		Method:    profileClearEffectMethod,
		Arguments: json.RawMessage(`{"profile-id":7}`),
	})

	var envelope struct {
		Error *MethodError `json:"error"`
	}
	require.NoError(t, json.Unmarshal(answer, &envelope))
	require.NotNil(t, envelope.Error, "answer = %s", answer)
	require.Equal(t, "core_error", envelope.Error.Code)
}

func TestDispatchedProfileClearEffectRemovesTheProfilesProviders(t *testing.T) {
	previousInit := isInit.Load()
	previousHome := C.Path.HomeDir()
	t.Cleanup(func() {
		isInit.Store(previousInit)
		C.SetHomeDir(previousHome)
	})
	isInit.Store(true)

	home := t.TempDir()
	C.SetHomeDir(home)
	_, target := providerPaths(home, 7)
	require.NoError(t, os.MkdirAll(target, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(target, "subscription.yaml"), []byte("proxies: []\n"), 0o600))

	answer := answerBytes(MethodCall{
		ID:        "8",
		Method:    profileClearEffectMethod,
		Arguments: json.RawMessage(`{"profile-id":7}`),
	})

	var envelope struct {
		Result json.RawMessage `json:"result"`
		Error  *MethodError    `json:"error"`
	}
	require.NoError(t, json.Unmarshal(answer, &envelope))
	require.Nil(t, envelope.Error, "answer = %s", answer)
	require.Equal(t, "null", string(envelope.Result))
	require.NoFileExists(t, filepath.Join(target, "subscription.yaml"))
}

// listedRuleSetProvider is a rule-set provider of the kind the tunnel actually
// lists: a file vehicle, so the answer carries a path beside the name.
func listedRuleSetProvider(t *testing.T, name string) cp.RuleProvider {
	t.Helper()
	return rp.NewRuleSetProvider(
		name,
		cp.Domain,
		cp.TextRule,
		0,
		resource.NewFileVehicle(filepath.Join(t.TempDir(), name+`.yaml`)),
		[]string{"MATCH,DIRECT"},
		nil,
		nil,
	)
}

// A side load writes the subscription's content straight through, which is how
// a profile whose file the host already holds gets loaded without a download.
func TestDispatchedProviderSideLoadWritesTheContent(t *testing.T) {
	rp.SetTunnel(tunnel.Tunnel)
	ruleSet := rp.NewRuleSetProvider(
		"ruleset", cp.Domain, cp.YamlRule, 0,
		resource.NewFileVehicle(filepath.Join(t.TempDir(), "ruleset.yaml")),
		nil, nil, rules.ParseRule,
	).(*rp.RuleSetProvider)
	withTunnelProviders(t, nil, map[string]cp.RuleProvider{"ruleset": ruleSet})
	require.Zero(t, ruleSet.Count(), "the rule set starts empty")

	answer := answerBytes(MethodCall{
		ID:        "side",
		Method:    providerSideLoadMethod,
		Arguments: json.RawMessage(`{"name":"ruleset","data":"payload:\n  - example.com\n"}`),
	})

	var envelope struct {
		Error *MethodError `json:"error"`
	}
	require.NoError(t, json.Unmarshal(answer, &envelope))
	require.Nil(t, envelope.Error, "answer = %s", answer)
	require.NotZero(t, ruleSet.Count(),
		"the content the host handed over is in the rule set, not just accepted")
}

// The Android host's first call is init, and every later one reads back what it
// set; a host that asked before init must be told the core is not ready.
func TestDispatchedInitAnswersTheStateItSets(t *testing.T) {
	previousInit := isInit.Load()
	previousRunning := isRunning.Load()
	previousHome := C.Path.HomeDir()
	previousVersion := sdkVersion.Load()
	t.Cleanup(func() {
		isInit.Store(previousInit)
		setRunning(previousRunning)
		C.SetHomeDir(previousHome)
		sdkVersion.Store(previousVersion)
	})
	isInit.Store(false)

	home := t.TempDir()
	answer := answerBytes(MethodCall{
		ID:        "init",
		Method:    coreInitMethod,
		Arguments: json.RawMessage(`{"home-dir":"` + filepath.ToSlash(home) + `","version":7}`),
	})

	var envelope struct {
		Result json.RawMessage `json:"result"`
		Error  *MethodError    `json:"error"`
	}
	require.NoError(t, json.Unmarshal(answer, &envelope))
	require.Nil(t, envelope.Error, "answer = %s", answer)
	require.Equal(t, "null", string(envelope.Result), "answer = %s", answer)
	require.True(t, isInit.Load(), "init left the core uninitialised")
	require.Equal(t, filepath.ToSlash(home), C.Path.HomeDir(), "the home the host named is not the one the core uses")
	require.EqualValues(t, 7, sdkVersion.Load())

	answer = answerBytes(MethodCall{ID: "initialized", Method: coreInitializedMethod})
	require.NoError(t, json.Unmarshal(answer, &envelope))
	require.Nil(t, envelope.Error, "answer = %s", answer)
	require.Equal(t, "true", string(envelope.Result), "answer = %s", answer)

	isInit.Store(false)
	answer = answerBytes(MethodCall{ID: "not-initialized", Method: coreInitializedMethod})
	require.NoError(t, json.Unmarshal(answer, &envelope))
	require.Equal(t, "false", string(envelope.Result), "answer = %s", answer)

	setRunning(true)
	answer = answerBytes(MethodCall{ID: "listener-stop", Method: listenerStopMethod})
	require.NoError(t, json.Unmarshal(answer, &envelope))
	require.Nil(t, envelope.Error, "answer = %s", answer)
	require.False(t, isRunning.Load(), "stopping the listeners left the core running them")
}

func TestMethodErrorCarriesTheMessageTheHostReads(t *testing.T) {
	require.EqualError(t, &MethodError{Code: "core_error", Message: "boom"}, "boom")
}

// The watch entry is the host's only hold on the poller, and it carries the
// call order, so the answer has to be the state the poll would keep current.
func TestDispatchedRouteWatchAnswersTheCurrentStateAndTheBadCall(t *testing.T) {
	recorder := recordRoutes(t)
	// An assertion that fails halfway must not leave the poller running over
	// the tests that follow.
	t.Cleanup(func() {
		answerBytes(MethodCall{
			Method:    routeWatchMethod,
			Arguments: json.RawMessage(`{"watch":false}`),
			seq:       methodCallSeq.Add(1),
		})
	})

	answered := answerBytes(MethodCall{
		ID:        "watch-on",
		Method:    routeWatchMethod,
		Arguments: json.RawMessage(`{"watch":true}`),
		seq:       methodCallSeq.Add(1),
	})

	var envelope struct {
		Result RouteState   `json:"result"`
		Error  *MethodError `json:"error"`
	}
	require.NoError(t, json.Unmarshal(answered, &envelope))
	require.Nil(t, envelope.Error, "answer = %s", answered)
	require.Equal(t, routeState(), envelope.Result, "answer = %s", answered)
	require.Empty(t, recorder.published(), "the watch answers the state it holds and publishes on a change")

	currentRoute.mu.Lock()
	polling := currentRoute.stopPoll != nil
	currentRoute.mu.Unlock()
	require.True(t, polling, "watching starts the poll")

	rejected := answerBytes(MethodCall{
		ID:        "watch-bad",
		Method:    routeWatchMethod,
		Arguments: json.RawMessage(`{"watch":`),
		seq:       methodCallSeq.Add(1),
	})
	var refused struct {
		Error *MethodError `json:"error"`
	}
	require.NoError(t, json.Unmarshal(rejected, &refused))
	require.NotNil(t, refused.Error, "answer = %s", rejected)
	require.Equal(t, "invalid_arguments", refused.Error.Code)
	currentRoute.mu.Lock()
	stillPolling := currentRoute.stopPoll != nil
	currentRoute.mu.Unlock()
	require.True(t, stillPolling, "a call that could not be read left the poller alone")

	answerBytes(MethodCall{
		ID:        "watch-off",
		Method:    routeWatchMethod,
		Arguments: json.RawMessage(`{"watch":false}`),
		seq:       methodCallSeq.Add(1),
	})
	currentRoute.mu.Lock()
	polling = currentRoute.stopPoll != nil
	currentRoute.mu.Unlock()
	require.False(t, polling, "releasing the route stops the poll")
}
