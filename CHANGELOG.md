# Changelog

## v0.9.8 (2026-10-21)

Internal improvements only.

## v0.9.7 (2026-10-18)

**Bug Fixes**

- **proxies** Remove unused delay view provider (af63d16)

## v0.9.6 (2026-10-18)

Internal improvements only.

## v0.9.5 (2026-10-18)

**Breaking Changes**

- **network** Desktop TUN keys follow the profile unless picked; changed values carry over (cb08088)

**Features**

- **app** Adopt upstream 0.9.1 (3356b82)
- **l10n** French, Spanish and Korean translations (f43755c)
- **android** No more Firebase analytics or crash reporting (bc72bba)
- **network** Per-key desktop TUN settings; system proxy and tray fixes (cb08088)
- **theme** Redesigned theme colors and color styles (5eafd7a)
- **dashboard** A redesigned dashboard around the current exit (9bd258f)
- **profiles** Profile-detail resources and include-all in custom groups (0bac500)
- **proxies** Proxy groups as cards, group tabs as chips (2ea52fd)
- **views** Sortable tables for connections, requests and DNS (da6fb0a)
- **ui** Optional two-tier Liquid Glass and slide-to-pick menus (7c9627f)
- **ui** iOS-style surfaces, alerts and sheets; clearer TV focus (9bd2286)

**Bug Fixes**

- **ui** Fix pasting and Chinese input in text fields (5607f70)
- **core** Large profiles no longer crash; downloads trust core CAs (5984c16)

**Performance**

- **android** Smoother Android UI while the proxy is busy (2201c19)

## v0.9.4 (2026-10-18)

**Bug Fixes**

- **ui** Shorten error notices to three seconds (fb86c1c)
- **profiles** Continue profile updates after a failure (eacc28a)

## v0.9.3 (2026-10-16)

**Bug Fixes**

- **release** Send update checks and release downloads to the maintained repository (5eae18a)
- **proxy,android** Prevent stale failover state and VPN options from surviving updates (bbb2958)
- **core** Close old sockets before resetting network pools (b08bb05)
- **core** Update proxy recovery submodule (9b8178a)
- **core** Validate proxy failover state (03854cf)

## v0.9.2 (2026-10-15)

**Bug Fixes**

- **core** Fix Core event delivery during page teardown (b4083f9)
- **app** Fix event dispatch, profile groups, and editor copying (b4e77d6)
- **app** Copy profile files reliably and remove first-launch prompts (63b8540)

**Performance**

