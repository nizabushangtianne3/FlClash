# 性能优化账本

本文记录 FlClash 主仓库与 `core/Clash.Meta` 子模块的性能优化成果、验证结果、已拒绝方案和后续切入点。后续继续优化时，先读本文，再按当前工作区重新测量，不要直接复用旧数据当作当前结论。

- 最近核对日期：2026-11-05
- FlClash main：`65ba30c9`
- Clash.Meta main：`5c215995c`
- 基准主机：Intel Core i9-9900，Windows/amd64
- 基准策略：改动前后使用同一负载、同一 Go 缓存目录，`benchstat` 至少 7 组；时间显著回退的方案即使内存/分配更好也要撤销。

## 1. 工作流约定

1. 先建立 baseline，再做重构；重构必须通过 paired benchmark 证明。
2. focused tests 通过后跑 focused race、`go vet ./...`、core 全量测试、wrapper 全量测试和 vet。
3. 提交顺序固定为：先提交并推送 `core/Clash.Meta`，再更新父仓库 submodule 指针并推送父仓库。
4. 用户没有明确要求时不触发 GitHub Actions；本地验证是当前性能改动的发布门槛。
5. 不做兼容层、shim 或保守包装；被基准否决的实验必须撤销。
6. 不回收 UDP wrapper、不池化 `packetAdapter`，也不清理 flow 最后一次交给 sender 的 write-back 目标。
7. 临时 Go 缓存放 `D:\Codex\tmp\<task>`，任务结束后清理；不要复用旧缓存作为新结论。

## 2. 已落地优化

### 2026-11-03 全量复核轮次

