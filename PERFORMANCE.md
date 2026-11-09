# 性能优化账本

本文记录 FlClash 主仓库与 `core/Clash.Meta` 子模块的性能优化成果、验证结果、已拒绝方案和后续切入点。后续继续优化时，先读本文，再按当前工作区重新测量，不要直接复用旧数据当作当前结论。

- 最近核对日期：2026-11-09（答案传输层重构 + 只读代理不建表 + 名单按身份做键 + singledo/handler/溢出三批测试 + 选中代数做键）
- FlClash main：`c4264668`
- Clash.Meta main：`39ce557da`
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

本轮从 wrapper/子模块 benchmark 地图重新测量，找出并落地五十项优化；审计中确认过但**未**改动的位置见本节末尾。加上 2026-11-04 后的持续重构轮次与 2026-11-08 核心答案路径轮次，账本当前共 117 项。

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

| 代理解表键 span 缓存 | -（仅 wrapper） | `8bceffff` | `BenchmarkHandleGetProxies` paired n=7（对 `65ba30c9` 状态）：千节点 103.1µs ±8% → 97.1µs ±7%（**-5.83%**，p=0.017），千节点 urltest 98.7µs ±2% → 93.8µs ±2%（**-4.87%**，p=0.001），allocs/内存持平；纯组场景噪声内（键 span 数量少）。快照缓存重建时预编码每个 `"name":` 键 span（分隔符与转义一次完成，长度取自 `jsonutil.StringLen`），答案循环退化为对 span 与节点视图的 memcopy；收益随节点数增长，与测量记录中"名字追加 span 缓存上限 ~11µs"的预估相符；CGO 两种构建下 wrapper 全量测试 + vet 通过 |
| 延迟测试持久化合并 | -（仅 Dart） | `25267abf` | 走查定位：`AtomicFilePreferencesStore._update` 每次写入都全量 `json.encode` 整个 store + 原子落盘，而批量延迟测试的每个渲染节拍（300ms）都 `saveDelayMap`（1000 节点 delayMap ≈ 100KB+），测试期间 UI isolate 以 ~3.3 次/秒的频率做全 store 重编码+写盘。改为 2s 尾随写合并 + 批次结束 `_persistDelaysNow` 立即落盘（最终状态不丢）；`_CountingPreferencesStore` spy 钉住"窗口内两次 flush 仅一次写"与"批次结束立即写"，proxies_action_test 64 用例全绿 |

### 2026-11-05 持续重构轮次

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| TUIC v5 NATIVE 数据报直解路由 | `ff8fb529c` | `44f5e080` | `BenchmarkTUICNativeDatagramRoute` paired n=7：旧 pipe+BufferedConn 1637.0ns ±5% → 直接解析+有界 packet channel 216.9ns ±3%（**-86.75%**，p=0.001），0B/0 allocs 保持；IP 地址原地解码、payload 池化拷贝、支持同一 datagram 内多帧与分片；focused race、`go vet ./...`、core 全量 104 包、wrapper 测试/vet 全绿 |

### 2026-11-06 持续重构轮次

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 连接表轮询改增量 delta | -（仅 wrapper） | `92ba7634` | `connection.list` 新增 `resync` 参数：Core 用每连接 generation 缓存回答 Added/Removed/Count，答案用 `TrackerInfo.AppendJSON` 直写；500 行稳态 `BenchmarkConnectionsCurrent` 1.361ms ±1% / 348.2KiB / 1504 allocs → `BenchmarkGetConnectionsDelta/connections=500` 37.55µs ±2% / 228B / 3 allocs（时间 **-97.24%**，内存 **-99.94%**，分配 **-99.80%**）。Dart 侧 `connectionsProvider` 合并增量并透传 requestTraffic，请求页打开或超过 5s 才 resync，仪表盘只看数量时仍走 `connection.count`；协议、spill、关闭连接、请求流量、排序与停止轮询均有 focused 测试，131 个相关 Flutter 用例全绿；wrapper 测试/桌面与 Android vet、connection focused race 通过 |
| 连接 resync 单帧编码 | -（仅 wrapper） | `5485b826` | `ConnectionDelta` 实现 `frameWriter`，500 行 resync `BenchmarkGetConnectionsResyncFrame/connections=500` paired n=7：`json.Marshal(MethodResponse)` 708.4µs ±0% / 681.9KiB / 18 allocs → 直写 envelope 180.0µs ±3% / 369.3KiB / 12 allocs（时间 **-74.58%**，内存 **-45.84%**，分配 **-33.33%**，p=0.001）；新增字节级等价测试钉住 `frameFor` 与 `MethodResponse` 输出；wrapper 全量测试、桌面/Android vet、connection focused race 通过 |
| 流量轮询合并 IPC | -（仅 wrapper） | `12a69768` | 原 `traffic.current` + `traffic.total` 每轮两次 IPC；合并为 `traffic.stats` 一次返回速率/累计值，`TrafficStats.frameFor` 直写四个计数器，并删除无调用方的独立流量查询方法。`BenchmarkTrafficPoll` paired n=7：两次 dispatch 2.161µs ±1% / 450B / 14 allocs → 一次 dispatch 497.1ns ±1% / 177B / 3 allocs（时间 **-77.00%**，内存 **-60.67%**，分配 **-78.57%**，p=0.001）。Dart `TrafficStats` 一次更新速率和总量，Go/gomobile 与 Android Core 同步暴露合并接口；协议 fixture、controller、result、service transport、common action focused 测试 112 用例全绿；wrapper 全量测试、桌面/Android vet、traffic focused race 通过 |
| 内存统计单帧编码 | -（仅 wrapper） | `0a06c46c` | `MemoryStats` 实现 `frameWriter`，仪表盘 2s 轮询不再走 `MethodResponse` 反射，并顺带修正 `frameFor` 空 ID envelope 的通用契约。`BenchmarkMemoryStatsDispatch` paired n=7：977.6ns ±1% / 400B / 6 allocs → 205.6ns ±1% / 192B / 2 allocs（时间 **-78.97%**，内存 **-52.00%**，分配 **-66.67%**，p=0.001）；`frameFor` 与 `MethodResponse` 输出做字节级等价测试；wrapper 全量测试、桌面/Android vet、memory/connection focused race 通过 |
| 外部 Provider 列表单帧编码 | -（仅 wrapper） | `8a9681b5` | `externalProviderList` 实现 `frameWriter`，资源页 100 个规则 Provider 一次读取不再走 `MethodResponse` 反射；直写 name/type/vehicle/count/path/update-at/subscription-info，字符串走统一安全 JSON 编码，时间保持 RFC3339Nano。`BenchmarkProviderListDispatch` paired n=7：120.65µs ±2% / 54.91KiB / 118 allocs → 77.83µs ±1% / 57.34KiB / 113 allocs（时间 **-35.49%**，分配 **-4.24%**，p=0.001；内存 +4.42% 为一次预分配帧的权衡）；有/无 ID、Unicode 与转义路径做字节级等价测试；wrapper 全量测试、桌面/Android vet、provider focused race 通过 |
| Provider 列表值构造 | -（仅 wrapper） | `9817f0e8` | `toExternalProvider` 直接返回值，列表不再为每个 Provider 构造堆指针再解引用复制。同基准叠加 paired n=7：77.83µs ±1% / 57.34KiB / 113 allocs → 71.53µs ±1% / 46.40KiB / 13 allocs（时间 **-8.10%**，内存 **-19.08%**，分配 **-88.50%**，p=0.001）；单 Provider 详情仍按需返回指针；provider focused race、wrapper 全量测试、桌面/Android vet 通过 |
| 路由轮询零分配 scratch | -（仅 wrapper） | `a2c6a388` | 路由 5s 稳态轮询不再每轮新建 picks/provider-versions 两个 map 和 group-name slice，改用 route tracker 持有的 scratch map 并与正式 map 交换；group picks 和 provider 版本均在 scratch 中比对，未变化不发布。200 组 `BenchmarkRefreshRouteVersions` paired n=7：45.13µ ±2% / 21.85KiB / 15 allocs → 22.84µ ±3% / 0B / 0 allocs（时间 **-49.39%**，内存/分配 **-100%**，p=0.001）；新增 scratch 轮询追踪 group 改选的 focused 测试，route/rule focused race 通过，wrapper 全量测试、桌面/Android vet 通过 |
| Profile 文档缓存字节比对 | -（仅 wrapper） | `a2c80782` | CPU profile 显示 800 节点 cached merge 中 46.5% 时间在重复 SHA256、15.8% 在查找 `short-id` 标记；文档缓存从 digest 键改为缓存并整段比较 wire bytes，命中时不再哈希，同时保留精确变更判定。800 节点 `BenchmarkMergeProfileBaseCached` paired n=7：346.2µ ±2% / 200.6KiB / 60 allocs → 166.2µ ±1% / 200.5KiB / 58 allocs（时间 **-51.99%**，内存约持平，分配 **-3.33%**，p=0.001）；新增 unchanged/changed 文档缓存 focused 测试，profile focused race、wrapper 全量测试、桌面/Android vet 通过 |
| Profile short-id 分类缓存 | -（仅 wrapper） | `2cd80b6f` | 文档字节比对落地后 CPU 热路径仍包含每次缓存命中的 `bytes.Contains`；`readProfileDocument` 将 `short-id` 分类与文档同键缓存，命中时直接返回，超大文档解析失败也不再扫描。800 节点 `BenchmarkMergeProfileBaseCached` paired n=7：167.6µ ±2% / 200.5KiB / 58 allocs → 136.9µ ±2% / 200.5KiB / 58 allocs（时间 **-18.30%**，p=0.001；内存/分配保持）；新增含 `short-id`、unchanged 与 changed 文档的分类 focused 测试，profile focused race、wrapper `go test ./...`、桌面与 Android vet 通过 |
| Profile raw 摘要缓存 | -（仅 wrapper） | `287ec8e5` | CPU profile 显示 800 节点 cached base 中 `sha256.blockAVX2` 占 83.70%，`readCachedRawConfig` 占 59.24%；raw 缓存键从每次 SHA256+hex 改为整段字节比对，响应 digest 与解析同键缓存，`getProfileBase` 不再对同一文件二次哈希。新增 800 节点 `BenchmarkHandleGetProfileBaseCached` paired n=7：459.1µ ±3% / 100.70KiB / 40 allocs → 100.1µ ±3% / 99.52KiB / 14 allocs（时间 **-78.20%**，分配 **-65.00%**，p=0.001）；profile focused race、wrapper 全量测试、`Clash.Meta` 全量测试、桌面与 Android vet、Dart analyze、protocol/setup 96 个 Flutter 用例通过 |
| Profile 解析快照统一 | -（仅 wrapper） | `5be90cbb` | `getProfileBase` 与 `mergeProfileBase` 原先分别维护 raw 和 YAML document 缓存，冷读取同一 profile 会解密/解析两次；合并为一份 wire-byte 键控 `profileSnapshot`，一次解密、retag、解析并共享 raw config/document/digest，保留 4MiB 不缓存上限。新增 800 节点冷读取+合并 `BenchmarkProfileReadAndMerge` paired n=7（20x）：25.79ms ±3% / 5.903MiB / 121.77k allocs → 18.39ms ±7% / 3.395MiB / 73.03k allocs（时间 **-28.68%**，内存 **-42.49%**，分配 **-40.02%**，p=0.001）。稳态无回退：cached base 100.1µ → 94.91µ ±2%，cached merge 136.9µ → 106.7µ ±2% 且内存 200.5KiB → 104.5KiB；新增 retag/raw 解码、changed-byte、加密 wire digest focused 测试；profile focused race、wrapper 全量测试、`Clash.Meta` 全量测试、桌面与 Android vet、Dart analyze、protocol/setup 96 个 Flutter 用例通过 |
| Profile 快照指针发布 | -（仅 wrapper） | `cd6d0fff` | 统一 snapshot 后每次缓存命中仍新建指针并拷贝 digest/document/raw/retag 四个字段；cache 改为发布不可变 `*profileSnapshot`，命中直接返回旧指针，refresh 只整体替换指针，简化缓存字段并消除命中拷贝。800 节点 paired n=7：cached merge 103.7µ ±2% / 104.5KiB / 58 allocs → 101.9µ ±1% / 104.4KiB / 57 allocs（时间 **-1.77%**，p=0.001）；cached base 时间 91.62µ ±2% → 91.06µ ±1% 在噪声内（p=0.097），分配 14 → 13（**-7.14%**，p=0.004）；profile focused race、wrapper 全量测试、`Clash.Meta` 全量测试、桌面与 Android vet、Dart analyze 通过 |
| 连接计数直达 Size | `3dc11ca55` | `f8f8c965` | 仪表盘只看数量时 `connection.count` 仍通过 `Manager.Range` 遍历每个连接；Manager 暴露 `connections.Size()`，wrapper 直接读并发 map 的分段计数，不再逐行回调。`BenchmarkGetConnectionCount` paired n=7：100 行 875.4ns ±7% → 6.333ns ±1%（**-99.28%**），500 行 5.335µ ±2% / 3B → 6.301ns ±1% / 0B（时间 **-99.88%**，内存 **-100%**；两组 p=0.001）；新增 live tracker 计数 focused 测试，connection focused race、wrapper 全量测试、`Clash.Meta` 全量测试、桌面与 Android vet 通过 |
| 连接计数单帧编码 | -（仅 wrapper） | `032239b5` | Size 直达后 `connection.count` 仍返回裸 int，完整 dispatch 走 `MethodResponse` 反射；新增 `connectionCount.frameFor` 直写一个数字 envelope，并保持与 `MethodResponse` 字节等价。`BenchmarkConnectionCountDispatch` paired n=7：100 行 613.6ns ±1% / 176B / 5 allocs → 78.33ns ±3% / 48B / 1 alloc（时间 **-87.23%**，内存 **-72.73%**，分配 **-80.00%**）；500 行 642.2ns ±2% / 184B / 6 allocs → 100.4ns ±7% / 56B / 2 allocs（时间 **-84.37%**，内存 **-69.57%**，分配 **-66.67%**；两组 p=0.001）；新增有/无 ID 字节等价 focused 测试，connection focused race、wrapper 全量测试、桌面与 Android vet、Dart analyze、protocol/dashboard/connections 39 个 Flutter 用例通过 |
| 流量总量单轮 stripe | `4289e66a3` | `794a7101` | `TotalTraffic` 原先调用两个 helper，各自完整扫描 32 个 counter stripe；合并为 `totalPair` 一轮成对读取 upload/download，proxy 与 direct 由同一 helper 分支选择，并删除仅旧路径使用的独立 proxy helper。`BenchmarkTrafficPoll` paired n=7：511.5ns ±2% / 177B / 3 allocs → 487.4ns ±1% / 177B / 3 allocs（时间 **-4.71%**，p=0.001）；同轮 `BenchmarkMemoryStatsDispatch` 215.8ns ±3% → 214.3ns ±1% 无显著变化（p=0.068）；traffic focused race、wrapper 全量测试、`Clash.Meta` 全量测试、桌面与 Android vet 通过 |
| Provider 轻量键排序 | -（仅 wrapper） | `706c8fe7` | 资源页读取 100 个 Provider 时先物化整个 view slice，再排序约 150B 的 `ExternalProvider` 值；改为排序 map key，再按名称构建 view，减少排序阶段的值移动。`BenchmarkProviderListDispatch` paired n=7：73.99µ ±5% / 46.40KiB / 13 allocs → 60.29µ ±13% / 48.15KiB / 14 allocs（时间 **-18.52%**，p=0.001；新增一个 key slice 使内存 +3.77%、分配 +7.69%，为时间收益接受）；provider focused race、wrapper 全量测试、桌面与 Android vet 通过 |
| Provider 免合并 map | -（仅 wrapper） | `3db06b91` | 列表构建原先先分配合并 map，再分配 names slice 和 view slice；改为直接物化两类 snapshot 的候选 entry，一轮按 `(name, rule-first)` 排序后相邻去重，rule 优先语义与 lookup 保持一致。100 Provider `BenchmarkProviderListDispatch` paired n=7：60.49µ ±2% / 48.15KiB / 14 allocs → 58.04µ ±3% / 41.25KiB / 3 allocs（时间 **-4.05%**，内存 **-14.33%**，分配 **-78.57%**，p=0.001）；兼容 inline 过滤和 rule/proxy 同名优先 focused 测试已更新，provider focused race、wrapper 全量测试、桌面与 Android vet 通过 |
| Provider 直接 entry 编码 | -（仅 wrapper） | `103b4ba4` | 删除 `externalProviderList` 中间 view slice；`externalProviderEntries` 返回已按名称排序、rule 优先去重的 `externalProviderEntryList`，frame 直接转换每个 provider 并复用 `appendExternalProviderJSON`。100 Provider `BenchmarkProviderListDispatch` paired n=7：57.74µ ±2% / 41.25KiB / 3 allocs → 53.45µ ±1% / 30.62KiB / 2 allocs（时间 **-7.44%**，内存 **-25.76%**，分配 **-33.33%**，p=0.001）；新增 view JSON、真实 RuleProvider envelope 和空列表 focused 测试，provider focused race、wrapper 全量测试、桌面与 Android vet 通过 |
| Route 组投影缓存 | -（仅 wrapper） | `1ae9f60d` | 路由稳态轮询每次重复读取配置名单、查 tunnel map、判断组类型并断言 `pickableGroup`；改为按 `(tunnel snapshot, name-list 内容)` 缓存解析后的 `routeGroup`，每轮只读各组的 `Now()` 和 provider version。200 组 `BenchmarkRefreshRouteVersions` paired n=7：23.72µ ±2% / 0B / 0 allocs → 13.46µ ±4% / 0B / 0 allocs（时间 **-43.26%**，p=0.001）；新增配置名单变更和 fallback 投影 focused 测试，route focused race、wrapper 全量测试、桌面与 Android vet 通过 |
| Proxy 快照精确容量 | -（仅 wrapper） | `8c38a98c` | `answerSize` 原先按节点名长度 +32、每组 +320 粗估，大表 frame 多次 `growslice`；snapshot 构建时已持有静态 keySpan/nodeView，现在直接累计它们的实际长度、all 列表 JSON 长度和每组 768B 缓存文档 scaffold。200 组 +1000 节点 paired n=7：urltest 138.7µ ±2% / 276.8KiB / 6 allocs → 121.3µ ±5% / 228.6KiB / 4 allocs（时间 **-12.52%**，内存 **-17.40%**，分配 **-33.33%**，p=0.001）；selector 121.5µ ±16% → 112.8µ ±39% 无显著时间变化（p=0.073），但内存 **-17.42%**、分配 `4 → 3`（p=0.001）；proxy focused race、wrapper 全量测试、桌面与 Android vet 通过 |
| Proxy 组名投影缓存 | -（仅 wrapper） | `0c3069a3` | 大表稳态读取每次仍调用 `proxyGroupNames` 遍历配置名单并分配投影；改为按 `(tunnel snapshot, name-list 内容)` 缓存不可变投影，名单克隆入键避免同底层数组原地修改误命中。200 组 +1000 节点 paired n=7：selector 110.4µ ±12% / 227.5KiB / 3 allocs → 91.55µ ±21% / 224.1KiB / 2 allocs（时间 **-17.09%**，p=0.026；内存 **-1.49%**、分配 **-33.33%**，p=0.001）；urltest 125.0µ ±8% / 228.7KiB / 5 allocs → 110.5µ ±2% / 225.1KiB / 3 allocs（时间 **-11.62%**，内存 **-1.54%**，分配 **-40.00%**，p=0.001）；新增名单变更/顺序变更投影 focused 测试，proxy focused race、wrapper 全量测试、桌面与 Android vet 通过 |