- **ui** Cache line chart slopes (862315a)
- **core,manager** Avoid copying batched Core feeds before they reach the UI (1be55b3)
- **ui** Avoid rebuilding repeated notifications that stay unchanged (e984ace)
- **views** Avoid rebuilding the connections card header on count updates (a055436)
- **views** Avoid rebuilding the network speed card header on traffic updates (4d10783)
- **ui** Reduce repeated work when list pages rebuild (d8545a6)
- **views** Keep the memory card steady when memory usage is unchanged (1b1ee8e)
- **views** Stop feed cards from repainting for unchanged counts (9d066f9)
- **common,profiles** Trim repeated UI work (7f8b23c)
- **connections,models** Share connection polling and skip no-op sorting (d42dccd)
- **proxies** Smoother proxy list updates with large subscriptions (23f1b9e)
- **core,proxies** Faster automatic node failover and reliable selected-node locating (ba41c60)
- **proxies** Reuse group lists when no selection strip is needed (22a5aac)
- **proxies** Lower proxy card memory and rebuild churn (48d5fa6)
- **startup** Faster startup with no profile rewrite (895e6a3)
- **proxies** Lower delay batch snapshot overhead (9c9fb28)
- **proxies** Lower proxy card provider churn (f5fdf74)
- **proxies** Combine delay and phase watches (b222c0b)
- **connection** Reuse rows when speeds are unchanged (4b63281)
- **core,proxies** Smoother large proxy lists and lower event overhead (8416a37)
- **proxies** Smoother proxy tab updates (66f0a80)
- **proxies,startup** More stable proxy sorting and faster startup updates (5405455)
- **proxies,tray,core** Faster tray refreshes and system proxy transitions (d7bb950)
- **proxies,core,ui** Faster proxy updates and switching under load (1ec5f79)
- **core** Parse Core events once when several listeners are active (c96cd92)
- **proxies** Coalesce cleanup and skip redundant work (af7f4aa)
- **ui** Narrow navigation setting watches (820c8d2)
- **core** Drop buffered feeds when hidden (24d8cfd)
- **icons** Coalesce concurrent prefetches (051a2f8)
- **profiles** Coalesce concurrent auto updates (46bce8c)
- **startup** Skip unused dynamic color probe (6482793)
- **proxies** Keep equal-delay order stable (35a225c)
- **providers** Skip unchanged group publishes (1467344)
- **proxies** Build proxy rows without chunk lists (f44d4a7)
- **proxies** Avoid row builder allocations (776c6fe)
- **startup** Load profiles, localization, and window setup in parallel (21c9082)
- **proxies** Avoid rebuilding groups when every proxy matches (3c82946)
- **config** Skip rewriting unchanged configuration (2b1878c)
- **proxies** Reuse normalized proxy search text across queries (c5a25e0)
- **startup** Start migration reads in parallel (914f5a8)
- **ui** Stop repeated writes for unchanged view sizes (d976979)
- **startup** Read boot recovery probes concurrently (a5fb3ab)
- **startup** Start dynamic color probes in parallel (fe1c839)
- **ui** Avoid redundant sidebar layout writes (c97d74d)
- **startup** Avoid an empty first frame during startup (5db3b04)
- **core** Stop request and DNS event delivery while hidden (fd478f2)
- **ui** Pause icon prefetching while the app is hidden (69fc4ae)
- **tray** Reduce macOS tray delay menu rebuilds (7ff64cc)
- **app** Schedule profile updates only when they are due (7735961)
- **app** Reduce idle traffic polling and icon prefetch pressure (47cda7b)
- **proxies** Interactive delay tests jump ahead of bulk probes (2acdc84)
- **database** Improve database write responsiveness (ced9d88)
- **proxies** Faster proxy list updates and node switching (c3492a5)
- **core** Reduce Core event dispatch and buffering overhead (8f4a969)
- **proxies** Trim repeat work on group updates (525b52a)
- **views,common** Improve profile, app, and startup responsiveness (bfcf525)
- **core,providers** Cut redundant setup and feed work (d72f460)
- **proxies** Cache resolved proxy state and narrow watches (c47d2f7)
- **common** Keep unchanged groups during timeout filtering (0ed3ade)
- **common** Cache proxy types for timeout filtering (9b93f92)
- **common** Reuse groups when sorting does not change order (9277b47)
- **common** Reuse real proxy states while sorting (9010a79)
- Skip computeSort after buildGroups when sort is none (e9a3c92)
- Short-circuit computeSort for none and singleton groups (d6d705d)
- Patch group.now locally after proxy switch (131d953)
- Skip groups isolate below 80 proxy-map entries (9142bee)
- Wire delay resort and invalidate proxies cache on provider load (1277a2e)
- Skip AutoDisposeNotifier no-op value writes (b5636c0)
- Skip groups refetch fan-out when proxy switch is a no-op (9652fff)
- Cap Core feed buffers between flushes (89f38d7)
- Reuse Core message batch buffer capacity (b5e4513)
- Skip connections list notifier when live data is unchanged (89b2d41)
- Skip full connection sort when idle or empty (1ebe3bb)
- Lighter connections page polling (e006867)
- Cache groups-by-name map for proxyDesc (d1f5a38)
- **desktop** MacOS tray title throttle 1.5s -> 2s (7f41f2e)
- Coarser feed throttle and smaller live buffers (27ecf4e)
- Visible traffic ticker 1s -> 1.5s (0efd88a)
- Skip identical traffic samples on the chart buffer (cb27736)
- Use groups.getGroup in proxyDesc with select (ff5c54f)
- **android** Refresh foreground notification every 2s (5d73f39)
- Shrink traffic chart sample buffer 30 -> 24 (19a0262)
- Poll connection count every 3s on dashboard (d77a4c5)
- Poll memory stats every 3s (23065ae)
- Coarser Core event batches under load (2cc3a15)
- Always use combined traffic IPC when window is visible (01e61a4)
- Cut traffic IPC and skip delay-driven group rebuilds (774b691)
- Quieter traffic sampling and coarser core event batches (c08e87b)
- Cheaper background polls and accurate tray delay rebuilds (b16003f)
- Close dead sockets in background and batch UI feeds (3f9b6bc)
- Faster proxy switch and lower background UI work (66b651c)
- **macos** Cut NSStatusItem redraw CPU from tray title/menu (d545d62)
- **proxies** Subscribe cards to selection state (b8e2b85)
- **sheets** Cache selection search text (61ea03c)
- **scaffold** Skip unchanged keyword syncs (7b94b4d)
- **editors** Cache visible search results (4e3288c)
- **traffic** Cache display strings (b0094a0)
- **dns** Cache filtered query list (d255491)
- **lists** Cache filtered view results (829c5e8)
- **ui** Skip unchanged memory updates (33e05cf)
- **proxies** Reuse groups without selections (512d714)
- **search** Cache list query terms (b810510)
- **logs** Cache parsed payloads (42c47ca)
- **connections** Precompute speed ranking keys (7ecb97c)
- **tray** Cache resolved proxy states (deb2cd8)
- **proxies** Reuse group type lookups (fb65545)
- **proxies** Index group lookups during sorting (94e0a84)

## v0.9.1 (2026-10-15)

**Features**

- **proxies** A delay test that times out on every node says so, so the test URL can be checked (f8c5742)
- **release** Release downloads and announcements link the repository that published the build (66b7157)
- **proxies** ResortGroupsByDelay without Core getProxies (8b4bce5)
- **core** Cache full proxies tree and merge selection deltas (7aad516)
- **core** ProxiesSnapshot and getProxies(since) on the host interface (863c8ab)
- **core** GetProxies accepts optional ProxiesQuery.Since (5157d11)
- **core** Bump proxiesGeneration on applyConfig and updateConfig (b5e5dca)
- **core** Incremental getProxies with generation + selected map (60689f8)
- **core** ProxiesData generation and selection delta fields (1cf6ade)

**Bug Fixes**