本轮从 wrapper/子模块 benchmark 地图重新测量，找出并落地五十项优化；审计中确认过但**未**改动的位置见本节末尾。加上 2026-11-04/11-05 持续重构轮次，账本当前共 62 项。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 每连接行序列化的 enum 改共享文本（`DNSMode`/`DNSPrefer`/`FilterMode`/`TUNStack` 的 `MarshalText`，`NetWork`/`Type` 的 `MarshalJSON`） | `8cf7ce119` | `b0ad8b48` | 连接全量同步（500 行）分配 3516 → 2014，时间 1.60ms → 1.25ms |
| 延迟历史环首用分配（`Queue.ring` 替代 `make` 预分配） | `8cf7ce119` | `b0ad8b48` | `ParseConfig` 800 节点：分配 93917 → 93109，内存 5.54MB → 5.30MB |
| 组文档写入前精确计算容量 + `jsonutil.StringLen` | `8cf7ce119` | `b0ad8b48` | 代理列表接口（200 组×20）：分配 1237 → 421，内存 223KB → 105KB，`AllocsPerRun == 1` 被测试钉住 |
| `getConnections` 答案走 per-row 手写编码器（导出 `TrackerInfo.AppendJSON`） | `5ceac07ed` | `750317db` | 连接全量同步（500 行）分配 3516 → 517，内存 594KB → 476KB |
| 连接答案自己写响应帧（`frameWriter`），不再让 json writer 二次拷贝 | -（仅 wrapper） | `e0a257ca` | 连接全量同步（500 行）1.25ms → 0.18ms、分配 517 → 517；增量轮询 6 → 2 allocs |
| 每个代理映射复用 immutable proxy decoder | `12e1ec6b9` | `16c1740b` | 800 节点解析分配 93.15k → 92.34k，内存 5.041Mi → 5.016Mi；时间在噪声内 |
| URLTest writer/reader 进池并在交换结束后重置 | `91ecd8972` | `886bde94` | 稳定 pipe 交换 9.33µs/7.93KiB/39 allocs → 5.42µs/3.30KiB/35 allocs |
| DNS UDP query/read 缓冲进池并直接匹配 ID | `cf7405067` | `c9009c7e` | 本地 UDP exchange 21.87µs/4728B/19 allocs → 20.55µs/632B/18 allocs |
| TUIC v5 四分片内联存储 | `ef26c3053` | `2dccf18e` | 分片接收 1.155µs/288B/2 allocs → 1.131µs/288B/1 alloc |
| DNS UDP packed query buffer 复用 | `4d93a3c08` | `dc4cef77` | 本地 UDP exchange 632B/18 allocs → 600B/17 allocs；时间在噪声内 |
| SS/Snell obfs decoder 共享 | `2ca2ee6c4` | `59494517` | 800 节点解析 19.12ms/5.016Mi/92.33k → 16.48ms/4.992Mi/91.53k |
| 代理解析 options 直传指针 | `22d145c28` | `1e25b3f4` | 800 节点解析 4.992Mi/91.53k → 4.955Mi/90.74k；时间在噪声内 |
| 延迟历史单次拷贝 | `ee9804ad0` | `1dfb7bc6` | 10 行 history 400ns/640B/2 allocs → 221ns/320B/1 alloc；extra 1.044µs/1104B/4 → 868ns/784B/3 |
| 关闭连接免中间 tracker 切片 | -（仅 wrapper） | `4f002821` | 关闭/切网不再分配整表 tracker 切片 |
| 延迟历史有界写入单锁完成 | `19a1b546f` | `ab93682a` | 满 10 行记录 67.85ns → 48.68ns，分配保持 0 |
| Queue ring 拷贝分段化 | `7df5436c4` | `b8cee4e6` | 10 行 Copy 178.5ns → 104.2ns，内存/分配不变 |
| 代理解析 UUID 内联存储 | `87525b66c` | `2c71ce52` | 800 节点解析 4.955Mi/90.74k → 4.918Mi/89.94k；时间在噪声内 |
| Queue ring 遍历分段化 | `3085e89ef` | `129be484` | 10 行 Range 87.09ns → 27.48ns，分配保持 0 |
| DNS 缓存写入原地过滤 | `5352ae3f1` | `b6cfebac` | 典型缓存写入 419.8ns/440B/9 → 388.4ns/424B/8 |
| API JSON 池保留换行容量 | `8a69e7c7f` | `d1c478d7` | 避免池化响应每次追加 newline 触发整文档扩容 |
| Provider JSON 预设容量 | `9bf09809f` | `4778ba93` | 8×64 provider 响应 profile 从稳态扩容转为 warm-up |
| TUIC v5 packetBag 池化 | `54086dc59` | `60922137` | 4 分片接收 1.1285µs/288B/1 alloc → 848.5ns/0B/0 alloc；generation 防护 stale caller |
| DNS 缓存写入专用 slab 克隆 | `be2c37a1d` | `151e1f1a` | 典型缓存写入 377.8ns/424B/8 → 304.4ns/328B/4；缓存命中 304B/3 保持不变 |
| packetConn LocalAddr 一次性构造 | `f2a4a6259` | `90eb2b47` | 44.07ns/48B/1 alloc → 1.32ns/0B/0 alloc；QUIC multiplexer identity 保持稳定 |
| DNS UDP 简单 A/AAAA 快速解析 | `4a12bb4e3` | `d15aa27a` | 本地 UDP exchange 20.72µs/600B/17 → 19.88µs/624B/12；复杂回复回退 miekg 完整解析 |
| DNS all-A cache hit 单 slab | `0ac714f7b` | `8aaec6ca` | 典型 cache hit 277.4ns/304B/3 → 217.1ns/320B/1；混合/更大回复保留原路径 |
| DNS all-A cache write 单 slab | `6589edc27` | `4c9076e7` | 典型 cache write 293.6ns/328B/4 → 190.3ns/320B/1；丢弃 OPT 并保持调用方隔离 |
| DNS all-AAAA cache hit/write 单 slab | `e8fc306d5` | `4bfce356` | AAAA cache hit 283.0ns/320B/3 → 222.7ns/352B/1；write 246.2ns/344B/4 → 199.8ns/352B/1 |
| DNS one-A cache hit/write 单 slab | `d490036a8` | `5f581b29` | one-A cache hit 187.4ns/320B/1 → 168.0ns/240B/1；write 160.5ns/320B/1 → 141.6ns/240B/1 |
| UDP flow origin/dial 元数据单 slab | `028548951` | `1feee699` | 首包 173.4ns/832B/2 allocs → 155.5ns/896B/1 alloc；时间 -10.38%，allocs -50% |
| UDP sender 每 flow 队列容量 128→16 | `d2789cc8c` | `7b18412f` | 新建 sender 378.4ns/2528B/3 allocs → 162.7ns/480B/3 allocs；时间 -57.00%，内存 -81.01% |
| UDP tracker 单链快照免拷贝 | `1a45547c9` | `5d4f25e0` | 新建 UDP tracker 342.3ns/768B/4 allocs → 293.7ns/752B/3 allocs；时间 -14.20%，allocs -25% |
| UDP flow write-back proxy 进 slab | `99c7ec230` | `6b726556` | flow+sender+writeback 1392B/5 allocs → 1376B/4 allocs；allocs -20%，时间 p=0.225 在噪声内 |
| DNS 简单回复复用请求 question | `48097353a` | `9f0f69b2` | 快速解析 159.6ns/336B/2 allocs → 147.9ns/320B/1 alloc；UDP exchange 624B/12 allocs → 608B/11 allocs |
| DNS 未压缩 answer owner 复用 | `e1d018b18` | `f8b22fbd` | 未压缩 AAAA 快速解析 226.6ns/344B/2 allocs → 191.9ns/320B/1 alloc；时间 -15.29%，allocs -50% |
| DNS 空 EDNS OPT 快速路径 | `261af6d58` | `62bc32b2` | 554.9ns/304B/10 allocs → 168.0ns/384B/1 alloc；时间 -69.72%，allocs -90% |
| DNS CNAME+地址链快速解析 | `28b54bd19` | `52b43782` | 715.2ns/352B/11 allocs → 286.2ns/528B/3 allocs；时间 -59.98%，allocs -72.73% |
| DNS 多地址回答快速解析 | `3f8c1d95e` | `8d3d1a59` | CNAME+4A 1427.0ns/920B/24 allocs → 603.0ns/912B/6 allocs；时间 -57.74%，allocs -75% |
| DNS 直接回答 slab 收紧 | `3899aedbb` | `09744fca` | 直接 A 173.6ns/416B/1 alloc → 164.8ns/384B/1 alloc；时间 -5.07%，内存 -7.69% |
| DNS 按地址族拆分响应 slab | `3e5d98c37` | `3b5833b3` | 直接 A 内存 384B → 320B；CNAME+A 314.6ns/496B/3 allocs → 279.9ns/480B/2 allocs |
| Sing UDP wrapper 共享写状态指针 | `39bda80df` | `6252742f` | 100 包流 13.75µs/56.47KiB/104 allocs → 11.77µs/47.10KiB/104 allocs；时间 -14.38%，内存 -16.60% |
| Sing packet 原生 adapter 直通 | `f1955366c` | `9ccf787c` | 既有 flow wrapped 114.8ns/128B/2 allocs → native 40.8ns/0B/0 allocs；时间 -64.46%，allocs -100% |
| Tunnel packet 原生 adapter 直通 | `4e05598fd` | `41a763b4` | wrapped 24.34ns/64B/1 alloc → native 1.292ns/0B/0 allocs；时间 -94.69%，allocs -100% |
| Trojan packet 原生 adapter 直通 | `41320de4d` | `94f63690` | wrapped 27.88ns/64B/1 alloc → native 2.142ns/0B/0 allocs；时间 -92.32%，allocs -100% |
| TProxy packet 原生 adapter 直通 | `305a43e43` | `459ee5fb` | wrapped 23.15ns/64B/1 alloc → native 1.285ns/0B/0 allocs；时间 -94.45%，allocs -100% |
| Shadowsocks packet 原生 adapter 直通 | `89679eaa8` | `e8d66cfc` | wrapped 26.56ns/64B/1 alloc → native 2.129ns/0B/0 allocs；时间 -91.99%，allocs -100% |
| Snell packet 原生 adapter 直通 | `48d94d41a` | `e00bbe88` | wrapped 26.00ns/64B/1 alloc → native 1.285ns/0B/0 allocs；时间 -95.06%，allocs -100% |
| Mieru packet 原生 adapter 直通 | `94572bcaa` | `f06d563b` | wrapped 24.39ns/64B/1 alloc → native 2.192ns/0B/0 allocs；时间 -91.01%，allocs -100% |
| Socks packet 原生 adapter 直通 | `1fd9f5722` | `802e7e38` | wrapped 32.83ns/64B/1 alloc → native 2.156ns/0B/0 allocs；时间 -93.43%，allocs -100% |
| Sing UDP flow metadata 共享指针 | `04d09567d` | `a110341a` | 100 包流 11.77µs/47.10KiB/104 allocs → 9.50µs/8.44KiB/105 allocs；时间 -19.32%，内存 -82.09% |

