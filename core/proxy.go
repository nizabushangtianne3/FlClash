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
	// A relay group no longer parses: outboundgroup's parser answers that the
	// type was removed, so no proxy carries it.
	case constant.Selector, constant.URLTest, constant.Fallback, constant.LoadBalance:
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

// The group projection depends on both the tunnel snapshot and the host's
// configured name list. Cache that exact pair so a steady dashboard does not
// rebuild and reallocate the all-list on every read.
type groupProjectionCache struct {
	snapshot any
	source   []string
	names    []string
}

var groupProjection atomic.Pointer[groupProjectionCache]

func sameProxySnapshot(left, right any) bool {
	return reflect.ValueOf(left).Pointer() == reflect.ValueOf(right).Pointer()
}

func handleGetProxies() *proxiesAnswer {
	proxies := tunnel.AllProxies()
	source := config.GetProxyNameList()

	if cache := groupProjection.Load(); cache != nil &&
		sameProxySnapshot(cache.snapshot, proxies) && slices.Equal(source, cache.source) {
		return &proxiesAnswer{proxies: proxies, names: cache.names}
	}

	names := proxyGroupNames(source, func(name string) (constant.AdapterType, bool) {
		p, ok := proxies[name]
		if !ok || p == nil {
			return 0, false
		}
		return p.Type(), true
	})
	groupProjection.Store(&groupProjectionCache{
		snapshot: proxies,
		source:   slices.Clone(source),
		names:    names,
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
	return 64 + len(a.names)*24 + cachedProxiesSnapshot(a.proxies).sizeBase
}

func (a *proxiesAnswer) appendJSON(dst []byte) []byte {
	snapshot := cachedProxiesSnapshot(a.proxies)

	buf := append(dst, `{"proxies":{`...)
	buf = a.appendProxyTable(buf, snapshot)
	buf = append(buf, `},"all":[`...)
	for i, name := range a.names {
		if i > 0 {
			buf = append(buf, ',')
		}
		buf = jsonutil.AppendString(buf, name)
	}
	return append(buf, `]}`...)
}

// appendProxyTable writes the whole table under one document-cache lock: a
// lock per group was paid on every answer, and a table is answered in one
// pass anyway.
func (a *proxiesAnswer) appendProxyTable(buf []byte, snapshot *sortedProxyNameCache) []byte {
	groupDocsMu.Lock()
	defer groupDocsMu.Unlock()
	for i := range snapshot.names {
		buf = append(buf, snapshot.keySpans[i]...)
		if view := snapshot.nodeViews[i]; view != nil {
			// Node fields never change while the snapshot lives, so the view
			// rides the same identity cache as the sorted names.
			buf = append(buf, view...)
			continue
		}
		buf = appendGroupDoc(buf, snapshot.groupSlots[i])
	}
	return buf
}

// A group document carries its own name, so it reaches the host exactly as its
// AppendJSON writes it; the built-in GLOBAL is the one document that needs an
// edit, spliced in place instead of a decode/marshal round trip.
// The caller holds the document cache lock.
func appendGroupDoc(dst []byte, slot *groupDocSlot) []byte {
	// A slot for a kind the document cache does not cover still carries the
	// proxy, and its document is encoded live.
	if slot.group == nil {
		return appendGroupDocument(dst, slot.proxy)
	}
	key := groupDocKeyOf(slot)
	if slot.doc != nil && slot.key == key &&
		groupDocVersionsMatch(slot.group, slot.versions) {
		return append(dst, slot.doc...)
	}
	start := len(dst)
	dst = appendGroupDocument(dst, slot.proxy)
	slot.key, slot.versions = key, groupDocVersions(slot.group)
	slot.doc = slices.Clone(dst[start:])
	return dst
}

func appendGroupDocument(dst []byte, proxy constant.Proxy) []byte {
	// AppendJSON is part of ProxyAdapter, so a group document always has one.
	dst = proxy.Adapter().AppendJSON(dst)
	if isBuiltInGlobal(proxy) {
		dst = appendGlobalHidden(dst)
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
// documents are cached separately, below).
var sortedProxyNames atomic.Pointer[sortedProxyNameCache]

type sortedProxyNameCache struct {
	snapshot any
	names    []string
	// keySpans are the `"name":` members of the proxies object, separators
	// included, precomputed once per snapshot so an answer only memcopies
	// them; the escaped length comes from jsonutil.StringLen.
	keySpans  [][]byte
	nodeViews [][]byte
	// groupSlots aligns with names: a nil element marks a node row whose view
	// is precomputed, and a non-nil one carries that group's document cache.
	groupSlots []*groupDocSlot
	// sizeBase is the answer's precomputed share: static key/node bytes, the
	// escaped all-list length and a conservative scaffold per cached group kind.
	sizeBase int
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
	keySpans := make([][]byte, len(names))
	nodeViews := make([][]byte, len(names))
	groupSlots := make([]*groupDocSlot, len(names))
	// A cached group member list commonly dominates its document. One larger
	// allocation is cheaper than the old 320B scaffold's repeated growslices.
	const groupScaffold = 768
	sizeBase := 64
	for i, name := range names {
		proxy := proxies[name]
		span := make([]byte, 0, jsonutil.StringLen(name)+4)
		if i > 0 {
			span = append(span, ',')
		}
		span = jsonutil.AppendString(span, name)
		keySpans[i] = append(span, ':')
		sizeBase += len(keySpans[i]) + jsonutil.StringLen(name) + 1
		if isProxyGroupType(proxy.Type()) {
			groupSlots[i] = newGroupDocSlot(proxy)
			sizeBase += groupScaffold
			continue
		}
		nodeViews[i] = appendNodeView(nil, proxy)
		sizeBase += len(nodeViews[i])
	}
	cache := &sortedProxyNameCache{
		snapshot:  proxies,
		names:     names,
		keySpans:  keySpans,
		nodeViews: nodeViews,
		groupSlots: groupSlots,
		sizeBase:  sizeBase,
	}
	sortedProxyNames.Store(cache)
	return cache
}

// A group document's mutable fields are the selection the answer reads and its
// member list. Selector exposes its selection as Now; URLTest and Fallback add
// a pinned selection (their fixed field) that moves independently of their
// live re-election, and a LoadBalance document has no selection field at all.
// Every other field is fixed at construction, so keying the cache on exactly
// those values keeps a re-selection, a re-election or a provider reload a
// cache miss while the steady state copies bytes.
type groupDocKey struct {
	now   string
	fixed string
}

var (
	groupDocsMu       sync.Mutex
)

// groupDocSlot is one group row's document cache. The slots ride the snapshot
// they were built for, so a rebuilt table starts with empty slots and an
// answer needs no map lookup to reach the row it is writing.
type groupDocSlot struct {
	proxy    constant.Proxy
	group    outboundgroup.ProxyGroup // nil for a kind the cache does not cover
	// The adapter type and the pinned-selection reader are fixed for the
	// proxy's life, so the answer path reads them from the slot instead of
	// dispatching into the proxy for them on every group.
	typ   constant.AdapterType
	fixed interface{ SelectedName() string }
	key      groupDocKey
	versions []uint32
	doc      []byte
}

// newGroupDocSlot builds the cache row for one group: the caller has already
// decided the proxy is a group, and every kind that parses is cacheable.
func newGroupDocSlot(proxy constant.Proxy) *groupDocSlot {
	adapterType := proxy.Type()
	slot := &groupDocSlot{proxy: proxy, typ: adapterType}
	group, ok := adapterAs[outboundgroup.ProxyGroup](proxy)
	if !ok {
		return slot
	}
	// The key of a URLTest or Fallback also names its pinned selection, so a
	// group whose adapter does not expose one stays on the live path instead
	// of failing that read on every answer.
	if adapterType == constant.URLTest || adapterType == constant.Fallback {
		fixed, ok := proxy.Adapter().(interface{ SelectedName() string })
		if !ok {
			return slot
		}
		slot.fixed = fixed
	}
	slot.group = group
	return slot
}

// groupDocKeyOf reads the values the live encode would write.
func groupDocKeyOf(slot *groupDocSlot) groupDocKey {
	switch slot.typ {
	case constant.Selector:
		return groupDocKey{now: slot.group.Now()}
	case constant.LoadBalance:
		return groupDocKey{}
	}
	// A slot carries a group only for the four cacheable kinds, so what is
	// left is a URLTest or a Fallback, whose document also names its pinned
	// selection.
	return groupDocKey{now: slot.group.Now(), fixed: slot.fixed.SelectedName()}
}

func groupDocVersions(group outboundgroup.ProxyGroup) []uint32 {
	providers := group.Providers()
	versions := make([]uint32, 0, len(providers))
	for _, pd := range providers {
		versions = append(versions, pd.Version())
	}
	return versions
}

// groupDocVersionsMatch compares without building a slice, so a cache hit
// allocates nothing.
func groupDocVersionsMatch(group outboundgroup.ProxyGroup, versions []uint32) bool {
	providers := group.Providers()
	if len(providers) != len(versions) {
		return false
	}
	for i, pd := range providers {
		if pd.Version() != versions[i] {
			return false
		}
	}
	return true
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
func handleValidateProxies(params ProxiesParams) []ValidationIssue {
	issues := []ValidationIssue{}
	for i, mapping := range params.Proxies {
		name, _ := mapping["name"].(string)
		probe := mapping
		switch mapping["type"] {
		case "tailscale", "easytier":
			probe = maps.Clone(mapping)
			probe["name"] = name + validationNameSuffix
		}
		proxy, err := adapter.ParseProxy(probe, nil)
		if err != nil {
			issues = append(issues, ValidationIssue{Index: i, Message: strings.ReplaceAll(err.Error(), validationNameSuffix, "")})
			continue
		}
		_ = proxy.Close()
	}
	return issues
}

// The share-link list a proxy provider also accepts, plain or base64.
func handleConvertProxies(params PathParams) ([]map[string]any, error) {
	buf, err := os.ReadFile(params.Path)
	if err != nil {
		return nil, err
	}
	return convert.ConvertsV2Ray(buf)
}