- **ci** Keep tracked google services config (1a6caa9)
- **views** Keep the core status hold steady during repeated updates (5d13236)
- **core** Use the maintained Clash.Meta repository for core updates and links (39e7d5d)
- **release** Keep stable Android releases on the same signing key (e1ad780)
- **proxies** Keep the auto-select check mark only for a manually pinned node (c304c22)
- **app** Preserve delay state and subscription updates (c19a2aa)
- **pages** Shrinking the window off a page the navigation drops no longer shows a different page (00e4bbc)
- **tray** A tray the system refused to build is retried instead of staying empty until something else changes (3d62223)
- **proxies** A failed node switch falls back to the node that is in effect, not to an older pick (eb7b3b6)
- **proxies** A delay sweep started from the tray or a hotkey shows as testing on the proxies page (1d7b2f2)
- **proxies** A node waiting for a delay test keeps showing its last delay (0731b8e)
- **profiles** One dead subscription no longer stops the others from updating (8933b7d)
- **pages** The startup failure screen speaks the reader's language (dacafc7)
- **common** The tray menu names the proxies it left out in the reader's language (2cfafb6)
- **common** The update check and the download links follow the repository that publishes this build (c48373b)
- **proxies** Align computed selection marks (6db8db9)
- **macos** Turn the macOS system proxy on and off from a machine that is not set to English (96a97e6)
- **macos** Patch the macOS system DNS on a machine that is not set to English (4b2dac2)
- **core** Keep a measured node instead of switching to one the group has not tested yet (04efa66)
- **core** Starting again after a crashed core brings it back instead of failing (c1acb9e)
- **core** A crashed core no longer leaves the app looking connected (016b05d)
- **common** A subscription that stops responding no longer leaves its update hanging (4dc84dd)
- **bootstrap** Declining the disclaimer is no longer remembered as accepting it (b9daec5)
- **profiles** A subscription that fails to update retries with a growing delay instead of every five minutes (0146895)
- **profiles** An auto-update interval of zero minutes no longer re-downloads a subscription (1fcc9df)
- **core** Follow a subscription update at once instead of keeping a node the new list dropped (9d1ce7d)
- **editor** Complete proxy names inside a quoted list member again (e4b6ce9)
- **editor** Complete node names again on a config line that quotes a hash (f51c75f)
- **editor** Keep a quoted config value whole in editor completions (30f8ffd)
- **common** Keep localhost URLs out of the proxy (eb6f915)
- **views** The proxy list follows a group's node when the selection changes (43886cc)
- **proxies** Keep a group's live node selected after its saved pick disappears (7c3a3a8)
- **proxies** Keep a delayed re-sort from reverting newer proxy state (7786f2d)
- **core** Recover failed nodes sooner and keep DIRECT members out of failover marking (d20d588)
- **proxies** Keep proxy groups from showing a node that was never selected (d4f48b4)
- **proxies** Restore selected-node resolution and keep stale selections from breaking locating (be85440)
- **core** max-failed-times now triggers on the configured failure count (a7ff2d6)
- **core** Keep test-URL health results isolated between groups (feb35cc)
- **core** Keep per-URL proxy failures isolated between groups (d908ce7)
- **core** Load-balance groups rotate through unavailable members (95784da)
- **core** Fallback groups rotate through members when all are unavailable (e2aa2e7)
- **proxies,core** Faster URLTest failover and stable delay sorting (c858331)
- **core** Skip listeners removed during event dispatch (51304c8)
- **core,proxies** Correctly clear computed proxy selections (9b2a952)
- **proxies** Delay tests now start for later proxy groups without waiting for an earlier group to finish (e52e5bf)
- **boot** Keep storage failures non-fatal (25f87bb)
- **lifecycle** Keep connection polling active while a window is unfocused (f6a5635)
- **connectivity** Avoid redundant route probes on network changes (4125d0a)
- **core** Force full getProxies when delta arrives without a host cache (22e4825)
- **core** Bump proxiesGeneration after provider update and side-load (e5d6211)
- **core** Stringify loaded/crash event payloads before dispatch (3a6b598)
- **core** Skip onCrash work when CoreManager is already unmounted (ae580a8)
- **proxies** Notify CoreController cache after local group.now patch (db4c101)
- **core** Keep _lastGroups in sync when patching group.now locally (ad07db0)
- **core** Recursively encode nested proxy groups in getProxies (ad27378)
- **core** Guard CoreManager handlers against unmounted ref (e5fbd6f)
- **core** Dispatch Core events synchronously (101c5ed)
- **changelog** Fall back to release commit when the boundary tag is missing (f7fe00c)
- **core,dart** Align proxy snapshot and route builds (7a8788c)
- **macos** Keep visible dashboard watching after activity change (2d1cb0f)
- **providers** Return typed empty group list (4ef7cd0)
- Import TrayTitleState for tray title throttle (1219f47)
- **macos** The macOS build stays responsive in the background, and Intel Macs render through Skia (e866f74)

**Performance**