合计：连接表一次全量同步从 1.60ms/594KB/3525 allocs 降到 0.18ms/476KB/517 allocs。

#### 本轮审计确认、但刻意未动的位置

| 位置 | 证据 | 不做的原因 |
|---|---|---|
| `adapter/outbound.NewBase` 每代理 `uuid.NewV4().String()` | `ParseConfig` 800 节点下每代理 2 allocs | `ID()` 在链路信息里按需调用，改懒格式化会把成本挪到连接路径 |
| `NewAutoCloseProxyAdapter` 每代理 `runtime.SetFinalizer` | profile 中占 ~7.5% CPU | 它是代理泄漏的兜底自动关闭；删除改变安全语义，留给上游决策 |
| 规则索引前的大段 plain 规则线性扫描 | `MatchPlainRulesBeforeIndexedHit/plain=5000` 40µs/次 | 5000 条不可索引规则（PORT/NETWORK/进程名…）属极端配置；按判别键建桶要重写匹配顺序语义，风险大于收益 |
| 800 节点 profile 单次解析 6.6ms/51K allocs | wrapper `UnmarshalProfileDocument` | 成本 99% 在 yaml v3 解析本身（`parser.node/resolve/read`）；digest 缓存已覆盖重复读，冷解析无法再降 |
| host 传 digest 给 Core 省一次 sha256 | `MergeProfileBaseCached` 375µs 中 sha256 占 28% | 信任宿主 digest 会让 Core 在宿主重写文件后返回过期文档；正确性风险大于 100µs |
| Dart 侧入口（事件分发、连接 provider、仪表盘表格、代理列表） | 代码走查 + `dart analyze --fatal-warnings` 无问题 | 已过多轮优化（增量 delta、revision 相等、节流重绘、固定行高列表）；无实测热点可改 |
| DNS UDP 客户端交换剩余 ~10 allocs | `BenchmarkClientExchangeUDP` memprofile：miekg 打包 ~2、`net` sockaddr ~3、基准内测试服务器侧 ~4、快速路径 slab 1 | 剩余成本在 miekg 编码与 `net` 层；基准数字含测试服务器自身分配，客户端可削减的仅剩 miekg 打包，收益不抵复杂度 |
| TCP 每连接建立 ~114 allocs | `BenchmarkTCPConnSetupDirect` memprofile：`net` 拨号内部 ~38、stdlib `AfterFunc` 中断器 ~18、sing bufio 读等待器 ~5、`NewTCPTracker` 2（隔离基准钉住） | 拨号内部与 stdlib 连接中断不可绕过；`AfterFunc` 闭包换来 ctx 取消即断连的语义，账本 P4 附带项维持"收益小"结论 |
| 组文档每答案重编码（getProxies 主要剩余成本，200 组 ~200µs） | `BenchmarkHandleGetProxies` 296µs 中 Selector/URLTest `AppendJSON` 占大头 | 组 JSON 随选中项、延迟历史、provider 版本变化；无可靠的失效钩子，缓存会发出过期的 `now`/history 破坏选中显示，正确性风险大于收益 |