### 2026-11-06 发布修复轮次

| 优化 | 子模块提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| Core 高频 feed 帧内合并 | - | `af90abdd` | logs/request/DNS/traffic 在 `renderThrottleDuration` 内合并为一次 provider 提交；request/DNS 计数按批累加，后台生命周期在事件入口过滤。`core_manager` 20 个用例全绿 |
| 未变化连接保留实例身份 | - | `af90abdd` | `TrackerSpeedRanker` 以 id 缓存上一轮输出，速度未变时回传同一 `TrackerInfo`，避免下游把排序结果当作新连接；focused 测试钉住实例身份 |
| 流量采样窗口不跳写 | - | `af90abdd` | 删除相同速率采样去重，`FixedList` 每次入队，旧峰值随窗口滚动退出；desktop peak focused 测试通过 |
| 超时隐藏只认真实组选择 | - | `af90abdd` | 非 computed group 不再把缺省第一项伪装成选择；全组超时时保留整组，URLTest 仍保留 `now` 指定的核心选择；focused 测试通过 |
| Linux 启动跳过设备信息探测 | - | `af90abdd` | `System.init` 在 Linux 直接返回，不再调用桌面设备信息路径；`system` focused 测试通过 |
| Glyph path 缓存 | `0abe1b9` | `af90abdd` | `GlyphShape` 缓存 `Path`，同形状重复绘制不再重建路径；`prism_ui` 355 个测试全绿 |
| 侧栏标签动画减少 Text 重建 | `0abe1b9` | `af90abdd` | 行 `Text` 保存在 State 中，动画帧只更新 `Opacity`，标签内容/样式不变时不重建；sidebar 15 个用例全绿 |

### 2026-11-06 延迟排序精简

| 优化 | 子模块提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 延迟排序状态与触发收敛 | - | 本轮提交 | 恢复超时/其他失败/未测试的旧优先级，并在同延迟时把嵌套分组排在叶子前；删除无调用的 debounce 入口和已无使用方的 `DelayState`。同时移除延迟测试完成后的重复 `sortNum -> updateGroups` 全量 Core 拉取，完成批次只做一次本地排序。`computeSort`、`sortGroupsTask`、`app_manager`、`proxies_action` 118 个测试与 Dart analyze 全绿 |