- **ui** Cache line chart slopes (f95c1e3)
- **core,manager** Avoid copying batched Core feeds before they reach the UI (69386f9)
- **ui** Avoid rebuilding repeated notifications that stay unchanged (f237bd3)
- **views** Avoid rebuilding the connections card header on count updates (af98382)
- **views** Avoid rebuilding the network speed card header on traffic updates (31fd947)
- **ui** Reduce repeated work when list pages rebuild (6258d1d)
- **views** Keep the memory card steady when memory usage is unchanged (775747f)
- **views** Stop feed cards from repainting for unchanged counts (508eb47)
- **common,profiles** Trim repeated UI work (5da2a5f)
- **connections,models** Share connection polling and skip no-op sorting (763180a)
- **proxies** Smoother proxy list updates with large subscriptions (0ba2837)
- **core,proxies** Faster automatic node failover and reliable selected-node locating (e96cd8b)
- **proxies** Reuse group lists when no selection strip is needed (cb3b064)
- **proxies** Lower proxy card memory and rebuild churn (5bf2fed)
- **core** Scan only groups for proxy selection deltas (60b9e5a)
- **startup** Faster startup with no profile rewrite (fb48d28)
- **proxies** Lower delay batch snapshot overhead (b1a5c51)
- **proxies** Lower proxy card provider churn (2b53ee0)
- **proxies** Combine delay and phase watches (2416615)
- **connection** Reuse rows when speeds are unchanged (329e5c1)
- **core,proxies** Smoother large proxy lists and lower event overhead (ecd13ee)
- **proxies** Smoother proxy tab updates (b32125b)
- **proxies,startup** More stable proxy sorting and faster startup updates (686e421)
- **proxies,tray,core** Faster tray refreshes and system proxy transitions (bb75652)
- **proxies,core,ui** Faster proxy updates and switching under load (0f0ab9a)
- **core** Parse Core events once when several listeners are active (4c96ddb)
- **proxies** Coalesce cleanup and skip redundant work (2e85fc3)
- **ui** Narrow navigation setting watches (6e76931)
- **core** Drop buffered feeds when hidden (c78a473)
- **icons** Coalesce concurrent prefetches (6006023)
- **profiles** Coalesce concurrent auto updates (5ff5e31)
- **startup** Skip unused dynamic color probe (0008e7d)
- **proxies** Keep equal-delay order stable (789cc7e)
- **providers** Skip unchanged group publishes (088ca66)
- **proxies** Build proxy rows without chunk lists (5cf5986)
- **proxies** Avoid row builder allocations (765d386)
- **startup** Load profiles, localization, and window setup in parallel (204b57a)
- **proxies** Avoid rebuilding groups when every proxy matches (d64b66b)
- **config** Skip rewriting unchanged configuration (c7eddac)
- **proxies** Reuse normalized proxy search text across queries (c1b356e)
- **startup** Start migration reads in parallel (f4826f4)
- **ui** Stop repeated writes for unchanged view sizes (b7dd961)
- **startup** Read boot recovery probes concurrently (5258d39)
- **startup** Start dynamic color probes in parallel (127c909)
- **ui** Avoid redundant sidebar layout writes (cb56f67)
- **startup** Avoid an empty first frame during startup (f466bfb)
- **core** Stop request and DNS event delivery while hidden (d349b4b)
- **ui** Pause icon prefetching while the app is hidden (09c0630)
- **tray** Reduce macOS tray delay menu rebuilds (9ac2a2c)
- **app** Schedule profile updates only when they are due (8d79e58)
- **app** Reduce idle traffic polling and icon prefetch pressure (cf88acc)
- **proxies** Interactive delay tests jump ahead of bulk probes (20d21f9)
- **database** Improve database write responsiveness (9f59367)
- **proxies** Faster proxy list updates and node switching (67fd0df)
- **core** Reduce Core event dispatch and buffering overhead (2aaaf47)
- **proxies** Trim repeat work on group updates (ffba619)
- **views,common** Improve profile, app, and startup responsiveness (9d4c8ad)
- **core,providers** Cut redundant setup and feed work (3dd8bbe)
- **proxies** Watch only the selected proxy group (74a7402)
- **proxies** Cache resolved proxy state and narrow watches (0b32dd8)
- **common** Keep unchanged groups during timeout filtering (57b78c7)
- **common** Cache proxy types for timeout filtering (7d0bd61)
- **common** Reuse groups when sorting does not change order (624b62e)
- **common** Reuse real proxy states while sorting (d33a08f)
- Skip computeSort after buildGroups when sort is none (00d22eb)
- Short-circuit computeSort for none and singleton groups (bec9898)
- Keep group identity when stripping empty selection (e332b37)
- Patch group.now locally after proxy switch (a01da4f)
- **core** Encode only groups and referenced members in getProxies (eef0212)
- Skip groups isolate below 80 proxy-map entries (7ed09b6)
- Apply getProxies selection delta without isolate rebuild (fb3777e)
- Wire delay resort and invalidate proxies cache on provider load (f6e6a06)
- Skip AutoDisposeNotifier no-op value writes (3a7664e)
- Skip groups refetch fan-out when proxy switch is a no-op (b843f86)
- Drop per-call updateGroups log line (8f771d0)
- Cap Core feed buffers between flushes (d22c830)
- Reuse Core message batch buffer capacity (d3c0458)
- Skip connections list notifier when live data is unchanged (073e31d)
- Skip full connection sort when idle or empty (472f7b0)
- Lighter connections page polling (6f82188)
- Cache groups-by-name map for proxyDesc (fa8ae28)
- **desktop** MacOS tray title throttle 1.5s -> 2s (bde0dbc)
- Coarser feed throttle and smaller live buffers (8799ef4)
- Visible traffic ticker 1s -> 1.5s (b4dca35)
- Skip identical traffic samples on the chart buffer (3bbac1e)
- Use groups.getGroup in proxyDesc with select (bbca9f1)
- **android** Refresh foreground notification every 2s (a52eaa4)
- Shrink traffic chart sample buffer 30 -> 24 (8880038)
- Poll connection count every 3s on dashboard (8316056)
- Poll memory stats every 3s (dc5f719)
- Coarser Core event batches under load (56d6da6)
- Always use combined traffic IPC when window is visible (88ce17f)
- Cut traffic IPC and skip delay-driven group rebuilds (f702724)
- Quieter traffic sampling and coarser core event batches (285e378)
- Cheaper background polls and accurate tray delay rebuilds (4498941)
- Close dead sockets in background and batch UI feeds (82ac652)
- Faster proxy switch and lower background UI work (89c13e8)
- **macos** Cut NSStatusItem redraw CPU from tray title/menu (598a056)