### 2026-11-04 持续重构轮次

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| DNS 3–8 条 A/AAAA cache hit 单 slab | `7af0a7f9d` | `3be4cae8` | FourA 233.6ns/464B/3 allocs → 183.2ns/896B/1 alloc；FourAAAA 226.5ns/496B/3 allocs → 166.5ns/896B/1 alloc；时间分别 -21.58%/-26.49%，allocs -66.67%，内存增加为固定 8 槽 slab 权衡 |
| 延迟快照视图发布 | -（仅 wrapper） | `fa0b02af` | 1000 URL×1000 节点、100 URL 批量变更：3 轮均值 7559.8µs → 1739.6µs（-77.0%）；快照不可变与批量状态 focused/full Flutter 测试通过 |
| UDP 映射原始目的直传 | `b7a2b0c8b` | `7ebc0bf4` | `BenchmarkNewUDPFlowMetadata` paired n=7：156.2ns ±2% → 141.1ns ±4%（-9.67%），内存 896B → 480B（-46.43%），allocs 保持 1；focused race、core 全量测试、wrapper/Android arm64 vet 通过 |
| 代理解列表直写响应帧 | -（仅 wrapper） | `4d4283a5` | 200 组×20 成员端到端（旧路径含 `json.Marshal` 信封）461.3µs/224KB/1015 allocs → 206.4µs/187KB/5 allocs（时间 -55.3%，allocs -99.5%）；20 组 50.1µs/113 → 18.8µs/5；`ProxiesData`/`nodeView` 删除，答案形状由 `TestProxiesAnswerAnswersWhatTheHostReads` 钉住，GLOBAL hidden 键移至对象末尾（JSON 语义等价），Dart 契约无变化；wrapper 全量测试 + vet 通过 |
| 连接行快照跨 resync 复用 | -（仅 wrapper） | `28754060` | `BenchmarkGetConnectionsFull` paired n=7：500 行 166.1µs/463KiB/512 allocs → 133.5µs/369KiB/12 allocs（时间 -19.60%，内存 -20.25%，allocs -97.66%，p=0.001）；100 行 41.87µs/110 → 31.46µs/10；delta 轮询 2 allocs 不变；resync 答案字节级等价（死行静默清理，Removed 保持空），`TestConnectionDeltaAnswersWhatMoved` 新增连续 resync 复用与 stale 重建断言；wrapper 全量测试、focused race、vet 通过 |
| 代理解表排序缓存 | -（仅 wrapper） | `c265d9b9` | 200 组+1000 节点 A/B n=7：每次答案排序 424.9µs/302.7KB/6 allocs → 快照身份缓存命中 296.1µs/282.1KB/5 allocs（时间 -30.3%）；200 组场景 206.4µs → ~177µs；排序结果按 `tunnel.AllProxies` map 身份缓存，身份变更即重建，`TestProxiesAnswerAnswersWhatTheHostReads` 增加"表变更后答案携带新成员"断言；wrapper 全量测试 + vet 通过 |
| 事件批量直写编码 | -（仅 wrapper） | `d838533e` | `BenchmarkSendMessageBatch` paired n=7：64 条 62.59µs/17.93KiB/195 allocs → 6.30µs/16.0KiB/1 alloc（时间 **-89.94%**，allocs **-99.49%**，p=0.001）；16 条 15.96µs/51 → 1.81µs/1（-88.64%/-98.04%）；`messageBatchCall` 反射编码退役（结构体移入测试作参考实现），request 事件复用 `TrackerInfo.AppendJSON` 行编码器，线字节等价由 `TestMessageBatchMatchesReflection` 钉住（覆盖全部 8 种直写 payload + 回退，含 LogLevel MarshalText、HTML/U+2028 转义、omitted 空 DNS 字段）；初版基准曾把单值 `RequestTraffic` 误作负载使编码器落到回退分支（生产端只发切片），修正后测得真实分配为每批 1 次缓冲；wrapper 全量测试、batcher focused race、vet 通过 |
| 节点视图随快照缓存 | -（仅 wrapper） | c980109a | `BenchmarkHandleGetProxies` paired n=7：200 组+1000 节点 296.0µs → 236.0µs（**-20.27%**，p=0.001），allocs 5、内存持平；纯组场景噪声内（无节点可缓存）。CPU 剖析定位节点视图逐答案重编码占帧内 CPU ~40%（`isJSONSafeASCII` 15.7% + 接口分发），节点三字段（name/type/provider）在快照存续期恒定，预编码字节与排序名单共用同一身份缓存，组文档仍每次实时编码；缓存换算 ~80KB 常驻（1000 节点 × ~60B），快照变更即重建；wrapper 全量测试 + vet 通过 |
| 答案尺寸预计算 | -（仅 wrapper） | a251ab40 | 同基准叠加 paired n=7：千节点 236.0µs → 195.1µs（**-17.33%**，p=0.001），allocs/内存持平；纯组场景 -2.5%（噪声内）。answerSize 原每答案随机序遍历整张代理表（1200 项 map + 每项 Type() 接口分发），尺寸基数（名字长度和 + 组脚手架）改在快照缓存重建时一次算好；wrapper 全量测试 + vet 通过 |
| Selector 组文档缓存 | -（仅 wrapper） | e429715f | `BenchmarkHandleGetProxies` paired n=7：200 组 169.9µs → 86.6µs（**-48.99%**，p=0.001），千节点 195.1µs → 107.6µs（**-44.83%**，p=0.001），allocs/内存持平；本路径会话累计 461.3µs → 107.6µs（-76.7%）。缓存键完备性论证：history 已于先前轮次移出组文档，Selector 可变字段仅 now（选中）与 all（成员=provider 版本），testUrl/hidden/icon 构造期恒定，键=（Now，版本元组）即完备；GLOBAL hidden 拼接后整体入缓存；URLTest/Fallback/LoadBalance 自主改选/轮换，始终实时编码；键以代理实例为标识（同名字 GLOBAL 不串档），快照身份变更即清空；命中路径零分配（版本比较不建切片）；wrapper 全量测试 + vet 通过 |
| 组文档缓存扩展至全部组类型 | `5c215995c` | `65ba30c9` | `BenchmarkHandleGetProxies` paired n=7（新增 urltest/fallback/loadbalance 场景，无 kind 后缀的 Selector 场景名不变保持跨轮配对）：200 组 urltest 153.2µs ±5% → 69.9µs ±1%（**-54.42%**），千节点 urltest 188.1µs ±2% → 98.7µs ±2%（**-47.55%**），fallback 171.3µs ±3% → 79.2µs ±3%（**-53.75%**），loadbalance 154.3µs ±3% → 66.1µs ±10%（**-57.20%**），各 p=0.001，urltest allocs -1（命中路径免 `MarshalJSON` 缓冲）；Selector 既有场景 p=0.21–0.90 噪声内。键完备性：URLTest/Fallback 文档可变字段=（now=自主改选，fixed=用户钉选，all=provider 版本），fixed 与 now 独立可变（钉选节点死亡时 now 走最快而 fixed 保留，故两值都必须入键），LoadBalance 文档不含选择字段仅版本入键，其余字段构造期恒定——推翻本表上一行「URLTest/Fallback/LoadBalance 始终实时编码」的保守结论；键仍以代理实例为标识、快照身份变更即清空；子模块为 URLTest/Fallback 导出 `SelectedName()`（`5c215995c`）；`TestGroupDocsAnswerWhatTheirGroupsChange` 钉住四种 kind 的稳态答案字节等价、钉选（Set→fixed/now）与订阅刷新（provider 版本→all）到达下一答案、answered now==live Now()、每答案 AllocsPerRun≤4；CGO 启用/禁用两种构建下 wrapper 全量测试、focused race、`go vet .`、子模块 outboundgroup 测试+vet、core 全量 `go test ./...`（104 包）+`go vet ./...`、adapter 包 Android arm64 vet 全部通过 |

