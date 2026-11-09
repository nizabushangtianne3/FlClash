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

// sameProxyNameList reports whether two lists are the same one. The configured
// list is replaced rather than edited in place — SetProxyNameList is called
// once per config parse with the slice that parse built — so a shared identity
// is the same list, and a profile of a thousand nodes is not walked to learn
// what it already says.
func sameProxyNameList(left, right []string) bool {
	return len(left) == len(right) && (len(left) == 0 || &left[0] == &right[0])
}

func handleGetProxies() *proxiesAnswer {
	proxies := tunnel.AllProxies()
	source := config.GetProxyNameList()

	if cache := groupProjection.Load(); cache != nil &&
		sameProxySnapshot(cache.snapshot, proxies) && sameProxyNameList(cache.source, source) {
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
		source:   source,
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

// document implements frameWriter.
func (a *proxiesAnswer) document() []byte {
	snapshot := cachedProxiesSnapshot(a.proxies)

	// Refreshing the documents and assembling the answer share one lock: a
	// table is answered in a single pass, so a second answer cannot splice a
	// half-refreshed table into the cache.
	groupDocsMu.Lock()
	defer groupDocsMu.Unlock()

	liveDocs := refreshGroupDocs(snapshot)
	// The document is a pure function of the snapshot, the name list and the
	// documents the slots hold, so a table nothing moved in since the last
	// answer hands that document back instead of reassembling a byte per node.
	if cache := cachedProxiesFrame; cache != nil && !liveDocs && cache.matches(a) &&
		cache.generation == groupDocGeneration {
		return cache.document
	}

	buf := make([]byte, 0, a.documentSize())
	buf = a.appendDocument(buf, snapshot)
	// A table carrying a live-encoded group changes on every answer, so only
	// a fully keyed one gets its document remembered.
	if !liveDocs {
		cachedProxiesFrame = &proxiesFrameCache{
			snapshot:   a.proxies,
			names:      a.names,
			document:   buf,
			generation: groupDocGeneration,
		}
	}
	return buf
}

func (a *proxiesAnswer) documentSize() int {
	return 64 + len(a.names)*24 + cachedProxiesSnapshot(a.proxies).sizeBase
}

// appendDocument writes the whole proxy table and the display order the host
// reads it in.
func (a *proxiesAnswer) appendDocument(dst []byte, snapshot *sortedProxyNameCache) []byte {
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

// appendProxyTable writes the whole table from the documents the caller has
// already refreshed, so the pass only copies bytes. A node's fields never
// change while the snapshot lives, so a node view rides the same identity
// cache as the sorted names.
func (a *proxiesAnswer) appendProxyTable(buf []byte, snapshot *sortedProxyNameCache) []byte {
	for i := range snapshot.names {
		buf = append(buf, snapshot.keySpans[i]...)
		if view := snapshot.nodeViews[i]; view != nil {
			buf = append(buf, view...)
			continue
		}
		slot := snapshot.groupSlots[i]
		if slot.doc != nil {
			buf = append(buf, slot.doc...)
			continue
		}
		buf = appendGroupDocument(buf, slot.proxy)
	}
	return buf
}

// refreshGroupDocs revalidates every group's document and reports whether the
// table holds one that is encoded live, which no frame cache covers.
func refreshGroupDocs(snapshot *sortedProxyNameCache) bool {
	live := false
	// One read per answer: every group's membership is a function of the same
	// provider lists, so one generation stands for all of them.
	generation := providerListGeneration()
	for _, slot := range snapshot.groupSlots {
		if slot == nil {
			continue
		}
		if slot.group == nil {
			live = true
			continue
		}
		refreshGroupDoc(slot, generation)
	}
	return live
}

// providerListGeneration reads the generation the providers' lists carry. A
// generator is a variable so a test can stand in for a provider swapping its
// list, which only the core's own providers can do.
var providerListGeneration = provider.ListGeneration

// refreshGroupDoc rebuilds a slot's document when the values the live encode
// would write have moved.
//
// A Selector is keyed on the group's own selection counter beside the provider
// list generation, so its row is answered without resolving the selection --
// which is the expensive half of answering the table, since every other kind's
// document names the selection it currently holds. A group that publishes no
// counter is answered live, exactly like a URLTest or Fallback with no pinned
// reader.
func refreshGroupDoc(slot *groupDocSlot, generation uint64) {
	if slot.typ == constant.Selector {
		if slot.doc != nil && slot.selectedAt == slot.group.SelectionVersion() &&
			slot.generation == generation {
			return
		}
		// The selection counter is read before the encode: a selection that
		// moves while the document is being written would stamp the newer
		// counter on a document that does not carry it, and the staleness would
		// never be seen again. The generation was read once for the whole
		// answer, ahead of every document in it.
		selectedAt := slot.group.SelectionVersion()
		slot.doc = appendGroupDocument(nil, slot.proxy)
		slot.selectedAt = selectedAt
		slot.generation = generation
		groupDocGeneration++
		return
	}

	key := groupDocKeyOf(slot)
	if slot.doc != nil && slot.key == key &&
		slot.generation == generation {
		return
	}
	slot.doc = appendGroupDocument(nil, slot.proxy)
	slot.key, slot.generation = key, generation
	groupDocGeneration++
}

// A group document carries its own name, so it reaches the host exactly as its
// AppendJSON writes it; the built-in GLOBAL is the one document that needs an
// edit, spliced in place instead of a decode/marshal round trip.
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

// One lock per answer: the table is answered in a single pass, and the slots
// it writes ride the snapshot, so a rebuilt table starts with empty slots.
var groupDocsMu sync.Mutex

// groupDocGeneration counts the documents rebuilt behind that lock. A frame
// assembled under one count answers exactly the documents that count stands
// for, so an unchanged count says every byte it still carries is the slot's.
var groupDocGeneration uint64

// cachedProxiesFrame is the document the last answer built. It rides the same
// lock as the documents it copies, so an answer either reads a table whose
// every document is already refreshed or builds the document from the ones it
// just did.
var cachedProxiesFrame *proxiesFrameCache

type proxiesFrameCache struct {
	snapshot   any
	names      []string
	document   []byte
	generation uint64
}

// matches reports whether the cached document still answers exactly this
// table: the same tunnel snapshot behind it and the same display order.
func (cache *proxiesFrameCache) matches(answer *proxiesAnswer) bool {
	return sameProxySnapshot(cache.snapshot, answer.proxies) &&
		sameProxyNameList(cache.names, answer.names)
}

// groupDocSlot is one group row's document cache. The slots ride the snapshot
// they were built for, so a rebuilt table starts with empty slots and an
// answer needs no map lookup to reach the row it is writing.
type groupDocSlot struct {
	proxy    constant.Proxy
	// nil when the document cannot be keyed: the adapter is not a group, or
	// a URLTest or Fallback exposes no pinned selection to key on.
	group outboundgroup.ProxyGroup
	// The adapter type and the pinned-selection reader are fixed for the
	// proxy's life, so the answer path reads them from the slot instead of
	// dispatching into the proxy for them on every group.
	typ   constant.AdapterType
	fixed interface{ SelectedName() string }
	// The selection count the stored document was encoded under. A Selector's
	// document is keyed on the group's own counter beside the provider list
	// generation, so answering it never resolves the selection.
	selectedAt uint64
	key      groupDocKey
	generation uint64
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
	case constant.LoadBalance:
		return groupDocKey{}
	}
	// A slot carries a group only for the four cacheable kinds, so what is
	// left is a URLTest or a Fallback, whose document also names its pinned
	// selection.
	return groupDocKey{now: slot.group.Now(), fixed: slot.fixed.SelectedName()}
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