## v0.9.0 (2026-10-14)

**Breaking Changes**

- **views** DNS and NTP override toggles are removed; picked keys apply to every profile (491fae1)
- **database** Custom overwrites are removed; rebuild them as custom profiles (1677024)

**Features**

- **views** Per-key DNS, NTP, sniffer and TUN settings (491fae1)
- **profiles** Custom profiles (3abda78)
- **ui** Stacked sheets, context menus and a sort mode (8c43053)
- **providers** DNS, Hosts and ports apply without a restart (532ebf0)
- **android** Launcher shortcuts and one-step on-demand access (d3fa225)
- **core** Share link import and mrs rule sets (2fa2f7f)

**Bug Fixes**

- **database** Unreadable settings no longer block startup or restores (1677024)
- **desktop** Windows and Linux desktop fixes (94a25f4)
- **core,helper** The elevated Core only answers its owner (d780cb8)

## v0.8.99 (2026-10-05)

**Features**

- **proxies** ResortGroupsByDelay without Core getProxies (8b4bce5)
- **core** Cache full proxies tree and merge selection deltas (7aad516)
- **core** ProxiesSnapshot and getProxies(since) on the host interface (863c8ab)
- **core** GetProxies accepts optional ProxiesQuery.Since (5157d11)
- **core** Bump proxiesGeneration on applyConfig and updateConfig (b5e5dca)
- **core** Incremental getProxies with generation + selected map (60689f8)
- **core** ProxiesData generation and selection delta fields (1cf6ade)
- **editor** Editor word wrap and snippets (e131675)
- **dashboard** More dashboard cards (e62afb7)
- **views** Hide timed-out nodes and search every list (8378c70)
- **ui** Sidebar, floating dock and drag to go back (841d603)
- **ui** New app glyphs, empty states and theme page (ee6a497)
- **overwrite** Invalid override warnings and rule presets (46fb7fe)
- **config** DNS query log and per-key DNS/NTP overrides (a390a42)
- **core** Proxied service checks and outbound IP risk (8068e68)
- **platform** Tray hotkeys, node delays and a delay test (1e97716)

**Bug Fixes**

- **changelog** Fall back to release commit when the boundary tag is missing (f7fe00c)
- **core,dart** Align proxy snapshot and route builds (7a8788c)
- **macos** Keep visible dashboard watching after activity change (2d1cb0f)
- **providers** Return typed empty group list (4ef7cd0)
- Import TrayTitleState for tray title throttle (1219f47)
- **macos** The macOS build stays responsive in the background, and Intel Macs render through Skia (e866f74)
- **core** A changed resource link is now used by the next sync and by auto update (ff23f30)
- **core** DNS lookups no longer fail on networks that report no DNS servers (e55f6d1)
- **proxies** Smaller icons in icon-only group headers (786a6ab)
- **core,android** Push notifications reconnect in Doze (1e9955d)
- **backup,database** Restores never apply halfway (bee8f24)

**Performance**

- **proxies** Trim repeat work on group updates (ffba619)
- **views,common** Improve profile, app, and startup responsiveness (9d4c8ad)
- **core,providers** Cut redundant setup and feed work (3dd8bbe)
- **proxies** Watch only the selected proxy group (74a7402)
- **proxies** Cache resolved proxy state and narrow watches (0b32dd8)
- **common** Keep unchanged groups during timeout filtering (57b78c7)
- **common** Cache proxy types for timeout filtering (7d0bd61)
- **common** Reuse groups when sorting does not change order (624b62e)
- **common** Reuse real proxy states while sorting (d33a08f)
- Skip computeSort after buildGroups when sort is none (00d22eb)
- Short-circuit computeSort for none and singleton groups (bec9898)
- Keep group identity when stripping empty selection (e332b37)
- Patch group.now locally after proxy switch (a01da4f)
- **core** Encode only groups and referenced members in getProxies (eef0212)
- Skip groups isolate below 80 proxy-map entries (7ed09b6)
- Apply getProxies selection delta without isolate rebuild (fb3777e)
- Wire delay resort and invalidate proxies cache on provider load (f6e6a06)
- Skip AutoDisposeNotifier no-op value writes (3a7664e)
- Skip groups refetch fan-out when proxy switch is a no-op (b843f86)
- Drop per-call updateGroups log line (8f771d0)
- Cap Core feed buffers between flushes (d22c830)
- Reuse Core message batch buffer capacity (d3c0458)
- Skip connections list notifier when live data is unchanged (073e31d)
- Skip full connection sort when idle or empty (472f7b0)
- Lighter connections page polling (6f82188)
- Cache groups-by-name map for proxyDesc (fa8ae28)
- **desktop** MacOS tray title throttle 1.5s -> 2s (bde0dbc)
- Coarser feed throttle and smaller live buffers (8799ef4)
- Visible traffic ticker 1s -> 1.5s (b4dca35)
- Skip identical traffic samples on the chart buffer (3bbac1e)
- Use groups.getGroup in proxyDesc with select (bbca9f1)
- **android** Refresh foreground notification every 2s (a52eaa4)
- Shrink traffic chart sample buffer 30 -> 24 (8880038)
- Poll connection count every 3s on dashboard (8316056)
- Poll memory stats every 3s (dc5f719)
- Coarser Core event batches under load (56d6da6)
- Always use combined traffic IPC when window is visible (88ce17f)
- Cut traffic IPC and skip delay-driven group rebuilds (f702724)
- Quieter traffic sampling and coarser core event batches (285e378)
- Cheaper background polls and accurate tray delay rebuilds (4498941)
- Close dead sockets in background and batch UI feeds (82ac652)
- Faster proxy switch and lower background UI work (89c13e8)
- **macos** Cut NSStatusItem redraw CPU from tray title/menu (598a056)