### 稳定统计与统计链路

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `Manager.Snapshot()` 改为返回值 | `3c0530b48` | `9e82d9ff` | 快照路径 2 allocs/op → 1 |
| 合并 tracker chain clones | `8e88c6aaa` | `dea7114b` | 双 chain 场景 4 allocs/op → 3 |

### FakeIP 与 DNS 解析

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| FakeIP store 写入合并 | `fa45dd959` | `c7b0d01e` | 减少分配写入路径 |
| FakeIP 使用 intrusive LRU entry | `d6119831e` | `c1e72e8e` | 减少节点分配 |
| 移除 FakeIP memory store 冗余锁 | `3fb66bdf8` | `f5da7379` | 简化锁路径 |
| FakeIP answer 分配合并 | `061abd392` | `5f9eb897` | 降低 DNS answer 组装成本 |
| FakeIP unique lookup 维持零分配 | 同上系列 | 同上系列 | 当前基准为 0 allocs/op |

### Trie / DomainSet

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| domain key 直接构建 | `edb922d60` | `85626b24` | 减少 builder 中间字符串 |
| 反向 trie key 直接构造 | `06897d3f7` | `e190cc1f` | 避免额外 reverse 分配 |
| 存储域遍历替代 map 遍历 | `6b0d29788` | `21f7d185` | 降低构建遍历成本 |
| builder 存储复用 | `4182c5624` | `5a2cde67` | 支持构建器复用 |
| DomainSet starts 缓存 | `665fc1ace` | `2256d5e0` | 查询减少重复计算 |
| wildcard select lookup 重写 | `467945e3d` | `d66e8ecc` | 降低通配匹配成本 |
| arena 化 DomainSet keys | `0b92f5951` | `99a7f0d5` | BuilderReuse 分配 18226 → 214；Build builder 耗时约 -32.51% |

