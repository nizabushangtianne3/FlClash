package core

import (
	"context"
	"fmt"
	"maps"
	"slices"
	"sync"
	"time"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
)

// Group re-picks and rule-set swaps both notify, so this poll is the only net
// left for a proxy provider swapping its list behind the host's back.
const (
	routePollInterval  = 5 * time.Second
	routeResetDebounce = 5 * time.Millisecond
)

// An answer outlives a move while the hosts it reached keep their exits.
type routeChange int

const (
	routeUnchanged routeChange = iota
	routeMoved
	routeReset
)

type routeTracker struct {
	mu               sync.Mutex
	epoch            uint64
	version          uint64
	picks            map[string]string
	providerVersions map[string]uint32
	ruleSets         map[string]any
	watched          bool
	watchSeq         uint64
	stopPoll         context.CancelFunc
}

var (
	routeRefreshMu          sync.Mutex
	routeRefreshQueued      bool
	routeRefreshQueuedReset bool
)

func routeWatched() bool {
	currentRoute.mu.Lock()
	defer currentRoute.mu.Unlock()
	return currentRoute.watched
}

func scheduleRouteRefresh(reset bool) {
	if !isRunning.Load() {
		return
	}
	routeRefreshMu.Lock()
	defer routeRefreshMu.Unlock()
	routeRefreshQueuedReset = routeRefreshQueuedReset || reset
	if routeRefreshQueued {
		return
	}
	routeRefreshQueued = true
	if !routeWatched() {
		routeRefreshQueued = false
		routeRefreshQueuedReset = false
		return
	}
	safeGo("route invalidate", routeRefreshWorker)
}

func routeRefreshWorker() {
	for {
		routeRefreshMu.Lock()
		if !routeWatched() {
			routeRefreshQueued = false
			routeRefreshQueuedReset = false
			routeRefreshMu.Unlock()
			return
		}
		reset := routeRefreshQueuedReset
		routeRefreshQueuedReset = false
		routeRefreshMu.Unlock()
		if reset {
			time.Sleep(routeResetDebounce)
			routeRefreshMu.Lock()
			routeRefreshQueued = false
			routeRefreshQueuedReset = false
			routeRefreshMu.Unlock()
			bumpRouteEpoch()
			return
		}
		refreshRouteVersions()
		routeRefreshMu.Lock()
		more := routeRefreshQueuedReset
		if !more {
			routeRefreshQueued = false
		}
		routeRefreshMu.Unlock()
		if !more {
			return
		}
	}
}

func init() {
	outboundgroup.SetRouteInvalidate(func() { scheduleRouteRefresh(false) })
	tunnel.Tunnel.RuleUpdateCallback().Register(func(cp.RuleProvider) {
		scheduleRouteRefresh(true)
	})
}

var (
	currentRoute routeTracker

	publishRoute = func(state RouteState) {
		sendMessage(RouteChangedMessage, state)
	}
)

func routeStateLocked() RouteState {
	return RouteState{
		CoreEpoch:    currentRoute.epoch,
		RouteVersion: currentRoute.version,
	}
}

func routeState() RouteState {
	currentRoute.mu.Lock()
	defer currentRoute.mu.Unlock()
	return routeStateLocked()
}

func routeStamp() (epoch, version uint64) {
	currentRoute.mu.Lock()
	defer currentRoute.mu.Unlock()
	return currentRoute.epoch, currentRoute.version
}

// routeGroupNames prefers the parsed config list, falling back to the map for hosts that fill the tunnel without one.
func routeGroupNames(proxies map[string]constant.Proxy) []string {
	names := proxyGroupNames(config.GetProxyNameList(), func(name string) (constant.AdapterType, bool) {
		proxy, ok := proxies[name]
		if !ok || proxy == nil {
			return 0, false
		}
		return proxy.Type(), true
	})
	if len(names) > 0 {
		return names
	}
	for name, proxy := range proxies {
		if proxy != nil && isProxyGroupType(proxy.Type()) {
			names = append(names, name)
		}
	}
	return names
}

