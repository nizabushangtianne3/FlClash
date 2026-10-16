package core

import (
	"context"
	"maps"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

// mihomo has no hook for a health check moving a URLTest or Fallback pick, so
// the picks are re-read on this timer while the host watches.
// Failover and group health checks invalidate the route immediately; this
// slower poll only catches provider and rule-set changes from mihomo itself.
const routePollInterval = 5 * time.Second

type routeTracker struct {
	mu               sync.Mutex
	epoch            uint64
	picksVersion     uint64
	picks            map[string]string
	providerVersions map[string]uint32
	ruleSets         map[string]any
	watched          bool
	watchSeq         uint64
	stopPoll         context.CancelFunc
}

var (
	routeRefreshPending atomic.Bool
	routeRefreshDirty   atomic.Bool
)

func routeWatched() bool {
	currentRoute.mu.Lock()
	defer currentRoute.mu.Unlock()
	return currentRoute.watched
}

func scheduleRouteRefresh() {
	if !isRunning.Load() {
		return
	}
	routeRefreshDirty.Store(true)
	if !routeRefreshPending.CompareAndSwap(false, true) {
		return
	}
	if !routeWatched() {
		routeRefreshPending.Store(false)
		routeRefreshDirty.Store(false)
		return
	}
	safeGo("route invalidate", func() {
		for {
			dirty := routeRefreshDirty.Swap(false)
			if dirty && isRunning.Load() {
				refreshRoute()
			}
			routeRefreshPending.Store(false)
			if !routeRefreshDirty.Load() {
				return
			}
			if !routeRefreshPending.CompareAndSwap(false, true) {
				return
			}
		}
	})
}

func init() {
	outboundgroup.SetRouteInvalidate(scheduleRouteRefresh)
}

var (
	currentRoute routeTracker

	publishRoute = func(state RouteState) {
		sendMessage(RouteChangedMessage, state)
	}
)

func routeStateLocked() RouteState {
	picks := currentRoute.picks
	if picks == nil {
		picks = map[string]string{}
	}
	return RouteState{
		CoreEpoch:    currentRoute.epoch,
		PicksVersion: currentRoute.picksVersion,
		Picks:        maps.Clone(picks),
	}
}

func routeState() RouteState {
	currentRoute.mu.Lock()
	defer currentRoute.mu.Unlock()
	return routeStateLocked()
}

func routeStamp() (epoch, picksVersion uint64) {
	currentRoute.mu.Lock()
	defer currentRoute.mu.Unlock()
	return currentRoute.epoch, currentRoute.picksVersion
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
	providers := tunnel.ProvidersSnapshot()
	versions := make(map[string]uint32, len(providers))
	for name, p := range providers {
		versions[name] = p.Version()
	}
	return picks, versions
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

// A provider that swapped its list is a structural change: the names may
// survive while the servers behind them do not. The caller holds selectMu.
func refreshRouteLocked(structural bool) {
	picks, versions := readPicks()
	ruleSets := readRuleSets()

	currentRoute.mu.Lock()
	if currentRoute.providerVersions != nil && !maps.Equal(versions, currentRoute.providerVersions) {
		structural = true
	}
	if currentRoute.ruleSets != nil && !maps.Equal(ruleSets, currentRoute.ruleSets) {
		structural = true
	}
	currentRoute.providerVersions = versions
	currentRoute.ruleSets = ruleSets
	if structural {
		currentRoute.epoch++
	}
	changed := structural
	if !maps.Equal(picks, currentRoute.picks) {
		currentRoute.picks = picks
		currentRoute.picksVersion++
		changed = true
	}
	var state RouteState
	watched := currentRoute.watched
	if changed && watched {
		state = routeStateLocked()
	}
	currentRoute.mu.Unlock()

	if changed && watched {
		publishRoute(state)
	}
}
func refreshRoute() {
	selectMu.Lock()
	defer selectMu.Unlock()
	refreshRouteLocked(false)
}

func bumpRouteEpoch() {
	selectMu.Lock()
	defer selectMu.Unlock()
	refreshRouteLocked(true)
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
				refreshRoute()
			}
		}
	}
}