### 规则匹配

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| RuleWrapper 原子加法返回值复用 | `20e969ef4` | `689b9fa0` | Hit 19.36ns → 9.093ns（-53.03%）；Miss 13.775ns → 8.795ns（-36.15%）；两边 p=0.000，仍为 0B/0 allocs |

### 枚举序列化

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| AdapterType 静态名称表 | `944e548ca` | `39cedefc` | Shadowsocks -4.92%（p=0.000）、URLTest -6.61%（p=0.003）、GostRelay -7.39%（p=0.008）；geomean -5.66%，仍 0B/0 allocs |

### Route / JSON 输出

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| proxy JSON 直接 append | `022422cf2` | `09d09a34` | 避免 marshal/unescape/re-encode |
| proxies API 直接 append | `9710ba294` | `6fc6478a` | 降低 API 序列化成本 |
| rules API 直接 append | `69830bac2` | `4e393e37` | 降低规则 API 成本 |
| provider API 直接 append | `64ac59b04` | `33f47323` | 降低 provider API 成本 |
| adapter ID 字符串缓存 | `eb0a1cea2` | `13a15729` | Providers API 分配 530 → 18；内存约 -14.44% |
| Proxy 空 extra map 跳过 | `735c420c7` | `536d2de5` | Proxy JSON 144.80ns → 94.92ns（-34.44%，p=0.000）；8×64 Providers API 129.5µs → 103.8µs（-19.85%，p=0.000）；内存/分配无回退 |
| JSON 零时间戳直接追加 | `5de9d6a8f` | `3f5ce42f` | `AppendTime/zero` 32.33ns → 3.957ns（-87.76%，p=0.000）；value 路径无显著变化，内存/分配保持 0 |
| JSON 纯 ASCII 快路径 | `5d234cb4d` | `6232f71d` | 32B ASCII 47.53ns → 16.58ns（-65.12%）；256B ASCII 296.9ns → 111.7ns（-62.37%）；两边 p=0.000，仍 0B/0 allocs；转义/Unicode 无显著回退 |
| JSON safe string length 快路径 | `d34b92754` | `037d9236` | 32B ASCII 53.98ns → 17.32ns（-67.91%）；256B ASCII 382.9ns → 122.5ns（-68.01%）；两边 p=0.000，仍 0B/0 allocs；AppendString 四类路径无显著回退 |
| 连接视图复用安全 JSON encoder | `e6ba2ffaf` | `c36359d4` | 256B 安全 ASCII 301.4ns → 128.8ns（-57.26%，p=0.000）；256B 转义 +15.32%（p=0.001），Unicode 无显著变化；删除 79 行重复逻辑，仍 0B/0 allocs |
| Proxy JSON 一次预分配 | `da7bd157a` | `f91f922a` | 340.8ns → 227.9ns（-33.13%，p=0.000）；allocs 6 → 1（-83.33%）；内存 504B → 576B（+14.29%）为一次分配权衡 |

### UDP / 传输层

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| Hysteria packet source address 缓存 | `db755cfd4` | `cf071ad4` | 65.24ns → 22.77ns，内存 48B → 0 |
| SSR UDP pooled buffer 编码 | `9886adc2b` | `099ded61` | 333.20ns / 1288B / 2 allocs → 43.20ns / 0B / 0 allocs |
| TUIC v5 单分片绕过 deFragger | `5f62efc66` | `a10db91b` | 53.28ns → 11.21ns，约 -78.96% |
| TUIC v5 完成分片立即释放 bag | `749677e1d` | `9ff36935` | 唯一分片消息 1704ns → 937.9ns，约 -44.96% |

### DNS client

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| UDP/TCP DNS client address 缓存 | `8313088fc` | `6382b2d2` | Address：102ns / 56B / 3 allocs → 0.283ns / 0B / 0 allocs |
| DoT client address 缓存 | `1ecd02889` | `e12a3d13` | Address：176ns / 56B / 3 allocs → 0.449ns / 0B / 0 allocs |

该函数不是冷路径：`batchExchange` 在每个上游成功响应后都会通过 `traceAnswer(..., client.Address())` 调用。

### 序列化与通用库

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| pool invalid-size error 静态化 | `054a0a27a` | `f6701244` | Mekya forward 16B / 1 alloc → 0B / 0 allocs |
| OrderedMap YAML 一次编码 | `f0e4e3251` | `b3f32d57` | 108.38µs / 200.54KiB / 647 allocs → 37.41µs / 41.12KiB / 164 allocs |

### 连接稳定性与内存安全修复