## v0.8.98 (2026-09-14)

**Bug Fixes**

- **resources** Refresh the geo file size and time after an update finishes (c5bf5bd)
- **core** Keep the core running while Windows sleeps with the app suspended (60f371a)

## v0.8.97 (2026-09-10)

**Features**

- **ui** Rework the app UI and refresh the localization (26cfbaf)
- **app** Rework the app layer and window handling, and add proxy authentication (aaf934c)
- **desktop** Rework the desktop runners, packaging, and native build (c0fcbc0)
- **android** Rework the Android VPN service and lifecycle handling (ae29f38)
- **plugins** Rework the desktop plugins and add the Helper service and Rust bridge (adf715f)
- **core** Rework the core IPC and process lifecycle (c6eaa0a)

<!-- changelog:frozen -->
<!-- Entries below predate the structured pipeline. Their wording is kept as written; only the heading and list style were normalized. -->

## v0.8.96 (2026-08-17)

- Optimize commented policy
- Fix whole group delay test failing on Windows
- Optimize package icon loading and connections polling

## v0.8.95 (2026-08-14)

- Optimize core service
- Optimize Android TV launcher icon
- Optimize back navigation
- Optimize more details
- Fix some issues
- Optimize app layout
- Optimize focus control
- Adjust android process

## v0.8.94 (2026-07-11)

- Fix macos performance issue
- Support custom global-ua
- Update core
- Optimize some details
- Fix linux silent launching not working

## v0.8.93 (2026-05-29)

- Support custom overwrite
- Support run on demand
- Optimize windows ipc
- Optimize windows arm64
- Optimize build
- Optimize some details
- Update core

## v0.8.92 (2026-02-02)

- Add sqlite store
- Optimize android quick action
- Optimize backup and restore
- Optimize more details

## v0.8.91 (2025-12-12)

- Fix windows some issues
- Optimize overwrite handle
- Optimize access control page
- Optimize some details

## v0.8.90 (2025-10-08)

- Fix android tile service
- Support append system DNS
- Fix some issues
- Update changelog

## v0.8.89 (2025-09-27)

- Fix some issues
- Optimize Windows service mode
- Update core
- Update changelog

## v0.8.88 (2025-09-23)

- Add android separates the core process
- Support core status check and force restart
- Optimize proxies page and access page
- Update flutter and pub dependencies
- Update go version
- Optimize more details
- Update changelog

## v0.8.87 (2025-07-29)

- Optimize desktop view
- Optimize logs, requests, connection pages
- Optimize windows tray auto hide
- Optimize some details
- Update core
- Update changelog

## v0.8.86 (2025-06-15)

- Fix windows tun issues
- Optimize android get system dns
- Optimize more details
- Update changelog

## v0.8.85 (2025-06-07)

- Support override script
- Support proxies search
- Support svg display
- Optimize config persistence
- Add some scenes auto close connections
- Update core
- Optimize more details

## v0.8.84 (2025-05-01)

- Fix windows service verify issues
- Update changelog

## v0.8.83 (2025-05-01)

- Add windows server mode start process verify
- Add linux deb dependencies
- Add backup recovery strategy select
- Support custom text scaling
- Optimize the display of different text scale
- Optimize windows setup experience
- Optimize startTun performance
- Optimize android tv experience
- Optimize default option
- Optimize computed text size
- Optimize hyperOS freeform window
- Add developer mode
- Update core
- Optimize more details
- Add issues template
- Update changelog

## v0.8.82 (2025-04-18)

- Optimize android vpn performance
- Add custom primary color and color scheme
- Add linux nad windows arm release
- Optimize requests and logs page
- Fix map input page delete issues
- Update changelog

## v0.8.81 (2025-04-08)

- Add rule override
- Update core
- Optimize more details
- Update changelog

## v0.8.80 (2025-03-10)

- Optimize dashboard performance
- Fix some issues
- Fix unselected proxy group delay issues
- Fix asn url issues
- Update changelog

## v0.8.79 (2025-03-07)

- Fix tab delay view issues
- Fix tray action issues
- Fix get profile redirect client ua issues
- Fix proxy card delay view issues
- Add Russian, Japanese adaptation
- Fix some issues
- Update changelog

## v0.8.78 (2025-03-05)

- Fix list form input view issues
- Fix traffic view issues
- Update changelog

## v0.8.77 (2025-03-05)

- Optimize performance
- Update core
- Optimize core stability
- Fix linux tun authority check error
- Fix some issues
- Fix scroll physics error
- Update changelog

## v0.8.75 (2025-02-09)

- Add windows storage corruption detection
- Fix core crash caused by windows resource manager restart
- Optimize logs, requests, access to pages
- Fix macos bypass domain issues
- Update changelog

## v0.8.74 (2025-02-03)

- Fix some issues
- Update changelog

## v0.8.73 (2025-02-02)

- Update popup menu
- Add file editor
- Fix android service issues
- Optimize desktop background performance
- Optimize android main process performance
- Optimize delay test
- Optimize vpn protect
- Update changelog

## v0.8.72 (2025-01-10)

- Update core
- Fix some issues
- Update changelog

