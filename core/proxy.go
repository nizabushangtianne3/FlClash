package core

import (
	"errors"
	"maps"
	"os"
	"reflect"
	"slices"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/common/convert"
	"github.com/metacubex/mihomo/common/jsonutil"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

const globalProxyName = "GLOBAL"

var (
	// Selection writes need the mutual exclusion mihomo's Selector.Set lacks.
	// The lock order is configMu -> selectMu.
	selectMu sync.Mutex

	errGroupNotFound    = errors.New("Not found group")
	errGroupInvalidType = errors.New("Group has invalid proxy type")
	errGroupNotSelect   = errors.New("Group is not selectable")
)

type pickableGroup interface {
	outboundgroup.ProxyGroup
	outboundgroup.SelectAble
}

func lookupProxy(name string) constant.Proxy {
	return tunnel.AllProxies()[name]
}

func adapterAs[T any](proxy constant.Proxy) (group T, ok bool) {
	outbound, ok := proxy.(*adapter.Proxy)
	if !ok {
		return group, false
	}
	group, ok = outbound.ProxyAdapter.(T)
	return group, ok
}

func isProxyGroupType(adapterType constant.AdapterType) bool {
	switch adapterType {
	case constant.Selector, constant.URLTest, constant.Fallback, constant.Relay, constant.LoadBalance:
		return true
	default:
		return false
	}
}

func proxyGroupNames(
	nameList []string,
	typeOf func(name string) (constant.AdapterType, bool),
) []string {
	isGroup := func(name string) bool {
		adapterType, ok := typeOf(name)
		return ok && isProxyGroupType(adapterType)
	}

	hasGlobal := false
	names := make([]string, 0, len(nameList)+1)
	for _, name := range nameList {
		if name == globalProxyName {
			hasGlobal = true
		}
		if isGroup(name) {
			names = append(names, name)
		}
	}
	if !hasGlobal && isGroup(globalProxyName) {
		names = append([]string{globalProxyName}, names...)
	}
	return names
}

func handleGetProxies() *proxiesAnswer {
	proxies := tunnel.AllProxies()

	names := proxyGroupNames(config.GetProxyNameList(), func(name string) (constant.AdapterType, bool) {
		p, ok := proxies[name]
		if !ok || p == nil {
			return 0, false
		}
		return p.Type(), true
	})

	return &proxiesAnswer{proxies: proxies, names: names}
}

// The host re-reads the whole proxy table whenever the proxies page opens or a
// selection changes. Building it as a map[string]any view cost one boxed value
// per node plus a fresh buffer per group before the envelope marshal copied
// everything again; the answer now goes out the way the connections table does,
// encoded once into the frame the transport reads.
type proxiesAnswer struct {
	proxies map[string]constant.Proxy
	names   []string
}

// frameFor implements frameWriter.
func (a *proxiesAnswer) frameFor(id string) []byte {
	buf := make([]byte, 0, a.answerSize()+len(id)+32)
	buf = append(buf, `{"id":`...)
	buf = jsonutil.AppendString(buf, id)
	buf = append(buf, `,"result":`...)
	buf = a.appendJSON(buf)
	return append(buf, '}')
}

func (a *proxiesAnswer) answerSize() int {
	size := 64 + len(a.names)*24
	for name, proxy := range a.proxies {
		size += len(name) + 32
		if isProxyGroupType(proxy.Type()) {
			size += 320
		}
	}
	return size
}

func (a *proxiesAnswer) appendJSON(dst []byte) []byte {
	snapshot := cachedProxiesSnapshot(a.proxies)

	buf := append(dst, `{"proxies":{`...)
	for i, name := range snapshot.names {
		if i > 0 {
			buf = append(buf, ',')
		}
		buf = jsonutil.AppendString(buf, name)
		buf = append(buf, ':')
		if view := snapshot.nodeViews[i]; view != nil {
			// Node fields never change while the snapshot lives, so the view
			// rides the same identity cache as the sorted names.
			buf = append(buf, view...)
		} else {
			buf = appendProxyView(buf, a.proxies[name])
		}
	}
	buf = append(buf, `},"all":[`...)
	for i, name := range a.names {
		if i > 0 {
			buf = append(buf, ',')
		}
		buf = jsonutil.AppendString(buf, name)
	}
	return append(buf, `]}`...)
}

// A group document carries its own name, so it reaches the host exactly as its
// AppendJSON writes it; the built-in GLOBAL is the one document that needs an
// edit, spliced in place instead of a decode/marshal round trip.
func appendProxyView(dst []byte, proxy constant.Proxy) []byte {
	if !isProxyGroupType(proxy.Type()) {
		return appendNodeView(dst, proxy)
	}

	appender, ok := proxy.Adapter().(interface{ AppendJSON([]byte) []byte })
	if !ok {
		data, err := proxy.Adapter().MarshalJSON()
		if err != nil {
			log.Warnln("[APP] encode group %s: %v", proxy.Name(), err)
			return appendNodeView(dst, proxy)
		}
		dst = append(dst, data...)
	} else {
		dst = appender.AppendJSON(dst)
	}
	if isBuiltInGlobal(proxy) {
		return appendGlobalHidden(dst)
	}
	return dst
}

func appendNodeView(dst []byte, proxy constant.Proxy) []byte {
	dst = append(dst, `{"name":`...)
	dst = jsonutil.AppendString(dst, proxy.Name())
	dst = append(dst, `,"type":`...)
	dst = jsonutil.AppendString(dst, proxy.Type().String())
	if provider := proxy.ProxyInfo().ProviderName; provider != "" {
		dst = append(dst, `,"provider-name":`...)
		dst = jsonutil.AppendString(dst, provider)
	}
	return append(dst, '}')
}

// JSON object key order is not semantic, so hidden joins at the end rather
// than the alphabetical slot a map round trip gave it.
func appendGlobalHidden(dst []byte) []byte {
	dst = dst[:len(dst)-1]
	if len(dst) > 0 && dst[len(dst)-1] != '{' {
		dst = append(dst, ',')
	}
	return append(dst, `"hidden":true}`...)
}

// The proxy table is a tunnel-held snapshot whose map identity changes exactly
// when the snapshot is rebuilt, so the answer's static parts ride on that
// identity: the sorted name list and, per node, the pre-encoded node view (a
// node's name, type and provider never change while the snapshot lives; group
// documents do, so they stay nil here and encode live).
var sortedProxyNames atomic.Pointer[sortedProxyNameCache]

type sortedProxyNameCache struct {
	snapshot  any
	names     []string
	nodeViews [][]byte
}

func cachedProxiesSnapshot(proxies map[string]constant.Proxy) *sortedProxyNameCache {
	if cache := sortedProxyNames.Load(); cache != nil &&
		reflect.ValueOf(cache.snapshot).Pointer() == reflect.ValueOf(proxies).Pointer() {
		return cache
	}
	names := make([]string, 0, len(proxies))
	for name := range proxies {
		names = append(names, name)
	}
	slices.Sort(names)
	nodeViews := make([][]byte, len(names))
	for i, name := range names {
		proxy := proxies[name]
		if isProxyGroupType(proxy.Type()) {
			continue
		}
		nodeViews[i] = appendNodeView(nil, proxy)
	}
	cache := &sortedProxyNameCache{snapshot: proxies, names: names, nodeViews: nodeViews}
	sortedProxyNames.Store(cache)
	return cache
}

// mihomo builds its own GLOBAL over the reserved provider, which no configured
// group can use; a GLOBAL group from the config takes its place.
func isBuiltInGlobal(proxy constant.Proxy) bool {
	group, ok := proxy.Adapter().(outboundgroup.ProxyGroup)
	if !ok || proxy.Name() != globalProxyName {
		return false
	}
	for _, pd := range group.Providers() {
		if pd.Name() == provider.ReservedName {
			return true
		}
	}
	return false
}

func selectableGroup(groupName string) (pickableGroup, error) {
	group := lookupProxy(groupName)
	if group == nil {
		return nil, errGroupNotFound
	}
	adapterProxy, ok := group.(*adapter.Proxy)
	if !ok {
		return nil, errGroupInvalidType
	}
	selector, ok := adapterProxy.ProxyAdapter.(pickableGroup)
	if !ok {
		return nil, errGroupNotSelect
	}
	return selector, nil
}

func handleChangeProxy(params *ChangeProxyParams) *ChangeProxyResult {
	selectMu.Lock()
	defer selectMu.Unlock()

	selector, err := selectableGroup(params.GroupName)
	if err != nil {
		return &ChangeProxyResult{Message: err.Error()}
	}
	before := selector.Now()
	if params.ProxyName == "" {
		selector.ForceSet(params.ProxyName)
	} else if err := selector.Set(params.ProxyName); err != nil {
		return &ChangeProxyResult{Message: err.Error()}
	}
	changed := selector.Now() != before
	refreshRouteLocked(routeUnchanged)
	return &ChangeProxyResult{Changed: changed}
}

func patchSelectGroup(mapping map[string]string) {
	selectMu.Lock()
	defer selectMu.Unlock()
	proxies := tunnel.AllProxies()
	for name, selected := range mapping {
		if selector, ok := adapterAs[outboundgroup.SelectAble](proxies[name]); ok {
			selector.ForceSet(selected)
		}
	}
}

// Tailscale and EasyTier register a DNS client under the proxy name when built
// and drop that name's entry on Close, so a probe under the real name would
// take the resolver from a running proxy of the same name.
const validationNameSuffix = "\x00validate"

// The per-proxy parser the config load runs; checks across proxies, such as
// duplicate names, are left to the load itself.
func handleValidateProxies(mappings []map[string]any) []string {
	results := make([]string, len(mappings))
	for i, mapping := range mappings {
		name, _ := mapping["name"].(string)
		probe := mapping
		switch mapping["type"] {
		case "tailscale", "easytier":
			probe = maps.Clone(mapping)
			probe["name"] = name + validationNameSuffix
		}
		proxy, err := adapter.ParseProxy(probe, nil)
		if err != nil {
			results[i] = strings.ReplaceAll(err.Error(), validationNameSuffix, "")
			continue
		}
		_ = proxy.Close()
	}
	return results
}

// The share-link list a proxy provider also accepts, plain or base64.
func handleConvertProxies(path string) ([]map[string]any, error) {
	buf, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return convert.ConvertsV2Ray(buf)
}