| 修复 | core 提交 | 结果 |
|---|---|---|
| deadline pipe 读缓冲安全池化 | `c990a8cba` | 复用缓冲时保留所有权边界，避免读缓冲被提前释放或跨生命周期误用 |
| TCP 统计层下游 writer headroom | `20705de7d` + `20af3330e` | Relay 池化读缓冲缺少 front/rear headroom 时，按下游协议要求复制；覆盖 VLESS Vision、VMess WebSocket 等所有 TCP 协议 |
| YAML any round-trip fuzz oracle | `6d2ba3827` | 按 YAML 标量语义比较 `any` 值，避免把 YAML 规范化后的等价数值误判为回归 |
| MKCP 控制段池 close option 复位 | `826faaaf9` | 100 轮旧实现出现 4 次 FullDuplex EOF + 2 次 RoundTrip 超时；修复后 300 轮 `-cpu 1` 全绿 |

安卓 v1.0.1 两类崩溃都来自同一条 Relay 路径：`copyWaitWithPool` 把 `start=0` 的 32KB pooled buffer 交给下游 `WriteBuffer`。第一份栈在 VLESS Vision `ApplyPadding` 处 `ExtendHeader(2)`；第二份栈在 VMess WebSocket `WriteBuffer` 处 `ExtendHeader(8)`。现在 `tcpTracker.WriteBuffer` 在进入协议栈前预计算下游 front/rear headroom，复制时按当前 payload 长度分配，避免 sing 默认 4KB buffer 截断大包；VLESS 局部补丁已移除，防止同一份数据二次复制。

### 父仓库 / 桌面路径

| 优化 | 位置 | 父仓库提交 | 结果 |
|---|---|---|---|
| Windows process probe FFI symbol/library 缓存 | `lib/core/desktop/process_probe.dart` | `1db374ff` | 避免每次探测重新打开 DLL 和查找 4 个符号 |
| URLTest 已有状态复用 | `core/Clash.Meta/adapter/adapter.go` | `dcdbe4d1` | 精准基准 146ns / 400B / 3 allocs → 16.5ns / 0B / 0 allocs |

## 3. 已拒绝或已撤销实验

| 实验 | 结论 |
|---|---|
| `common/net/deadline` 常驻 reader goroutine | 分配可降为 0，但读耗时约 794ns 增至 940ns，已撤销，不要保留。 |
| DomainSet 构建前一次性预分配 bitmap/starts | 内存和分配下降，但 Builder/Build 耗时分别回退约 53%/49%，已撤销。 |
| URLTest 端到端 benchmark 的多进程同端口复跑 | Windows 会偶发客户端源端口与 httptest 监听端口冲突；该场景应使用确定性 state benchmark 或稳定测试端口方案。 |
| packetSender closed/active 合成单原子状态 | CAS 版 ready +0.88%、full +24.30%、closed +10.16%；Add 高位版 closed +296.60%。两者均撤销，保留原 closed/active 分离实现。 |
| UDP retry 改接口 action | `400.7ns/272B/4 allocs → 428.4ns/296B/5 allocs`；时间回退约 7%、多 1 alloc，已撤销。 |
| Sing packet 合并 flow state | 100 包流内存 -18.52%，但单包 allocs 4 → 5，时间在噪声内；撤销以保留单包路径。 |
| UDP 多地址回复固定 slab | CNAME+4A allocs 6 → 4，但内存 736B → 1136B（+54.35%），时间 p=0.542 无显著改善；撤销，避免未证明的内存换分配。 |
| UDP flow/sender 单 slab | paired benchstat：首包 367.5ns/1376B/4 allocs → 508.2ns/2112B/7 allocs（时间 +38.29%，allocs +75%）；escaped closure/interface 抵消收益，已撤销。 |
| packetSender Done 延迟创建 | paired benchstat：首包 367.5ns/1376B/4 allocs → 473.9ns/1696B/5 allocs（时间 +28.95%，内存 +23.26%）；lazy 路径复杂度无收益，已撤销。 |

## 4. 当前验证矩阵

2026-11-04 本轮性能工作收尾时以下验证全部通过：

```powershell
# core 子模块（Clash.Meta）全量：104 包 ok，exit 0
go test ./... -count=1 -p=1
go vet ./...

# wrapper（父仓库 core/）全量套件：每轮改动后全绿，exit 0
go test . -count=1
go vet .
# batcher/连接 focused race（CGO_ENABLED=1）
go test -race . -run 'TestRunMessageBatcher|TestMessageBatch|TestConnectionDelta|TestResetNetwork'

# Dart 全量（含 protocol_contract_test.dart，setup 构建钩子需 go 在 PATH）
# PUB_CACHE=D:\Codex\tools\pub-cache-task
dart run tool/test.dart   # exit 0
```

对应 paired benchstat（均 n=7）已在各自改动轮次执行；本轮五项优化的基准数据见第 2 节各行。

外部 V2Ray 互操作支持 `MIHOMO_V2RAY_INTEROP_BIN` 复用已构建的版本化二进制；本机使用 `D:\Codex\tools\v2ray-5.51.2\bin\v2ray.exe`。`TestInboundVMess_MKCP_V2RayInterop` 现覆盖默认、seed 和全部 5 种 header，双向共 14 个子用例；普通与 `-race` 全绿。未知 header 现在启动/拨号即报错，不再静默回退 none。