## v0.8.71 (2025-01-09)

- Remake dashboard
- Optimize theme
- Optimize more details
- Update flutter version
- Update changelog

## v0.8.70 (2024-12-09)

- Support better window position memory
- Add windows arm64 and linux arm64 build script
- Optimize some details

## v0.8.69 (2024-12-06)

- Remake desktop
- Optimize change proxy
- Optimize network check
- Fix fallback issues
- Optimize lots of details
- Update change.yaml
- Fix android tile issues
- Fix windows tray issues
- Support setting bypassDomain
- Update flutter version
- Fix android service issues
- Fix macos dock exit button issues
- Add route address setting
- Optimize provider view
- Update changelog
- Update CHANGELOG.md

## v0.8.67 (2024-11-09)

- Add android shortcuts
- Fix init params issues
- Fix dynamic color issues
- Optimize navigator animate
- Optimize window init
- Optimize fab
- Optimize save

## v0.8.66 (2024-10-26)

- Fix the collapse issues
- Add fontFamily options

## v0.8.65 (2024-10-26)

- Update core version
- Update flutter version
- Optimize ip check
- Optimize url-test

## v0.8.64 (2024-10-12)

- Update release message
- Init auto gen changelog
- Fix windows tray issues
- Fix urltest issues
- Add auto changelog
- Fix windows admin auto launch issues
- Add android vpn options
- Support proxies icon configuration
- Optimize android immersion display
- Fix some issues
- Optimize ip detection
- Support android vpn ipv6 inbound switch
- Support log export
- Optimize more details
- Fix android system dns issues
- Optimize dns default option
- Fix some issues
- Update readme

## v0.8.60 (2024-09-17)

- Fix build error2
- Fix build error
- Support desktop hotkey
- Support android ipv6 inbound
- Support android system dns
- fix some bugs

## v0.8.59 (2024-09-09)

- Fix delete profile error

## v0.8.58 (2024-09-08)

- Fix submit error 2
- Fix submit error
- Optimize DNS strategy
- Fix the problem that the tray is not displayed in some cases
- Optimize tray
- Update core
- Fix some error

## v0.8.57 (2024-09-02)

- Fix tun update issues
- Add DNS override
- Fixed some bugs
- Optimize more detail
- Add Hosts override

## v0.8.56 (2024-08-26)

- fix android tip error
- fix windows auto launch error

## v0.8.55 (2024-08-25)

- Fix windows tray issues
- Optimize windows logic
- Optimize app logic
- Support windows administrator auto launch
- Support android close vpn

## v0.8.53 (2024-08-15)

- Change flutter version
- Support profiles sort
- Support windows country flags display
- Optimize proxies page and profiles page columns

## v0.8.52 (2024-08-11)

- Update flutter version
- Update version
- Update timeout time
- Update access control page
- Fix bug

## v0.8.51 (2024-08-05)

- Optimize provider page
- Optimize delay test
- Support local backup and recovery
- Fix android tile service issues

## v0.8.49 (2024-07-31)

- Fix linux core build error
- Add proxy-only traffic statistics
- Update core
- Optimize more details
- Merge pull request #140 from txyyh/main
- 添加自建 F-Droid 仓库相关 workflow
- Rename readme fingerprint
- Rename workflow deploy repo name
- Add download guide to README
- Add push release files to fdroid-repo

## v0.8.48 (2024-07-25)

- Optimize proxies page
- Fix ua issues
- Optimize more details

## v0.8.47 (2024-07-22)

- Fix windows build error

## v0.8.46 (2024-07-22)

- Update app icon
- Fix desktop backup error
- Optimize request ua
- Change android icon
- Optimize dashboard

## v0.8.44 (2024-07-18)

- Remove request validate certificate
- Sync core

## v0.8.43 (2024-07-18)

- Fix windows error

## v0.8.42 (2024-07-18)

- Fix setup.dart error
- Fix android system proxy not effective
- Add macos arm64

## v0.8.41 (2024-07-17)

- Optimize proxies page
- Support mouse drag scroll
- Adjust desktop ui
- Revert "Fix android vpn issues"
- This reverts commit 891977408e6938e2acd74e9b9adb959c48c79988.

## v0.8.40 (2024-07-15)

- Fix android vpn issues
- Fix android vpn issues
- Rollback partial modification

## v0.8.39 (2024-07-15)

- Fix the problem that ui can't be synchronized when android vpn is occupied by an external
- Override default socksPort,port

## v0.8.38 (2024-07-14)

- Fix fab issues

## v0.8.37 (2024-07-14)

- Update version
- Fix the problem that vpn cannot be started in some cases
- Fix the problem that geodata url does not take effect

## v0.8.36 (2024-07-13)

- Update ua
- Fix change outbound mode without check ip issues
- Separate android ui and vpn
- Fix url validate issues 2
- Add android hidden from the recent task
- Add geoip file
- Support modify geoData URL

## v0.8.35 (2024-07-07)

- Fix url validate issues
- Fix check ip performance problem
- Optimize resources page

## v0.8.34 (2024-07-04)

- Add ua selector
- Support modify test url
- Optimize android proxy
- Fix the error that async proxy provider could not selected the proxy

## v0.8.33 (2024-07-01)

- Fix android proxy error
- Fix submit error
- Add windows tun
- Optimize android proxy
- Optimize change profile
- Update application ua
- Optimize delay test

## v0.8.32 (2024-06-28)

- Fix android repeated request notification issues

## v0.8.31 (2024-06-28)