func readPicks() (map[string]string, map[string]uint32) {
	proxies := tunnel.AllProxies()
	picks := map[string]string{}
	for _, name := range routeGroupNames(proxies) {
		if group, ok := adapterAs[pickableGroup](proxies[name]); ok {
			selected := group.Now()
			if selected != "" {
				picks[name] = selected
			}
		}
	}
	return picks, readProviderVersions()
}

func readProviderVersions() map[string]uint32 {
	providers := tunnel.ProvidersSnapshot()
	versions := make(map[string]uint32, len(providers))
	for name, p := range providers {
		versions[name] = p.Version()
	}
	return versions
}

// mihomo swaps in a new strategy each time a rule set, manually or on its
// interval, loads new content.
func readRuleSets() map[string]any {
	providers := tunnel.RuleProvidersSnapshot()
	ruleSets := make(map[string]any, len(providers))
	for name, p := range providers {
		ruleSets[name] = p.Strategy()
	}
	return ruleSets
}

// The caller holds selectMu. A nil ruleSets skips that scan: the poll leaves
// rule sets to their update event instead of rescanning them every tick.
func applyRouteSnapshot(picks map[string]string, versions map[string]uint32, ruleSets map[string]any, change routeChange) {
	currentRoute.mu.Lock()
	if currentRoute.providerVersions != nil && !maps.Equal(versions, currentRoute.providerVersions) {
		// A provider may bump its version for a rewrite with equivalent rules;
		// only the resulting picks and rule sets may move the route.
		change = max(change, routeMoved)
	}
	if ruleSets != nil && currentRoute.ruleSets != nil && !maps.Equal(ruleSets, currentRoute.ruleSets) {
		change = max(change, routeMoved)
	}
	if !maps.Equal(picks, currentRoute.picks) {
		change = max(change, routeMoved)
	}
	currentRoute.providerVersions = versions
	if ruleSets != nil {
		currentRoute.ruleSets = ruleSets
	}
	if change == routeReset {
		currentRoute.epoch++
	}
	currentRoute.picks = picks
	var state RouteState
	if change != routeUnchanged {
		currentRoute.version++
	}
	watched := currentRoute.watched
	if change != routeUnchanged && watched {
		state = routeStateLocked()
	}
	currentRoute.mu.Unlock()
	if change != routeUnchanged && watched {
		publishRoute(state)
	}
}

// A provider that swapped its list is a structural change: the names may
// survive while the servers behind them do not. The caller holds selectMu.
func refreshRouteLocked(change routeChange) {
	picks, versions := readPicks()
	applyRouteSnapshot(picks, versions, readRuleSets(), change)
}

// The steady-state poll body. Rule sets and group picks notify on their own,
// so this only re-reads provider versions and the picks they may have moved.
func refreshRouteVersions() {
	picks, versions := readPicks()
	applyRouteSnapshot(picks, versions, nil, routeUnchanged)
}

func refreshRoute() {
	selectMu.Lock()
	defer selectMu.Unlock()
	picks, versions := readPicks()
	applyRouteSnapshot(picks, versions, readRuleSets(), routeUnchanged)
}

func bumpRouteEpoch() {
	selectMu.Lock()
	defer selectMu.Unlock()
	picks, versions := readPicks()
	applyRouteSnapshot(picks, versions, readRuleSets(), routeReset)
}

func changeRoute(change routeChange) {
	selectMu.Lock()
	defer selectMu.Unlock()
	refreshRouteLocked(change)
}

func handleWatchRoute(watch bool, seq uint64) RouteState {
	currentRoute.mu.Lock()
	if seq < currentRoute.watchSeq {
		state := routeStateLocked()
		currentRoute.mu.Unlock()
		return state
	}
	currentRoute.mu.Unlock()

	refreshRoute()

	currentRoute.mu.Lock()
	defer currentRoute.mu.Unlock()
	if seq < currentRoute.watchSeq {
		return routeStateLocked()
	}
	currentRoute.watchSeq = seq
	currentRoute.watched = watch
	if watch && currentRoute.stopPoll == nil {
		ctx, cancel := context.WithCancel(context.Background())
		currentRoute.stopPoll = cancel
		go pollRoute(ctx)
	}
	if !watch {
		stopRoutePollLocked()
	}
	return routeStateLocked()
}