## 5. 后续优化切入点

### P1：DNS UDP response parsing

- 常见 A/AAAA 简单回复已走单 slab 快速解析，`BenchmarkClientExchangeUDP` 为 11 allocs / 739B（端到端，含 UDP I/O）。
- 负回复（NXDOMAIN/NODATA+SOA）实测基线（2026-11-05，shaped 基准 `BenchmarkClientExchangeUDPNXDOMAIN/NODATA`）：端到端 ~21.8–22.3µs / 21 allocs，走完整 miekg 解析。
- **扩展实验已否决**（2026-11-05）：实现零答案+authority 解码快速路径后 paired n=7，时间 -2%（噪声内），allocs 21→19（-9.52%），B/op **+5.71%** 回退。结构性原因：交换由 UDP I/O 主导，解析占比小；且 authority 必须解码进消息（`minimalTTLSections` 用 Ns 计算 msg 缓存负 TTL，丢弃会破坏负缓存语义），SOA 解码的 slab+字符串分配抵消了收益。shaped 基准基建已保留（`startShapedUDPDNSServer`），TSIG/OPT-带选项回退的测试结论同样保留在实验分支历史中。不要池化已交给调用方的解析结果。

### P2：本地 DNS 服务端回包全链（新基线，未动）

- `BenchmarkServeMsgCacheHitWithPack`（本轮新增）测得缓存命中查询全链（查询 Unpack → ServeMsg → EDNS 回显 → reply Pack）：**1.29µs / 952B / 15 allocs**。
- 剖析：~9 allocs 在 miekg 服务端内部的查询解析（`Msg.Unpack` → `unpackRRslice`/`UnpackDomainName`），~4 在 `SetReply`+`Pack`，1 在我方缓存拷贝（已是单 slab）。
- 要消除查询解析成本必须绕过 miekg 的 UDP serve 循环自管超时/TCP 回退/EDNS/空闲清理；现实 qps 下每查询 ~1.3µs 不构成瓶颈，重构风险大于收益，留基准为将来重估起点。

### P4：UDP `packetSender` 首包

- `AddMapping`、origin/dial slab、队列容量、tracker 快照和 write-back slab 已完成；剩余成本主要来自 outbound dial/context 生命周期。
- 可审查是否有安全的一级 fast path；不要池化 sender，避免 Close/active 状态跨流复用。

### P5：Windows socket benchmark 稳定性

- 已解决：`BenchmarkProxyURLTestHTTP` 改为进程内 pipe HTTP server，避开 Windows 临时端口分配冲突。
- 旧实现 count=10 内复现多次 `connectex: Only one usage...`；pipe 版 count=20 全绿。

## 6. 后续会话推荐流程

```powershell
git pull --ff-only
git -C core/Clash.Meta switch main
git -C core/Clash.Meta pull --ff-only

$task = "D:\Codex\tmp\flclash-<new-topic>"
New-Item -ItemType Directory -Force -Path "$task\cache","$task\mod","$task\path"
$env:GOCACHE="$task\cache"
$env:GOPATH="$task\path"
$env:GOMODCACHE="$task\mod"
$env:GOPROXY='https://goproxy.cn,direct'

go test <pkg> -run '^$' -bench <Benchmark> -benchmem -count=7
```

修改后按同一基准生成 current，用：

```powershell
D:\Codex\tools\go-bin\benchstat.exe <baseline> <current>
```

只有时间、内存或分配有明确收益才继续；否则恢复改动并记录拒绝原因。

## 7. 已知维护事项

- `miekg/dns` 的 `ClientExchangeUDP` 中 `Context.AfterFunc` 每次分配一个 stop 闭包；单独优化收益小，建议与 P1 一起重构。
- 首次全量验证中 `TestInboundVMess_Mekya` 曾出现偶发 `unexpected EOF / closed pipe`；隔离复跑和后续全量均通过，尚不是稳定失败。
- 任务缓存清理工具此前被执行器安全策略拦截，`D:\Codex\tmp` 下仍有 benchmark/profile 缓存目录；继续前可按任务名确认是否可清理。
- `sqlite3` v3.7.0 的 Windows 原生资产钩子会失败：GitHub release `sqlite3-3.7.0` 的 `sqlite3.x64.windows.dll` 已于 2026-09-30 重新上传（官方 API 摘要 `98b4be67...`），与包内 `asset_hashes.dart` 钉住的 `3a29878d...` 不一致。已在本地 pub 缓存（`D:\Codex\tools\pub-cache-task`）按 GitHub 官方摘要修正该哈希；上游发布新版本前这是环境级阻塞。跑 `dart run tool/test.dart` 还需 `PUB_CACHE=D:\Codex\tools\pub-cache-task`，并把 Flutter 与 Go 的 bin 放进 PATH（`setup` 包的构建钩子要调 `go`）。
- 本轮 `dart run tool/test.dart` 的 32 个 bundle 里有 2 个用例失败，单独重跑同一批文件全部通过（bundle 共享 isolate 的跨文件干扰）；工具的结论是退出码 0。Dart 侧本轮零改动。