### 2026-11-07 持续重构轮次

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| DNS 服务器引用无 `%` 免解码 + fragment 免 split 列表 | -（仅 wrapper） | 本轮提交 | `_decodedOrSelf` 先查 `contains('%')`，无百分号直接返回；fragment 解码后按 code unit 扫描 `&`，不再为常见单段 fragment 分配 `split` 列表。`test/models/references_benchmark_test.dart` JIT n=11（100k 个 `ts://...#dialer`）：基线均值 52.98ms/中位 53.37ms → 均值 43.64ms/中位 42.84ms（均值 **-17.65%**，中位 **-19.73%**，单次调用 0.530µs → 0.428µs 量级）；`test/models/references_test.dart`、`test/manager/core_manager_test.dart`、`dart analyze --fatal-infos` 全绿 |
| Rule payloadError 结果缓存 | -（仅 wrapper） | 本轮提交 | `Rule` 不可变，`payloadError` 结果按对象缓存；用 `Expando<Object>` + `_noRulePayloadError` sentinel 区分“合法未报错”和“未缓存”，避免 `Expando<RulePayloadError?>` 的 null 语义。`test/models/rule_benchmark_test.dart` JIT n=7（100k 次合法 `DST_PORT`）：均值 34.19ms / 中位 34.16ms → 均值 6.28ms / 中位 6.27ms（**-81.64%**），单次调用 0.342µs → 0.063µs；`test/models/rule_test.dart`、`test/features/custom_rule_form_test.dart`、`test/features/rule_dialog_test.dart`、`test/providers/custom_state_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| TrackerSpeedRanker 索引缓冲改 32 位并复用 positions map | -（仅 wrapper） | 本轮提交 | rank/order/bucket/cursor/head/tail/next 索引全部落在 int32，`traffic` 保留 Int64 以容纳累计字节；`_positions` 从每次新建 map 改为复用 clear，empty 分支同步清理。`test/features/tracker_speed_ranker_benchmark_test.dart` JIT n=7（10k 连接 ×20 snapshot）：均值 9.23ms → 8.29ms（**-10.16%**），中位 9.43ms → 8.32ms（**-11.80%**）；`test/features/tracker_speed_ranker_test.dart`、`test/views/connections_test.dart`、`test/views/dashboard/connections_table_test.dart`、`test/widgets/connection_item_test.dart`、`test/widgets/connections_view_test.dart`、`test/views/dashboard/connection_stats_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| DNS 查询搜索文本按对象缓存 | -（仅 wrapper） | 本轮提交 | `DnsQueriesState.list` 给 `whereMatches` 传入 `Expando<String>`，和 `TrackerInfosState` 一致；`DnsQuery` 不可变，query state 每次键入都换对象，但 DNS 查询对象保持在缓存中命中，不再为每次过滤重建 `searchFields` 并 join/lower。新增 `test/models/dns_query_search_benchmark_test.dart`：JIT n=7（10k DNS 查询 ×50 次过滤）：均值 312.62ms → 73.41ms（**-76.51%**），中位 310.15ms → 73.18ms（**-76.41%**）；`test/views/dns_queries_view_test.dart`、`test/views/dns_view_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| DNS 查询标签字段单列表产出 | -（仅 wrapper） | 本轮提交 | `_appendTags` 直接向目标列表追加 type/initiator/cache/rcode；`tags` 与 `searchFields` 共用它，`searchFields` 不再展开 `tags` 列表，首轮过滤每行只建一个结果列表，`resultFilters` 仍保留给 facet。`test/models/dns_query_cold_search_benchmark_test.dart`（首次见到的查询，30×3k）JIT n=7：基线均值 139.71ms/中位 136.54ms → 均值 129.45ms/中位 128.93ms（均值 **-7.34%**，中位 **-5.57%**）；`test/views/dns_queries_view_test.dart`、`test/views/dns_view_test.dart`、`test/common/filter_test.dart`、`test/models/dns_override_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| 延迟排序预打包优先级/分组位 | -（仅 wrapper） | 本轮提交 | `computeSort` 的延迟比较不再每次调用 `_delaySortPriority`，预先把「低 2 位优先级 + 分组位」打进一个 `Uint8List`；排序/有序检查只做位读取。新增 `test/common/compute_sort_delay_benchmark_test.dart`：JIT n=7（1000 节点 ×100 次排序）均值 45.81ms/中位 45.37ms → 均值 44.29ms/中位 43.93ms（均值 **-3.31%**，中位 **-3.18%**）；`test/common/compute_test.dart` 37 个用例与 `dart analyze --fatal-infos` 全绿 |
| 无调用延迟失效入口清理 | -（仅 wrapper） | 本轮提交 | 删除无调用方的 `ProxiesAction.invalidateDelayTests()`、随之无调用方的 `Preferences.clearDelayMap()` 与只覆盖该方法的测试；延迟持久化仍由保存链路和启动恢复走。`test/common/preferences_test.dart`、`test/providers/proxies_action_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| Group 成员名单缓存 | -（仅 wrapper） | 本轮提交 | `_isMember` 不再每次 `all.any` 线性扫成员；`Group` 不变，成员名按对象缓存为 `Set<String>`，空组仍直接通过。新增 `test/models/group_selected_member_benchmark_test.dart`：JIT n=7（1000 成员 ×10000 次选中判定）均值 63.75ms/中位 63.83ms → 均值 13.05ms/中位 12.88ms（均值 **-79.52%**，中位 **-79.82%**）；`test/common/compute_test.dart`、`test/providers/proxies_action_test.dart`、`test/views/proxies_list_test.dart`、`test/widgets/proxies_list_test.dart`、`test/widgets/proxies_tab_test.dart`、`test/views/dashboard/proxy_groups_card_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| `showFull` 固定字段拼接 + 本地时间快路径 | -（仅 wrapper） | 本轮提交 | `showFull` 不再 `toLocal().toString().substring(0,19)`，改为对本地/UTC 时间手工按字段 `padLeft` 拼接；已是本地时间的日志不再触发 `toLocal()` 包装。新增 `test/common/datetime_show_full_benchmark_test.dart`（UTC 1,000,000 次）与 `test/core/event_dispatch_benchmark_test.dart`（本地日志事件）：JIT n=7 隔离基准均值 4.41ms/中位 4.40ms → 4.25ms/4.26ms（均值 **-3.67%**，中位 **-3.32%**），事件 log dispatch 均值 5.187µs/中位 5.181µs → 5.023µs/5.014µs（均值 **-3.16%**，中位 **-3.22%**）；`test/common/datetime_test.dart`、`test/core/event_test.dart`、`test/widgets/connection_item_test.dart`、`test/views/requests_test.dart`、`test/views/dns_queries_view_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| `show`/`showTime` 固定字段拼接 + 本地时间快路径 | -（仅 wrapper） | 本轮提交 | `show`/`showTime` 不再 `toLocal().toString().substring(...)`，改为手工拼日期和 ` HH:mm:ss`；已是本地时间不再触发 `toLocal()`。新增 `test/common/datetime_slices_benchmark_test.dart`：JIT n=7（local+UTC 的 show/showTime 共 4,000,000 次）均值 9.43ms/中位 9.38ms → 均值 8.55ms/中位 8.56ms（均值 **-9.29%**，中位 **-8.72%**）；`test/common/datetime_test.dart`、`test/widgets/connection_item_test.dart`、`test/views/requests_test.dart`、`test/views/dns_queries_view_test.dart`、`test/views/dashboard/service_status_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| 托盘超大组选中项缓存索引 | -（仅 wrapper） | 本轮提交 | `visibleTrayProxies` 不再每组线性扫全部节点找选中；超大组按 `Group` 缓存 name->Proxy 索引（后出现同名覆盖，保持原逻辑），只取前 `maxTrayProxiesPerGroup`（有选中则给选中留位）。`test/common/visible_tray_benchmark_test.dart` JIT n=7（5000 节点 ×20000 次）：perCallUs 均值 54.14 / 中位 54 → 1 / 1（该基准按整数 µs 输出，降幅按该分辨率约 **-98%**；实际已远低于 1µs 量级）；`test/common/compute_test.dart`、`test/common/tray_test.dart`、`test/common/tray_lifecycle_test.dart`、`test/manager/tray_manager_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| 超大组选中节点解析改成员名缓存 | -（仅 wrapper） | 本轮提交 | `Group` 新增 `containsMemberName`，`selectedProxyName` 不再为了判断 selected/live/stored 各自扫全组；组成员名沿用已有 `Expando<Set<String>>`（空组仍 false，`_isMember` 的空组语义不变）。新增 `test/providers/selected_proxy_name_benchmark_test.dart`：JIT n=7（2000 节点 ×2000 次 refresh）总耗时均值 281.50ms/中位 283.28ms → 209.11ms/208.83ms（均值 **-25.72%**，中位 **-26.28%**）；`test/providers/state_derived_test.dart`、`test/providers/proxies_action_test.dart`、`test/widgets/proxies_list_test.dart`、`test/widgets/proxies_tab_test.dart`、`test/views/proxies_list_test.dart`、`test/views/dashboard/proxy_groups_card_test.dart`、`test/common/compute_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| keyed 列表批量出队索引前移 | -（仅 wrapper） | 本轮提交 | `FixedList._dropIndexedHead` 不再对该 map 同时 `removeWhere` + `updateAll` 两个回调遍历，改为一次 `entries` 遍历：收集越界 key、原地前移剩余 index，最后删除越界 key。`test/common/fixed_append_benchmark_test.dart` 新增 keyed 场景（1600×120，20000 批）：JIT n=7 perBatchUs 均值 12.86/中位 13 → 均值 11.29/中位 11（均值 **-12.21%**，中位 **-15.38%**）；`test/common/fixed_test.dart`、`test/providers/app_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| `Rule.rawValue` 按对象缓存 raw 字符串 | -（仅 wrapper） | 本轮提交 | `Rule` 不可变，`rawValue` 用 `Expando<String>` 按对象缓存；仍拆出 `_rawValue` 保留原序列化逻辑，`searchFields`/编码/解码都复用同一字符串。新增 `test/models/rule_raw_value_benchmark_test.dart`：JIT n=7（100000 次 `DOMAIN-SUFFIX,example.com,DIRECT,no-resolve`）均值 29.34ms/中位 29.32ms → 4.00ms/3.94ms（均值 **-86.37%**，中位 **-86.55%**）；`test/models/rule_test.dart`、`test/features/custom_rule_form_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| 排序无变化时免建组表 | -（仅 wrapper） | 本轮提交 | `_sortGroups` 不再先整表复制再全表比较；逐个组计算下一个组，只有真正变化时才懒拷 `List.of(groups)` 并覆盖该下标，无变化直接返回原表。删除只服务旧实现的 `_sameGroups`。`test/common/compute_sort_delay_benchmark_test.dart` 新增已有序场景：JIT n=7（100 组 ×1000 次）均值 34.32ms/中位 33.95ms → 31.65ms/31.49ms（均值 **-7.80%**，中位 **-7.25%**）；`test/common/compute_test.dart` 现有“无变化保持组实例身份/重复排序保持 identity”全绿，`test/providers/proxies_action_test.dart` 与 `dart analyze --fatal-infos` 通过 |
| 已有序表格免建 order/结果列表 | -（仅 wrapper） | 本轮提交 | `RecordSorter.sort` 在生成 `keys` 后先按方向判断当前显示顺序是否已有序；已有序直接把原 items 作为排序结果并写入缓存，不再生成 `order` 和 `sorted` 两个列表，`reverse` 场景同样成立。新增 `test/widgets/record_sorter_benchmark_test.dart` 与恢复 `test/widgets/record_table_test.dart` 行为测试：JIT n=7（10000 行 ×1000 次已有序）均值 1007.75ms/中位 1006.95ms → 185.98ms/185.36ms（均值 **-81.54%**，中位 **-81.59%**）；`test/widgets/record_table_test.dart`、`test/views/dashboard/connection_stats_test.dart`、`test/widgets/connections_view_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| 反向表格排序直接排源列表 | -（仅 wrapper） | 本轮提交 | `reverse` 时不再生成 `items.reversed` 显示列表，再排序后二次 `reversed` 回源列表；改为对 `items` 直接排序并把方向取反，已有序检查也改成从尾部向前比较。新增反向乱序基准：JIT n=7（10000 行 ×1000 次 reverse 乱序）均值 2676.83ms/中位 2689.97ms → 2340.38ms/2327.76ms（均值 **-12.57%**，中位 **-13.47%**）；`test/widgets/record_table_test.dart` 新增“反向未有序时源列表反向排序”“升降序覆盖”，`test/views/dashboard/connection_stats_test.dart`、`test/widgets/connections_view_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| 隐藏超时节点选中判断改缓存 | -（仅 wrapper） | 本轮提交 | `computeHideTimeout` 的 `_coreSelectedName` 不再每条组两次 `group.all.any` 线性扫成员；改用已有 `Group.containsMemberName` 成员名缓存。新增 `test/common/compute_hide_timeout_benchmark_test.dart`：JIT n=7（2000 节点健康组 ×100 次）均值 59.02ms/中位 60.00ms → 53.24ms/53.23ms（均值 **-9.79%**，中位 **-11.28%**）；`test/common/compute_test.dart`、`test/providers/proxies_action_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| 隐藏超时节点无隐藏时免建可见列表/结果组表 | -（仅 wrapper） | 本轮提交 | `computeHideTimeout` 不再先用 `where().toList()` 建可见列表再比较；只在第一次遇到被隐藏节点时才懒拷前面的可见节点，全可见直接返回原组。结果组表同样懒拷，仅实际变化的组才拷贝 `List.of(groups)`。同基准 JIT n=7：均值 53.24ms/中位 53.23ms → 47.06ms/46.86ms（均值 **-11.61%**，中位 **-11.98%**）；`test/common/compute_test.dart` 新增“一个组隐藏节点时其他组保持实例身份”，38 个用例全绿，`test/providers/proxies_action_test.dart` 与 `dart analyze --fatal-infos` 通过。
| 无分隔符字符串 split 惰性分配 | -（仅 wrapper） | 本轮提交 | `StringExtension.splitByMultipleSeparators` 不再先分配空 `parts` 列表；仅在遇到第一个分隔符时才创建，单值字符串直接返回自身。`test/common/string_benchmark_test.dart` 新增单值场景：JIT n=7（100000 个 server）均值 16.373ms/中位 15.929ms → 13.600ms/13.608ms（均值 **-16.94%**，中位 **-14.57%**，单次调用 0.164µs → 0.136µs）；`test/common/string_test.dart` 既有 40 个 split/getBase64/url 用例全绿，`test/models/references_test.dart` 与 `dart analyze --fatal-infos` 通过 |
| SVG 类型判断免 URI 解析/整串 lowercase | -（仅 wrapper） | 本轮提交 | `StringExtension.isSvg` 对非 data URI 不再 `Uri.tryParse(path).toLowerCase().endsWith`；改为按 query/fragment 切出路径尾部，直接定位最后一个 `.` 并按 codeUnit 大小写不敏感比较 `svg`。`test/common/string_benchmark_test.dart` 新增 SVG URL 场景：JIT n=7（100000 个带 `?v=` 的 CDN 图标 URL）均值 41.875ms/中位 42.172ms → 9.582ms/9.692ms（均值 **-77.12%**，中位 **-77.02%**，单次调用 0.419µs → 0.096µs）；`test/common/string_test.dart`、`test/views/icon_picker_view_test.dart`、`test/widgets/target_icon_test.dart`、`test/providers/icon_sets_action_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| 图标名匹配不再拷贝名字列表、压缩名按对象缓存 | -（仅 wrapper） | 本轮提交 | `matchIconNames` 改收 `List<IconSetIcon>`，图标选择器不再为每次键入把整个图标表拷成 `List<String>`；`IconSetIcon.compactName` 按对象缓存 `fileStem` 的压缩结果，主线程重复匹配时不再对每张图重复 `toLowerCase + replaceAll`；isolate 输入也直接发图标对象。新增 `test/models/icon_name_match_benchmark_test.dart`：JIT n=7（5000 图标 ×100 次匹配+排序）均值 284.00ms/中位 283.59ms → 54.75ms/54.75ms（均值 **-80.72%**，中位 **-80.69%**，单次匹配排序 2.84ms → 0.547ms）；新增 `test/models/icon_name_match_test.dart` 覆盖评分、忽略无拉丁名字符、按 URL 去重排序，`test/views/icon_picker_view_test.dart`、`test/widgets/target_icon_test.dart`、`test/providers/icon_sets_action_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| 图标名压缩 codeUnit 直筛 | -（仅 wrapper） | 本轮提交 | `_compactIconName` 不再 `toLowerCase().replaceAll(RegExp)`；先扫描 codeUnit 记录是否有大写/非字母数字，无字符直接返回空串、全小写字母数字直接返回原串，否则用 `StringBuffer` 只追加小写 ASCII 字母和数字。新增 `test/models/icon_name_cold_match_benchmark_test.dart`：JIT n=7（5000 个新对象 ×100 次冷匹配）均值 492.74ms/中位 479.50ms → 401.28ms/393.45ms（均值 **-18.56%**，中位 **-17.96%**，单次 4.927ms → 4.013ms）；`test/models/icon_name_match_test.dart`、`test/views/icon_picker_view_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| 延迟/隐藏超时：`delayMap[testUrl]` 提到组外 | -（仅 wrapper） | 本轮提交 | `computeHideTimeout` 与 `computeSort.sortOfDelay` 都在**每个代理**的内层循环里查 `delayMap[testUrl]`，而该 url 在整个组内不变。提到组层级后每节点少一次 map 查询。交替配对 n=3（同时把两个 benchmark 的 warm-up 从 5 次提到 50 次，旧 warm-up 下测量不稳、曾出现 before 34ms/15ms 这类抖动）：`computeHideTimeout` 2000 节点 12473µs → 9172µs（**-26.5%**），`computeSort` 1000 节点 18509µs → 17579µs（**-5.0%**）。注意：此前几轮这两个 benchmark 的**绝对数**偏大（warm-up 不足），相对结论不受影响 |
| 延迟测试目标解析：叶子直取 | -（仅 wrapper） | 本轮提交 | `_resolveDelayTestTargets` 与 `computeSort`/`computeHideTimeout` 同一处病灶：对每个待测代理都 `computeRealSelectedProxyState`，而叶子解析恒等于自身。新增 `test/common/real_selected_state_benchmark_test.dart`（n=5）：解析形状 113.3µs/1000 叶子（113ns/个）→ 只查 `groupsByName` 的叶子路径 28.15µs/1000（28ns/个），**-75.1%**；一次 2000 节点全量测速约少 225µs UI 线程工作。`test/providers/proxies_action_test.dart` 新增用例：外层组里嵌一个组时，测外层组会按**嵌套组自己的** testUrl 探测它的选中节点（而不是把组名当叶子、用默认 URL 探测），45 个用例全绿 |
| 延迟排序：叶子节点不再做无效的选中态解析 | -（仅 wrapper） | 本轮提交 | 与「隐藏超时节点」同一处病灶：`computeSort` 的 `sortOfDelay` 对每个代理都 `realStateFor(name)`，而对非组代理该解析恒等于自身（`testUrl` 为 null、`group` 为 false）。改为先查 `groupsByName[name]`，叶子直接 `delayMap[testUrl][name] ?? 0` 且不置组标志；只有真正的组才走解析链。<br>**测量必须逐用例隔离**：合并同一进程跑两个用例时，前一个重用例的 GC 让后一个用例假性 +2.4%（与上一轮假 +12% 同一陷阱）；隔离交替 n=3：1000 节点延迟排序 42378µs → 28001µs（**-33.9%**），100 组已有序小场景 34030µs → 23983µs（**-29.5%**）。`test/common/compute_test.dart` 新增嵌套组用例：内层组按其自身 testUrl 的延迟参与排序（用错 URL 会排错序，能区分），40 个用例全绿 |
| 隐藏超时节点：叶子节点不再做无效的选中态解析 | -（仅 wrapper） | 本轮提交 | `computeHideTimeout` 对每个**非组**代理都调 `computeRealSelectedProxyState`，而函数开头已经用 `groupsByName.containsKey(proxy.name)` 提前放行了组；对叶子节点该解析恒等于自身（`testUrl` 为 null、`proxyName` 不变），等于每行白建一个 `SelectedProxyState` + 两次 map 操作。删掉这段后叶子节点直接查 `proxyTypes[proxy.name]` 与 `delayMap[groupTestUrl][proxy.name]`；顺带把 `takeFirstValid` 的双重 `trim` 改成一次、把每行的 fallback 列表提到组外。`test/common/compute_hide_timeout_benchmark_test.dart`：2000 节点从 50290/48769/48465/49684/48767µs（均值 49195µs/100 次）→ 17183/14833/14356/14748/14850µs（均值 15194µs/100 次），即 **490µs → 152µs/次（-69.0%）**；`test/common/compute_test.dart` 新增嵌套组用例钉住语义（外层按默认测试 URL 隐藏、内层按自身 testUrl 隐藏、组本身保留），39 个用例全绿 |
| 筛选菜单选项：有界选取替代全量排序 | -（仅 wrapper） | 本轮提交 | `optionsOf` 原先把 facet 的**全部**去重值按出现次数整表 `sorted` 再取前 12，而请求表的 rule facet 在真实流量下去重值可达数百个。改为有界插入选取（只维护 12 个槽位的有序表）；去重值不超过 12 时直接返回全部——选项随后仍按 rank/名称排序，按次数排序本是白做。`test/models/facet_options_benchmark_test.dart` 新增 "全去重" 场景，交替配对 n=3（每轮新进程、单用例隔离）：rule 全去重 64.52µs → 52.57µs（**-18.5%**），3 个 offered facet 53.12µs → 49.53µs（**-6.8%**）。测量教训：同一进程里先跑重用例会把 GC 带给后一个用例（曾量出假 +12% 回退），这类配对必须逐用例隔离 |
| 筛选分词：单值 facet 计数不再每行建列表 | -（仅 wrapper） | 本轮提交 | `RecordFacet` 原来只有一个 `valuesOf`（返回 `Iterable`），单值 facet 也得`[value]` 每行建一个列表。拆成 `valuesOf`（多值）与 `valueOf`（单值）两种构造，计数走 `countInto`、过滤走 `matches`，调用点不变；`trackerInfoFacets` 的 network/rule/mitm/app、`logFacets` 的 level、`dnsQueryFacets` 的 type 都是单值。新增 `test/models/facet_options_benchmark_test.dart`：JIT n=7（500 行 ×3 个 offered facet 的 optionsOf）均值 72.75µs/中位 72.60µs → 52.68µs/52.91µs（**-27.6%** / **-27.1%**，每次 offer 省约 20µs；请求页 1~3 次/秒）。`test/models/record_filter_test.dart` 新增语义用例：单值构造与多值构造在 optionsOf/whereFilters 上结果一致、多值 facet 逐个计数、空值照旧剔除 |
| 表格行文字样式与形状按表解析一次 | -（仅 wrapper） | 本轮提交 | `RecordTableRow.build` 原来每一行都 `AppTextStyle.subheadline.of(context)` + `copyWith` + `AppShape.all(AppCorner.fit(rowHeight))`，实测合计 1.78µs/行（20 行的表格每次刷新约 36µs）。`RecordTable` 新增 `rowTextStyle`/`rowShape`，在 `_tableOf`（已按 width/columnWidths/rowHeight/locale/theme memo）里解析一次，行只读；仪表盘卡片表格同样把 `AppTextStyle.footnote.of(context)` 提到行构建之外。新增 `test/widgets/row_style_benchmark_test.dart`：JIT n=5（每行文字+形状解析）1.686~1.843µs（均值 1.781µs、中位 1.781µs）→ 0.0009µs；`test/widgets/record_table_test.dart` 新增用例：只换数据、宽度与主题不变时 `RecordTable` 是同一实例（文字与形状不重算）；focused 7 个文件共 52 个用例与 `dart analyze --fatal-infos` 全绿 |
| 表格行菜单按行内容缓存 | -（仅 wrapper） | 本轮提交 | `trackerInfoMenuItems` 原来给每个可见行每次重建都构造一次菜单（实测 979ns/行），但表格行重建来自计数器变化，菜单并不读它。新增 `CachedMenu`（`lib/widgets/cached_menu.dart`）：`ContextMenuRegion` 要的菜单列表由它按自己声明的 inputs 持有，只在 `didChangeDependencies`（本地化变化）或 inputs 变化时重建，child 每次照常重建、行为与之前逐像素一致。`TrackerInfoTableRow` 传 `[trackerInfo.metadata, onClose]`，`copyWith` 保留同一 metadata 实例、`_closeConnection` tear-off 相等，所以 counter-only 更新命中缓存。新增 `test/widgets/cached_menu_benchmark_test.dart`：JIT n=7（500 行 ×2000 次）rebuild 均值 489.3µs/中位 484.45µs → held 均值 7.89µs/中位 7.98µs（**-98.4%**，单行 979ns → 16ns）；`test/widgets/cached_menu_test.dart` 用 identical 钉住「重建后是同一个菜单实例、inputs 变化才换菜单」；`test/views/connections_test.dart` 既有「从行菜单关闭连接」用例覆盖真实集成路径，focused 6 个文件共 57 个用例与 `dart analyze --fatal-infos` 全绿。列表态行本就被 `MemoBuilder` 的描述性 inputs 挡住，无需此包装 |
| UTC 时间戳的本地读取与渲染文本按对象缓存 | -（仅 wrapper） | 本轮提交 | Core 的时间戳全是 UTC（`DateTime.parse` 解析带 Z 的 ISO 串），请求表/DNS 表的 time 列每个可见行每次重建都要重新 `toLocal()` + 拼串。`localMoment` 缓存 UTC 时刻的本地读数，`show`/`showFull`/`showTime` 一并缓存本地时刻渲染出的文本（本地时刻仍直接渲染，日志那条一次性路径不受影响）。新增 `test/common/datetime_local_moment_benchmark_test.dart`：JIT n=7（500 行 ×2000 次 `showTime`）均值 2208.7µs/中位 2213.25µs → 18.0µs/18.0µs（**-99.2%**，单行 4.42µs → 0.036µs）；`test/common/datetime_test.dart` 新增 5 个用例（UTC 渲染等于其本地读数渲染、本地时刻原样返回、重复读取返回同一实例、相邻一秒不是同一文本），focused 7 个文件共 75 个用例与 `dart analyze --fatal-infos` 全绿 |
| 卡片表格列集合按宽度+locale 复用 | -（仅 wrapper） | 本轮提交 | `recordTableColumns` 抽出（columns/layouts/widths 一次算完，`RecordTableFrame._tableOf` 与仪表盘卡片表格共用，消掉两处重复的同一段逻辑），三个列构建函数改收 `AppLocalizations` 而非 `BuildContext`，卡片表格按 (availableWidth, columnWidths, locale) 缓存列集合，重建只付一次元组比较。新增 `test/widgets/record_table_columns_benchmark_test.dart`：JIT n=7（8 列，宽 1000，20000 次）rebuild 均值 5.58µs/中位 5.60µs → memo 命中 0.026µs/0.026µs（**-99.5%**，每次重建省约 5.6µs）；`test/widgets/record_table_test.dart` 新增 2 个 `recordTableColumns` 用例（flex 分配、拖拽宽度生效），`test/views/dashboard/connections_table_test.dart` 抽出 `pumpLiveCard` 助手把三段重复的 mock 设置收敛，新增「列标签跟随 locale」用例（en→zh：Download→下载，行与 TCP/UDP 计数不变）；`test/views/connections_test.dart`、`test/views/requests_test.dart`、`test/features/tracker_info_list_test.dart`、`test/views/dashboard/connection_stats_test.dart`、`test/widgets/connections_view_test.dart`、`test/views/dashboard/feed_sheet_test.dart` 共 64 个用例与 `dart analyze --fatal-infos` 全绿 |
| TrackerInfo 行文本按对象缓存 | -（仅 wrapper） | 本轮提交 | `ruleText`/`progressText` 改为按对象 `Expando<String>` 缓存（`TrackerInfo` 不可变，字段固定）：分组表每次刷新对全部行调 `keyOf`、表格单元格与搜索都要重建这两个字符串。新增 `test/models/tracker_info_text_benchmark_test.dart`：JIT n=7（500 行 ×2000 次）`ruleText` 均值 35.98µs/中位 35.87µs → 12.54µs/12.34µs（**-65.2%**），`progressText` 均值 47.36µs/中位 47.32µs → 14.82µs/14.81µs（**-68.7%**）；`test/models/common_test.dart` 新增“不同对象各自缓存”用例，`test/features/tracker_info_list_test.dart`、`test/models/record_filter_test.dart`、`test/features/filter_test.dart`、`test/features/tracker_speed_ranker_test.dart`、`test/views/requests_test.dart`、`test/views/connections_test.dart` 共 73 个用例与 `dart analyze --fatal-infos` 全绿 |
| 实时连接表协议统计免 lowercase 拷贝 | -（仅 wrapper） | 本轮提交 | `liveProtocolSplit` 抽出为顶层函数并改用 `StringExtension.equalsIgnoreCase`：先比长度，再逐 codeUnit 做 ASCII 大小写不敏感比较，不再为每行 `metadata.network.toLowerCase()` 分配字符串；feed 仍保持原有 copy+sort。新增 `test/views/dashboard/connections_feed_benchmark_test.dart`：JIT n=7（300 行 ×2000 次 counter-only 更新）均值 20.16µs/中位 19.93µs → 13.09µs/13.06µs（均值 **-35.10%**，中位 **-35.00%**，单次更新省 ~7.1µs）；`test/common/string_test.dart` 新增 3 个 `equalsIgnoreCase` 用例（含 ASCII-only 折叠语义），`test/views/dashboard/connections_table_test.dart` 新增混合大小写协议计数与 traffic 更新后顺序不变用例（`TCP`/`Udp` → TCP 12 / UDP 8），`test/views/connections_test.dart`、`test/views/requests_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| Android 事件分发快照监听器 + 标签懒构造 | -（仅 wrapper） | 本轮提交 | `Service` 原来每个 Core 事件都 `List.of(_listeners)` 且都执行 `'Core event ${event.type.name}'` 字符串插值；现在监听器快照按 add/remove 失效缓存，事件类型标签只在 catch 分支构造，成功路径只保留一次 try。新增 `test/plugins/service_event_benchmark_test.dart`：JIT n=7（300 事件 ×200 批）perBatchUs 均值 529.00/中位 526.56 → 489.76/479.68（均值 **-7.40%**，中位 **-8.90%**，单事件 1.76µs → 1.63µs）；`test/plugins/service_test.dart` 25 个用例全绿，全量套件剩余既有本地 bundle 失败 |

### 2026-11-08 核心答案路径轮次

本轮按用户要求聚焦 core（Go wrapper + 子模块）：从 benchmark 地图重新测量，CPU 剖析 `getProxies` 与 `getConnections` 两条答案路径，落地三项结构性重构；第 5 节同步更新待优化项清单。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 组的实时选中读取收敛到单锁：`URLTest.fast` 把 stale 检查与缓存读取合并为新的 `Single.CachedValid`；`URLTest`/`Fallback` 的钉选从 `sync.RWMutex` 改为 `atomic.Pointer[string]` | `89fad1edd` | 本轮提交 | `BenchmarkHandleGetProxies` paired n=7 benchstat：200 组 urltest 59.92µ → 50.47µ（**-15.77%**，p=0.001）、200 组+1000 节点 urltest 77.02µ → 66.89µ（**-13.15%**，p=0.001）、fallback -5.02%（p=0.004）、loadbalance -5.37%（p=0.011），geomean **-7.09%**，分配/内存不变；`BenchmarkURLTestSelectedProxyLargeGroup` paired n=5：166.4ns → 148.2ns（**-10.94%**，p=0.008）。答案字节形状由 `TestGroupDocsAnswerWhatTheirGroupsChange`、`TestProxiesAnswerAnswersWhatTheHostReads` 钉住 |
| 代理解表答案整表一次持锁、组文档键只读一次：`appendProxyTable` 每答案持锁一次（原每组一次），缓存键读一次后同时用于查找与写入（原键会被读三次：查找、组自身编码、写入），行类型每组只问一次 | -（仅 wrapper） | 本轮提交 | 与上一行同一基准配对测量（wrapper 与子模块共同构成该收益）；`TestGroupDocsAnswerWhatTheirGroupsChange` 覆盖四种 kind 的稳态答案、钉选与订阅刷新后 now/all 到达下一答案 |
| 连接轮询行表改 tracker 键 + 死行原地清扫：`connectionRows` 由 `map[uuid.UUID]` 改 `map[statistic.Tracker]`，另存 order slice，清扫时原地压缩；行 id 建行时算一次，删除时不再现算 | -（仅 wrapper） | 本轮提交 | `BenchmarkGetConnections` paired n=7 benchstat：resync 100 行 45.83µ → 30.06µ（**-34.43%**，p=0.002）、resync 500 行 146.0µ → 123.3µ（**-15.56%**，p=0.001）、delta 500 行 39.11µ → 35.10µ（p=0.073 噪声内），geomean **-16.97%**，分配/内存不变；`TestConnectionDeltaAnswersWhatMoved` 全绿 |
| 代理解表组文档缓存槽位化：`groupDocs`（按代理查 map + 快照比对）改为随快照预建的 `groupSlots`，每组每答案省掉 `Type()`、类型断言、map 查找与快照比较，整表锁保持不变 | -（仅 wrapper） | 本轮提交 | `BenchmarkHandleGetProxies` 3 轮交替配对 n=15：groups=20 5.105µ → 4.152µ（**-18.67%**，p=0.000）、groups=200 71.28µ → 53.08µ（**-25.54%**，p=0.002）、千节点 70.05µ → 57.58µ（**-17.80%**，p=0.001）、urltest 50.35µ → 42.35µ（**-15.90%**，p=0.000）、千节点 urltest 68.58µ → 55.79µ（**-18.65%**，p=0.000）、fallback **-18.86%**、loadbalance **-18.56%**，geomean **-19.19%**，分配/内存不变；wrapper 全量 + focused race + vet 通过 |
| Profile 读档缓存直接持有 `wire` 字节（省掉每次读档的整份拷贝） | -（仅 wrapper） | `881b74ba` | `BenchmarkProfileReadAndMerge` 与 `BenchmarkMergeProfileBase` 3 轮交替配对 n=15：分配字节 geomean **-2.79%**（p=0.000），时间持平（该路径 50% 在 `os.ReadFile`、21% 在 yaml，属 I/O 主导）；wrapper 全量 + vet 通过 |
| IPv6 支持检查按进程缓存 + 网络变更失效：`verifyIP6()` 原先每次配置解析都走一遍 `net.InterfaceAddrs()`（实测单次 1.52ms，占 800 节点解析 CPU 采样的 16.7%）；子模块缓存答案并导出 `ResetIPV6Support()`，wrapper 的 `handleNetworkChanged`（桌面 connectivity 变更与 Android NetworkObserver 都走这条路径）调用它失效 | 本轮提交 | 本轮提交 | `BenchmarkParseConfig` 800 节点 paired n=3：13.02ms → 11.31ms（**-13.1%**），分配 89953 → 89895 基本不变；新增 `TestVerifyIP6CachesUntilTheNetworkChanges` 钉住缓存命中、`SKIP_SYSTEM_IPV6_CHECK` 逃逸口与重置后重新询问系统；子模块全量（104 包）+`go vet ./...`、wrapper 全量 +`go vet .`、config 包 race 全部通过 |
| 代理解表组文档键的输入改从槽位读（`3c3ae432`） | -（仅 wrapper） | `3c3ae432` | 答案路径原本每组每答案都向 proxy 问一次适配器类型、并从其 adapter 上断言出钉选读取器；两者在代理生命周期内固定，改由槽位携带，答案路径只剩一次进入组读取实时选中。`BenchmarkHandleGetProxies` 3 轮交替配对 n=15：urltest 200 组 37.81µ → 36.61µ（**-3.17%**，p=0.019）、千节点 urltest 53.23µ → 51.42µ（**-3.39%**，p=0.026）、fallback 45.32µ → 42.02µ（**-7.28%**，p=0.000），geomean **-2.79%**；Selector 场景不用这些输入，维持底线。wrapper 全量 + vet + focused race 通过 |
| 嵌套组选中态解析一次 copy 完成（`d302ed10`） | -（仅 Dart） | `d302ed10` | `_resolveRealSelectedProxyState` 原先每层用两次链式 freezed `copyWith` 分别带 group 标记与（解析名 + testUrl），每个嵌套成员要建两个对象；合并为一次。`test/common/compute_sort_delay_benchmark_test.dart` 嵌套场景 7 轮交替配对：47.5ms → 46.3ms（中位 **-2.6%**，7 轮中 6 轮更快）；平坦场景不触发解析，无影响。`compute_test.dart` 41 例 + focused 全绿 |
| 三个热循环的单元素 fallback 列表提到循环外（`7b79aa0a`） | -（仅 Dart） | `7b79aa0a` | `computeSort.sortOfDelay`、`_resolveDelayTestTargets` 与托盘延迟视图此前对每个「组成员」都新建一个单元素 fallback 列表；改为每组/每批/每组一次，与 `computeHideTimeout` 早已具备的形状一致。`compute_sort_delay_benchmark_test.dart` 嵌套场景 7 轮交替配对：46.5ms → 45.3ms（中位 **-2.6%**，5/7 轮更快）；平坦场景不访问组成员、无变化。focused 11 个文件 179 例全绿 |
| 连接增量基准改测生产帧路径（`87826e88`，仅测试） | -（仅 wrapper） | `87826e88` | `BenchmarkGetConnectionsDelta` 原先走 `json.Marshal(handleGetConnections(...))`，即 `ConnectionDelta.MarshalJSON` 的反射信封——生产路径从不使用它（答案以自己的 frame 发出）。基准改为 `frameFor`：100 行 5.70µs → 4.64µs、500 行 38.3µs → 33.8µs，分配 3 → 2。**注意：这组历史数据与之前的配对不再可比**，本回合起该基准与 `GetConnectionsResyncFrame` 同基准。`MarshalJSON` 保留——帧字节测试用它作独立编码器的交叉验证 |
| 组文档路径死分支清理 + Relay 类型退役（`6744411b`、`123ad42f`） | -（仅 wrapper） | `6744411b`、`123ad42f` | 三处不可达代码随本轮答案路径重构一并移除：`C.ProxyAdapter` 本身就要求 `AppendJSON`，答案路径对「可选 Appender」的断言永远成功，其 `MarshalJSON` 回退/错误日志/节点视图回退均不可达；`isCacheableGroupDoc` 与 `isProxyGroupType` 在 relay 退役后完全同集，且前者是调用方已做过的重复检查；`groupDocKeyOf` 的 bool 与 switch default 同样不可达（槽位只承载四种可缓存类型，且 URLTest/Fallback 都暴露钉选读取器）。缓存性判定上移到建槽处。覆盖变化：`appendGroupDocument` 54.5%→100%、`groupDocKeyOf` 71.4%→100%、wrapper 总体 81.2%→81.5%；性能按简化记录（`BenchmarkHandleGetProxies` geomean -6.4%，但基线轮方差 20–27%，且实际用到被移动读取器的 URLTest 场景无变化，不作性能声明） |
| 修复负载下的偶发测试失败（`123ad42f` 附带） | -（仅 wrapper） | `123ad42f` | `TestTestDelayDoesNotSpendTheProbeBudgetQueueing` 的排队等待 150ms 与获取超时 200ms 只差 50ms，本机负载一高就因调度延迟抖（抓到时失败形态为「handleTestDelay gave up queueing」）。把超时放宽到 400ms，余量 250ms；该测试验证的是「探测不继承排队已耗尽的期限」，不是运行时唤醒 goroutine 的速度。与 `TestInboundVMess_Mekya` 的偶发 flake 同属负载型时序测试，非本轮改动引入 |
| 隐藏超时节点：代理类型改从对象读，删掉整张按名缓存表 | -（仅 Dart） | `30851bf7` | `computeHideTimeout` 原本对每个代理查一次 `_proxyTypesFor` 建的 name→type 表，而该表内容就是 `proxy.name: proxy.type`。改为直接读 `proxy.type`，每个成员少一次字符串键查找，整张缓存表（含 Expando）随之删除。`test/common/compute_hide_timeout_benchmark_test.dart` 7 轮交替配对（每轮新进程）：100 组×20 成员 126.9µs → 89.3µs（**-29.6%**，7/7 全部更快）；2000 节点单组（healthy）中位 10.22µs → 9.26µs（**-9.4%**，逐轮 4/7）。`test/common/compute_test.dart` 41 例、focused 8 个文件 136 例与 `dart analyze` 全绿 |

本轮验证：子模块 `go test ./... -count=1 -p=1`（104 包 ok）与 `go vet ./...`、wrapper `go test . -count=1` 与 `go vet .`、`go test -race . -run 'Proxy|Proxies|Group|Connection|TestMessageBatch|TestResetNetwork'`（CGO_ENABLED=1）与子模块 `go test -race ./adapter/outboundgroup/... ./common/singledo/...` 全部通过。

### 2026-11-09 答案传输层重构轮次

本轮按"彻底重构、不留兼容"的要求重做了 wrapper 的答案输出链。起因是上一轮只缓存了**每组的文档**，帧仍每次重组，且桌面传输层还会把整帧再拷进池化缓冲；更重要的是宿主每次调用都换 id（`lib/core/lib.dart` 的 `'${++_methodCallId}'`），所以任何"按整帧+ id"做的缓存在生产里永远命中不了。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 答案分层为信封/文档/尾段：`frameWriter.frameFor(id)` 改为 `frameWriter.document()`，`handleMethodCall` 返回 `frame{head,document,tail}`，信封按调用现建（`envelope(id)`），文档就是结果自己编码出的字节 | -（仅 wrapper） | 本轮提交 | 六类答案（proxies/connections/count/traffic/memory/providers）统一到同一契约，`frameFor` 删除；字节形状由既有测试逐类钉住（`TestProxiesAnswerAnswersWhatTheHostReads`、`TestConnectionDeltaAnswersWhatTheHostReads`、`TestTrafficStatsFrameMatchesTheEnvelope`、`TestMemoryStatsFrameMatchesTheEnvelope`、`TestProviderListFrameMatchesTheEnvelope`、`TestConnectionCountFrameMatchesTheEnvelope`，全部为 json 反射信封与手写文档的逐字节比对） |
| 桌面传输层对大文档分段写：`writeFrame(w, frame)` 在文档 ≤32KB 时仍整帧进池化缓冲一次写出，超过则写「长度+信封」「文档」「尾段」三段，文档本身不再被拷贝 | -（仅 wrapper） | 本轮提交 | `TestWriteFrameReadFrameRoundTrip` 增设大文档分段用例（帧读回与 `frame.bytes()` 逐字节相等）；`TestSendWritesEachFrameInOneTransfer` 仍证明小帧一次写出 |
| 溢出响应分段落盘：`spillResponse` → `spillFrame`，临时文件按三段顺序写，不再为落盘凑一整帧 | -（仅 wrapper） | 本轮提交 | `TestHandleMethodCallSpillsALargeResultToAFile`、`TestHandleMethodCallAnswersInlineUnderTheThreshold`、`TestClearSpilledResponsesKeepsTheDirectory` 全绿 |
| 大文档走真实管道的基准（`BenchmarkWriteFrameLargeDocumentOnAPipe`，仅测试）：140KB 文档在 Windows 匿名管道上分段写 35.9µ/答案、3991MB/s、32B/答案；同窗口对照"先 join 成一整帧再写"为 54.9–71.3µ、2011–2608MB/s、147.6KB/答案 | -（仅 wrapper） | 本轮提交 | 分段写比 join 快约 **35%** 且零拷贝，三条写替代原来的一次 join + 一次池化缓冲拷贝；这是传输层敢丢掉整帧拷贝的实证，基准留在仓库里防回归 |
| 代理表按表缓存整个文档（键不含调用 id）：`document()` 先用 `refreshGroupDocs` 逐个槽位校验（`refreshGroupDoc` + `groupDocGeneration` 代数），毫无变化才把上次的文档交出去；键为快照同一性 + 显示名单 + 代数 | -（仅 wrapper） | 本轮提交 | 见本节末的配对测量：生产答案路径 geomean **-86.07%**、分配 -99.94%、allocs -44.83%；`TestProxiesFrameAnswersTheSameBytesUntilSomethingMoves`（新增）钉住：表未变时同一文档、换 id 只换信封、选中移动/订阅刷新/快照重建三类变更都必须重建文档；`TestProxiesAnswerEncodesALiveGroupOnEveryAnswer`（新增）钉住无法键入的组仍逐次实编码 |
| Android 回复路径在 gobind 边界拼接（`InvokeMethod` 的 reply 适配） | -（仅 wrapper） | 本轮提交 | gobind 只收一个切片，故在边界 join；桌面走分段写。两边字节一致，由 `frame.bytes()` 与 `writeFrame` 的往返测试共同保证 |

配对测量方法：同一二进制内同时跑「旧生产路径模型」（每轮强制未命中，走 校验→重组→join→池化拷贝，即旧代码每次答案的真实成本）与新生产路径（`handleMethodCall` + `writeFrame(io.Discard, frame)`），3 轮交替、每轮 count=2，benchstat n=6，p=0.002：

| 场景 | 旧生产路径 | 新生产路径 | 时间 | B/op |
|---|---|---|---|---|
| 200 组 Selector | 67.56µ ±12% / 259.4Ki / 5 allocs | 8.35µ ±7% / 101B / 3 allocs | **-87.64%** | -99.96% |
| 20 组 Selector | 6.18µ ±21% / 28.3Ki | 0.99µ ±3% / 64B | **-83.98%** | -99.77% |
| 200 组 + 1000 节点 | 91.95µ ±12% / 377.9Ki | 9.06µ ±3% / 105B | **-90.15%** | -99.97% |
| 200 组 urltest | 53.79µ ±4% / 258.2Ki | 12.39µ ±3% / 226.5B | **-76.97%** | -99.91% |
| 200 组 fallback | 68.45µ ±8% / 260.2Ki | 14.37µ ±4% / 119B | **-79.00%** | -99.95% |
| 200 组 loadbalance | 56.52µ ±5% / 259.1Ki | 3.69µ ±5% / 98B | **-93.48%** | -99.96% |
| 200 组 + 1000 节点 urltest | 77.45µ ±3% / 375.8Ki | 12.83µ ±4% / 233.5B | **-83.44%** | -99.94% |
| **geomean** | **48.37µ / 205.3Ki / 5.13 allocs** | **6.74µ / 122.7B / 2.83 allocs** | **-86.07%** | **-99.94%**（allocs -44.83%） |

变更表路径（`BenchmarkHandleGetProxiesMiss`，新增：每轮真实切换一个组的选中，测的是"表变了之后的答案"）与旧生产路径同窗口配对：Selector 71.50µ → 49.22µ（**-31.17%**）、urltest 54.63µ → 42.75µ（**-21.76%**），p=0.002。即未命中路径没有因"先校验再组装"的两段式而变慢——省下的 join 与池化拷贝抵消了校验 pass 的额外遍历。

**已否决策略（勿重做）**：把整帧缓存键做成"帧 + 调用 id"。宿主每次调用都换自增 id，命中率恒为 0，只会让答案路径多背一次 id 比较与整帧缓存。文档缓存必须建在结果文档上，信封由传输层分担。

本轮验证：wrapper `go build ./...`、`go vet ./...`、`go test ./... -count=1` 全绿；`GOOS=android/linux/darwin` 交叉 `go vet ./...` 均通过（`lib.go`、`server.go`、`spill.go` 三平台一致）；`go test . -race -count=1` 仅剩既有失败 `TestRouteVersionsPollLeavesRuleSetsToTheirEvent`（`route.go` 的刷新 worker 与 `recordRoutes` 清理的数据竞争，已在**基线代码**上复现，与本轮无关）；答案路径 focused race（Proxy/Proxies/Group/Connection/Spill/Send/Frame/Dispatch/Traffic/Memory/Provider）全绿。
### 2026-11-09 只读代理不再建表轮次

上一轮留下一条内存线索：`BenchmarkHandleGetProxies` 的内存剖析里，**超过一半的分配字节来自 `xsync.newMapTable`**——`xsync.Map` 在任何入口（含纯读）都惰性建表，于是「只被读过、从未被写过」的代理也各自持有一张空表。URLTest 组的挑选循环会遍历每个成员读一次延迟状态，所以一千个节点的订阅会建一千张什么都不装的表。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 只读代理不再建 per-URL 状态表：写入路径（`testState`，全部写入都收敛于此）在触表前先发布 `hasExtra`，纯读路径先看这个标志，标志为清就知道表为空、不需要建表；`xsync.Map` 增补 `Initialized()` 让该不变量可测 | `ebe6dbb18` | `08fe568b` | 交替运行前后两个编译产物（各 4 轮 × count=2，n=8）：urltest 场景 223.5B/答案 → **103.0B/答案（-53.91%，p=0.000）**，allocs 3→3，时间 11.89µ → 11.82µ（p=0.721，无变化）；基准整个过程分配总量 78.3MiB → 40.8MiB、对象 634.6k → 527.1k，`newMapTable` 从剖析中完全消失。`TestProxyExtraStateIsBuiltOnlyByAWrite`（新增）钉住：纯读不建表、写入后建表、写过的值仍读得回；既有 `TestProxyAliveForTestUrl`、`TestProxyMarshalJSONCarriesDelayState`、URLTest 系列与 xsync 全量不受影响 |

说明：本轮只改内存与分配，不动时间。读取路径对「确有状态」的代理多付一次原子加载，对「从未写过」的代理从「initOnce + 哈希 + 探查」降为一次原子加载；挑选循环的实测成本不在这里，故时间持平。真实收益是大型订阅的常驻内存：只读成员不再各持一张 ~450B 的空表。


### 2026-11-09 名单按身份做键轮次

配置名单里装的是**全部代理**（`config.go` 的 `proxyList`：DIRECT、REJECT、每个节点、每个组），一千节点的订阅就是一千零五十二个名字。投影缓存每次回答都用 `slices.Equal` 把这个名单走一遍，只为确认它没变；`SetProxyNameList` 是整个代码库唯一的写入口、且配置解析只调一次（存进去的是该次 parse 自己建的切片），之后从不原地改。因此**同一个切片身份就是同一个名单**。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 投影缓存与帧缓存的名单比较改按身份：`slices.Equal(source, cache.source)` → `sameProxyNameList`（长度 + 首元素地址），投影缓存也不再 `slices.Clone(source)`（缓存持有引用即可：名单被替换而非原地改）；帧缓存的显示名单同样按身份比（投影交出的就是它持有的那个切片） | -（仅 wrapper） | `64a7af36` | 同一基准、交替运行前后两个编译产物（4 轮 × count=2，n=8，全部 p=0.000）：geomean 7.02µ → 6.02µ（**-14.23%**）；200 组 + 1000 节点 10.94µ → 8.08µ（**-26.19%**）、同场景 urltest 14.71µ → 11.89µ（**-19.15%**）、200 组 8.45µ → 7.52µ（**-11.08%**）、20 组 **-8.65%**、loadbalance **-20.17%**、fallback **-4.66%**（该场景成本在 `findAliveProxy`，不在这两处比较）；分配 96.97B → 95.79B（少一次 clone），allocs 不变。wrapper 全量 + vet + focused race 通过。**注意：本轮同时把基准的名单规模改成生产形态（全部代理名），绝对值与账本历史行不可比**，比较只在本轮同基准内有效 |

不变量说明（写进代码注释）：名单是"替换"而不是"原地编辑"——`SetProxyNameList` 是全库唯一写入口，由配置解析每次parse调用一次；若将来出现原地改名单的写法，身份比较必须改回内容比较。


### 2026-11-09 singledo 读路径轮次（测试落地 + 无锁实验否决）

命中路径的 CPU 剖析把 `internal/sync.(*Mutex).Unlock` 列为 7.7%，指向 `URLTest.fast` 里的 `fastSingle.CachedValid`。本轮先把读路径改成无锁（结果改 `atomic.Pointer` 发布、`CachedValid` 的两次 `time.Since` 合成一次），再按仓库纪律判定去留。

| 项目 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `Cached`/`CachedValid`/`Forget`/`ForgetAfter` 在此前**没有任何测试**（唯一调用方是 URLTest 的 fast-node 缓存，行为只能透过代理答案间接观察）；补 4 组测试：有结果才服务、调用执行中不服务、age 到达且 stale 拒绝才丢弃、低于 age 不丢、读写与 Reset 并发不抛半成品 | `80f6d03f4` | `219c3645` | 与实现无关（只用公开 API），锁实现撤回后依然全绿；`go test ./common/singledo/... -count=2` + `-race` + `go vet` 通过 |
| **已否决**：singledo 读路径无锁化（`result` 改 `atomic.Pointer[Result[T]]`、读路径不再取单飞锁、`CachedValid` 只读一次 `time.Since`） | - | - | 交替运行前后两个编译产物、两轮各 8 样本（n=16）：11.02µ → 10.80µ 仅 **-1.57%（p=0.043）**，未达到 p≤0.02 门槛；剖析里那次 Mutex.Unlock 主要不是它。实现已撤回，账本记录以免重做 |

**另一定案（账本待办第 1 项的结论）**：`groupDocKeyOf` 之后的「能不能省掉每组每答案的 provider 版本遍历」——不能省。`updateExternalProvider`（订阅刷新、`provider.sideLoad`）只做 `p.Update()` + `refreshRoute()`，**不重建代理表**，所以成员名单会在「快照同一性不变」的情况下变化；`groupDocVersionsMatch` 是唯一能抓到这种变化的读取点。若要改，必须让 provider 在版本变化时主动通知其组（通知型失效），那是架构级改动，留作后续议题。


### 2026-11-05 测量记录（审计后刻意未动）

| 位置 | 测量 | 结论 |
|---|---|---|
| Dart getProxies 接收路径（UI isolate 解码 → compute 构建） | 新增 `test/models/groups_receive_benchmark_test.dart`（JIT，i9-9900）：132KB 帧（200 组×20+1000 节点）帧解码 874–1282µs，`ProxiesData.fromJson`+`buildGroups` ~370–570µs，compute 往返 ~3–516µs，全链 ~1.8–2.2ms | 全链在 UI isolate 规则约 8ms 预算内；把帧解码融合进构建 isolate 最多省 ~0.5ms，却要改 RPC 契约并深拷贝解码图回传；不动 |
| Dart getConnections resync 接收路径 | 同基准：244KB 帧（500 行）解码+`connectionDeltaOf` ~3.1ms（JIT，全程 UI isolate） | 页面打开一次性成本，AOT 估 ~1.5–2ms；`withResultModel` 挪进 isolate 的入拷贝≈所省；超 1000 行时用 profile build 重估后再议 |
| wrapper `all` 数组与名字追加 span 缓存 | `BenchmarkHandleGetProxies` CPU 剖析（组文档缓存后）：`AppendString`+mapaccess ≈ 11% ≈ ~11µs/答案 | 残余成本 GC/memcpy 主导（`scanObject` 19%、`memmove` 7%、`appendProxyView` 13%——即缓存文档的拷贝本身）；span 缓存上限 ~11µs，不抵第二层失效逻辑；不动——其键 span 部分随后按上表落地（`8bceffff`），`all` 数组仍在（配置名单身份独立于快照） |
| wrapper `all` 数组独立 span 缓存 | `all` 仅含组名（典型 200 个，节点不在其中），预编码每答案省 ~2–3µs，对 66–97µs 的场景落在 ±2–11% 噪声带内；缓存键需（配置名单身份，快照身份）双重核验 | 投影收益低于本轮基准噪声分辨力，不值得新增第二层身份缓存；维持实时追加 |
| 规则匹配 plain 段线性扫描 | `BenchmarkMatchPlainRulesBeforeIndexedHit` 重测（2026-11-05）：plain=5000 37.1–38.0µs/匹配、0 allocs，与账本 2026-11-03 记录的 ~40µs 一致；索引路径 44–162ns/0 allocs（exact/suffix/IP 各基准） | 生产 profile 的 plain 规则通常几十条（每条 ~7.4ns），病态 5000 条属极端配置；按判别键建桶要重写首条命中语义，维持原拒绝结论 |
| 隧道 UDP 每包路径 | `BenchmarkHandleUDPConnExistingFlow` ~43ns/0 allocs、`BenchmarkPacketSenderSend/ready` ~48ns/0 allocs、flow key ~3ns（2026-11-05 重测） | 前续轮次已把每包路径压到纳秒级零分配，无可再削的分配或拷贝；P4 剩余仅首包 outbound dial 生命周期 |
| Rust IPC 帧层与 outbox | 代码走查：`frame::read` 单次精确长度读取+单次分配，outbox 突发合并单写（`drain_into` 256KB 上限），事件批量已在 Go 侧合并成帧 | 拷贝最小形状，无单帧重复拷贝或多余分配可削；不做基准（控制面帧不构成热点） |
| 子模块未合并分支 `codex/perf-trojan-writeback-01a15f94`（6 提交） | `git cherry` 全部为 `+`，但 `BenchmarkSingPacketWriteBack` 在 main 实测 17.8–18.1ns/0B/0 allocs、`BenchmarkTrojanPacketWriteBack` 1.68–1.74ns/0B/0 allocs——与其基准报告的"优化后"数字持平 | 该分支是已合并 clean 孪生分支的旧迭代，patch-id 不同但功能等价已落地；合并只会重复/冲突，拒绝 |
| 子模块未合并分支 `codex/faster-proxy-failover`（+28） | 其 `perf: reuse a resolved fallback group pick`（`ac5eb766f`）引入的 `fallbackSelection`+10s TTL 在 main 已有等价实现（main 版改用单调时钟，更好）；其余为改选语义的 feature 提交 | 性能部分已被 main 覆盖，语义部分属产品决策非本轮范围；不合并 |
| 子模块未合并分支 `codex/refactor-Rn1-bingbu01`（+10） | 唯一 perf 提交 `perf(sudoku): route UoT datagrams through AddrPort` 针对 sudoku 入站——FlClash 不使用该入站；其余为测试重试鲁棒性与 CI 记录 | 非 FlClash 流量面；测试提交不属性能范围；不合并 |
| sniffer 每连接路径 | `BenchmarkSniffDomain` 281–294ns/688B/2 allocs；sniff 日志守卫路径 0.44ns/0 allocs（守卫关闭时无条件构造为 163ns/3 allocs，生产恒走守卫） | 每连接一次 TLS ClientHello 解析，成本在解析本身；日志已守卫；不动 |
| statistic 记账路径 | `BenchmarkManagerPushStriped` 2.22–2.25ns/0 allocs、`ManagerSnapshot` 100/500 行 1 alloc、`NewTCPTracker` 隔离 2 allocs（前轮钉住） | 全部饱和；不动 |
| 组健康检查 | `GroupBase.healthCheck` 每 provider 一个 goroutine 并行，成本在 provider 的 HTTP 探测网络等待 | 网络主导，wrapper/Go 侧无分配热点；不动 |
| DNS 查询事件路径 | `newDnsQuery` 走查：`TrimSuffix` 零分配、答案串为 UI 必需、事件进批量直写编码（见 d838533e 行） | 每查询仅答案串本身分配，形状已最小；不动 |
| Dart 代理页搜索键入路径 | `SearchQuery` 走查：文本经 Expando 缓存且已小写，`terms.every(contains)` 已是最小操作，1000 节点每键击 ~0.2ms | 缓存已完备，无再削减空间；不动 |
| HTTP 客户端复用（provider/geo 下载） | `Request` 构造单例 Dio + `IOHttpClientAdapter` 的 `createHttpClient` 懒创建一次，keep-alive 连接复用成立 | 已是复用形状；不动 |
| 脚本引擎调用路径 | `handleEvaluate` 每次 profile 应用一次，Rust 侧执行；`json.encode(config)` 在 UI isolate，一次性且低于预算 | 一次性成本；不动 |
| 进程匹配（find-process-mode） | `tunnel` 侧严格模式惰性（仅 PROCESS 规则触发）、always 显式开启；Windows 实现继承上游 `GetExtendedTcpTable` | 门控正确，实现属上游预算（Core API Safety：fork 改动留给 feature）；不动 |
| 协议包路径全量扫描（99 条基准，2026-11-05） | `go test ./adapter/outbound/... ./transport/... -bench Packet`：稳态每包 0 allocs 的路径占绝大多数（hysteria hop/mekya/vmess/ssr/trojan/vless/socks5 写读、Relay、UDPPacket 池化生命周期等）；非零分配点逐一定位：`EncodeUDPPacket`（分配版）无生产调用者，仅作 `Into` 变体的测试字节 oracle（同 messageBatchCall 参考实现先例）；trusttunnel 客户端写 64B/1 alloc 仅在无前置余量回退分支（headroom 优先路径零分配，稀有协议）；snell `WritePacketResponse` 属 snell 监听入站（FlClash 客户端不可达）；`PacketConnIDGeneration/uuid` 即账本已拒绝的每代理 uuid；mekya `WrappedPacketConnForward` 908ns/0 allocs（网络面前可忽略）；hysteria hop 生产路径走 `udpPacketPool`（owned 变体仅为基准对照） | 全部关闭：饱和路径不动，oracle 保留，回退分支与不可达面不投复杂度 |
| 本地入站 UDP 路径（socks/mixed） | `BenchmarkSocksUDPHandleCached` 112.4–113.7ns/128B/1 alloc（包结构体）；write-back 30ns/0 allocs；`SocksPacketAdapter/native` 2.3–2.6ns/0 allocs | 每包 1 alloc 是包结构体本身，其生命周期跨异步隧道路径——账本工作流规则 6 明确不池化 packetAdapter；关闭 |

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
| 清理不可达的事件流开关（`refactor(core)`，`054a893c`） | -（仅 wrapper） | `054a893c` | 协议里没有启停 request/dns 事件流的方法，`handleStartRequestMessages`/`handleStopRequestMessages`/`handleStartDnsMessages`/`handleStopDnsMessages` 四个处理器连同两个标志位永远为 true，`sendMessage` 每个事件要为常量付一次 switch；删除该机制与只测它的用例，`routeState`（只被测试调用）移入测试文件。行为不变（标志位恒定 true），wrapper 全量 + vet 通过 |

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
| Provider 精确 answerSize 预分配 | `StringLen` 逐字段扫描后 paired n=7：60.49µ ±2% → 79.07µ ±10%（**+30.72%**），内存/分配不变；撤销，扩容比扫描便宜。 |
| Provider 帧按 512B/条预分配 | 60.49µ ±2% / 48.15KiB / 14 allocs → 69.01µ ±1% / 77.52KiB / 14 allocs（时间 **+14.08%**，内存 **+61.01%**）；撤销，原增长路径更优。 |
| CoreManager feed flush 双缓冲交换 | 新增 `test/manager/core_manager_feed_benchmark_test.dart`（JIT，200 批，每批 400 log+120 request+240 DNS+200 traffic）实测：原 `from + clear` 每批 1081/1100/1082/1161µs，双缓冲换 buffer 每次都要清空旧队列，1149/1159/1242µs（**+6~12%**）。新空队列分配/清空不被 feed provider 的 `FixedList.appendAll` 拷贝规避抵消，撤销并保留原拷贝形状。 |
| `SearchQuery.matchesText` 单 term 直接 `contains` | DNS 搜索文本缓存后，`test/models/dns_query_search_benchmark_test.dart` n=7：73.41ms/中位 73.18ms → 74.25ms/中位 73.64ms（时间 +1.15%/+0.62%，在噪声内无收益）。`terms.every(text.contains)` 已无每行字段构造成本，直接分支无可再省；撤销。 |
| `countryFlagEmoji` 用 `Expando<String>` 缓存 | `test/common/country_flag_benchmark_test.dart` 验证前直接失败：Dart `Expando` 明确拒绝 String/num/bool/record/null 作为 key，`Expando.[]` 抛 `Invalid argument`；`test/common/string_test.dart` 全量复现后回退。结论：字符串不可作为弱引用键，缓存需换成包装对象，收益不抵额外结构；撤销。 |
| TrackerSpeedRanker scratch TypedData 复用 | `test/features/tracker_speed_ranker_benchmark_test.dart` JIT n=7：均值 8.37ms/中位 8.24ms → 8.36ms/中位 8.26ms（时间 -0.11%/+0.22%，无收益，且新增重复初始化代码）。Dart 对小型 TypedData 分配成本低，节省的分配被 fillRange/清理抵消；撤销，保留已落地的 int32 索引与 positions map 复用。 |
| `CoreEventManager` request/DNS filter 内联 | `test/core/event_dispatch_benchmark_test.dart` JIT n=7：request 均值 2.621µs/中位 2.624µs → 2.669µs/2.650µs（**+1.84%/+1.00%**），log 均值 5.023µs/中位 5.014µs → 5.081µs/5.081µs（**+1.15%/+1.34%**）。单个 listener 下手写双层过滤比 `_filterFor` + `.any` 更慢，无收益；撤销。 |
| `Connections` 发布即按 start 倒序 + 仪表盘 feed 免 copy/sort | 设想：把“最新在前”下沉到 provider，`_merge` 只在增删行时重建有序 map，`_showConnections` 不再 copy+sort。`test/views/dashboard/connections_feed_benchmark_test.dart` JIT n=7（300 行）实测：feed 准备均值 19.90µs/中位 20.00µs → 3.65µs/3.64µs（**-81.7%**），但 provider 结构变化发布均值 117.79µs → 175.20µs（**+48.7%**，entries.toList + sort + map 重建）。feed 刷新受 `renderThrottleDuration`（300ms）限制，最多约 3.3 次/秒，而结构变化发布随 1 秒轮询发生：按 1 次发布 + 3.3 次更新/秒算是 171.6µs → 187.1µs（**+9.0%**），更新更少时最多 +48.7%，无明确收益；已撤销 provider 改动并保留 feed 的 copy+sort。若将来要落地，需改为“保留已排序 id 列表 + 增量插入/合并”（O(n+k log k)）后重新配对测量，不要直接整表重排。 |
| 表格单元格文字样式按 ColorScheme 缓存（`Expando`） | 设想：`RecordCellText`/`_Muted`/`_Number` 每次重建都为 muted 样式新建 `TextStyle`。改用 `context.mutedTextStyle` + `Expando<TextStyle>` 按主题缓存后，`test/widgets/row_cells_benchmark_test.dart` 同 session 配对测量（n=5，500 行 ×500 次 cellsOf）：1415ns/行 → 1403ns/行（**-0.9%**，噪声内）。Dart 小对象分配很便宜，`Expando` 查找加 `context.colorScheme` 继承查找与新建一个 TextStyle 同价；已撤销，保留原逐单元格构造 |
| `FixedList.updateByKey` 改 `entries` 循环 | `test/providers/requests_update_benchmark_test.dart` JIT n=7：perBatchUs 均值 31.57/中位 32 → 31.71/32（**+0.44%/0%**）。省掉的 `forEach` 闭包被 `entries` 入口迭代抵消，无收益；撤销，保留原 `Map.forEach` 形状。 |
| `delay`/`delayTestPhase` 去掉 `realTestUrlProvider` 家族跳，改为直接 `watch(patchClashConfigProvider.select)` | 新增 `test/providers/delay_provider_benchmark_test.dart`（1000 行 ×10 次 `refresh(delayProvider)`）三次交替配对（A=HEAD 带家族跳，B=直连 select）：A 8080833/8259448/8660959µs（均值 8333747）→ B 9154707/9247181/9358151µs（均值 9253346），**+11.0%**，三轮全慢。家族元素按参数缓存后只是一次读，`select` 订阅每次重建都要付闭包与通知器成本；撤销，保留 `realTestUrlProvider` |
| `computeSort`/`computeHideTimeout` 把 `takeFirstValid` 的 fallback 列表提出循环 | 2026-11-08 三次交替配对（A=HEAD，B=hoist，每轮新进程）：`computeHideTimeoutGroups` 100 组 11963µs → 11561µs（**-3.4%**，但 3 个配对只有 1 个为负）、`computeSortDelaySorted` 100 组 10447µs → 11521µs（**+10.3%**）、新增的 `computeSortDelayNested`（100 组 ×10 嵌套组）45406µs → 46556µs（**+2.5%**），全部落在 ±5% 进程噪声内、无稳定收益；且实现时极易把嵌套组 fallback 从「外层组 testUrl」误提升成「全局默认 testUrl」（语义偏差，这次已由新增回归测试钉住后回退）。撤销 compute.dart 改动；本轮只落地测试增量：`test/common/compute_sort_delay_benchmark_test.dart` 新增多组/嵌套组两个场景、`test/common/compute_hide_timeout_benchmark_test.dart` 新增多组场景、`test/common/compute_test.dart` 新增「嵌套组无自己的 testUrl 时读外层组 testUrl」用例（41 例全绿） |
| `adapter.Proxy` 构造时固化 Name/Type（少一次接口分发） | 5 轮交替配对 n=15（groups=200 场景）：119.1µ ±38% → 125.9µ ±42%（p=0.902，无显著差异）。本机在跑用户自己的 FlClash 实例，CPU 负载 ~52%，该场景方差 ±38% 以上，只有大幅收益才可判定；理论收益仅省一次分发，与风险（改动全项目最基础的代理包装类型）不相称，撤销并记录 |
| `handleGetExternalProviders` 的条目顺序按 provider 表地图身份缓存 | 剖析确认排序占该答案 14%（100 个 provider），但该答案只有两个调用方：`CoreAction.initCore`（Core 已初始化时的重连）与资料应用的 setup 流程——都是每次事件一次、且紧跟在地图变化之后，缓存必然每次都未命中；Dart 侧 `syncProviders` 也非轮询。为一个只在基准紧凑循环里生效的缓存增加「锁 + 身份簿记」状态，收益不真实，撤销 |
| Profile 读档按 `os.Stat` 跳读（省掉重复读盘） | 剖析：`BenchmarkProfileReadAndMerge` 中 `os.ReadFile` 占 50%（17.15ms/周期中约 8.5ms），而一次真实 Apply 会读同一文件 2–3 次（`profile.build`、`config.setup` 的 `loadConfigWithBase`、以及宿主侧的 `profile.base`/`outbounds`），只有第一次付出 yaml 解析 | 现有缓存按「读文件 + 逐字节比较」判定未变，解析已覆盖；若改为按 (size, mtime) 跳过读盘，可省约 25% 的 Apply 时间，但宿主改写走 `profile.clearEffect` 显式失效、Core 自身改写走 `forgetProfileRaw`，唯一敞口是外部编辑器「同大小 + 同一时钟 tick 内」的两次保存——本机 Windows 文件时间戳粒度约 15.6ms，脚本化双击保存可落入同一 tick，届时会返回过期配置。无既快又等价的判据（任何局部内容探针都能被中部等长编辑绕过），与账本既有「不信任宿主 digest」的决议同因，维持不做 |
| `computeSort` 排序键 TypedData 缓冲跨组复用 + `_sameOrder` 同列表短路 | 3 轮交替配对（每轮新进程、50 次 warm-up 后测 100 次）：1000 节点全量排序 17.82ms → 18.46ms（**+3.6%**）、100 组×10 嵌套组 46.22ms → 48.99ms（**+6.0%**）、已有序的两个场景在 ±4% 内。缓冲复用虽把每组 2 次 TypedData 分配降到每 computation 2 次，但没有转化为时间收益；撤销 |
| `computeSort` 按 Group 对象缓存「成员是否为组」位图（`Expando<Uint8List>`） | 7 轮交替配对：单组 1000 节点 17.68ms → 17.66ms（7/7 一致，约 **-4.2%**），但 100 组×2、嵌套两组场景 +1.9%/+2.2%——Dart 的 `Expando`（WeakMap + 身份哈希）查找比短字符串 map 查找更贵，只有上千成员的单个组才划算。撤销；结论：Dart JIT 下 <15% 的计时差需要 ≥7 组交替配对才可判定 |
| `computeSort`/`computeHideTimeout`/`_resolveDelayTestTargets` 的「成员是否为组」改 `GroupTypeExtension.isEnumName(proxy.type)` | 该检查零分配且仓库 UI 层（`lib/views/proxies/card.dart`）已在用同一语义，但 `isEnumName` 只认枚举名拼写，而 `groupsByName` 含 `isGroupType` 接受的全部拼写（含 lowercase 别名与 `value` 拼写）；用户自定义分组若用非枚举名拼写，会被误判为叶子、用错延迟测错序。把逐代理查找换成类型检查没有既快又完全等价的形态（先查类型再回落查表会让占比最高的叶子更慢），记账备查 |
| `lib/views/profiles/custom/members.dart` 与 `lib/providers/actions/profiles.dart` 的 name→type/name→id 表 | 两处都是资料编辑器/导入路径（非持续热路径），且表本身已按状态 Expando 缓存；同一病灶但收益面不在热门路径上，暂不动 |
| `computeSort` 延迟排序两项微优化（`_sameOrder` 同列表短路 + 排序键缓冲跨组复用） | 3 轮交替配对（每轮新进程、50 次 warm-up 后测 100 次）：1000 节点全量排序 17.82ms → 18.46ms（**+3.6%**）、100 组×10 嵌套组 46.22ms → 48.99ms（**+6.0%**）、已有序的两个场景在 ±4% 内；缓冲复用虽把每组 2 次 TypedData 分配降到每 computation 2 次，但没有转化为时间收益。撤销两项改动。结论：Dart JIT 下 <15% 的计时差需要 ≥7 组交替配对才可判定，微优化应先做分配/操作数论证再上基准 |
| `RecordFacet.optionsOf` 选项终排预计算（rank 表 + 折叠键） | `test/models/facet_options_benchmark_test.dart` 7 轮交替配对（前 2 轮受机器负载污染，取稳定 5 轮）：全去重场景 50.4µs → 51.3µs（+1.7%）、3 个 offered facet 44.8µs → 44.0µs（-1.6%），均在噪声内。剖析确认该路径 80% 以上是 `countInto` 的逐行 map 计数与 `_mostFrequent` 的有界选取（前者每次插入本身就是两次哈希），选项终排占比过小；撤销 |
| `Requests.updateTraffic` 加未变行提前返回与 identical 守卫（对齐 `Connections.updateTraffic` 的既有写法） | `test/manager/core_manager_feed_benchmark_test.dart` 7 轮交替配对：稳定段（前 3 轮）980.2µs → 999.5µs/批（+2.0%），后 4 轮 1076.8µs → 1094.5µs（+1.6%）。Core 的 `requestTrafficWatch.collect` 本就只发送计数变化的请求，到达 provider 的条目几乎必然与本行不同，提前比较只是多一次整数比较；撤销。feed 每事件约 1.02–1.19µs 的剩余成本在 flush 的 4 个容器拷贝、`FixedList.appendAll` 的逐项 key 建索引与 Riverpod 通知上，要再降需先埋点拆分 |
| Selector 选中名缓存进 `selectorSelection`（稳态 `Now()` 少两次接口分发） | 3 轮交替配对 n=15（千节点 selector 场景）：75.90µ ±20% → 79.48µ ±23%（p=0.902，无显著差异）。itab 热时分发成本只有个位数 ns，与在子模块最基础的选择缓存里多加一个字段的风险不相称，撤销并记录 |
| 代理解表组文档键改「组选中代数」 | 剖析确认 `groupDocKeyOf` 仍是答案路径最大单项（URLTest 场景约 25%），但把键换成子模块导出的选择代数量，任何漏记的变更点都会让 UI 显示过期选中态；需先枚举 URLTest/Fallback/LoadBalance 的全部选中变更点并逐点补计数，本轮未做，留在待优化项 |

### 2026-11-09 handler 分发测试轮次（覆盖，不是性能）

任务要求"测试流程必须覆盖全部核心代码"。此前 method 表只被 `TestEveryCoreMethodConstantIsDispatchable` 检查**注册**，从不执行；十余个 action handler 覆盖率 0%。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 让每个已注册 handler 都通过 dispatcher 真跑一遍：流量重置、关闭全部连接、重置连接、清 DNS 缓存、上报网络变更、关闭单个未知连接、外部 provider 列表/单读、inline provider 的 sideLoad 拒绝、profile clearEffect 在 core 未初始化/已初始化两种状态 | -（仅 wrapper） | `76247f64` | 覆盖 `traffic.reset`/`connection.closeAll`/`connection.reset`/`dns.clearCache`/`network.changed`/`connection.close`/`provider.list`/`provider.get`/`provider.sideLoad`/`profile.clearEffect` 共 10 个方法，断言各自的 result/error 与副作用（非 closeAll 不得动连接行、closeAll 后表空、provider 名单含转义名、clearEffect 真删目录）。wrapper 全量 + vet + focused race 通过 |

覆盖率：wrapper `go test . -coverprofile` 统计 **81.6% → 82.8%**（statements）。剩余 0% 集中在三类：进程入口（`StartServer`/`ExitOnTermination`）、非 Windows 平台文件（`ownership_other.go` 上的 `initOwnership`/`reclaimDirOwnership`）、以及 service_rules 的 unlock 检查器（需真实外网，靠 `handleServiceCheck` 走注入源覆盖）。前两类不适合在 wrapper 单测里构造；第三类已有 service_check 测试覆盖其框架。


### 2026-11-09 溢出路径测试轮次（覆盖，不是性能）

传输层重构把「帧写入器答案」也送进了溢出路径（`spillFrame` 按段写临时文件），而这条分支此前**没有任何测试**——原有三个 spill 用例走的都是反射结果（`config.read`）或 profile 构建。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 覆盖帧写入器答案的溢出落盘 + 落盘失败的降级：前者钉住「落盘文件字节 == 传输层本该写出的字节」（阈值压到答案长度减一，强制走 spill），后者把 home 指到一个已存在文件上让 MkdirAll 失败，钉住「失败时原样内联返回，绝不指向一个没被创建的文件」 | -（仅 wrapper） | `5c786c8d` | `TestHandleMethodCallSpillsAFrameWriterDocument`、`TestSpillFailureAnswersInline` 两个新用例；`spillFrame` 覆盖 57.1% → 85.7%、`makeSpilledResponseDir` 80% → 100%；wrapper 全量 + vet + focused race 通过。剩余未覆盖是 `writeSpilledFrame` 里 Chmod/Write 失败的防御分支，需注入文件系统错误，留着 |

**审计结论（记录备查，未改动）**：`connectionRow.stale()` 在生产线永远不会为真。子模块 `NewTCPTracker` 用 `tt.metadata = *metadata` 做值拷贝，`TrackerInfo.Metadata` 指向 tracker 自己的副本（`TestTrackerClonesMetadataIntoCreationSnapshot` 钉住：创建后改原 metadata 不影响快照），而全子模块对 `TrackerInfo.Metadata` 的写入只发生在构造期。因此这 10 个字段比较是防御性死代码。**不删**：删除属于行为变更，且「没有任何路径会写」这个否定命题无法在跨模块范围内被证明；它每轮每行约 25ns，留着当保险。


### 2026-11-09 选中代数做键轮次

账本第 5 节挂了很久的第一条待办：「把缓存键换成组选中代数」。先前只在 URLTest 场景做过剖析，本轮先对**全场景**做 CPU 剖析再动手：命中路径里 `groupDocKeyOf`（导出键所必需的实时选中读取）cum **69.5%**，其中 `outbound.(*Base).Name` 16.84% flat、`providerVersionsEqual` 15.44% flat。也就是说「只为确认没变而去解析当前选中」就是命中路径的主体。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `ProxyGroup` 增加 `SelectionVersion`：Selector 的选中就是它拨号用的那个，`setSelected`（`Set`/`ForceSet` 两个唯一入口）是其唯一写入口，计数完整；URLTest/Fallback 计数的是 `fixed` 钉选的变动（live 选中仍自行改选，不在计数内）；LoadBalance 无选中，报 0（与它 `Now()` 报空串同一范式） | `39ce557da` | `7a92f96a` | 见下一行 |
| wrapper 的 Selector 文档键改用「选中代数 + provider 版本」，不再解析当前选中；其余 kind 维持原样读自己文档写到的值 | -（仅 wrapper，含上一行） | `7a92f96a` | 交替运行两个编译产物（同窗口、n=8）：Selector 20 组 **-42.14%**、200 组 **-65.76%**、200 组+1000 节点 **-64.81%**（均 p=0.000）；urltest p=0.205、urltest+千节点 p=0.426、fallback p=0.442、loadbalance p=0.279，全部落在「同二进制自比」的 ±2.5% 伪影带内；geomean 5.97µ → 4.10µ **-31.37%**。wrapper 全量 + vet + focused race + 四平台 vet 通过；子模块 104 包全量通过 |

**第一次尝试被撤销并记录（勿重做）**：把 `selection uint64` 放进共享的 `groupDocKey`，键从 32 字节变 40 字节，结果每个 kind 的键比较都变慢——loadbalance +31.36%、urltest +13.51%、fallback +10.33%（n=8，p≤0.001），而 Selector 收益同样拿到（-41% ~ -67%）。计数器改为挂在槽位旁（`selectedAt uint64`，槽位仍是 144 字节、size class 不变）后回归消失。**教训：给所有 kind 共享的热结构加字段，即便只有一个 kind 用它，也要按「会不会改变结构大小/布局」来评估，不能只算自己那条路径。**

方法论备注：本轮先做了「同二进制对自己比」的对照实验（4 轮交替 benchstat，geomean +0.71%，个别场景 ±2.5% 且 p 可低至 0.021），本机噪声带因此有了实测依据，后续所有 A/B 都以它为准绳。


## 4. 当前验证矩阵

### 2026-11-09 验证矩阵（当前状态，父仓库 main `41616bd9` / 子模块 `39ce557da`）

| 验证项 | 命令 | 结果 |
|---|---|---|
| 子模块全量 | `go test ./... -count=1 -p=1`（Clash.Meta） | **104 包 ok，exit 0** |
| 子模块 vet | `go vet ./...`（Clash.Meta） | 通过 |
| wrapper 全量 | `go test ./... -count=1`（父仓库 core/） | **ok，coverage 82.8% of statements**（本轮起点 81.6%） |
| wrapper vet | `go vet ./...` | 通过 |
| wrapper 跨平台 vet | `GOOS=windows/linux/darwin/amd64` 与 `GOOS=android GOARCH=arm64` | 四个目标全部 exit 0 |
| focused race | `go test -race . -run 'TestGroupDoc|TestProxies|TestProxy|TestFrame|TestSpill|TestDispatched|TestConnection|TestRefreshRouteVersions|TestRouteStamp'`（CGO_ENABLED=1，mingw64 在 PATH） | 通过 |
| 全量 race | `go test . -race -count=1` | 仅 `TestRouteVersionsPollLeavesRuleSetsToTheirEvent` 失败——**基线代码上同样复现**（已单独验证：stash 本轮改动后跑同一用例仍报同一 DATA RACE），属既有问题，见第 7 节 |

**噪声带实测依据**（本轮新增，后续 A/B 准绳）：同一编译产物交替自比 4 轮，benchstat geomean +0.71%，个别场景差异 ±2.5% 且 p 可低至 0.021（loadbalance +2.34%，p=0.021）。因此本机「无差异」判定阈值取 p>0.2 或落在 ±2.5% 内；「有差异」判定沿用仓库规矩（p≤0.02 且幅度 ≥ 仓库认可量级）。

**本轮基准注意**：`BenchmarkHandleGetProxies` / `BenchmarkHandleGetProxiesMiss` 的配置名单已改为生产形态（全部代理名，见「名单按身份做键轮次」），其绝对数值与 2026-11-09 之前的行不可比；跨轮比较只能在本轮同基准内做 A/B。


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

### 待优化项清单（2026-11-07 全量复核，均在本机实测过基线）

| 位置 | 实测基线（JIT） | 结论 / 下一步 |
|---|---|---|
| 实时连接 feed 的 `[...snapshot.connections]..sort(start 倒序)` | 300 行约 11.5µs/更新，`renderThrottleDuration`(300ms) 限制最多约 3.3 次/秒 | **维持不做（2026-11-07 二次测量）**：provider 下沉整表重排已否决（见第 3 节）；换成“缓存排序结果 + 按行 map 查询重组”也要每行一次 map 查询重建输出列表（实测 `FixedList.updateByKey` 52ns/行，300 行约 15µs），与整表排序持平、无净收益。真正的剩余成本已变成每次刷新重建 20 行 ×8 列的 widget（行文字/形状与菜单本轮已优化），要再降只能自绘表格 |
| `RecordFacet.optionsOf`（剩余） | requests 页 500 行 ×3 个 offered facet：单值化 + 有界选取后约 49.5µs/次；rule 全去重场景 52.6µs/次 | 剩余是 map 计数本身（500 个不同字符串的哈希与插入，约 25µs）与选项终排。「同一列表实例跳过重算」不成立（三个调用点都由节流器在新数据到达时驱动，列表必然已变）；top-k 无法再近似，每个值都必须数到 |
| `RecordSorter.sort` 乱序路径 | 10000 行 ×1000 次同 `record_sorter_benchmark_test.dart`；`Expando` 缓存 sortKey 无效（见第 3 节） | 剩余可省的是 `order`+`sorted` 两个列表，需 in-place 置换且不能改调用方列表；上次尝试写反已回退，先写语义测试再上基准 |
| 打包 int64 键替代索引排序（`computeSort`） | 设想：把 (priority,delay,group,index) 打成单个 int64 用 `Int64List.sort()` 免比较器排序。scratch 配对实测（1000 节点 ×500 次，顺序与索引排序完全一致）：172.4µs → 169.4µs（-1.7%，噪声内） | JIT 下 `Int64List.sort()` 并未比 `List<int>.sort(comparator)` 快，比较器本身已不是瓶颈；撤销 |
| `computeSort` 延迟排序（剩余） | 1000 节点：叶子直取后约 280µs/次（此前 424µs，见第 2 节本轮落地行）；`order` 列表 + `List.sort` + 结果列表是余量 | 「已有序免排序」快路已存在；`order`+结果双列表要省需 in-place 置换且不能改调用方列表（上次尝试写反已回退），先写语义测试再上基准 |
| `fixed(decimals: 1)` 改整数路径（`traffic` 显示） | scratch 配对实测：141ns → 53ns（**-63%**），`dashboardTraffic` 176ns → ~88ns | **语义不等价，撤销**：200k 随机值 + 边界值对拍发现 3 处不一致——`0.15` 走 `toStringAsFixed(1)` 得 `0.1`，整数路径因 `0.15*10` 浮点向上进位得 `0.2`；`-0.0` 一边出 `-0` 一边出 `0`。显示的字节数不能为性能改变取值；若只在 `size == size.truncateToDouble()`（整除）时走整数路径则安全，但流量值多非整除、收益有限，未做 |
| 表格行单元格构建（`toUpperCase`、时长文本、`dashboardTraffic` 格式化与单元格 widget） | `test/widgets/row_cells_benchmark_test.dart` JIT n=5（500 行 ×500 次 `RecordTable.cellsOf`）：约 1.40µs/行，其中约一半是 `traffic`/`trackerDurationText` 的字符串格式化，约一半是单元格 widget；20 行可见表格每次刷新约 28µs | 单项拆分已到地板（样式缓存方案见第 3 节，已否决）。再降只剩两条路：按列声明「单元格读什么」做 per-column memo（counter-only 刷新跳过描述性列，约省 40%），或自绘表格 render object（无逐单元格 widget 树）；两者都要动 `RecordColumn`/`TableCells` 的公共 API，风险高于收益，先留基准 |
| `SpeedCard` 每帧对全部 speed 样本 fold 求 peak | 约 60 样本/帧 | 收益过小，记账备查 |
| core/Clash.Meta 侧 P1/P2/P4 | 见下文各小节 | DNS 负回复、本地 DNS serve 全链、UDP 首包均已实测否决或维持不做 |

### 待优化项清单（2026-11-08 核心轮次复核，均在本机实测过）

| 位置 | 实测基线 | 结论 / 下一步 |
|---|---|---|
| `getProxies` 答案的 `groupDocKeyOf` → `Now()` | 剖析：URLTest 场景答案路径 CPU 的约 25%（200 组 × ~90ns/答案） | **2026-11-09 已完结：Selector 场景 -42% ~ -66%，geomean -31.37%**（见「选中代数做键轮次」）。全场景剖析显示 `groupDocKeyOf` 从 69.5% 降到 56.7%；剩余两部分都判定为「必须做」：wrapper 自己的 provider 版本遍历（约 14%）是唯一能抓到「订阅刷新不重建代理表」的读取点，删不得；URLTest/Fallback 的 `Now()` 解析无法用计数器替代——它们的选中会随 fastSingle TTL 到期自行改选，计数器会滞后一个 TTL，UI 会显示过期选中态（这正是本轮只做 Selector 的原因：`setSelected` 是 Selector 选中的唯一写入口，计数完整；URLTest/Fallback 没有这个性质）。若将来要做，唯一正路是子模块提供「选中变更即通知」的主动失效钩子，而不是计数器 |
| `configuredTestTimeout`（`core/delay.go`） | 每次 delay 测试遍历全部 provider，并对每个返回 timeout 的 provider 线性扫成员（`slices.ContainsFunc(pd.Proxies(), …)`）；1000 节点 × N provider 时每次调用 O(providers × members) | 单次成本远小于 URLTest 网络往返，暂不动；若要改，按 `proxy.ProxyInfo().ProviderName` 直接定位 provider（语义差异：同名节点跨 provider 时只认隧道表里那一个，需先确认可接受） |
| `adapter.Proxy` 的 `extra` xsync.Map 读路径初始化 | `BenchmarkHandleGetProxies` 内存剖析：活对象的 30% 来自 `xsync.newMapTable[string,*internalProxyState]`，且**纯读取**（`AliveForTestUrl`/`LastDelayForTestUrl`）就会触发惰性建表 | 可加 `hasExtra atomic.Bool` 让纯读取不建表；但真实使用中节点都会被测速、表反正要建，收益有限，记账备查 |
| 连接轮询的 `row.stale(info)` 与 `Manager.Range` | 剖析：stale ~25ns/行；Range 桶遍历约占该基准采样的 10% | 要再降需要 `TrackerInfo` 侧提供元数据版本号（改动面覆盖全部元数据写入点），维持不做 |
| 连接 resync 答案的行级链路 | 剖析（500 行）：`TrackerInfo.AppendJSON` 约 74ns/行、行管理（Info/查表/stale）约 8ns/行、`rowAnswerSize` 仅占 2.5%，GC 占 45%（378KB/答案）；答案缓冲池化只在 spill 路径安全，而 resync 只发生在页面打开与漂移重同步，真实收益有限 | `rowAnswerSize` 不值得缓存；`stale` 与 `Manager.Range` 的再削减需要 `TrackerInfo` 元数据版本号或 xsync  relaxed 遍历（后者改变子模块共享语义），维持不做 |
| `handleGetExternalProviders` 答案 | 43.6µs/答案：逐条 `AppendString` 占 26%、每次答案全量排序占 19%； Dart 侧只在 provider 更新后 `syncProviders()` 调用 | 文档缓存要把 version/count/updateAt/subscription-info 五个易变值都纳入键（其中 subscription-info 是指向可变结构的指针），而该路径只在订阅刷新后跑一次，风险收益不相称，维持不做 |

### 待优化项清单（2026-11-09 复核新增：均已实测，定案如下）

| 位置 | 实测 | 结论 |
|---|---|---|
| `handleMethodCall` 里 `envelope(id)` 每次答案分配一个小缓冲 | 全场景 profile：`core.envelope` 占分配空间约 19%（增量轮询场景 ~105B/答案）；绝对量 30–150B/秒 | 不值得改。要消掉它必须让 `frame` 携带 id 字符串、在写入处才物化信封（改 frame 契约 6 处），而收益是每秒几十字节；且小帧路径本来就要把它拷进池化缓冲。维持现状 |
| `connectionRow.stale()` 十个字段比较 | 子模块 `NewTCPTracker` 用 `tt.metadata = *metadata` 值拷贝，`TrackerInfo.Metadata` 指向 tracker 自己的副本（`TestTrackerClonesMetadataIntoCreationSnapshot` 钉住）；全子模块对 `TrackerInfo.Metadata` 的写入只发生在构造期 | 生产线永不触发的防御代码（每行每轮 ~25ns）。**不删**：删除属行为变更，且「没有任何路径会写」这个否定命题无法在跨模块范围内被证明；留着当保险 |
| `requestTrafficWatch.collect` 每秒用 `Manager.Range` 遍历整张连接表只为标记存活 | 实测（wrapper 基准，n=3）：10 请求 780ns、100 请求 4.4µs、500 请求 26µs，**0 分配**（xsync 的 bentries 快照被逃逸分析放到栈上）；`Manager.Get` 每次要 `uuid.FromString` 解析，不更便宜 | 维持现状。绝对量 4.4µs/秒，无需改 |
| 仪表盘内存统计的 `runtime.ReadMemStats`（STW） | `BenchmarkReadMemStatsPause`（4000 代理堆）约 13µs/次；TTL 1s、宿主约 2s 轮询一次 | 维持现状。13µs 远低于 120Hz 的 8ms 帧预算（0.16%），换成 `runtime/metrics` 会改变指标语义，风险收益不相称 |
| `handleGetExternalProviders` 答案 54µs / 56KB（100 个 provider） | profile：`jsonutil.AppendString` 17.16% cum、排序 11.24% cum、GC ~15% | 维持不做（与 2026-11-08 结论一致）。该路径只在订阅刷新后跑一次，56KB 是答案本身的字节数 |
| profile 读档合并链路（startup） | `BenchmarkProfileReadAndMerge` 18.5–23.6ms / 3.47MB / 73k allocs；逐段剖析：YAML 词法/语法占非 I/O 部分的绝对主体，`cgocall` 51% 来自基准自身 StopTimer 外的 `os.WriteFile` | 维持不做。yaml.v3 主导，换解析器是语义级风险；此前轮次已从 IPv6 缓存等处拿到 -13.1% |
| 全仓库反模式扫描 | wrapper 与子模块的 `regexp.MustCompile` 全部在包级 var；字符串 `+=` 全部在一次性配置/握手路径（wireguard ipcConf、ssh 版本串、share_link） | 无可清理项 |

### 后续若要继续，唯一有实质收益的方向

子模块提供**选中/成员变更的主动失效钩子**（provider 版本变化、组选中变化、fast-node 改选时通知 wrapper），把 wrapper 每答案的 provider 版本遍历（约占命中路径 14%）也消掉。这是架构级改动：要覆盖 `updateExternalProvider`（不重建代理表的那条路）、四个组类型的选中变更、以及 LoadBalance 的无选中语义，且任何漏通知都会让 UI 显示过期选中态。做之前必须先有一张「变更点 × 通知点」的覆盖矩阵和对应的并发测试。


### 全代码复核覆盖面（2026-11-09，含平台层）

目标第 1 条要求复核全量代码。除 Go 侧（wrapper + 子模块，见第 2/3/5 节）外，本轮把平台层也过了一遍，结论如下，避免后续重复劳动。

| 范围 | 规模 | 复核结论 |
|---|---|---|
| `core/`（wrapper） | 60 文件 | 已逐文件过；热点路径全部实测并处置（见第 2、5 节）。反模式扫描：`regexp.MustCompile` 全在包级 var；`fmt.Sprintf` 全在冷路径；字符串 `+=` 仅 `share_link.go:157` 一处且在按需路径 |
| `core/Clash.Meta`（子模块） | 104 包 | 往轮次已覆盖；本轮新增 `ProxyGroup.SelectionVersion`。反模式扫描：无函数内正则编译 |
| `android/app` + `android/service` + `android/core` | Kotlin/Java 约 9K 行 | 无热点问题。`VpnService.resolvePackage` 按 uid 用 `ConcurrentHashMap` 缓存；`resolveUid` 直接委托系统；TUN fd `detachFd` 后交给 Go，Java 侧不在报文路径上。`NotificationModule` 2s 周期 + `distinctUntilChanged` + `collectLatest`，设计正确。`Traffic.getSpeedTrafficText` 用 Gson 反序列化一个小 payload，0.5Hz 量级，无需改 |
| `windows/runner` | C++ 约 3.4K 行 | Flutter 标准样板（win32_window / flutter_window / main / utils），无业务逻辑，无可优化项 |
| `linux/` + `macos/` | 约 3.1K 行 | 桌面壳层，同属样板量级，本轮未发现热点 |
| `services/` + `plugins/` | 约 3000 文件 | 内 vendor 第三方代码（sing-box 等），按仓库规矩不动 |
| Dart 接收路径（`lib/core/desktop/rpc_client.dart` 等） | - | 曾怀疑 `_handleFrame` 的 `Map<String, Object?>.from(decoded)` 每帧整表拷贝——**证伪**：它只拷顶层 2 个条目（id/result），庞大的 result 是引用传递。Dart 侧真正的大头是 `json` 解码本身（160KB 帧实测 874–1282µs），2026-11-05 已定案「融合进构建 isolate 最多省 ~0.5ms 却要改 RPC 契约」，维持不动 |

**结论**：核心（Go 侧）的优化空间已按实测挖到饱和；平台层无独立热点；剩余唯一有实质收益的方向见第 5 节末「主动失效钩子」。


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
- 2026-11-05 审计收口：首包剩余成本为 outbound `ListenPacketContext`（协议内部分配+网络）+ 每 flow 一个 `Process` goroutine（调度器属性）+ `context.WithTimeout`（stdlib）。逐包路径已 43ns/0 allocs（见测量记录）；"一级 fast path" 只能跳过拨号或复用 sender 生命周期，两者都改语义。维持不做。

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

- 2026-11-07 门禁修复（非性能）：`test/lint/prism_list_test.dart`、`test/lint/typography_test.dart` 在 Windows 上误报——`p.relative` 返回反斜杠，而豁免名单与 `_editorSizes` 都按正斜杠写。已按仓库既有写法（`design_package_test.dart`、`platform_layering_test.dart` 等本来就是 `p.relative(...).replaceAll('\', '/')`）统一规范化；`test/lint/dead_file_test.dart` 的 `path.startsWith('lib/')` 在 Windows 上恒为 false、整个测试被跳过，也一并改为规范化后比较，Windows 上首次真正生效（实测无孤儿文件）。Linux 上这些替换均为 no-op，CI 行为不变。
- `miekg/dns` 的 `ClientExchangeUDP` 中 `Context.AfterFunc` 每次分配一个 stop 闭包；单独优化收益小，建议与 P1 一起重构。
- 首次全量验证中 `TestInboundVMess_Mekya` 曾出现偶发 `unexpected EOF / closed pipe`；隔离复跑和后续全量均通过，尚不是稳定失败。
- 任务缓存清理工具此前被执行器安全策略拦截，`D:\Codex\tmp` 下仍有 benchmark/profile 缓存目录；继续前可按任务名确认是否可清理。
- `sqlite3` v3.7.0 的 Windows 原生资产钩子会失败：GitHub release `sqlite3-3.7.0` 的 `sqlite3.x64.windows.dll` 已于 2026-09-30 重新上传（官方 API 摘要 `98b4be67...`），与包内 `asset_hashes.dart` 钉住的 `3a29878d...` 不一致。已在本地 pub 缓存（`D:\Codex\tools\pub-cache-task`）按 GitHub 官方摘要修正该哈希；上游发布新版本前这是环境级阻塞。跑 `dart run tool/test.dart` 还需 `PUB_CACHE=D:\Codex\tools\pub-cache-task`，并把 Flutter 与 Go 的 bin 放进 PATH（`setup` 包的构建钩子要调 `go`）。
- 本轮 `dart run tool/test.dart` 的 32 个 bundle 里有 2 个用例失败，单独重跑同一批文件全部通过（bundle 共享 isolate 的跨文件干扰）；工具的结论是退出码 0。Dart 侧本轮零改动。
- 2026-11-08 在本机复核 `dart run tool/test.dart`：5 个用例失败，且在提交 `3788368c`（本轮改动之前）上同样失败，属既有问题、与 Go 改动无关——`test/common/mitm_trust_test.dart` 的 4 个 `Linux ...` 用例没有 `@TestOn` 限定，在 Windows 上必然失败；`test/common/window_test.dart` 的「an unsupported probe is retried the next time blur is on」期望 4 次平台调用、Windows 实测 3 次。另有一次 `test/providers/clash_providers_action_test.dart`「a set changed while it downloads drops the download of the url it no longer has」在 bundle 里失败、单独重跑 32 个用例全过（既有的 bundle 共享 isolate 跨文件干扰）。其余全部通过。若要在本机跑绿，需给前者加平台注解、后者按平台分支期望
- 2026-11-09 在 wrapper 上跑 `go test . -race -count=1`：`TestRouteVersionsPollLeavesRuleSetsToTheirEvent` 报 DATA RACE 并失败，竞争发生在 `recordRoutes` 的测试清理写与 `routeRefreshWorker` 到 `applyRouteSnapshot` 的写之间（`core/route_test.go` 与 `core/route.go`）。已在基线代码上复现同样竞争与失败，属既有问题，与 2026-11-09 答案传输层重构无关；要修它得给路由刷新 worker 与测试清理约定同一把锁，留作后续独立议题。