// The stop takes its own place in the call order: a watch dispatched before
// it, the newest one included, may still be waiting to run.
func stopRouteWatch() {
	currentRoute.mu.Lock()
	defer currentRoute.mu.Unlock()
	currentRoute.watchSeq = max(currentRoute.watchSeq, methodCallSeq.Add(1))
	currentRoute.watched = false
	stopRoutePollLocked()
}

func stopRoutePollLocked() {
	if currentRoute.stopPoll != nil {
		currentRoute.stopPoll()
		currentRoute.stopPoll = nil
	}
}

// With the listeners down the host pins every probe to DIRECT, so the picks
// do not matter until they come back.
func pollRoute(ctx context.Context) {
	ticker := time.NewTicker(routePollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if isRunning.Load() {
				refreshRouteVersions()
			}
		}
	}
}

type RouteHit struct {
	Host  string `json:"host"`
	Proxy string `json:"proxy,omitempty"`
	Exit  string `json:"exit"`
}

type CheckRoutesParams struct {
	Routes [][]RouteHit `json:"routes"`
}

type RouteCheck struct {
	CoreEpoch    uint64 `json:"core-epoch"`
	RouteVersion uint64 `json:"route-version"`
	Held         []bool `json:"held"`
}

// The stamp is read before any route resolves, so a move that lands meanwhile
// is checked again under its own version rather than missed.
func handleCheckRoutes(params *CheckRoutesParams) *RouteCheck {
	epoch, version := routeStamp()
	exits := map[RouteHit]string{}
	held := make([]bool, len(params.Routes))
	for index, route := range params.Routes {
		held[index] = len(route) > 0
		for _, hit := range route {
			key := RouteHit{Host: hit.Host, Proxy: hit.Proxy}
			exit, resolved := exits[key]
			if !resolved {
				exit = resolveExit(hit.Host, hit.Proxy)
				exits[key] = exit
			}
			if exit != hit.Exit {
				held[index] = false
				break
			}
		}
	}
	return &RouteCheck{CoreEpoch: epoch, RouteVersion: version, Held: held}
}

func resolveExit(host string, proxyName string) string {
	metadata, err := probeMetadata(host)
	if proxyName != "" {
		return exitThrough(lookupProxy(proxyName), metadata)
	}
	if err != nil {
		return ""
	}
	proxy, err := tunnel.ResolveRoute(metadata)
	if err != nil {
		return ""
	}
	return exitThrough(proxy, metadata)
}

func exitThrough(proxy constant.Proxy, metadata *constant.Metadata) string {
	for proxy != nil {
		if proxy.Type() == constant.LoadBalance {
			return exitName(proxy)
		}
		next := proxy.Unwrap(metadata, false)
		if next == nil {
			return exitName(proxy)
		}
		proxy = next
	}
	return ""
}

// Chains run from the hop that dialed out to the outermost group, so they are
// read from the end to meet the load balancer exitThrough stops at.
func exitOfChains(chains []string) string {
	if len(chains) == 0 {
		return ""
	}
	proxies := tunnel.AllProxies()
	for _, name := range slices.Backward(chains[1:]) {
		if proxy := proxies[name]; proxy != nil && proxy.Type() == constant.LoadBalance {
			return exitName(proxy)
		}
	}
	if leaf := proxies[chains[0]]; leaf != nil {
		return exitName(leaf)
	}
	return ""
}

// A load balancer spreads connections without the route moving, so it is the
// exit; the server counts since a provider can swap the node behind a name.
func exitName(proxy constant.Proxy) string {
	return fmt.Sprintf("%q %s %s", proxy.Name(), proxy.Type(), proxy.Addr())
}