- Fix memory overflow issues

## v0.8.30 (2024-06-27)

- Optimize proxies expansion panel 2
- Fix android scan qrcode error

## v0.8.29 (2024-06-27)

- Optimize proxies expansion panel
- Fix text error

## v0.8.28 (2024-06-26)

- Optimize proxy
- Optimize delayed sorting performance
- Add expansion panel proxies page
- Support to adjust the proxy card size
- Support to adjust proxies columns number
- Fix autoRun show issues
- Fix Android 10 issues
- Optimize ip show

## v0.8.26 (2024-06-22)

- Add intranet IP display
- Add connections page
- Add search in connections, requests
- Add keyword search in connections, requests, logs
- Add basic viewing editing capabilities
- Optimize update profile

## v0.8.25 (2024-06-19)

- Update version
- Fix the problem of excessive memory usage in traffic usage.
- Add lightBlue theme color
- Fix start unable to update profile issues
- Fix flashback caused by process

## v0.8.23 (2024-06-16)

- Add build version
- Optimize quick start
- Update system default option

## v0.8.22 (2024-06-16)

- Update build.yml
- Fix android vpn close issues
- Add requests page
- Fix checkUpdate dark mode style error
- Fix quickStart error open app
- Add memory proxies tab index
- Support hidden group
- Optimize logs
- Fix externalController hot load error

## v0.8.21 (2024-06-13)

- Add tcp concurrent switch
- Add system proxy switch
- Add geodata loader switch
- Add external controller switch
- Add auto gc on trim memory
- Fix android notification error

## v0.8.20 (2024-06-12)

- Fix ipv6 error
- Fix android udp direct error
- Add ipv6 switch
- Add access all selected button
- Remove android low version splash

## v0.8.19 (2024-06-10)

- Update version
- Add allowBypass
- Fix Android only pick .text file issues

## v0.8.18 (2024-06-09)

- Fix search issues

## v0.8.17 (2024-06-09)

- Fix LoadBalance, Relay load error
- Fix build.yml4
- Fix build.yml3
- Fix build.yml2
- Fix build.yml
- Add search function at access control
- Fix the issues with the profile add button to cover the edit button
- Adapt LoadBalance and Relay
- Add arm
- Fix android notification icon error

## v0.8.16 (2024-06-08)

- Add one-click update all profiles
- Add expire show

## v0.8.15 (2024-06-06)

- Temp remove tun mode
- Remove macos in workflow
- Change go version

## v0.8.14 (2024-06-06)

- Update Version
- Fix tun unable to open

## v0.8.13 (2024-06-06)

- Optimize delay test2
- Optimize delay test
- Add check ip
- add check ip request

## v0.8.12 (2024-06-06)

- Fix the problem that the download of remote resources failed after GeodataMode was turned on, which caused the
  application to flash back.
- Fix edit profile error
- Fix quickStart change proxy error
- Fix core version

## v0.8.10 (2024-06-05)

- Fix core version

## v0.8.9 (2024-06-05)

- Update file_picker
- Add resources page
- Optimize more detail
- Add access selected sorted
- Fix notification duplicate creation issue
- Fix AccessControl click issue

## v0.8.7 (2024-05-31)

- Fix Workflow
- Fix Linux unable to open
- Update README.md 3
- Create LICENSE
- Update README.md 2
- Update README.md
- Optimize workFlow

## v0.8.6 (2024-05-31)

- optimize checkUpdate

## v0.8.5 (2024-05-30)

- Fix submit error

## v0.8.4 (2024-05-30)

- add WebDAV
- add Auto check updates
- Optimize more details
- optimize delayTest

## v0.8.2 (2024-05-15)

- upgrade flutter version

## v0.8.1 (2024-05-15)

- Update kernel
- Add import profile via QR code image

## v0.8.0 (2024-05-11)

- Add compatibility mode and adapt clash scheme.

## v0.7.14 (2024-05-07)

- update Version
- Reconstruction application proxy logic

## v0.7.13 (2024-05-06)

- Fix Tab destroy error

## v0.7.12 (2024-05-06)

- Optimize repeat healthcheck

## v0.7.11 (2024-05-06)

- Optimize Direct mode ui

## v0.7.10 (2024-05-06)

- Optimize Healthcheck
- Remove proxies position animation, improve performance
- Add Telegram Link
- Update healthcheck policy
- New Check URLTest
- Fix the problem of invalid auto-selection

## v0.7.8 (2024-05-05)

- New Async UpdateConfig
- add changeProfileDebounce
- Update Workflow
- Fix ChangeProfile block
- Fix Release Message Error

## v0.7.7 (2024-05-04)

- Update Selector 2

## v0.7.6 (2024-05-04)

- Update Version
- Fix Proxies Select Error

## v0.7.5 (2024-05-03)

- Fix the problem that the proxy group is empty in global mode.
- Fix the problem that the proxy group is empty in global mode.

## v0.7.4 (2024-05-03)

- Add ProxyProvider2

## v0.7.3 (2024-05-03)

- Add ProxyProvider
- Update Version
- Update ProxyGroup Sort
- Fix Android quickStart VpnService some problems

## v0.7.1 (2024-05-01)

- Update version
- Set Android notification low importance
- Fix the issue that VpnService can't be closed correctly in special cases
- Fix the problem that TileService is not destroyed correctly in some cases
- Adjust tab animation defaults
- Add Telegram in README_zh_CN.md
- Add Telegram

## v0.7.0 (2024-04-30)

- update mobile_scanner
- Initial commit
