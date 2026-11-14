# 性能优化账本

本文记录 FlClash 主仓库与 `core/Clash.Meta` 子模块的性能优化成果、验证结果、已拒绝方案和后续切入点。后续继续优化时，先读本文，再按当前工作区重新测量，不要直接复用旧数据当作当前结论。

- 最近核对日期：2026-11-11 深夜（晚间接续会话，全部本机实测）：连接轮询稳态免扫描一轮（500 连接 32.78µs -> 371ns，-98.87%；stale 十字段与十个镜像字段整段删除）；Dart 侧连接排序一轮（1 万行每快照 10.4ms -> ~4.19ms，-60.7%，三张 per-poll 字符串 map 合并为一张状态表）；UDP 数据报主路径覆盖一轮（tunnel 76.5% -> 82.7%，processUDP/startUDPSender/dialUDPSender 从 0/0/50% 到 100/100/89.6%）；wrapper IPC 入口覆盖一轮（StartServer 走真实命名管道，93.7% -> 93.9%）；死代码清扫一轮（staticcheck 名下未用测试 helper 与两处死赋值）；另有三项实测否决记账（feed flush 归属拆解、GOGC 策略、连接 churn 增量日志）
- FlClash main：`83477313`
- Clash.Meta main：`bbf113d6f`
- 深夜会话后半程（全部本机实测）：时间戳改纪元微秒一轮（wire 端到端契约变更，到达路径 10.25ms -> 3.06ms），该轮曾把 Go 门禁弄红（gofmt 三文件 + 四个测试文件仍在传 time.Time），已修复；Log 到达免格式化一轮（3.06ms -> 0.98ms）；到达路径批量轮次（信封手写解码 -69%、log 读入 -77%、端到端配对 -10%/min -26%）；连接行解码轮次（行读入 -29%）；融合帧读取轮次（到达路径 median -33%、min -40%）；连接环索引轮次（满环 append -79%，feed flush -16%，修一处 newest-row 丢键 bug）
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

本轮从 wrapper/子模块 benchmark 地图重新测量，找出并落地五十项优化；审计中确认过但**未**改动的位置见本节末尾。加上 2026-11-04 后的持续重构轮次与 2026-11-08 核心答案路径轮次，账本当前共 138 项。

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
| 延迟排序状态与触发收敛 | - | `83477313` | 恢复超时/其他失败/未测试的旧优先级，并在同延迟时把嵌套分组排在叶子前；删除无调用的 debounce 入口和已无使用方的 `DelayState`。同时移除延迟测试完成后的重复 `sortNum -> updateGroups` 全量 Core 拉取，完成批次只做一次本地排序。`computeSort`、`sortGroupsTask`、`app_manager`、`proxies_action` 118 个测试与 Dart analyze 全绿 |

### 2026-11-07 持续重构轮次

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| DNS 服务器引用无 `%` 免解码 + fragment 免 split 列表 | -（仅 wrapper） | `83477313` | `_decodedOrSelf` 先查 `contains('%')`，无百分号直接返回；fragment 解码后按 code unit 扫描 `&`，不再为常见单段 fragment 分配 `split` 列表。`test/models/references_benchmark_test.dart` JIT n=11（100k 个 `ts://...#dialer`）：基线均值 52.98ms/中位 53.37ms → 均值 43.64ms/中位 42.84ms（均值 **-17.65%**，中位 **-19.73%**，单次调用 0.530µs → 0.428µs 量级）；`test/models/references_test.dart`、`test/manager/core_manager_test.dart`、`dart analyze --fatal-infos` 全绿 |
| Rule payloadError 结果缓存 | -（仅 wrapper） | `83477313` | `Rule` 不可变，`payloadError` 结果按对象缓存；用 `Expando<Object>` + `_noRulePayloadError` sentinel 区分“合法未报错”和“未缓存”，避免 `Expando<RulePayloadError?>` 的 null 语义。`test/models/rule_benchmark_test.dart` JIT n=7（100k 次合法 `DST_PORT`）：均值 34.19ms / 中位 34.16ms → 均值 6.28ms / 中位 6.27ms（**-81.64%**），单次调用 0.342µs → 0.063µs；`test/models/rule_test.dart`、`test/features/custom_rule_form_test.dart`、`test/features/rule_dialog_test.dart`、`test/providers/custom_state_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| TrackerSpeedRanker 索引缓冲改 32 位并复用 positions map | -（仅 wrapper） | `83477313` | rank/order/bucket/cursor/head/tail/next 索引全部落在 int32，`traffic` 保留 Int64 以容纳累计字节；`_positions` 从每次新建 map 改为复用 clear，empty 分支同步清理。`test/features/tracker_speed_ranker_benchmark_test.dart` JIT n=7（10k 连接 ×20 snapshot）：均值 9.23ms → 8.29ms（**-10.16%**），中位 9.43ms → 8.32ms（**-11.80%**）；`test/features/tracker_speed_ranker_test.dart`、`test/views/connections_test.dart`、`test/views/dashboard/connections_table_test.dart`、`test/widgets/connection_item_test.dart`、`test/widgets/connections_view_test.dart`、`test/views/dashboard/connection_stats_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| DNS 查询搜索文本按对象缓存 | -（仅 wrapper） | `83477313` | `DnsQueriesState.list` 给 `whereMatches` 传入 `Expando<String>`，和 `TrackerInfosState` 一致；`DnsQuery` 不可变，query state 每次键入都换对象，但 DNS 查询对象保持在缓存中命中，不再为每次过滤重建 `searchFields` 并 join/lower。新增 `test/models/dns_query_search_benchmark_test.dart`：JIT n=7（10k DNS 查询 ×50 次过滤）：均值 312.62ms → 73.41ms（**-76.51%**），中位 310.15ms → 73.18ms（**-76.41%**）；`test/views/dns_queries_view_test.dart`、`test/views/dns_view_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| DNS 查询标签字段单列表产出 | -（仅 wrapper） | `83477313` | `_appendTags` 直接向目标列表追加 type/initiator/cache/rcode；`tags` 与 `searchFields` 共用它，`searchFields` 不再展开 `tags` 列表，首轮过滤每行只建一个结果列表，`resultFilters` 仍保留给 facet。`test/models/dns_query_cold_search_benchmark_test.dart`（首次见到的查询，30×3k）JIT n=7：基线均值 139.71ms/中位 136.54ms → 均值 129.45ms/中位 128.93ms（均值 **-7.34%**，中位 **-5.57%**）；`test/views/dns_queries_view_test.dart`、`test/views/dns_view_test.dart`、`test/common/filter_test.dart`、`test/models/dns_override_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| 延迟排序预打包优先级/分组位 | -（仅 wrapper） | `83477313` | `computeSort` 的延迟比较不再每次调用 `_delaySortPriority`，预先把「低 2 位优先级 + 分组位」打进一个 `Uint8List`；排序/有序检查只做位读取。新增 `test/common/compute_sort_delay_benchmark_test.dart`：JIT n=7（1000 节点 ×100 次排序）均值 45.81ms/中位 45.37ms → 均值 44.29ms/中位 43.93ms（均值 **-3.31%**，中位 **-3.18%**）；`test/common/compute_test.dart` 37 个用例与 `dart analyze --fatal-infos` 全绿 |
| 无调用延迟失效入口清理 | -（仅 wrapper） | `83477313` | 删除无调用方的 `ProxiesAction.invalidateDelayTests()`、随之无调用方的 `Preferences.clearDelayMap()` 与只覆盖该方法的测试；延迟持久化仍由保存链路和启动恢复走。`test/common/preferences_test.dart`、`test/providers/proxies_action_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| Group 成员名单缓存 | -（仅 wrapper） | `83477313` | `_isMember` 不再每次 `all.any` 线性扫成员；`Group` 不变，成员名按对象缓存为 `Set<String>`，空组仍直接通过。新增 `test/models/group_selected_member_benchmark_test.dart`：JIT n=7（1000 成员 ×10000 次选中判定）均值 63.75ms/中位 63.83ms → 均值 13.05ms/中位 12.88ms（均值 **-79.52%**，中位 **-79.82%**）；`test/common/compute_test.dart`、`test/providers/proxies_action_test.dart`、`test/views/proxies_list_test.dart`、`test/widgets/proxies_list_test.dart`、`test/widgets/proxies_tab_test.dart`、`test/views/dashboard/proxy_groups_card_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| `showFull` 固定字段拼接 + 本地时间快路径 | -（仅 wrapper） | `83477313` | `showFull` 不再 `toLocal().toString().substring(0,19)`，改为对本地/UTC 时间手工按字段 `padLeft` 拼接；已是本地时间的日志不再触发 `toLocal()` 包装。新增 `test/common/datetime_show_full_benchmark_test.dart`（UTC 1,000,000 次）与 `test/core/event_dispatch_benchmark_test.dart`（本地日志事件）：JIT n=7 隔离基准均值 4.41ms/中位 4.40ms → 4.25ms/4.26ms（均值 **-3.67%**，中位 **-3.32%**），事件 log dispatch 均值 5.187µs/中位 5.181µs → 5.023µs/5.014µs（均值 **-3.16%**，中位 **-3.22%**）；`test/common/datetime_test.dart`、`test/core/event_test.dart`、`test/widgets/connection_item_test.dart`、`test/views/requests_test.dart`、`test/views/dns_queries_view_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| `show`/`showTime` 固定字段拼接 + 本地时间快路径 | -（仅 wrapper） | `83477313` | `show`/`showTime` 不再 `toLocal().toString().substring(...)`，改为手工拼日期和 ` HH:mm:ss`；已是本地时间不再触发 `toLocal()`。新增 `test/common/datetime_slices_benchmark_test.dart`：JIT n=7（local+UTC 的 show/showTime 共 4,000,000 次）均值 9.43ms/中位 9.38ms → 均值 8.55ms/中位 8.56ms（均值 **-9.29%**，中位 **-8.72%**）；`test/common/datetime_test.dart`、`test/widgets/connection_item_test.dart`、`test/views/requests_test.dart`、`test/views/dns_queries_view_test.dart`、`test/views/dashboard/service_status_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| 托盘超大组选中项缓存索引 | -（仅 wrapper） | `83477313` | `visibleTrayProxies` 不再每组线性扫全部节点找选中；超大组按 `Group` 缓存 name->Proxy 索引（后出现同名覆盖，保持原逻辑），只取前 `maxTrayProxiesPerGroup`（有选中则给选中留位）。`test/common/visible_tray_benchmark_test.dart` JIT n=7（5000 节点 ×20000 次）：perCallUs 均值 54.14 / 中位 54 → 1 / 1（该基准按整数 µs 输出，降幅按该分辨率约 **-98%**；实际已远低于 1µs 量级）；`test/common/compute_test.dart`、`test/common/tray_test.dart`、`test/common/tray_lifecycle_test.dart`、`test/manager/tray_manager_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| 超大组选中节点解析改成员名缓存 | -（仅 wrapper） | `83477313` | `Group` 新增 `containsMemberName`，`selectedProxyName` 不再为了判断 selected/live/stored 各自扫全组；组成员名沿用已有 `Expando<Set<String>>`（空组仍 false，`_isMember` 的空组语义不变）。新增 `test/providers/selected_proxy_name_benchmark_test.dart`：JIT n=7（2000 节点 ×2000 次 refresh）总耗时均值 281.50ms/中位 283.28ms → 209.11ms/208.83ms（均值 **-25.72%**，中位 **-26.28%**）；`test/providers/state_derived_test.dart`、`test/providers/proxies_action_test.dart`、`test/widgets/proxies_list_test.dart`、`test/widgets/proxies_tab_test.dart`、`test/views/proxies_list_test.dart`、`test/views/dashboard/proxy_groups_card_test.dart`、`test/common/compute_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| keyed 列表批量出队索引前移 | -（仅 wrapper） | `83477313` | `FixedList._dropIndexedHead` 不再对该 map 同时 `removeWhere` + `updateAll` 两个回调遍历，改为一次 `entries` 遍历：收集越界 key、原地前移剩余 index，最后删除越界 key。`test/common/fixed_append_benchmark_test.dart` 新增 keyed 场景（1600×120，20000 批）：JIT n=7 perBatchUs 均值 12.86/中位 13 → 均值 11.29/中位 11（均值 **-12.21%**，中位 **-15.38%**）；`test/common/fixed_test.dart`、`test/providers/app_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| `Rule.rawValue` 按对象缓存 raw 字符串 | -（仅 wrapper） | `83477313` | `Rule` 不可变，`rawValue` 用 `Expando<String>` 按对象缓存；仍拆出 `_rawValue` 保留原序列化逻辑，`searchFields`/编码/解码都复用同一字符串。新增 `test/models/rule_raw_value_benchmark_test.dart`：JIT n=7（100000 次 `DOMAIN-SUFFIX,example.com,DIRECT,no-resolve`）均值 29.34ms/中位 29.32ms → 4.00ms/3.94ms（均值 **-86.37%**，中位 **-86.55%**）；`test/models/rule_test.dart`、`test/features/custom_rule_form_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| 排序无变化时免建组表 | -（仅 wrapper） | `83477313` | `_sortGroups` 不再先整表复制再全表比较；逐个组计算下一个组，只有真正变化时才懒拷 `List.of(groups)` 并覆盖该下标，无变化直接返回原表。删除只服务旧实现的 `_sameGroups`。`test/common/compute_sort_delay_benchmark_test.dart` 新增已有序场景：JIT n=7（100 组 ×1000 次）均值 34.32ms/中位 33.95ms → 31.65ms/31.49ms（均值 **-7.80%**，中位 **-7.25%**）；`test/common/compute_test.dart` 现有“无变化保持组实例身份/重复排序保持 identity”全绿，`test/providers/proxies_action_test.dart` 与 `dart analyze --fatal-infos` 通过 |
| 已有序表格免建 order/结果列表 | -（仅 wrapper） | `83477313` | `RecordSorter.sort` 在生成 `keys` 后先按方向判断当前显示顺序是否已有序；已有序直接把原 items 作为排序结果并写入缓存，不再生成 `order` 和 `sorted` 两个列表，`reverse` 场景同样成立。新增 `test/widgets/record_sorter_benchmark_test.dart` 与恢复 `test/widgets/record_table_test.dart` 行为测试：JIT n=7（10000 行 ×1000 次已有序）均值 1007.75ms/中位 1006.95ms → 185.98ms/185.36ms（均值 **-81.54%**，中位 **-81.59%**）；`test/widgets/record_table_test.dart`、`test/views/dashboard/connection_stats_test.dart`、`test/widgets/connections_view_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| 反向表格排序直接排源列表 | -（仅 wrapper） | `83477313` | `reverse` 时不再生成 `items.reversed` 显示列表，再排序后二次 `reversed` 回源列表；改为对 `items` 直接排序并把方向取反，已有序检查也改成从尾部向前比较。新增反向乱序基准：JIT n=7（10000 行 ×1000 次 reverse 乱序）均值 2676.83ms/中位 2689.97ms → 2340.38ms/2327.76ms（均值 **-12.57%**，中位 **-13.47%**）；`test/widgets/record_table_test.dart` 新增“反向未有序时源列表反向排序”“升降序覆盖”，`test/views/dashboard/connection_stats_test.dart`、`test/widgets/connections_view_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| 隐藏超时节点选中判断改缓存 | -（仅 wrapper） | `83477313` | `computeHideTimeout` 的 `_coreSelectedName` 不再每条组两次 `group.all.any` 线性扫成员；改用已有 `Group.containsMemberName` 成员名缓存。新增 `test/common/compute_hide_timeout_benchmark_test.dart`：JIT n=7（2000 节点健康组 ×100 次）均值 59.02ms/中位 60.00ms → 53.24ms/53.23ms（均值 **-9.79%**，中位 **-11.28%**）；`test/common/compute_test.dart`、`test/providers/proxies_action_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| 隐藏超时节点无隐藏时免建可见列表/结果组表 | -（仅 wrapper） | `83477313` | `computeHideTimeout` 不再先用 `where().toList()` 建可见列表再比较；只在第一次遇到被隐藏节点时才懒拷前面的可见节点，全可见直接返回原组。结果组表同样懒拷，仅实际变化的组才拷贝 `List.of(groups)`。同基准 JIT n=7：均值 53.24ms/中位 53.23ms → 47.06ms/46.86ms（均值 **-11.61%**，中位 **-11.98%**）；`test/common/compute_test.dart` 新增“一个组隐藏节点时其他组保持实例身份”，38 个用例全绿，`test/providers/proxies_action_test.dart` 与 `dart analyze --fatal-infos` 通过。
| 无分隔符字符串 split 惰性分配 | -（仅 wrapper） | `83477313` | `StringExtension.splitByMultipleSeparators` 不再先分配空 `parts` 列表；仅在遇到第一个分隔符时才创建，单值字符串直接返回自身。`test/common/string_benchmark_test.dart` 新增单值场景：JIT n=7（100000 个 server）均值 16.373ms/中位 15.929ms → 13.600ms/13.608ms（均值 **-16.94%**，中位 **-14.57%**，单次调用 0.164µs → 0.136µs）；`test/common/string_test.dart` 既有 40 个 split/getBase64/url 用例全绿，`test/models/references_test.dart` 与 `dart analyze --fatal-infos` 通过 |
| SVG 类型判断免 URI 解析/整串 lowercase | -（仅 wrapper） | `83477313` | `StringExtension.isSvg` 对非 data URI 不再 `Uri.tryParse(path).toLowerCase().endsWith`；改为按 query/fragment 切出路径尾部，直接定位最后一个 `.` 并按 codeUnit 大小写不敏感比较 `svg`。`test/common/string_benchmark_test.dart` 新增 SVG URL 场景：JIT n=7（100000 个带 `?v=` 的 CDN 图标 URL）均值 41.875ms/中位 42.172ms → 9.582ms/9.692ms（均值 **-77.12%**，中位 **-77.02%**，单次调用 0.419µs → 0.096µs）；`test/common/string_test.dart`、`test/views/icon_picker_view_test.dart`、`test/widgets/target_icon_test.dart`、`test/providers/icon_sets_action_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| 图标名匹配不再拷贝名字列表、压缩名按对象缓存 | -（仅 wrapper） | `83477313` | `matchIconNames` 改收 `List<IconSetIcon>`，图标选择器不再为每次键入把整个图标表拷成 `List<String>`；`IconSetIcon.compactName` 按对象缓存 `fileStem` 的压缩结果，主线程重复匹配时不再对每张图重复 `toLowerCase + replaceAll`；isolate 输入也直接发图标对象。新增 `test/models/icon_name_match_benchmark_test.dart`：JIT n=7（5000 图标 ×100 次匹配+排序）均值 284.00ms/中位 283.59ms → 54.75ms/54.75ms（均值 **-80.72%**，中位 **-80.69%**，单次匹配排序 2.84ms → 0.547ms）；新增 `test/models/icon_name_match_test.dart` 覆盖评分、忽略无拉丁名字符、按 URL 去重排序，`test/views/icon_picker_view_test.dart`、`test/widgets/target_icon_test.dart`、`test/providers/icon_sets_action_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| 图标名压缩 codeUnit 直筛 | -（仅 wrapper） | `83477313` | `_compactIconName` 不再 `toLowerCase().replaceAll(RegExp)`；先扫描 codeUnit 记录是否有大写/非字母数字，无字符直接返回空串、全小写字母数字直接返回原串，否则用 `StringBuffer` 只追加小写 ASCII 字母和数字。新增 `test/models/icon_name_cold_match_benchmark_test.dart`：JIT n=7（5000 个新对象 ×100 次冷匹配）均值 492.74ms/中位 479.50ms → 401.28ms/393.45ms（均值 **-18.56%**，中位 **-17.96%**，单次 4.927ms → 4.013ms）；`test/models/icon_name_match_test.dart`、`test/views/icon_picker_view_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| 延迟/隐藏超时：`delayMap[testUrl]` 提到组外 | -（仅 wrapper） | `83477313` | `computeHideTimeout` 与 `computeSort.sortOfDelay` 都在**每个代理**的内层循环里查 `delayMap[testUrl]`，而该 url 在整个组内不变。提到组层级后每节点少一次 map 查询。交替配对 n=3（同时把两个 benchmark 的 warm-up 从 5 次提到 50 次，旧 warm-up 下测量不稳、曾出现 before 34ms/15ms 这类抖动）：`computeHideTimeout` 2000 节点 12473µs → 9172µs（**-26.5%**），`computeSort` 1000 节点 18509µs → 17579µs（**-5.0%**）。注意：此前几轮这两个 benchmark 的**绝对数**偏大（warm-up 不足），相对结论不受影响 |
| 延迟测试目标解析：叶子直取 | -（仅 wrapper） | `83477313` | `_resolveDelayTestTargets` 与 `computeSort`/`computeHideTimeout` 同一处病灶：对每个待测代理都 `computeRealSelectedProxyState`，而叶子解析恒等于自身。新增 `test/common/real_selected_state_benchmark_test.dart`（n=5）：解析形状 113.3µs/1000 叶子（113ns/个）→ 只查 `groupsByName` 的叶子路径 28.15µs/1000（28ns/个），**-75.1%**；一次 2000 节点全量测速约少 225µs UI 线程工作。`test/providers/proxies_action_test.dart` 新增用例：外层组里嵌一个组时，测外层组会按**嵌套组自己的** testUrl 探测它的选中节点（而不是把组名当叶子、用默认 URL 探测），45 个用例全绿 |
| 延迟排序：叶子节点不再做无效的选中态解析 | -（仅 wrapper） | `83477313` | 与「隐藏超时节点」同一处病灶：`computeSort` 的 `sortOfDelay` 对每个代理都 `realStateFor(name)`，而对非组代理该解析恒等于自身（`testUrl` 为 null、`group` 为 false）。改为先查 `groupsByName[name]`，叶子直接 `delayMap[testUrl][name] ?? 0` 且不置组标志；只有真正的组才走解析链。<br>**测量必须逐用例隔离**：合并同一进程跑两个用例时，前一个重用例的 GC 让后一个用例假性 +2.4%（与上一轮假 +12% 同一陷阱）；隔离交替 n=3：1000 节点延迟排序 42378µs → 28001µs（**-33.9%**），100 组已有序小场景 34030µs → 23983µs（**-29.5%**）。`test/common/compute_test.dart` 新增嵌套组用例：内层组按其自身 testUrl 的延迟参与排序（用错 URL 会排错序，能区分），40 个用例全绿 |
| 隐藏超时节点：叶子节点不再做无效的选中态解析 | -（仅 wrapper） | `83477313` | `computeHideTimeout` 对每个**非组**代理都调 `computeRealSelectedProxyState`，而函数开头已经用 `groupsByName.containsKey(proxy.name)` 提前放行了组；对叶子节点该解析恒等于自身（`testUrl` 为 null、`proxyName` 不变），等于每行白建一个 `SelectedProxyState` + 两次 map 操作。删掉这段后叶子节点直接查 `proxyTypes[proxy.name]` 与 `delayMap[groupTestUrl][proxy.name]`；顺带把 `takeFirstValid` 的双重 `trim` 改成一次、把每行的 fallback 列表提到组外。`test/common/compute_hide_timeout_benchmark_test.dart`：2000 节点从 50290/48769/48465/49684/48767µs（均值 49195µs/100 次）→ 17183/14833/14356/14748/14850µs（均值 15194µs/100 次），即 **490µs → 152µs/次（-69.0%）**；`test/common/compute_test.dart` 新增嵌套组用例钉住语义（外层按默认测试 URL 隐藏、内层按自身 testUrl 隐藏、组本身保留），39 个用例全绿 |
| 筛选菜单选项：有界选取替代全量排序 | -（仅 wrapper） | `83477313` | `optionsOf` 原先把 facet 的**全部**去重值按出现次数整表 `sorted` 再取前 12，而请求表的 rule facet 在真实流量下去重值可达数百个。改为有界插入选取（只维护 12 个槽位的有序表）；去重值不超过 12 时直接返回全部——选项随后仍按 rank/名称排序，按次数排序本是白做。`test/models/facet_options_benchmark_test.dart` 新增 "全去重" 场景，交替配对 n=3（每轮新进程、单用例隔离）：rule 全去重 64.52µs → 52.57µs（**-18.5%**），3 个 offered facet 53.12µs → 49.53µs（**-6.8%**）。测量教训：同一进程里先跑重用例会把 GC 带给后一个用例（曾量出假 +12% 回退），这类配对必须逐用例隔离 |
| 筛选分词：单值 facet 计数不再每行建列表 | -（仅 wrapper） | `83477313` | `RecordFacet` 原来只有一个 `valuesOf`（返回 `Iterable`），单值 facet 也得`[value]` 每行建一个列表。拆成 `valuesOf`（多值）与 `valueOf`（单值）两种构造，计数走 `countInto`、过滤走 `matches`，调用点不变；`trackerInfoFacets` 的 network/rule/mitm/app、`logFacets` 的 level、`dnsQueryFacets` 的 type 都是单值。新增 `test/models/facet_options_benchmark_test.dart`：JIT n=7（500 行 ×3 个 offered facet 的 optionsOf）均值 72.75µs/中位 72.60µs → 52.68µs/52.91µs（**-27.6%** / **-27.1%**，每次 offer 省约 20µs；请求页 1~3 次/秒）。`test/models/record_filter_test.dart` 新增语义用例：单值构造与多值构造在 optionsOf/whereFilters 上结果一致、多值 facet 逐个计数、空值照旧剔除 |
| 表格行文字样式与形状按表解析一次 | -（仅 wrapper） | `83477313` | `RecordTableRow.build` 原来每一行都 `AppTextStyle.subheadline.of(context)` + `copyWith` + `AppShape.all(AppCorner.fit(rowHeight))`，实测合计 1.78µs/行（20 行的表格每次刷新约 36µs）。`RecordTable` 新增 `rowTextStyle`/`rowShape`，在 `_tableOf`（已按 width/columnWidths/rowHeight/locale/theme memo）里解析一次，行只读；仪表盘卡片表格同样把 `AppTextStyle.footnote.of(context)` 提到行构建之外。新增 `test/widgets/row_style_benchmark_test.dart`：JIT n=5（每行文字+形状解析）1.686~1.843µs（均值 1.781µs、中位 1.781µs）→ 0.0009µs；`test/widgets/record_table_test.dart` 新增用例：只换数据、宽度与主题不变时 `RecordTable` 是同一实例（文字与形状不重算）；focused 7 个文件共 52 个用例与 `dart analyze --fatal-infos` 全绿 |
| 表格行菜单按行内容缓存 | -（仅 wrapper） | `83477313` | `trackerInfoMenuItems` 原来给每个可见行每次重建都构造一次菜单（实测 979ns/行），但表格行重建来自计数器变化，菜单并不读它。新增 `CachedMenu`（`lib/widgets/cached_menu.dart`）：`ContextMenuRegion` 要的菜单列表由它按自己声明的 inputs 持有，只在 `didChangeDependencies`（本地化变化）或 inputs 变化时重建，child 每次照常重建、行为与之前逐像素一致。`TrackerInfoTableRow` 传 `[trackerInfo.metadata, onClose]`，`copyWith` 保留同一 metadata 实例、`_closeConnection` tear-off 相等，所以 counter-only 更新命中缓存。新增 `test/widgets/cached_menu_benchmark_test.dart`：JIT n=7（500 行 ×2000 次）rebuild 均值 489.3µs/中位 484.45µs → held 均值 7.89µs/中位 7.98µs（**-98.4%**，单行 979ns → 16ns）；`test/widgets/cached_menu_test.dart` 用 identical 钉住「重建后是同一个菜单实例、inputs 变化才换菜单」；`test/views/connections_test.dart` 既有「从行菜单关闭连接」用例覆盖真实集成路径，focused 6 个文件共 57 个用例与 `dart analyze --fatal-infos` 全绿。列表态行本就被 `MemoBuilder` 的描述性 inputs 挡住，无需此包装 |
| UTC 时间戳的本地读取与渲染文本按对象缓存 | -（仅 wrapper） | `83477313` | Core 的时间戳全是 UTC（`DateTime.parse` 解析带 Z 的 ISO 串），请求表/DNS 表的 time 列每个可见行每次重建都要重新 `toLocal()` + 拼串。`localMoment` 缓存 UTC 时刻的本地读数，`show`/`showFull`/`showTime` 一并缓存本地时刻渲染出的文本（本地时刻仍直接渲染，日志那条一次性路径不受影响）。新增 `test/common/datetime_local_moment_benchmark_test.dart`：JIT n=7（500 行 ×2000 次 `showTime`）均值 2208.7µs/中位 2213.25µs → 18.0µs/18.0µs（**-99.2%**，单行 4.42µs → 0.036µs）；`test/common/datetime_test.dart` 新增 5 个用例（UTC 渲染等于其本地读数渲染、本地时刻原样返回、重复读取返回同一实例、相邻一秒不是同一文本），focused 7 个文件共 75 个用例与 `dart analyze --fatal-infos` 全绿 |
| 卡片表格列集合按宽度+locale 复用 | -（仅 wrapper） | `83477313` | `recordTableColumns` 抽出（columns/layouts/widths 一次算完，`RecordTableFrame._tableOf` 与仪表盘卡片表格共用，消掉两处重复的同一段逻辑），三个列构建函数改收 `AppLocalizations` 而非 `BuildContext`，卡片表格按 (availableWidth, columnWidths, locale) 缓存列集合，重建只付一次元组比较。新增 `test/widgets/record_table_columns_benchmark_test.dart`：JIT n=7（8 列，宽 1000，20000 次）rebuild 均值 5.58µs/中位 5.60µs → memo 命中 0.026µs/0.026µs（**-99.5%**，每次重建省约 5.6µs）；`test/widgets/record_table_test.dart` 新增 2 个 `recordTableColumns` 用例（flex 分配、拖拽宽度生效），`test/views/dashboard/connections_table_test.dart` 抽出 `pumpLiveCard` 助手把三段重复的 mock 设置收敛，新增「列标签跟随 locale」用例（en→zh：Download→下载，行与 TCP/UDP 计数不变）；`test/views/connections_test.dart`、`test/views/requests_test.dart`、`test/features/tracker_info_list_test.dart`、`test/views/dashboard/connection_stats_test.dart`、`test/widgets/connections_view_test.dart`、`test/views/dashboard/feed_sheet_test.dart` 共 64 个用例与 `dart analyze --fatal-infos` 全绿 |
| TrackerInfo 行文本按对象缓存 | -（仅 wrapper） | `83477313` | `ruleText`/`progressText` 改为按对象 `Expando<String>` 缓存（`TrackerInfo` 不可变，字段固定）：分组表每次刷新对全部行调 `keyOf`、表格单元格与搜索都要重建这两个字符串。新增 `test/models/tracker_info_text_benchmark_test.dart`：JIT n=7（500 行 ×2000 次）`ruleText` 均值 35.98µs/中位 35.87µs → 12.54µs/12.34µs（**-65.2%**），`progressText` 均值 47.36µs/中位 47.32µs → 14.82µs/14.81µs（**-68.7%**）；`test/models/common_test.dart` 新增“不同对象各自缓存”用例，`test/features/tracker_info_list_test.dart`、`test/models/record_filter_test.dart`、`test/features/filter_test.dart`、`test/features/tracker_speed_ranker_test.dart`、`test/views/requests_test.dart`、`test/views/connections_test.dart` 共 73 个用例与 `dart analyze --fatal-infos` 全绿 |
| 实时连接表协议统计免 lowercase 拷贝 | -（仅 wrapper） | `83477313` | `liveProtocolSplit` 抽出为顶层函数并改用 `StringExtension.equalsIgnoreCase`：先比长度，再逐 codeUnit 做 ASCII 大小写不敏感比较，不再为每行 `metadata.network.toLowerCase()` 分配字符串；feed 仍保持原有 copy+sort。新增 `test/views/dashboard/connections_feed_benchmark_test.dart`：JIT n=7（300 行 ×2000 次 counter-only 更新）均值 20.16µs/中位 19.93µs → 13.09µs/13.06µs（均值 **-35.10%**，中位 **-35.00%**，单次更新省 ~7.1µs）；`test/common/string_test.dart` 新增 3 个 `equalsIgnoreCase` 用例（含 ASCII-only 折叠语义），`test/views/dashboard/connections_table_test.dart` 新增混合大小写协议计数与 traffic 更新后顺序不变用例（`TCP`/`Udp` → TCP 12 / UDP 8），`test/views/connections_test.dart`、`test/views/requests_test.dart` 与 `dart analyze --fatal-infos` 全绿 |
| Android 事件分发快照监听器 + 标签懒构造 | -（仅 wrapper） | `83477313` | `Service` 原来每个 Core 事件都 `List.of(_listeners)` 且都执行 `'Core event ${event.type.name}'` 字符串插值；现在监听器快照按 add/remove 失效缓存，事件类型标签只在 catch 分支构造，成功路径只保留一次 try。新增 `test/plugins/service_event_benchmark_test.dart`：JIT n=7（300 事件 ×200 批）perBatchUs 均值 529.00/中位 526.56 → 489.76/479.68（均值 **-7.40%**，中位 **-8.90%**，单事件 1.76µs → 1.63µs）；`test/plugins/service_test.dart` 25 个用例全绿，全量套件剩余既有本地 bundle 失败 |

### 2026-11-08 核心答案路径轮次

本轮按用户要求聚焦 core（Go wrapper + 子模块）：从 benchmark 地图重新测量，CPU 剖析 `getProxies` 与 `getConnections` 两条答案路径，落地三项结构性重构；第 5 节同步更新待优化项清单。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 组的实时选中读取收敛到单锁：`URLTest.fast` 把 stale 检查与缓存读取合并为新的 `Single.CachedValid`；`URLTest`/`Fallback` 的钉选从 `sync.RWMutex` 改为 `atomic.Pointer[string]` | `89fad1edd` | `83477313` | `BenchmarkHandleGetProxies` paired n=7 benchstat：200 组 urltest 59.92µ → 50.47µ（**-15.77%**，p=0.001）、200 组+1000 节点 urltest 77.02µ → 66.89µ（**-13.15%**，p=0.001）、fallback -5.02%（p=0.004）、loadbalance -5.37%（p=0.011），geomean **-7.09%**，分配/内存不变；`BenchmarkURLTestSelectedProxyLargeGroup` paired n=5：166.4ns → 148.2ns（**-10.94%**，p=0.008）。答案字节形状由 `TestGroupDocsAnswerWhatTheirGroupsChange`、`TestProxiesAnswerAnswersWhatTheHostReads` 钉住 |
| 代理解表答案整表一次持锁、组文档键只读一次：`appendProxyTable` 每答案持锁一次（原每组一次），缓存键读一次后同时用于查找与写入（原键会被读三次：查找、组自身编码、写入），行类型每组只问一次 | -（仅 wrapper） | `83477313` | 与上一行同一基准配对测量（wrapper 与子模块共同构成该收益）；`TestGroupDocsAnswerWhatTheirGroupsChange` 覆盖四种 kind 的稳态答案、钉选与订阅刷新后 now/all 到达下一答案 |
| 连接轮询行表改 tracker 键 + 死行原地清扫：`connectionRows` 由 `map[uuid.UUID]` 改 `map[statistic.Tracker]`，另存 order slice，清扫时原地压缩；行 id 建行时算一次，删除时不再现算 | -（仅 wrapper） | `83477313` | `BenchmarkGetConnections` paired n=7 benchstat：resync 100 行 45.83µ → 30.06µ（**-34.43%**，p=0.002）、resync 500 行 146.0µ → 123.3µ（**-15.56%**，p=0.001）、delta 500 行 39.11µ → 35.10µ（p=0.073 噪声内），geomean **-16.97%**，分配/内存不变；`TestConnectionDeltaAnswersWhatMoved` 全绿 |
| 代理解表组文档缓存槽位化：`groupDocs`（按代理查 map + 快照比对）改为随快照预建的 `groupSlots`，每组每答案省掉 `Type()`、类型断言、map 查找与快照比较，整表锁保持不变 | -（仅 wrapper） | `83477313` | `BenchmarkHandleGetProxies` 3 轮交替配对 n=15：groups=20 5.105µ → 4.152µ（**-18.67%**，p=0.000）、groups=200 71.28µ → 53.08µ（**-25.54%**，p=0.002）、千节点 70.05µ → 57.58µ（**-17.80%**，p=0.001）、urltest 50.35µ → 42.35µ（**-15.90%**，p=0.000）、千节点 urltest 68.58µ → 55.79µ（**-18.65%**，p=0.000）、fallback **-18.86%**、loadbalance **-18.56%**，geomean **-19.19%**，分配/内存不变；wrapper 全量 + focused race + vet 通过 |
| Profile 读档缓存直接持有 `wire` 字节（省掉每次读档的整份拷贝） | -（仅 wrapper） | `881b74ba` | `BenchmarkProfileReadAndMerge` 与 `BenchmarkMergeProfileBase` 3 轮交替配对 n=15：分配字节 geomean **-2.79%**（p=0.000），时间持平（该路径 50% 在 `os.ReadFile`、21% 在 yaml，属 I/O 主导）；wrapper 全量 + vet 通过 |
| IPv6 支持检查按进程缓存 + 网络变更失效：`verifyIP6()` 原先每次配置解析都走一遍 `net.InterfaceAddrs()`（实测单次 1.52ms，占 800 节点解析 CPU 采样的 16.7%）；子模块缓存答案并导出 `ResetIPV6Support()`，wrapper 的 `handleNetworkChanged`（桌面 connectivity 变更与 Android NetworkObserver 都走这条路径）调用它失效 | `83477313` | 本轮提交 | `BenchmarkParseConfig` 800 节点 paired n=3：13.02ms → 11.31ms（**-13.1%**），分配 89953 → 89895 基本不变；新增 `TestVerifyIP6CachesUntilTheNetworkChanges` 钉住缓存命中、`SKIP_SYSTEM_IPV6_CHECK` 逃逸口与重置后重新询问系统；子模块全量（104 包）+`go vet ./...`、wrapper 全量 +`go vet .`、config 包 race 全部通过 |
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
| 答案分层为信封/文档/尾段：`frameWriter.frameFor(id)` 改为 `frameWriter.document()`，`handleMethodCall` 返回 `frame{head,document,tail}`，信封按调用现建（`envelope(id)`），文档就是结果自己编码出的字节 | -（仅 wrapper） | `83477313` | 六类答案（proxies/connections/count/traffic/memory/providers）统一到同一契约，`frameFor` 删除；字节形状由既有测试逐类钉住（`TestProxiesAnswerAnswersWhatTheHostReads`、`TestConnectionDeltaAnswersWhatTheHostReads`、`TestTrafficStatsFrameMatchesTheEnvelope`、`TestMemoryStatsFrameMatchesTheEnvelope`、`TestProviderListFrameMatchesTheEnvelope`、`TestConnectionCountFrameMatchesTheEnvelope`，全部为 json 反射信封与手写文档的逐字节比对） |
| 桌面传输层对大文档分段写：`writeFrame(w, frame)` 在文档 ≤32KB 时仍整帧进池化缓冲一次写出，超过则写「长度+信封」「文档」「尾段」三段，文档本身不再被拷贝 | -（仅 wrapper） | `83477313` | `TestWriteFrameReadFrameRoundTrip` 增设大文档分段用例（帧读回与 `frame.bytes()` 逐字节相等）；`TestSendWritesEachFrameInOneTransfer` 仍证明小帧一次写出 |
| 溢出响应分段落盘：`spillResponse` → `spillFrame`，临时文件按三段顺序写，不再为落盘凑一整帧 | -（仅 wrapper） | `83477313` | `TestHandleMethodCallSpillsALargeResultToAFile`、`TestHandleMethodCallAnswersInlineUnderTheThreshold`、`TestClearSpilledResponsesKeepsTheDirectory` 全绿 |
| 大文档走真实管道的基准（`BenchmarkWriteFrameLargeDocumentOnAPipe`，仅测试）：140KB 文档在 Windows 匿名管道上分段写 35.9µ/答案、3991MB/s、32B/答案；同窗口对照"先 join 成一整帧再写"为 54.9–71.3µ、2011–2608MB/s、147.6KB/答案 | -（仅 wrapper） | `83477313` | 分段写比 join 快约 **35%** 且零拷贝，三条写替代原来的一次 join + 一次池化缓冲拷贝；这是传输层敢丢掉整帧拷贝的实证，基准留在仓库里防回归 |
| 代理表按表缓存整个文档（键不含调用 id）：`document()` 先用 `refreshGroupDocs` 逐个槽位校验（`refreshGroupDoc` + `groupDocGeneration` 代数），毫无变化才把上次的文档交出去；键为快照同一性 + 显示名单 + 代数 | -（仅 wrapper） | `83477313` | 见本节末的配对测量：生产答案路径 geomean **-86.07%**、分配 -99.94%、allocs -44.83%；`TestProxiesFrameAnswersTheSameBytesUntilSomethingMoves`（新增）钉住：表未变时同一文档、换 id 只换信封、选中移动/订阅刷新/快照重建三类变更都必须重建文档；`TestProxiesAnswerEncodesALiveGroupOnEveryAnswer`（新增）钉住无法键入的组仍逐次实编码 |
| Android 回复路径在 gobind 边界拼接（`InvokeMethod` 的 reply 适配） | -（仅 wrapper） | `83477313` | gobind 只收一个切片，故在边界 join；桌面走分段写。两边字节一致，由 `frame.bytes()` 与 `writeFrame` 的往返测试共同保证 |

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

### 2026-11-11 outboundgroup `GetProxies` 覆盖轮次（测试，非性能）

`GetProxies` 是 `adapter/outboundgroup` 内最大的未覆盖块（53.5%），而它每条未覆盖分支都直接改变宿主读到的成员名单：谁能活过滤、按什么顺序排、exclude 丢谁、空组拿谁顶。本轮只补测试，生产代码一行未动。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `GetProxies` 五条行为钉住：touch 契约（没要 touch 的读不碰 provider）、compatible provider 不过 filter、多 filter 跨 provider 按 filter 顺序重排、exclude-filter 与 exclude-type 两类剔除、空组回退 `EmptyFallback` | `fcaf694ac` | `78b830de` | `GetProxies` **53.5% → 95.8%**，包 **72.7% → 76.1%**；新增 5 例 focused 全过（连既有共 7 例）、focused race 通过、原生 `go vet ./...` 与 darwin/arm64、linux/arm64、android/arm64 三平台包级 vet 全部 exit 0、子模块全量 **104 包 ok** |

两条易错点各钉一处：compatible provider 的成员是别处已经过滤过的，再过一次 filter 会把合格成员误杀；`len(providers) > 1 && len(filterRegs) > 1` 时必须按 filter 顺序整体重排（不是按 provider 顺序），否则成员名单顺序会随 provider 声明顺序漂移。

### 2026-11-11 数据平面每连接缓冲复用轮次（性能，本会话最大单项）

先说这个项目是怎么被找到的：此前所有基准测的都是「答案路径」（宿主 IPC）与「每包传输原语」，**真实负载下产品自己怎么跑从没被测过**。本轮在子模块内起了完整应用（`UnmarshalRawConfig` + `ParseRawConfig` + `ApplyConfig`：mixed 监听、嗅探开启、DIRECT 规则）加一个回显服务器，用 100 并发 SOCKS5 连接打 20 秒，从进程内抓 CPU/分配 profile——之前全是单 goroutine 微基准，稳态分配与锁竞争从没露过面。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `common/net.Relay` 每个方向每连接持有一个 32KB 缓冲复用，不再每数据块新建（sing 的 `CopyExtendedWithPool` 每块调 `ReadWaitOptions.NewBuffer()` = 结构体堆分配 + 池取出，且几乎不回池）；缓冲每读前 reset 并按目的地 headroom 重新 `Resize/Reserve`（链路里的读实现全是追加式，不 reset 会叠块）；`CachedConn` 的记录前缀（回退路径录下的握手航段）进循环前先写对端——它的 `ReadBuffer` 不吃前缀，旧路径靠 `bufio.Copy` 的 `ReadCached` 分支 | `1c78f33f6` | `93d6a6e8` | `BenchmarkRelayStream` paired n=7：**sec/op -73.65%**（1127.9µ → 297.2µ，p=0.001）、**B/s +279.50%**（3.46 → 13.14 GiB/s）、**B/op -99.97%**（4132.8KiB → 1.375KiB）、**allocs 270 → 14**（p=0.001）；端到端 harness（100 并发 SOCKS5 + mixed 监听 + 嗅探 + DIRECT，20 秒）：**130,993 → 203,454 req/s（+55%）**，分配 profile 里产品侧稳态分配归零。旧路径中转 4MB 要分配 4MB：从池里取的 32KB 数组几乎从不回池（负载 profile 实取 2.72M 次 vs 回池 0.17M 次） |

**两个必须一起改的点**：缓冲复用要求每读前 reset + 按 `CalculateFrontHeadroom`/`CalculateRearHeadroom` 重新 `Resize`/`Reserve`——链路下的读实现（`ExtendedReaderWrapper`、mihomo 的 deadline reader、`BufferedConn`）都是往缓冲里**追加**，旧路径每块换新缓冲正好掩盖了「没人 reset」这件事；`CachedConn.ReadBuffer` 不吃 `data` 前缀，所以进循环前必须 `ReadCached()` 先写走。

**中途被测试抓到的写法**（记下来，别重犯）：第一版只改缓冲复用，`transport/jls`（HelloRetryRequest 回退）、`transport/mekya`、`transport/shadowtls` 三个包全挂——回退路径把录好的 ClientHello 交给 `NewCachedConn`，没有前缀先写，回退服务器永远等不到 ClientHello（jls 直接 3 分钟超时堆栈）。修法就是上表第三栏那句。另外第一版还把基准的等待对象写错（数据从左流向右），busy-wait 永不退出。

**覆盖**：`common/net/sing_test.go` 三条——`TestRelayStreamsEveryChunkBothWays`（双向各 240KB、字节级一致、双端关闭）、`TestRelaySteadyStateCostsNothingPerChunk`（稳态每块 `AllocsPerRun == 0`）、`TestRelayWritesTheCachedPrefixFirst`（记录前缀必须先于线路数据到达对端）。focused race、原生 `go vet ./...`、三平台包级 vet、子模块全量 **104 包 ok** 通过。

## 3. 已拒绝或已撤销实验

| 文档缓存改用路由版本（`routeStamp`）替代每组的 provider 版本遍历 | 否决。`updateExternalProvider` 里 `refreshRoute()` 确实是同步的，但 wrapper 自己的 `cachingProvider.setProxies` 只 bump 版本、不经过路由刷新（hub_test.go:896 注释即写明「版本是运行时 provider 更新留下的唯一信号」），所以该键会直接破坏 `TestGroupDocsAnswerWhatTheirGroupsChange`，也会漏掉所有不走 `refreshRoute` 的更新路径。provider 版本遍历是唯一稳健的探测器，保留 |
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
| `RecordSorter.sort` 乱序路径改 `List<T>.of` + 按序索引填充 | `record_sorter_benchmark_test.dart` 同会话交替配对 4 轮：已有序路径 202.6/207.8ms → 207.4/209.8ms（**+2~3% 更慢**），逆序路径 2420/2395ms → 2379/2290ms（噪声内）。Dart JIT 下预分配 + 索引写比 collection-for 更贵；与「收益被键列表构建吃掉」的既有结论一致，撤销。 |
| `SearchQuery.matchesText` 单 term 直接 `contains` | DNS 搜索文本缓存后，`test/models/dns_query_search_benchmark_test.dart` n=7：73.41ms/中位 73.18ms → 74.25ms/中位 73.64ms（时间 +1.15%/+0.62%，在噪声内无收益）。`terms.every(text.contains)` 已无每行字段构造成本，直接分支无可再省；撤销。 |
| `countryFlagEmoji` 用 `Expando<String>` 缓存 | `test/common/country_flag_benchmark_test.dart` 验证前直接失败：Dart `Expando` 明确拒绝 String/num/bool/record/null 作为 key，`Expando.[]` 抛 `Invalid argument`；`test/common/string_test.dart` 全量复现后回退。结论：字符串不可作为弱引用键，缓存需换成包装对象，收益不抵额外结构；撤销。 |
| 流量文本按 `TrackerInfo` 行对象缓存（`Expando<TrafficShow>`） | 设想：把 `dashboardTraffic`/`amount.traffic.show` 缓存到行对象上，让 `row_cells` 与连接表格免掉每次重建字符串。同会话基线 1.34–1.41µs/行（500 行 ×500 次 `cellsOf`）→ 改后 2.16µs/行（**+53%**）。原因：连接表格每次 counter-only 刷新都会 `copyWith` 生成新行，`Expando` 缓存永远 miss，还要为每次读取付 4–5 次弱表哈希。撤销；要再省流量文本，只能做 per-column memo 或自绘 render object，不要重试按行缓存 |
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
| `isJSONSafeASCII` 改 8 字节一组的字长扫描（高位/控制位/五个转义字节全用位运算） | paired n=7：`AppendStringSafeASCII32` 16.61n → 19.79n（**+19.15%**）、`SafeASCII256` +9.27%、`Escaped32` +2.94%，geomean +3.53%，**纯时间回退**。原因：128 字节的表常驻 L1，逐字节「一次比较 + 一次表查」本来就是缓存友好且可预测的形态；字长版要为五个转义字节各做一次 xor+haszero（带循环级依赖），短字符串上反而更贵。已撤销，勿重做 |
| 信封契约改造：`frame` 改带 `id string`、`size()`/`bytes()`/`writeFrame`/`spill` 在现场物化信封（省每答案 1 次分配 + 1 次 copy） | paired n=7：小文档路径（<32KB）allocs 1→**0**、sec/op -1.74%；**大文档路径 +22.31%~+24.61%**（141n→175n），geomean +19.48%。剖析定位到 `writeFrame` 里 `answer.head = appendEnvelope(nil, id)` cum 1.70s/12.4s：`envelopeLen` 与 `appendEnvelope` 各扫一遍 id，加上 `size()` 被 spill/handleMethodCall/writeFrame 调三次又各扫一遍，而旧代码只在 `envelope()` 里扫一次；分配档也从 `len(id)+20` 的 32B 变 48B。结论：**净负，撤销**——省下的那次分配换不回大答案路径的 22%。这也给第 5 节挂了很久的"信封契约改造"结了案 |
| `RecordColumn.sortKey` 的 `toLowerCase()` 改「扫描到大写才降格」的守卫版（省掉对小写 ASCII 的无谓分配） | 5 轮交替配对（同进程、500 行 × 300 次/轮）：`progress` 7093 → 5792µs（-18%，更快）、`title` 3727 → 3044（-18%）、`network` 1755 → 1520（-13%），但 `rule` 13524 → 13522（持平）与 `exit` 4199 → 4719（**+12% 更慢**）。方向不一致：`progressText`/`title` 是长串（20+ 字符）且以大写进程名开头，守卫提前命中；`exit` 只 5 字符、`rule` 是字符串插值产物，守卫的逐字符 scan 跑完全部字符仍要再走一遍 `toLowerCase`，白白多扫一次。混合大小写数据集上（`Example-N.COM` 类 payload）两个方向都只有个位数百分比。结论：**否决**，收益取决于列的数据形状，不值得为其中三列引入手写 ASCII 判断 |
| `RecordColumn.sortKey` 的 rule 列改用「两段式 `Comparable`」替掉 `'$rule $rulePayload'.toLowerCase()`（同时干掉插值新建与降格） | 5 轮交替配对：key 构建 12404 → 1625µs（**7.6 倍更快**），含 499 次相邻比较的整轮 27805 → 4832µs（**5.8 倍更快**）。倍数成立，但**语义不等价**：`'$rule $payload'` 是单串比较，等价于「先比 rule、rule 相等时比 ` payload`」；两段式是「先比 rule、再比 payload」。穷举 17 种 rule（来自 `RuleType.String()` 的全部返回值）× 10 种真实 payload 共 28900 组，`sign` 不一致 34 组，全部形如 `payloadA='a b'` vs `payloadB='C:\Program Files\App\app.exe'`：单串比较在空格处分叉先比 `' '` 与 `'\\'`，两段式直接比 `'a'` 与 `'C'`。14 种 rule 名本身无空格（已核 `core/Clash.Meta/constant/rule.go` 的 `RuleType.String()` 共 39 个固定返回值，全部单字，且 `tracker.go:202/305` 只以该枚举或空串赋值），但 payload 会带空格（Windows 进程路径），排序结果在这些行上会变。结论：**否决**——速度收益确凿，代价是用户可见的规则列排序行为回归 |
| 「按 metadata 对象锚定的 lower key 缓存」缓解 counter-only 刷新导致的行级 Expando 失效 | 500 行 × 300 次配对：同一批行对象下 `metadata.network.toLowerCase()` 1755µs，每行先 `copyWith(upload:, download:)` 再取则是 8292µs（55.3ns/行），即行对象一换 JIT 内联缓存与 `Expando` 查找同时失效。按 metadata 锚定可绕过前者，但 `Expando` 查找本身在 JIT 下已被账本两次证明不足 15% 收益的下限，且需为 5 个 sortKey 各建一张表。本轮未实现，记为**否决**：不引入第二套缓存层去换一个未证实的个位数百分比 |

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




### 2026-11-09 事件批量缓冲复用轮次（性能）

生产环境频率最高的一条 wrapper 路径：事件每 48ms 一批（繁忙时每批 64 条），每批都把整份文档装进一个新缓冲、当成一个 piece 交给传输层，然后整块丢掉。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 信封固定化 + 正文进缓冲池 + 按 frame 三段投递：`encodeMessageBatch`（整份文档）拆成固定的 `messageBatchHead`/`messageBatchTail` 与 `encodeBatchBody(dst, …)`；`sendMessageBatch` 从池里取缓冲、编码正文、以 `frame{head, document, tail}` 投递后归还；正文超过帧池上限（`maxPooledFrameSize`，1MiB）时不归还，避免一次超大刷盘把缓冲钉住；`encodedBatchSize` 随之成为死代码被删 | -（仅 wrapper） | `947fc165` | 交替配对 A/B（n=6，`-benchtime 1s`，benchstat）：16 条一批 4096 → **24 B/op**（-99.41%，p=0.002），64 条一批 16384 → **25.5 B/op**（-99.84%，p=0.002），geomean **-99.70%**；allocs 仍为 1。时间：geomean -21.31% 但两个场景 p=0.394、方差 ±75~90%（本机在跑用户自己的 FlClash），按仓库噪声带判为「无显著差异」——**这项是按分配落地，不是按时间**。另新增 `TestSendMessageBatchWritesAnOversizedBatchInPieces`：超过单写阈值的批次第一次真正走三段写路径，钉住三段按序落地 |
| `deliverEvent` 两个平台统一收 `frame`；Android 侧在自己的一参回调里 join（`answer.bytes()`）；`maxPooledFrameSize` 挪到 `frame` 类型旁边（method.go），桌面与 Android 共用 | -（仅 wrapper） | `947fc165` | 修掉只改 `server.go` 会让 `GOOS=android GOARCH=arm64` 编译失败的问题（vet 四个目标全过） |

**本轮基准注意**：`BenchmarkSendMessageBatch` 改为测真实的 flush（`sendMessageBatch`）而非只测编码，因此它的绝对数值与 2026-11-09 之前不可比；跨轮比较只能在本轮同基准内做 A/B。

**一次未能复现的全量失败（记录备查）**：覆盖率达到 91.2% 的那次 `-coverprofile` 全量跑里出现过一次 FAIL，之后 12 次全量（含 3 次带覆盖计数）全绿，未能再复现，也未抓到失败用例名。为降低时序敏感度，`log_test.go` 的 `waitForWrittenPayload` 上限从 2s 放宽到 5s（与仓库现有 flood 测试一致）。若之后再现，按当时日志定位。
### 2026-11-09 服务规则与日志泵覆盖轮次（覆盖，不是性能）

上一轮把 method 表的 action handler 都跑通之后，剩下的 0% 集中在两类：**400 行没人跑过的 unlock 规则**（`service_rules.go` 14 个检查器，全靠 `handleServiceCheck` 的注入源覆盖其框架）和**日志泵的三条分支**（只有宿主真的开/关日志时才走到）。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `serviceEnv` 改为持有自己拨号用的传输（`request func(probeRequest) *ProbeResult`），规则不再只能拿去打真实外网；`runServiceCheck` 走新的 `newServiceEnv` | -（仅 wrapper） | `0852f7ce` | `service_rules.go` 的 14 个检查器全部有确定性用例：区域读取（Claude/Gemini/YouTube/Spotify/TikTok/Discord/Prime/Netflix/Disney）、状态折叠（`chatGptIosStatus`/`tikTokStatus`/`bilibiliStatus`/`statusFromCode` 的各分支）、Disney 三步握手的四个收尾、以及 Disney 拒绝无浏览器令牌请求的那条 header 合并。`checkClaude`/`checkChatGpt`/`spotifyRegion`/`tikTokStatus`/`tikTokRegion`/`checkBilibili`/`bilibiliStatus`/`netflixServed`/`netflixFromCdn`/`firstSubmatch` 达 100% |
| 覆盖 `logPump.run()`：低于当前等级的丢弃、已停止后的丢弃、以及「停止后仍继续排空订阅」 | -（仅 wrapper） | `0852f7ce` | 订阅由测试直接喂事件（不经过 mihomo logger），因为「等级已越过 logger 已接受的事件」这个分支只能这样确定性构造；等级/停止两条丢弃都钉住，`run` 100% |
| 覆盖 `reportDialerLoop`：同一轮 dialer loop 只上报一次 | -（仅 wrapper） | `0852f7ce` | 两次上报只产生一帧；`reportDialerLoop` 100% |
| 覆盖 `watchRouteHandler`：答案就是当前状态，读不动的调用不动轮询器 | -（仅 wrapper） | `0852f7ce` | 经 `answerBytes` 走 handler 表；另加 cleanup，断言中途失败也不会把轮询器留给后面的用例；`watchRouteHandler` 100% |
| 删掉没有调用方的 `fallibleWithoutArguments` | -（仅 wrapper） | `fc0e3a43` | 纯死代码：method 表的每个条目都从 `command`/`withArguments`/`withFallible`/`withoutArguments`/`action` 之一进入，该适配器不回答任何方法 |

覆盖率：wrapper `go test ./... -coverprofile` **85.2% → 91.3%**（statements）。剩余 0% 全部落在「单测里构造不出来」的三类：进程/信号入口（`main`、`StartServer`、`ExitOnTermination`、windows 的 `dial`）、`ownership_other.go` 的非 Windows 平台空实现、以及桌面端永远为真的 `hasEventListener` 使 `requestTrafficWatch.clear` 不可达（Android 侧才走得到）。另有一处既有台账更正：`MethodError.Error`/`handleCrash`/`handleInit`/`handleInitialized`/`handleStopListener` 仍未覆盖，列入后续，未在本轮做。

**审计结论（记录备查，未改动）**：`netflixRegion` 读的是 `Location` 里第 4 段（`/jp-en/title/80018499` 这类绝对 URL 拆段后的 locale 段），本机无法连 netflix.com 取真实响应，行为按现值钉住；若将来拿到真实响应与此不符，那是行为修正而非测试失败。

### 2026-11-09 分享链接与残余分支覆盖轮次（覆盖，不是性能）

上一轮把 unlock 规则和日志泵收口后，剩下能覆盖的都是「只在特定字段/特定错误下才走」的分支，其中最大一块是 `share_link.go`：14 个编码器此前只被「生成后交由 convert 读回」的往返测试覆盖，那只证明**能往返的字段**没丢。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 每个编码器的每个可选字段各有一个用例：直接断言链接的 scheme/userinfo/host/query（含 hysteria2 的端口段这种 `url.Parse` 会拒绝、只能手拆的形状），以及 v2rayN JSON 形态的 base64 解包断言 | -（仅 wrapper） | `c3414ff5` | `share_link.go` **逐函数 100%**（此前 63.8%~94.4%）；`proxyFields` 的 str/flag/sub/list/first 五种入参形态全部钉住。顺带删掉 `encodeVmess` 里一段不可达分支（legacy 形态只在 alterId 既非空也非 "0" 时进入，`aid` 不可能是空串） |
| 补 `handleSetupConfig` 未初始化即拒绝、`mappingValue` 的 merge key 查找（`<<: *anchor` 与 `<<: [*a, *b]`） | -（仅 wrapper） | `234aa525` | `handleSetupConfig` 66.7% → 100%，`mappingValue` 47.4% → 94.7% |
| 补 `forgetPendingProbeRoute` 的「忘记未登记的连接」与「忘记已登记的连接」两半、`logError` 的 stderr 调试开关、`reportMissingDelayTestProxy` 的一秒静默 | -（仅 wrapper） | `a9b44e6d` | `forgetPendingProbeRoute` 50% → 100%、`logError` 66.7% → 100%、`reportMissingDelayTestProxy` 71.4% → 85.7%（剩 compare-and-swap 失败那一行，需要并发竞争才能确定性地走到） |

包覆盖率：91.8% → **93.8%**（statements）。

**剩余未覆盖（本轮盘点，均需在单测里「造不出来」或价值极低）**：`main`/`StartServer`/`ExitOnTermination`/`dial`（进程与信号入口）、`ownership_other.go` 三个非 Windows 平台空实现、`handleCrash`（开发者专用的主动崩溃路径）、`requestTrafficWatch.clear`（桌面端 `hasEventListener` 恒真，只有 Android 走得到），以及各处的「写文件/Chmod 失败」「compare-and-swap 失败」类防御分支（需注入文件系统错误或并发竞争）。

### 2026-11-09 死代码与残余路径审计轮次（审计，无代码改动）

「不写无效代码」需要证据而不是印象，本轮把 wrapper 的生产函数逐个对账，并给残余的两条路径补了实测依据。

**1. wrapper 无死代码（360 个生产函数全对账）**：对 `core/*.go`（不含测试）里的每个函数名，统计它在生产文件与测试文件里的引用次数。**没有任何函数只被测试引用**（`routeState` 早前轮次已移入测试文件）；引用数为 0 的 12 个全是导出的宿主接口：`ExitOnTermination`/`StartServer`（`core/cmd/core/main.go`）、`ForceGC`/`GetTrafficStats`/`InvokeMethod`/`StartListener`（`lib/core/interface.dart`、`common.dart`、`lib.dart`）、`QuickSetup`/`ResetNetwork`/`UpdateDns`/`StartTun`/`StopTun`/`SetEventListener`（`android` 侧 `Core.kt`/`ServiceController.kt`/`ServicePlugin.kt`/`VpnService.kt`/`NetworkObserver.kt`）。均不可删。

**2. 冷读档路径的瓶颈在文件打开，不在 wrapper**：`BenchmarkMergeProfileBase/proxies=800` CPU 剖析（60x）显示 `os.Open`/`createFile` 占 **48.15%**（每次约 8.2ms）、`yaml.v3` 占 33%，wrapper 自己的合并逻辑远小于两者。8.2ms 的打开耗时来自本机对 %TEMP% 新文件的实时扫描（每轮基准都写新文件），生产环境反复打开同一文件不会有这个代价。**结论不变**：「按 (size, mtime) 跳过读盘」仍否决——宿主改写走 `profile.clearEffect` 显式失效、Core 自身改写走 `forgetProfileRaw`，唯一敞口是外部编辑器同大小 + 同一时钟 tick 内的两次保存（本机 NTFS 时间戳粒度约 15.6ms），既快又等价的判据不存在。

**3. 新否决（勿重做）：把事件批次直接编码进帧缓冲**。设想：`writeFrame` 已有「文档超过 32KB 就分三段写」的路径，若让批次正文直接写进一个预留 4 字节头、写完回填长度的帧缓冲，可省掉一次 14KB 的 memmove 与一个池化缓冲。实测现状：64 条一批已降到 25.5 B/op、1 alloc，剩下的就是那一次拷贝（约 1µs/批，按 21 次/秒合计约 20µs/秒，占 CPU 万分之二以下）。为它新增一条「预组装帧」传输路径不相称，撤销。

**4. 新否决（勿重做）：按槽位缓存每组的 provider 列表**，省掉命中路径里一次 `Providers()` 接口分发。`(*Selector).Providers()` 就是 `return s.providers`（无锁无分配），收益约等于把 200 组的接口分发从 400 次降到 200 次：按剖析占比约 2%（~50ns/答案）。且「providers 构造后不变」只是读代码得到的印象，上游一旦改为可替换，wrapper 会拿着旧列表比版本——为 50ns 背这个风险不相称，撤销。

### 2026-11-09 provider 列表代号轮次（性能，本会话最大单项）

账本挂了很久的第一条待办——「provider 选中/成员变更的主动失效钩子」——原判定是「架构级改动，必须先有变更点 × 通知点矩阵」。本轮把矩阵做出来后发现它比预估的小得多，于是用**一个全局代号**而不是逐组通知落地了。

**变更点 × 通知点矩阵**（wrapper 答案路径要探测的是「组成员列表是否变过」）：

| 变更点 | 位置 | 是否唯一写入口 |
|---|---|---|
| provider 的列表被替换 | `adapter/provider/provider.go` 的 `baseProvider.setProxies` | **是**。全子模块对 `bp.proxies` 的写只有两处：构造函数（provider 尚未发布，无读者）与 `setProxies`；`bp.version` 也只在 `setProxies` 递增 |
| 组选中的变化 | Selector 的 `setSelected` / URLTest·Fallback 的 live 改选 | 与列表无关，wrapper 已用 `SelectionVersion`/`Now()` 处理 |
| 组的 provider 集合变化 | `tunnel.UpdateProxies`（唯一写入口，必然调 `invalidateAllProxies`） | 已有失效路径 |
| 健康检查结果 | `HealthCheck.setProxies` 里的 `hc.version` | **不影响成员列表**，`Version()` 读的是 `bp.version` |

结论：mihomo 自己的组缓存（`GroupBase.GetProxies` 的 `providerVersionsEqual`）就建立在「provider 版本没变 ⟺ 成员列表没变」这个不变量上；在这个不变量旁边加一个「列表换代」计数器，完备性不会比 mihomo 自身更强也不会更弱，却把探测成本从「每组每答案 1+N 次接口分发」降到「每次答案 1 次原子读」。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 子模块新增全局列表代号：`setProxies` 里 `providerListGeneration.Add(1)`，导出 `provider.ListGeneration()` | `16f06520e` | `1a296a0b` | 变更点只有一个函数，计数器放在同一把锁内，与列表替换原子对应 |
| wrapper 的组文档槽位 `versions []uint32` → `generation uint64`；`groupDocVersions`/`groupDocVersionsMatch` 两个函数删除；`refreshGroupDocs` 每次答案读一次代号传给每个槽位 | -（仅 wrapper） | `1a296a0b` | 交替配对 A/B（n=5，`-benchtime 700ms`，benchstat）：20 组 545.9ns → 365.0ns（**-33.14%**）、200 组 2.500µ → 1.013µ（**-59.48%**）、200 组+1000 节点 2.783µ → 1.281µ（**-53.97%**）、loadbalance 2.974µ → 1.433µ（**-51.82%**）、urltest 11.49µ → 10.57µ（-7.99%）、urltest+千节点 12.15µ → 11.03µ（-9.15%）、fallback 12.69µ → 12.11µ（-4.55%），geomean **-35.21%**（p=0.008~0.016），allocs 不变、内存 -1~2%。槽位少一个切片，重建时也少一次分配 |
| 路由轮询不再建 provider 版本表：`routeTracker.providerVersions map[string]uint32` + `versionsScratch` 合成 `providerGeneration uint64`；`readProviderVersions`（每 poll 建一张 map）与 `applyRouteSnapshot` 的 `maps.Equal` 整表比较都改为一次比较 | -（仅 wrapper） | `1a296a0b` | 5 秒稳态轮询少建一张 map；语义不变（任何 provider 列表变化都让代号前移，与原来「任一版本变化即 routeMoved」等价） |

**读取顺序（本轮一并修正的既有隐患）**：代号在每次答案的**所有文档编码之前**读一次，Selector 的 `SelectionVersion` 也在编码前读。原代码在编码**之后**读 `SelectionVersion`：若选中在编码期间变化，新计数器会被盖在写着旧选中的文档上，从此永不重建。改为编码前读后，编码期间发生的变更会在下一次答案被发现。

**测试怎么模拟 provider 换列表**：`providerListGeneration` 是包级函数变量（仓库既有的 `setupConfig`/`readMemoryStats`/`publishRoute` 同款模式），测试用一个可推座的 stamp 顶上；`cachingProvider.setProxies` 像 core 的 `setProxies` 一样把 stamp 推一下。这样「provider 重载后不得继续用缓存文档」的既有断言原样通过。

**又一次既有 DATA RACE 复核（未修，属测试夹具）**：`TestRouteVersionsPollLeavesRuleSetsToTheirEvent` 的 `-race` 失败——本次改动前后**同一竞态**：写入在 `route_test.go:63`（`recordRoutes` 的 cleanup 还原 `publishRoute`），读取在 `applyRouteSnapshot` 里的 `publishRoute(state)`（基线 `route.go:321`，本轮 `route.go:313`）。是 cleanup 没有先停掉后台 `routeRefreshWorker` 就还原钩子，与本次改动无关；要修应修夹具（先 `stopRouteWatch()` 再还原），留作后续。

### 2026-11-09 组内缓存选中跟换代号轮次（性能，接上一轮）

上一轮把 wrapper 的答案路径换到列表代号后，剖析显示 urltest 行的剩余成本仍在子模块里：`(*URLTest).fast` 的 cum 18.10%、`providerVersionsUnchanged`/`providerVersionsEqual` 合计约 8~15%。原因就是 `dropCacheForProviderSwap`——它每次挑路都在走一遍 group 自己的 provider 版本遍历，而这正是代号已经回答的问题。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `URLTest.dropCacheForProviderSwap` 改用列表代号：`knownVersions atomic.Pointer[[]uint32]` + `versionsMu` 换成 `knownGeneration atomic.Uint64`，`providerVersionsUnchanged` 删除；代号经包级变量 `listGeneration` 读（子模块自己的 failover 测试用 stamp 顶上，与 wrapper 同款模式） | `d2ba563e9` | `d43b5bea` | wrapper 答案路径配对 A/B（n=4，`-benchtime 1s`，benchstat）：urltest 10.192µ → 7.904µ（**-22.45%**，p=0.029）、urltest+千节点 10.937µ → 8.557µ（**-21.76%**）、其余场景全不变（fallback 在样本拉长后 p=0.200，回到噪声带内）；allocs/内存不变。子模块自己的挑路基准同向：cached 26.32ns → 23.72ns（**-9.88%**）、large group 125.4ns → 121.7ns（**-2.95%**） |

**本轮一并发现的测试保真度缺口（已修）**：wrapper 的组文档测试原先用一个 wrapper 自建的 provider 换列表。那个 provider 推不到子模块的代号，于是「provider 重载后丢弃组内缓存选中」这条路径在 wrapper 测试里**恰好失效**——而断言写的是 `doc.Now == Now()`（同一份陈旧值自比对），所以一直绿。改为：两个会换列表的测试改用**真实的 core provider**（文件载体 + wrapper 自带 `resource.Parser`，换列表时改写文件并 `Update()`，真的推动代号），并把 `now` 钉成「不得再是被丢弃的那个成员」。wrapper 的 stamp 也跟着推一次，因为答案路径读的是它。

**审计结论（记录备查）**：`GroupBase.GetProxies` 重建成员列表后**先读版本再入缓存**，注释称「版本在列表之后读，交换发生在本次调用内时会把新版本盖在混合结果上」——这段推理与 `tunnel/patch.go` 的注释（「Version before proxies，另一种顺序会让缓存永不恢复」）互相矛盾，按后者才是对的。影响面极窄（只在 provider 恰好于列表读取期间交换时出现一次永久陈旧），本轮未改，留待单独一轮修。

**新否决（勿重做）**：想在 wrapper 测试里用 `provider.NewProxiesParser` 造真实 provider——不行，它的 `override overrideSchema` 是未导出类型，wrapper 无法构造。可行做法是自己传一个 `resource.Parser[[]constant.Proxy]`（本轮回退方案即此）。

### 2026-11-09 成员列表版本读取顺序修正（正确性）

账本上一轮记下的「两条矛盾注释」有了结论并落地。`GroupBase.GetProxies` 在读完列表**之后**才读 provider 版本并入缓存，其注释称「交换发生在本次调用内时会把新版本盖在混合结果上，于是下次重建」——恰恰相反：新版本盖上去之后，下次比较「当前 == 已存」必然相等，那份**混合/陈旧列表会被永久 serving**。`tunnel/patch.go` 对同一个问题的注释（「Version before proxies，另一种顺序会让缓存永不恢复」）才是对的。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `GroupBase.GetProxies` 把 `providerVersionsNow()` 挪到读列表之前，缓存盖的就是读列表前那一代；新增 `TestGetProxiesDoesNotCacheAListItsVersionOutran`，用「读取期间列表被换掉」的 provider 钉住不变量 | `7f653cb1b` | 本轮父仓库提交 | 先实证：不修复时该用例失败（`expected: second, actual: first`，陈旧列表被永久缓存），修复后通过。成本不变（同一次 `providerVersionsNow()`，只是提前），稳态命中路径完全不经过它。子模块 104 包全量 + vet（四目标）+ focused race 通过 |

### 2026-11-09 组文档改由计数器作答轮次（性能，本会话最大单项）

账本第 5 节长期挂着一条「URLTest/Fallback 的 `Now()` 解析无法用计数器替代，计数器会滞后一个 TTL」。本轮把剖析做到底后发现结论下错了：**.parse 本身不必要**——wrapper 只要知道「选中有没有变」，不需要知道变成了什么。

**剖析证据（urltest 行，200 组，8.5µs/答案）**：`URLTest.Now()` cum **77.78%**，其中 `singledo.CachedValid` 48.43%（含每次调用的 `time.Since`）、`outbound.(*Base).Name` 13.11%。也就是说「为了确认没变而去解析当前选中」就是命中路径的主体。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 子模块新增「实时选中代号」：`announceLivePick` 记录组本次答应的 pick，pick 变化时用 CAS 推进计数器；代号与 pick 同指针发布，读者一次 load 拿到匹配的一对。`ProxyGroup` 接口新增 `LiveSelectionVersion()`（Selector=pin 计数，LoadBalance=0） | `66474a949` | `6bbe9689` | 子模块 104 包全量 + vet 四目标 + focused race 通过；现有两个「provider 交换后跟随」用例补上「未换 pick 不得推进、换了必须推进」断言 |
| wrapper 组文档改由**三个计数器**判定：pin 选中、实时 pick、provider 列表；`groupDocKey`/`groupDocKeyOf` 随之删除（计数器覆盖了键覆盖的一切，读计数器是几次原子读，键是每组一次字符串读+接口分发） | -（仅 wrapper） | `6bbe9689` | 交替配对 A/B（n=5，`-benchtime 700ms`）：urltest 8.547µ → 1.367µ（**-84.01%**）、urltest+千节点 9.028µ → 1.624µ（**-82.01%**）、fallback 13.127µ → 1.383µ（**-89.46%**）、loadbalance 1407ns → 871.5ns（**-38.06%**）；Selector 两行无变化（p=0.738 / p=0.333），geomean **-64.86%**，allocs 不变 |

**为什么不会滞后**：计数器只在「本次答应的 pick 与上次不同」时推进，而文档里的 `now` 正是答应的 pick 的名字；pick 没变 ⟺ 名字没变。同名换节点会多推进一次（无害，只是多重编码一次）。这不是第 5 节否定的「给自选中的组配一个计数器」——那个方案数的是写入口，本方案数的是**答案本身**。

**读取顺序**：三个计数器都在编码前读（与 pick 代号、provider 代号同一规则）：编码期间发生的变化会在下一次答案被发现，而不是把新计数器盖在不含它的文档上。

**本会话答案路径累计**：Selector 行从账本历史峰值 5.1µs → 1.02µs；urltest 12.15µs → 1.62µs；fallback 12.69µs → 1.38µs；loadbalance 2.97µs → 0.87µs。

### 2026-11-09 组答案单代号轮次（性能 + 精简，接上一轮）

上一轮把答案路径改成「三个计数器」后，剖析显示剩下的成本就是**每组 3 次计数器读取**（`refreshGroupDoc` flat 29.64%、`liveVersionOf` 11.86%、两个 version getter 合计 17.79%）。而其中 pin 与 pick 两个计数器，语义上本来就是同一件事的两次计数。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 子模块把 pin 与 pick 合并成**一个答案代号**：`setSelected`/`clearSelected` 推它，挑到与上次不同的 pick 时也推它；`ProxyGroup` 接口的 `SelectionVersion`/`LiveSelectionVersion`/`SelectedName` 三个方法收敛为 `AnswerVersion` 一个（Selector=pin 计数，LoadBalance=0）；`selectedVersion` 字段因只写不读被删 | `5104e8860` | `6cda8e36` | 子模块 104 包全量 + vet 四目标 + focused race 通过 |
| wrapper 槽位只带一个 `answerAt` + provider 代号；`fixed` 字段与 `SelectedName` 断言随键一起消失 | -（仅 wrapper） | `6cda8e36` | 交替配对 A/B（n=5，`-benchtime 700ms`）：urltest 1.329µ → 1.057µ（**-20.47%**）、urltest+千节点 1.598µ → 1.307µ（**-18.21%**）、fallback 1.409µ → 1.130µ（**-19.80%**）、loadbalance 873.6ns → 830.6ns（**-4.92%**）；Selector 两行无变化（p=0.548 / p=1.000），geomean **-11.11%** |

**本会话答案路径累计**（200 组场景，父仓库 main 起点 → 现在）：Selector 5.105µ → **0.996µ**；urltest 12.15µ → **1.06µ**；fallback 12.69µ → **1.13µ**；loadbalance 2.974µ → **0.831µ**。四类组现在同一量级，剩下的成本是帧装配本身（`appendGroupDocument`/`answerSize`/`writeFrame`），不再是选中解析。

**精简账**：本轮净删代码——子模块 3 个导出方法、1 个只写字段、1 个测试夹具字段；wrapper 1 个结构体字段、1 个接口断言、`groupDocKey` 结构体与 `groupDocKeyOf` 函数（上一轮）。

### 2026-11-09 子模块 provider 覆盖面补齐轮次（测试，非性能）

目标第 2 条要求「测试必须覆盖全部核心代码」。此前只量了 wrapper 自己的覆盖率（93.8%），从没量过**子模块**——而子模块才是真正的引擎。首量子模块覆盖：`adapter/outboundgroup` 72.2%、`adapter/provider` 67.1%、`adapter` 62.1%、`tunnel` 60.3%。

本轮先补「本 fork 自己写、且两侧都没覆盖」的部分：

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `ListGeneration`（本轮新加的导出函数）在子模块自己的测试里 0%：真 provider + 改写文件，钉住「两次读之间不动、一次交换必动」 | `c20d3c398` | 本轮父仓库提交 | `TestListGenerationHoldsStillAndMovesOnASwap` |
| `baseProvider` 的对外方法（Version/Proxies/Count/Touch/HealthCheckURL/AppendJSON/MarshalJSON）在本包无调用方：一次跑通，并钉住「touch 只更新近况、不换内容」与「MarshalJSON 与 AppendJSON 同字节」 | `c20d3c398` | 本轮父仓库提交 | `TestProxySetProviderReportsItsOwnState` |
| `provider.ProxyMapping`（订阅节点的详情映射，fork 自己的 126 行）**两侧都 0%**：wrapper 只走到 nil 分支，子模块从不调用。补上「带 override/dialer-proxy 的命名映射 + 四种 filter/exclude 分支 + 非法 filter 报错 + payload 形态」 | `c20d3c398` | 本轮父仓库提交 | `TestProxyMappingReturnsTheNamedProxyWithTheProviderApplied`、`TestProxyMappingHonoursTheProviderFilters`、`TestProxyMappingAnswersFromThePayload` |
| 契约补齐：LoadBalance 的答案代号恒 0、从未作答的组报 0 而非 1 | `c20d3c398` | 本轮父仓库提交 | `TestAnswerVersionReportsZeroWhereThereIsNothingToCount` |

`adapter/provider` 覆盖率 **67.1% → 71.8%**。

**剩余未覆盖（本轮盘点，均已确认是「任何一侧测试都到不了」或上游自带机制）**：`healthcheck.go` 的 `process` 轮询循环（要真开 interval）、`subscription_info.go` 的 `NewSubscriptionInfo`（只在 HTTP 载体的 InRead 钩子里被调）、`override_expr.go` 里单个 `eval` 重载、`parser.go` 的 `ParseProxyProvider` 入口（由 wrapper 的配置测试在运行时覆盖，不计入本包画像）、`provider.go` 的 inline provider AppendJSON 与 `GetSubscriptionInfo`。`adapter/outboundgroup` 剩下的 0% 全是 `DialContext`/`ListenPacketContext`/`SupportUDP` 一类接口方法，属上游机制，由隧道侧测试间接覆盖。

### 2026-11-09 子模块死代码清扫轮次（精简，非性能）

用户要求里有一条「不写无效代码」。此前只对 wrapper 做过死代码扫描（清理过 `fallibleWithoutArguments`、`encodedBatchSize` 等），从没扫过子模块。本轮把两侧都扫了一遍：对每个未导出函数名，统计它在**全仓所有 .go 文件**（子模块 + wrapper，含测试）里的引用数，只留「仅剩定义处一次」的。

| 范围 | 未导出函数总数 | 死代码 |
|---|---|---|
| wrapper（`core/`） | 360 | **0**（本会话已清干净） |
| 子模块（104 包，1192 个 .go 文件） | — | 3 处 |

| 删除 | core 提交 | 父仓库提交 | 依据 |
|---|---|---|---|
| `adapter/outboundgroup/groupbase.go` 的 `memberNames` | `411321146` | 本轮父仓库提交 | 全仓 0 引用；组视图编码早已改走 `writeGroupNames` |
| `tunnel` 的整张监听器表：`runtimeSnapshot.listeners` + `tunnel.Listeners()` + `tunnel.UpdateListeners()`（一个读者一个写者，两者都无人调用） | `411321146` | 本轮父仓库提交 | 本 fork 的监听器补丁由宿主侧直接走 `listener` 包，快照那份副本从未被写，`Listeners()` 永远返回空表。同包的 `Rules()`/`NatTable()` 有真实调用方（`hub/route`），保留 |
| `constant/metadata.go` 的 `appendSourceDetail` | `d6179b8ad` | 本轮父仓库提交 | 全仓 0 引用；`SourceDetail()` 用定长数组产出同一段文本 |

**扫描口径备忘**：PowerShell 的 `-match` 默认忽略大小写，`[a-z]` 拦不住导出名，必须用 `-cmatch`；否则会把 81 个导出 API 和生成代码（`*.pb.go` 的 getter）当成死代码误报。导出但无调用方的函数（如 `common/atomic.NewUint32`、`component/updater.StopGeoUpdater`）属 fork 的对外 API 面，本轮不动，记账备查。

### 2026-11-09 inline provider 与订阅头覆盖轮次（测试，非性能）

**用户要求里有一条「测试必须覆盖全部核心代码」。此前只量了 wrapper 自己的覆盖率（93.8%），从没量过**子模块**——而子模块才是真正的引擎。首量子模块覆盖：`adapter/outboundgroup` 72.7%、`adapter/provider` 76.8%、`adapter` 62.1%、`tunnel` 60.3%。

本轮先补「本 fork 自己写、且两侧都没覆盖」的部分：

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `ListGeneration`（本轮新加的导出函数）在子模块自己的测试里 0%：真 provider + 改写文件，钉住「两次读之间不动、一次交换必动」 | `c20d3c398` | `141279bf` | `TestListGenerationHoldsStillAndMovesOnASwap` |
| `baseProvider` 的对外方法（Version/Proxies/Count/Touch/HealthCheckURL/AppendJSON/MarshalJSON）在本包无调用方：一次跑通，并钉住「touch 只更新近况、不换内容」与「MarshalJSON 与 AppendJSON 同字节」 | `c20d3c398` | `141279bf` | `TestProxySetProviderReportsItsOwnState` |
| `provider.ProxyMapping`（订阅节点的详情映射，fork 自己的 126 行）**两侧都 0%**：wrapper 只走到 nil 分支，子模块从不调用。补上「带 override/dialer-proxy 的命名映射 + 四种 filter/exclude 分支 + 非法 filter 报错 + payload 形态」 | `c20d3c398` | `141279bf` | `TestProxyMappingReturnsTheNamedProxyWithTheProviderApplied`、`TestProxyMappingHonoursTheProviderFilters`、`TestProxyMappingAnswersFromThePayload` |
| 契约补齐：LoadBalance 的答案代号恒 0、从未作答的组报 0 而非 1 | `c20d3c398` | `141279bf` | `TestAnswerVersionReportsZeroWhereThereIsNothingToCount` |
| `NewSubscriptionInfo`（解析 `subscription-userinfo` 头，宿主流量条读它）：全字段、空格/大小写/浮点/指数、坏字段只废自己 | `3d6e4cbe8` | 本轮父仓库提交 | `TestNewSubscriptionInfo*` 三个用例 |
| inline provider 一族（`NewInlineProvider`/`AppendJSON`/`MarshalJSON`/`VehicleType`/`Update`/`Close`）+ 配置入口 `ParseProxyProvider`（此前 0%） | `3d6e4cbe8` | 本轮父仓库提交 | `TestInlineProviderReportsItsOwnState`，经 `ParseProxyProvider` 构造（`NewProxiesParser` 的 override 参数是包内类型，测试无法直接构造） |

`adapter/provider` 覆盖率 **67.1% → 76.8%**（statements）。

**剩余未覆盖（本轮盘点）**：`healthcheck.go` 的 `process` 轮询循环与 `RegisterHealthCheckTask`/`HealthCheck`（要真开 interval 与 HTTP 打点）、`provider.go` 的 compatible provider `Update`/`MarshalJSON`、`override_expr.go` 的 2 个 `eval` 重载（该文件 1683 语句已覆盖 77.8%）、`patch.go` 的 `GetSubscriptionInfo`（走 cachefile）。`adapter/outboundgroup` 剩下的 0% 全是 `DialContext`/`ListenPacketContext`/`SupportUDP` 一类接口方法，由 wrapper 与隧道侧测试在运行时覆盖。

### 2026-11-10 资料页缓存命中零分配轮次（性能）

宿主每打开一个分区就重读一次 base，而旧代码读回来的字节只用来和缓存比一遍，每次却都要一个 100KB 的新缓冲。现在比较走池化缓冲：命中即归还，未命中直接接管刚读到的字节继续解析，不再读第二遍。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `readProfile` 命中走 `profileBytes`：借池 `readFileInto` 读全文 → `bytes.Equal` → 归还；未命中接管池内字节，省掉第二次 `os.ReadFile` | -（仅 wrapper） | `0d66c43f` | n=7 交替 A/B：`BenchmarkMergeProfileBaseCached` sec/op 200 组 67.69µ → 57.75µ（**-14.67%**）、800 组 88.97µ → 62.53µ（**-29.72%**，两者 p=0.001）；B/op 32.5KB → 8.6KB（**-73.48%**）、104.5KB → 8.8KB（**-91.57%**）；allocs -1.75%。`BenchmarkHandleGetProfileBaseCached` 82.1µ/101.9KB/12 allocs → 54.4µ/3.6KB/10 allocs |

冷路径（`BenchmarkProfileReadAndMerge`）B/op +3.22% 已查明原因并接受：该基准 b.N≈66、每轮总分配约 200MB，触发约 50 次 GC，`sync.Pool` 每轮清空后要重建 64KB+101KB 缓冲；真实场景中是每次改配置一次性 165KB，换来 cached 路径每打开一个分区省约 100KB。sec/op 在噪声内（p=0.456）。

验证：wrapper 全量 ok；四平台 vet（windows/linux/darwin/amd64 + android/arm64）exit 0；focused race（`-run 'Profile\|Route\|Base\|Merge'`）除 `TestRouteVersionsPollLeavesRuleSetsToTheirEvent` 外全绿——该例在 HEAD 基线上同样复现（本轮把 `profile_cache.go` 单独换回基线后复跑确认），属既有 DATA RACE，与本次改动无关。

### 2026-11-10 代理表组刷新只走组行轮次（性能）

CPU 剖析（`BenchmarkHandleGetProxies`）显示答案路径 58% 落在 `refreshGroupDocs`/`refreshGroupDoc`：刷新组文档要先遍历**行对齐**的槽位表，为找 200 个组先扫过 1000+ 个节点行的 nil 检查。现在快照另带一张只含可建键组的紧凑表，且「表里有不可建键组 ⇒ 答案必须现场编码」这个事实在建快照时数一次（`unkeyed`），刷新循环里一个分支都不留。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 快照新增 `groupRows`（只收 `slot.group != nil` 的组）与 `unkeyed` 计数；`refreshGroupDocs` 只遍历紧凑表并直接返回 `snapshot.unkeyed > 0` | -（仅 wrapper） | `d1387757` | n=7 交替 A/B：`BenchmarkHandleGetProxies` sec/op 200 组/1000 节点 **-28.30%**、同形态 urltest **-28.85%**、200 组无节点 **-9.24%**、urltest 无节点 -10.27%、fallback 无节点 -13.01%、loadbalance 无节点 -5.35%、20 组无节点 -3.61%，geomean **-14.66%**（各 p≤0.002）；分配不变（2–3 allocs/答案） |

**中间实验（已撤销，记录路径本身）**：只加紧凑表、循环内保留 `slot.group == nil` 分支时，1000 节点形态 -18%，但纯组表（nodes=0）+9%~+10%；把该分支换成永假的 `slot == nil` 检查能把回退压到 +1.8%（判定为代码布局效应）。最终把分支整体移出循环（`unkeyed` 建快照时数一次）后两种形态才同时获益，保留了有效代码、没有无效分支。

### 2026-11-10 组槽按缓存行打包轮次（性能 + 精简）

剖析（上一轮改后）显示答案路径仍有过半落在 `refreshGroupDoc`，其中早退检查读 `slot.doc`/`slot.answerAt`/`slot.generation`/`slot.answer` 四个字段，而 `groupDocSlot` 当时 112 字节、这四个字段横跨两条缓存行；同时 `typ`/`fixed`/`live` 三个字段**全仓只有写入没有读取**（`slot.typ` 在构造时赋值后无人使用）——既拖慢又属死重。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 删除 `groupDocSlot` 的 `typ`/`fixed`/`live`；按「校验读的字段排在前面」重排，使 `answer`/`answerAt`/`generation`/`doc` 落在同一条缓存行 | -（仅 wrapper） | `40496d06` | 相对 `d1387757` n=7 交替 A/B：geomean **-1.71%**、urltest 无节点 **-4.03%**（p=0.001）、loadbalance 无节点 **-5.59%**（p=0.011），其余行在噪声内；分配不变。相对今日改前累计答案路径 **-15.00%** |


### 2026-11-10 ParseProxy 全分支覆盖轮次（测试，非性能）

「测试必须覆盖全部核心代码」这条在子模块上一直没做透：`adapter/parser.go` 的 `ParseProxy`（映射变成代理的唯一入口，29 个类型的 switch）此前只有 **8.6%** 覆盖——等于除 `ss` 之外谁都没解析过。

| 覆盖 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 表驱动用例逐个解析全部可达类型（含 fork 自有的 gost-relay/shadowquic/sudoku/masque/trusttunnel/rematch/easytier 与 openvpn/zerotier），外加 missing type、未知类型、解码失败三条错误分支与 options 传入（ProviderName 透传）路径 | `21a22f5f2` | `bbee578c` | `ParseProxy` **8.6% → 75.9%**；`adapter` 包 **62.1% → 85.2%**。密钥由测试现铸：wireguard 用随机 32 字节 base64，masque 现生成 P-256 密钥对（base64 DER/SPKI）。唯一未覆盖是 `tailscale`——默认构建用 build tag 关掉了它，分支存在但无法解析 |


### 2026-11-10 稳定态答案两次读轮次（性能，本会话最大单项）

剖析显示答案路径过半落在 `refreshGroupDoc`：稳定态下每个组都在做「读自己的答案代号 + 比较 + 早退」。既然要的只是「有没有动过」，就不该逐组问。子模块因此增加一个进程级代号：**任何组的答案移动都 +1**（pin 与自行改选两条写入口都写它），wrapper 在快照上记住「上一次全量校验前读到的代号」，稳定态答案只做两次原子读 + 一次 provider 代号码，然后直接复印缓存文档。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 子模块 `adapter/outboundgroup` | 72.7% | 0% 全是 `DialContext`/`ListenPacketContext`/`SupportUDP` 一类接口方法，由 wrapper 与隧道测试在运行时覆盖 |
| wrapper `refreshGroupDocs` 快路径：`validated` + `answersSeen`/`providersSeen` 两个戳记，任一较新才走全量；戳记同样取「校验前读到的值」，与按槽 `answerAt` 的「编码前读」同款保守 | -（仅 wrapper） | `9b143f7c` | n=7 交替 A/B：`BenchmarkHandleGetProxies` sec/op 200 组/无节点 883.8n → **186.8n（-78.86%）**、200 组/1000 节点 864.7n → 183.0n（**-78.84%**）、urltest -79.60%/-79.80%、fallback -81.41%、loadbalance -74.63%、20 组 -23.20%，geomean **-74.68%**（各 p=0.001）；**分配不变（2–3 allocs/答案）** |

**正确性**：选中变更与订阅刷新两条路径早已被 `TestGroupDocsAnswerWhatTheirGroupsChange` 钉住（`selectable.Set` 后下一答案必须反映 `now`/`fixed`，provider swap 后必须反映成员表），本轮全量通过。miss 路径（换表重建）无回退：+1.55%（p=0.310，噪声内），分配逐项一致。

**为什么不更早做**：它要求子模块先提供"有没有动"的单一真相源。此前轮次只把 URLTest/Fallback 的 `Now()` 解析换成了代号（见 2026-11-09 各轮次），而"逐组问一遍"这件事本身，只有当 wrapper 侧拿着一个可比较的快照级戳记时才能省掉。


### 2026-11-10 表身份直读轮次（性能，接上一轮）

上一轮把答案路径压到约 190ns 后，剖析显示 `reflect.Value.Pointer` 仍占 4.3%：每次答案要为「这两张代理表是不是同一张」问 reflect 要地址，一个答案要问约 6 次。map 变量的那一个字就是它指向的表的地址，直接读那一个字即可。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `sameProxySnapshot`/`cachedProxiesSnapshot`/`routeGroupProjections` 的比较改走 `snapshotIdentity`（`*(*uintptr)(unsafe.Pointer(&table))`），四个缓存的 `snapshot any` 字段随之改为具体 map 类型；`reflect` 从 `core/proxy.go` 的 import 中移除 | -（仅 wrapper） | `0730546a` | n=7 交替 A/B：`BenchmarkHandleGetProxies` geomean **-12.93%**（197.8n → 172.2n），各行 **-10.70% ~ -15.46%**（p≤0.026）；分配不变。`TestSnapshotIdentityIsTheTablesOwnAddress` 把「一个字就是表的地址」与 reflect 的答案钉在一起，未来 Go 若改 map 表示，测试失败而不是答案静默出错 |

**本会话答案路径累计**（`BenchmarkHandleGetProxies`，200 组/20 成员）：5.105µ → **0.163µ**（约 31 倍），分配 -96%（101.9KB → 3.6KB 的那一轮见资料页小节）。


### 2026-11-10 wrapper 覆盖缺口记账（哪些 0% 是结构性的，不动代码）

「测试必须覆盖全部核心代码」这条留一个尾巴：wrapper 全量覆盖率 93.6%，剩余 0% 的六个函数逐个查过，结论是**都不该为覆盖而改代码**：

| 位置 | 为什么为 0% |
|---|---|
| `core/server.go:StartServer` | IPC 服务端入口，测试直接走 `dispatchMethodCall`；起真监听要占管道/端口，跨平台不稳 |
| `core/method.go:handleCrash` | `core.crash` 这个 dev 方法就是 `go handleCrash()` 故意让进程崩，测试跑了它也活不下来；`TestEveryCoreMethodConstantIsDispatchable` 已把它单独记账 |
| `core/request_traffic.go:clear` | 只在「没有事件监听者」时走到，而桌面构建的 `hasEventListener()` 恒返回 true（`server.go:54`，注释即原因）；Android 构建（`lib.go:321`）返回真实标志位，该分支在 Android 上可达 |
| `core/dial_pipe.go:dial` | 宿主把管道交给核心的那条 dialer，测试用 `dispatchMethodCall` 与真 tracker 绕开了它 |
| `core/exit.go:ExitOnTermination`、`core/ownership_other.go` 三个 | 平台粘合：桌面/Windows 专有路径，当前宿主不触发 |

余下非 0% 的零散分支（`method.go:encodeResponse` 50%、`server.go:writeAll` 90% 等）都是磁盘/网络错误分支，属「写失败才走到」，与正常答案路径无关。子模块侧剩余缺口另见 2026-11-09 provider 轮次小结（healthcheck 轮询、`*.pb.go` 生成代码、接口方法的运行时覆盖）。

### 2026-11-10 答案结构随投影缓存轮次（性能，答案路径收官）

答案路径降到 170ns 后，逐项看剩下的 3 次分配：`proxiesAnswer` 结构体每答案新建一次，而它的两个字段（表与名单）正是投影缓存已经持有的东西，且结构体本身只读。随缓存一起给它一个位置即可。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `groupProjectionCache` 增持 `answer *proxiesAnswer`，命中即原样返回（结构体不可变：只有 `proxies`/`names` 两个字段，`document()` 改的是全局槽与帧缓存，不改自己） | -（仅 wrapper） | `131ba6da` | n=7 交替 A/B：sec/op geomean **-11.63%**（各行 -9.65% ~ -12.60%），B/op 96 → **64**、allocs 3 → **2**（-36%）。200 组答案路径 **164.0n → 145.7n** |

**偶发失败记录**：一次全量里 `TestRouteVersionsPollLeavesRuleSetsToTheirEvent` 在 2 秒截止时间（`route_test.go:440`）上超时失败，紧接其后的两次全量与单跑均通过；失败前机器刚跑完 7 轮 A/B（编译与基准负载拉满）。判定为负载型偶发，与代码无关，但它是这条链路上第二个不稳定点（另一个是 `-race` 下必现的 DATA RACE，见第 7 节）。


### 2026-11-10 大答案 header 池化轮次（性能，答案路径收官）

信封契约那条路两次被否之后（见第 3 节），答案路径仍剩 2 次分配。逐个归因：`envelope(id)` 一次、大文档路径的 `header := make([]byte, 4+len(answer.head))` 一次。后者的大小只由 id 决定，与答案本身无关，却每答案分配一次。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `writeFrame` 大文档路径的 header 改从 `frameHeaderBuffers` 池取（初始 256B，够 `{"id":"` + 转义 id + `","result":` 的最坏形态），写完三个 piece 即归还；沿用 `maxPooledFrameSize` 作上限，超限的缓冲丢弃而不是常驻 | -（仅 wrapper） | `02858294` | n=7 交替 A/B：`BenchmarkHandleGetProxies` sec/op geomean **-2.17%**，200 组各行 **-1.29% ~ -3.52%**（p≤0.029）；B/op 64 → **32**、allocs 2 → **1**（各行均 -50%）。小文档路径不变（本就不分配 header）。至此答案路径 **2 allocs → 1**，唯一剩下的是信封本身 |

### 2026-11-10 statistic 覆盖补全轮次（测试）

「测试必须覆盖全部核心代码」在子模块的最小包上收口：`tunnel/statistic` 83.8%，而 0% 的恰是**仪表盘每秒读的计数器、连接页每次拉的整表、以及 tracker 交出去的计数包装**——全是宿主真的在读的东西。

| 覆盖 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `Manager` 的 `Size`/`Now`/`Total`/`swapUploadTemp`/`swapDownloadTemp`/`swapProxyUploadTemp`/`swapProxyDownloadTemp`/`ResetStatistic`/`Get`/`Range`/`Join`/`Leave`/`AppendJSON`（含空表与带连接两种形态、以及「blip 只在 tick 动、push 不动」这条易错点） | `3cce3749f` | `c4492a89` | `TestManagerCountersAnswerWhatAPushLeftAndASwapTakes`、`TestManagerSizeAndLookupFollowJoinsAndLeaves`、`TestManagerAppendJSONCarriesTheCountersAndTheRows` |
| `tcpCounterConn` 的 `Read`/`Write`/`ReadBuffer`/`WriteBuffer`（转发后计数仍落 tracker）与 `ReaderReplaceable`/`WriterReplaceable`（不可替换）；`udpTracker` 的 `ID`/`Upstream`/`WaitReadFrom` | `3cce3749f` | `c4492a89` | `TestTCPTrackerCounterKeepsAccountingAndRefusesReplacement`、`TestUDPTrackerAnswersItsIdItsConnAndAWait`。`tunnel/statistic` **83.8% → 94.4%** |

remaining uncovered there is the 1s ticker loop in `handle` and tracker-level read/write of the raw conn, which the existing direction tests already drive through a real pipe.


### 2026-11-10 DNS 拨号器覆盖轮次（测试）

「测试必须覆盖全部核心代码」的下一站：`tunnel/dns_dialer.go`（fork 自己写的 DNS 专用拨号器，189 行）此前 **0% 覆盖**——DNS 模块把每个查询交给它，而它一天都没被测试走过。

| 覆盖 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `DNSDialer.DialContext`/`ListenPacket`/`NewDNSDialer`：无法解析的地址、主机解析失败、代理不支持 UDP、代理自身拨号/监听失败、两种传输经适配器成功返回、按隧道持有的名字选中代理（`SpecialProxy` 置位）、未知名字交回平台接口 | `f6e0a19ca` | `2e63a485` | 7 个用例全过，`NewDNSDialer` 100%、`DialContext` 62.5%、`ListenPacket` 77.1%；**tunnel 包 60.5% → 69.2%**。测试自持 resolver 与 adapter（`dnsTestResolver`/`dnsTestAdapter`），查询不出进程；平台拨号路径只断言"平台自己回答了，而不是某个 proxy"，不锁平台措辞 |


### 2026-11-10 UDP 回写面覆盖轮次（测试，接上一轮）

| 覆盖 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `packetSender` 的 `Deadline`/`Done`/`Err`/`Value`/`DoSniff`（关闭前后 `Err` 从 nil 变 `context.Canceled`）；`handleUDPToRemote` 的「无地址即拒绝」与「写入调用方交来的 conn」两条路径 | `3cc42fe55` | `d269284e` | 2 个用例。**tunnel 69.2% → 70.0%**。此后 tunnel 剩余 0% 全是接口转发行与 `initUDP` 这类需真网络的入口 |


### 2026-11-10 代理读取面覆盖轮次（测试，收官当日覆盖三连）

| 覆盖 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `Proxy.Adapter`/`DelayHistory`/`DelayHistoryForTestUrl`（隧道对代理的三次读取，含「从未答过的代理返回 nil 而不是 panic」）；`urlToMetadata` 的默认端口三态、非法 URL、以及「scheme 不带端口即按名拒绝」 | `3e99932c5` | 本轮父仓库提交 | 2 个用例；**adapter 85.2% → 86.7%** |


### 2026-11-11 tunnel 表面与路由覆盖轮次（测试，收口「覆盖全部核心代码」）

把「测试必须覆盖全部核心代码」在子模块上收口：`tunnel` 从 60.5% 一路推到 **76.5%**，逐块补的都是 fork 自己写的真逻辑或宿主每次答案都要读的存取器。

| 覆盖 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `ResolveRoute`（不拨号就问路由，宿主给连接命名用的）：match 表选中代理、空表返回 (nil, nil) 而不报错 | `e4891c7d3` | 本轮父仓库提交 | 0% → 80%（剩 `preHandleMetadata` 失败分支，构造代价不值） |
| `tunnel.go` 存取器面：`Proxies/Providers/RuleProviders/Rules`（包级与接口版同一张表）、`Mode/SetMode`、`FindProcessMode/SetFindProcessMode`、`Status/OnSuspend/OnInnerLoading/OnRunning`、`IsSniffing/SetSniffing`（无 sniffer 时不动、装了 enabled sniffer 后开、可关）、`NatTable`（两个）、`RuleUpdateCallback`；`HandleUDPPacket` 丢弃无 flow key 的包 | `d59a5a3e7` | 本轮父仓库提交 | tunnel 74.6% → **76.5%** |
| `packetSender.Process`（UDP worker 的主循环）：交给它的包被处理、`Close()` 后循环退出；`idlePacketConn.Upstream()` | `d59a5a3e7` | 本轮父仓库提交 | 0% → 覆盖。剩余 0% 只有 `processUDP`/`startUDPSender`/`dialUDPSender`（真 UDP 往返 + 代理拨号）与两个 error 分支 |


### 2026-11-11 wrapper 残余路径覆盖两轮（测试）

wrapper 93.8%。剩余低覆盖逐个查过，取两条有真实逻辑的：

| 覆盖 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `writeRuleSetFile`（temp 文件 + rename 的原子写）：替换已存在的集、temp 不残留；父路径是文件 → MkdirAll 报错；目标是目录 → rename 失败并带走 temp | -（仅 wrapper） | `d6b013eb` | 3 个用例。`writeRuleSetFile` 64.7% → **82.4%** |
| `pollRoute`：上下文已取消即退出（不等下一个 tick）；活着时跨过一个 tick 仍在轮询；再取消才退 | -（仅 wrapper） | `d6b013eb` | 2 个用例（第二个跨 5s tick，耗时 5.35s）。`pollRoute` 71.4% → **100%** |


### 2026-11-11 `AllProxies` 免读锁轮次（性能，子模块）

剖析答案路径时发现：`tunnel.AllProxies()` 单独测 **17.73ns / 0 alloc**，占答案路径约 9%，而它只是个读——却为"比较 provider 版本 + 返回 map"拿了写锁。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `allProxies`/`allProxiesVersions` 两个全局合并为单个 `atomic.Pointer[allProxiesTable]`（表 + 构建时的 provider 版本同指针发布，读者见两者或都不见）；`AllProxies` 读路径免锁，只有重建加锁，且锁内先重查缓存避免重复重建装两张表 | `c4a135561` | `443b9842` | 微基准 `AllProxies` 17.73n → **9.4n（-47%）**；端到端 n=7 交替 A/B：`BenchmarkHandleGetProxies` geomean **-6.02%**，200 组各行 **-4.97% ~ -7.73%**（p≤0.026），**分配不变**。`TestAllProxiesCacheAndInvalidation` 继续钉住缓存存活、版本保持、四种失效与显式丢弃 |


### 2026-11-11 `GetProxyNameList` 免读锁轮次（性能，子模块，接上一轮）

上一轮拆掉 `AllProxies` 的锁后，剖析里剩下最后一个每答案锁：`config.GetProxyNameList()` 单独测 **12.62ns / 0 alloc**，几乎全是 RWMutex 读锁成本，占答案路径约 6%。而名单是**整体替换**（`SetProxyNameList` 每次配置解析调用一次，包装的就是解析建的那片），从未原地改。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `proxyNameList`/`proxyNameListMu` 换成单个 `atomic.Pointer[[]string]`；读只做一次原子加载 | `697114569` | 本轮父仓库提交 | 微基准 **12.62n → 0.45n（-96%）**；端到端 n=7 交替 A/B：`BenchmarkHandleGetProxies` geomean **-5.69%**，各行 **-4.50% ~ -7.08%**（p≤0.038），**分配不变**。叠加 `AllProxies` 那轮的 -6.02%，两次免锁合计答案路径 geomean **约 -11.3%** |


### 2026-11-11 信封就地构建轮次（性能，答案路径归零分配）

此前账本按「每秒几十字节」判过信封不值得改，漏看了**单次成本**：`envelope("benchmark")` 微基准实测 **27.6ns / 32B / 1 alloc**，占答案路径约 24%。而它写出的字节随后就被 `writeFrame` 拷进池化缓冲——纯浪费。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `frame` 增加 `id` 字段：携带文档的答案改为"指名调用"而非"携带信封字节"；信封在**消费点就地构建**——小路径直接 append 进池化写缓冲、大路径进池化 header、整片调用方进自己的缓冲；`spillFrame` 落盘前才物化。信封预留容量按"全转义 id 的宽度"用算术算，不再为预留多扫一遍 id | `a18f91a0` | -（仅 wrapper） | n=7 交替 A/B：**每答案 1 alloc/32B → 0 alloc/0B（-100%）**；sec/op geomean **-2.92%**，小文档路径 **-6.10%**（p=0.001），大文档各行全部在噪声内无回退（p=0.209~0.929）。`frame_test.go` 的 `answerFrame` 同步改走 id 形态，其余测试原样通过 |

**与 2026-11-09 否决的关系**：那次否掉的是"frame 携带 id 且 `size()`/`appendEnvelope` 各扫一遍 id"的写法（测出 +19%~+24%）。本次的差别是**预留容量走算术不扫描**，且小路径把信封直接写进已定大小的池缓冲（不多一次 StringLen）。同一思路、不同实现，结论相反。

**覆盖**：新代码 `size`/`bytes`/`envelopeLen`/`appendEnvelope` 均 100%。等价不变量由既有测试显式钉住——`connection_test.go:96/99/316/319` 把 id 形态与匿名形态的信封字节分别对拍 `json.Marshal(MethodResponse{...})` 的输出（四条全过，`frame_test.go` 的 `answerFrame` 已改走 id 形态）。spill 路径的 head 物化由 `TestHandleMethodCallSpillsAFrameWriterDocument` 覆盖。

### 2026-11-11 structure `getFold` 折叠缓存轮次（性能，撤销）

`getFold` 每个字段查找都对 map 的每个 key 跑一遍 `KeyReplacer.Replace`；把折叠结果按 replacer 缓存（`foldList`，每张 map 一个 slice）后，harness 汇总看着像 -4.6%。配对基准给出相反判决：`BenchmarkParseRawConfigBig`（800 节点 + 200 组 + 200 规则的文档，unmarshal + parse）n=7 交替：**sec/op 13.46ms → 13.68ms（+1.6%）**、**B/op 6.209MB → 6.314MB（+1.7%）**、**allocs 104,468 → 105,881（+1.4%）**——每张 map 多出的 fold slice 比省下的 Replace 扫描更贵。已撤销。

副产品（保留）：`BenchmarkParseRawConfigBig` 基线 = **13.59ms / 6.209MB / 104,385 allocs**，其中 YAML 反序列化约 9.3ms（`go.yaml.in/yaml/v3` 词法/解析，上游库，占 70%），`ParseRawConfig` 约 4.2ms（剖析：YAML 解析 ~30%、`structure.getFold` ~28%、GC ~15%）。启动文档成本的大头在反序列化，产品侧无可动之处；`ParseRawConfig` 内部此前多轮已挖过（延迟历史、options 指针、UUID 内联）。

### 2026-11-11 连接轮询稳态免扫描轮次（性能，wrapper + 子模块）

账本此前两轮都判过「连接轮询维持不做」：`row.stale(info)` 被当成生产永不触发的防御（2026-11-09），`Manager.Range` 占 delta 基准 80% cum 被当成「接口 map 查询 + 回调」的固有成本（2026-11-08）。本轮重新剖析换了个问法：**稳态轮询为什么还要走一遍全表？**

剖析（`BenchmarkGetConnectionsDelta/connections=500` cpuprofile）：`handleGetConnections` cum 82.9%，其中 `xsync.Map.Range` 79.6% cum、`connectionRow.stale` **23.7% flat（单点最大）**、`tcpTracker.Info` 9.2%、`mapaccess2` 22.4% cum（`connectionRows.rows[tracker]` 接口 map 查询）。也就是说：一次「什么也没发生」的轮询，CPU 全花在证明「什么也没发生」上。

两个可动点依次落地：

1. **`stale` 整段删除**：逐字段全子模块 grep（排除测试）证实 tracker 的 metadata 只有构造期写入（`NewTCPTracker`/`NewUDPTracker` 的值拷贝 + 构造期 `RemoteDst`），没有任何生产路径原地改 `Info().Metadata` 的字段；`connectionRow` 的十个镜像字段与每次新建行的两个 `slices.Clone` 随之删除，行只留 `tracker/id/generation`。子模块测试 `TestTrackerClonesMetadataIntoCreationSnapshot` 增加「流量穿过 live tracker 之后快照字段不变、指针不变」的断言，把这条不变量钉在测试里而不是只靠 grep。
2. **稳态免扫描**：子模块 `Manager` 增 `members` 计数器，`Join`/`Leave` 在 map 操作**之后**各 +1（保证读到新值时背后的变更已可见），并暴露 `Generation()`；wrapper 记「上一次全表走到的 generation」，非 resync 轮询在「generation 未动 且 表层数与本地 `order` 等长」时直接返回上一次已证明的空 delta。两个条件都用上是因为计数 bump 尾随 map 操作：只有 generation 相等可能漏掉「已 Store、未 bump」，只有 Size 相等可能漏掉「bump 先于 Size 可见」，取交集才无遗漏。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 连接轮询稳态免扫描（`Manager.Generation()` + wrapper 快路径 + 删 stale 镜像字段） | `5018ea4c4` | `9e4bbd64` | `BenchmarkGetConnectionsDelta` paired n=5：100 连接 5.133µs → 422.4ns（**-91.77%**，p=0.008）、500 连接 32.78µs → 371.4ns（**-98.87%**，p=0.008），geomean **-96.95%**；**分配 6、内存 308B 全部不变**。新增 `BenchmarkGetConnectionsDeltaWalk`（每轮 leave+join 两个预建 tracker）钉住表变动路径：100 连接 2.39µs/2.44KB/13 allocs、500 连接 2.15µs/2.31KB/13 allocs。验证：子模块 104 包全量 + `go vet ./...` 通过、statistic 四平台 vet（windows/linux/darwin/android arm64）exit 0、wrapper 全量测试 + vet 通过、四平台 vet exit 0、connection focused race（mingw64 gcc）通过 |

**与 2026-11-09 否决的关系**：那次否掉的是「删 stale 不改轮询」（那时没有 generation，删了字段比较省不下 Range 的 80%）；本轮把 Range 本身在稳态短路掉，字段比较随之失去存在理由。测试里「原地改 `Metadata.Process` 驱动 stale」的场景改写为「快照只在读取时被看到」，并新增断言：改字段后的稳态轮询仍答空、resync 携带读取时值。

### 2026-11-11 晚间 Dart 侧连接排序轮次（性能，UI isolate）

账本此前两度把 `TrackerSpeedRanker` 记为「-10% 后维持」，测量口径是 10k ×20 快照总量。本轮换口径（每次 `rank` 的墙钟）重跑，发现 10k 连接每个快照要 **10.4ms**——按规则「120Hz 下每帧 ≤8ms UI 工作」单独就超预算，是连接页在万级连接下掉帧的原因。剖析拆开：每次 `rank` 要把 1 万个连接 id 做三张 map 的清空+重填（`_samples`、`_outputs`、`_positions`），另加 1 万次查找；10k 行的 `copyWith` 实测 102ns/行（1.02ms/快照），字符串 map 查找 62ns/次（0.62ms/快照）。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `rank` 的 per-poll 三张 map 合并为一张按 id 的状态表（样本+已发布行+槽位），用 poll stamp 恢复「缺席一轮就重新开始」的旧语义；顺带删掉两处可证明死工作的 `-1` 填充（计数排序保证每个槽位必被写一次） | -（仅 Dart） | `ec5b76d4` | `tracker_speed_ranker_benchmark_test.dart` JIT（`@Skip` 临时摘除、跑完还原）：10k 连接 ×20 快照 **10402µs → 4087µs/快照（-60.7%）**，同批 "unchanged rows" 453µs → 262µs/次（-42%）；三遍复测 4135/4222/4211µs，判定取 ~4.19ms。探针实测：`copyWith` 102ns/行、map 查找 62ns/次、桶位数学 15ns/行、四个 typed 数组分配 51.9µs/次——余量主要在 `copyWith` 与十余遍 1 万次 typed 遍历，均属该形状的固有成本（再降要改模型的公开契约），记账不动 |

**语义等价论证**：`_outputs` 连「未复制的输入实例」也存（第二次同速调用因此返回同一实例），状态表照搬（未变行也写 `row.output`）；`_sample` 的 500ms 间隔分支返回的是上一份样本本身，状态表现在只改 stamp 不改字段，等价；缺席一轮的行 stamp 不匹配 → 新建，等价于旧实现的整表清空；清理阈值 `_purgeSlack=1024` 只在「过期行数超过 1024」时触发一次无哈希遍历，摊到每次 join 约 10 次迭代。新增两条测试：离开又回来的连接从头开始（不把跨间隔的增量当成尖峰）、过期行数超过阈值后存活行的顺序与速度不变（churn 下清理不被察觉）。

**验证**：`flutter test test/features/tracker_speed_ranker_test.dart`、`test/widgets/connections_view_test.dart`、`test/views/dashboard/connections_table_test.dart` 全绿；`dart analyze --fatal-infos` 两文件零告警；Dart 全量 `dart run tool/test.dart` 5179 个用例，失败集与账本第 7 节记录的 5 个既有失败完全一致（4 个 `Linux ...` mitm + 1 个 Windows 窗口探针计数），无新增。

| `num.compact`（`NumberFormat.compact(locale:"en")`）换成手写 K/M/B 后缀 | 否决，本轮实测 2041 个 0..12.3B 采样值错 1936 个。它的真实规则是 `minimumSignificantDigits=3` 加上 `_styleForNumber` 里按量级逐级 `updateRounding()` 进位传播：7755 打印 `7.75K` 是截断，9999 打印 `10K`、10857 打印 `10.9K` 又带进位，123456 打印 `123K` 而 12345678901 打印 `12.3B`（进位跨量级还会换后缀）。本轮试过固定 2 位小数、四舍五入、截断三种写法，分别错 8/6/1936 处，无法用廉价实现复刻。且 `lib` 中真实调用点只有 6 处（图标数、订阅节点数等），均不在帧热路径；`compact` 仍用于 `dashboardCount` 的 `>100000` 分支与这些低频处。若将来要改，必须照抄 significant-digit 那一趟，并配同形状的比对基准。 |

## 4. 当前验证矩阵

### 连接答案路径覆盖收口（2026-11-09）

`core/connection.go` 的 18 个函数现已 **100% 覆盖**（此前 `appendDocument` 68.8%、`documentSize` 71.4%、`rowAnswerSize` 81.8%、`handleResetNetwork` 0%）。补齐的四条都是仪表盘真实会走到的路径：带 GeoIP 的行（答案缓冲按 `rowAnswerSize` 预分配，两个字符串切片若不计入，每次 resync 都会扩容）、nil 行、一次轮询里离开多行的分隔符、按 id 关闭存活行。另外钉住一条不变量：`rowAnswerSize` 永不低于编码后长度（预分配就靠它）。父仓库 `b8bd4801`，包覆盖率 82.9% → 83.3%。

### 2026-11-12 vless encryption 覆盖轮次（测试，`transport/vless/encryption` 0% -> 80.5%）

「测试必须覆盖全部核心代码」的下一站：`transport/vless/encryption`（VLESS `mlkem768x25519plus` 的整套握手与帧层，1183 行）此前整包 **0% 覆盖**——只有一条打印 CPU 特性的用例跑过，而客户端握手、服务端握手、AEAD、XOR 伪装层一天都没被直接测试走过。listener 层的 `TestInboundVless_Encryption` 走的是完整的 TCP 入站/出站，路径虽长但断言不到帧边界，改坏了 XOR 掩码或 nonce 进位它照样绿。

| 覆盖 | core 提交 | 结果 |
|---|---|---|
| `XorConn` 读写状态机：跳过区、跨写边界的半截 header、跳过长度回填、空写、读端 mask 后交还原样、写失败上抛（8 例） | 本轮 | `xor.go` `Write`/`Read`/`NewXorConn` 全部 100% |
| 帧契约：`EncodeHeader`/`DecodeHeader` 的全部拒绝形状、`EncodeLength`/`DecodeLength` 往返、`IncreaseNonce` 逐字节进位与满格回绕、`AEAD` nonce 自增与重放拒绝、附加数据认证、上下文分流、`MaxNonce` 触发的 AEAD 轮换、chacha20poly1305 分支（13 例） | 本轮 | `common.go` 编解码与 AEAD 全部 100%，`ParsePadding` 87% |
| 配置入口：`NewClient`/`NewServer` 的 scheme/mode/rtt/base64/密钥长度拒绝、空串与 `none` 返回 nil、`Init` 重复初始化与空密钥集拒绝、`Close` 落 flag、未初始化 `Handshake` 拒绝（16 例） | 本轮 | `factory.go` 各 86.7%/86.5%，`key.go` 71% |
| 真实握手：三种 xor 模式（native/xorpub/random）经 TCP loopback 完成握手并双向传帧、32000 字节写切分为多条记录、读缓冲小于记录时剩余部分由内部缓冲续传、0-RTT 票据路径发整车并惰性由首个记录冲刷、服务端对无法解析的招呼直接失败（12 例） | 本轮 | `client.Handshake` 89.2%、`server.Handshake` 67.4%；**整包 0% -> 80.5%** |

**踩坑（后续复用，四个都会再犯）**：一、**客户端与服务端必须共享同一对 X25519 与同一个 ML-KEM 种子**——第一次写测试时我分别调 `GenX25519` 生成公私各一份，服务端立刻报 `unexpected hash32: [...]`。二、握手的 fragmented padding 写与随后服务端的读必须跑在**内核有缓冲的 socket** 上：`net.Pipe` 全同步无缓冲，两边都在写后等读，第一片 padding 就死锁；换成 `127.0.0.1:0` 的 TCP loopback 即通。三、`handshakePair` 里 `defer conn.Close()` 会在函数返回时拆掉刚握完的连接，后续帧传输全报 `use of closed network connection`；关闭责任交给 `t.Cleanup`。四、padding 字符串的约束是**首段 >=100 且第二三字段 >=35**（`100-0-0` 会被 `ParsePadding` 拒），而尾随 `.` 会产生空段同样被拒；0-RTT 的 `clientHello` 不在握手时落盘，要等第一次 `CommonConn.Write` 才连同 `PreWrite` 一起冲刷（客户端握手本身不读服务端任何字节）。

### 2026-11-12 listener/sudoku 覆盖轮次（测试，2.3% -> 12.6%）

「测试必须覆盖全部核心代码」的下一站：`listener/sudoku`（Sudoku 入站监听器，326 行）。该包此前**只有 UoT wrapper 被覆盖**，`New`、`handleConn`、`handleUoTSession`、`relayToFallback` 与三个访问器全是 0%。入站层 `listener/inbound/sudoku_test.go` 已用真实出站打通 basic/entropy/padding/packed-downlink/custom-table/http-mask-mode 九种组合，但它到不了帧边界：改坏 fallback 重放或 deadline 包装它照样绿。

| 覆盖 | core 提交 | 结果 |
|---|---|---|
| `wrapSessionConn` 两条分支：pipe 原样短路（pipe 自带的 deadline 实现已正确，再包一层会让握手超时失效）、裸 socket 由 wrapper 提供真实 deadline 并用一次读超时钉住 | 本轮 | `wrapSessionConn` 100% |
| `Listener.RawAddress`/`Address`/`Close`：无 listener 时地址回落空串、关闭置 flag、对已关闭 socket 二次关闭返回错误而非 panic | 本轮 | 三个访问器与 `Close` 100% |
| `relayToFallback`：把失败握手前已读走的字节原样重放给 fallback 再交给 `N.Relay`；无缓冲记录时不阻塞 | 本轮 | `relayToFallback` 72.7% |
| `uotPacket.Data`：交出 reader 产出的 payload 且不随 `Drop` 失效 | 本轮 | `Data` 100% |

**结构性未覆盖（记账，硬要盖就得把入站测试的整套 tunnel 基建搬进本包）**：`New`（需要 `C.InboundListenConfig` + 可监听 socket + `sing.ListenerHandler`）、`handleConn`（需要一次成功的 sudoku 握手）、`handleUoTSession`（需要 UoT 会话）。这三段的真实链路已由入站层九种组合覆盖，本包内再盖一遍等于把 `TestTunnel`/`NewHttpTestTunnel` 从 `inbound_test` 复制过来，收益是数字而非守护；`TestTunnel` 属 `inbound_test` 包内部设施，跨包不可引用。

**踩坑（后续复用）**：`relayToFallback` 的测试不能用同一个 `net.Pipe` 同时充当 wrapper、rawConn 与 fallback——`N.Relay(rawConn, fallback)` 是双向对接，自接自会让两边互等至超时；且 `t.Cleanup` 关管道的时机要晚于 relay goroutine 退出，否则 goroutine 里的断言在 cleanup 后触发 panic。正确形状是给 fallback 与 raw 各配一对独立 pipe，用 `io.ReadFull` 盯住重放字节，再主动关 raw 让 relay 返回。

### 2026-11-11 UDP 数据报主路径覆盖轮次（测试）

账本「覆盖侧剩余缺口」表里写着子模块 `tunnel` 剩 `processUDP`/`startUDPSender`/`dialUDPSender`——用 coverprofile 逐函数核了一遍：这三个函数分别 50%/0%/0%，`handleUDPConn` 58.1%。它们合起来就是「一个数据报从进来到被代理应答」的完整路径，产品每时每刻都在走，却一行覆盖都没有。此前没测是因为它们需要真 UDP 往返 + 一个能 `ListenPacketContext` 的代理。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 两个测试从真实入口 `tunnel.HandleUDPPacket` 驱动整条路径：一个代理应答本地 echo 服务器（覆盖入队→`processUDP`→`handleUDPConn`→`startUDPSender`→`dialUDPSender`→`handleUDPToLocal`→write-back 回包），一个代理拒绝（覆盖 `startUDPSender` 的错误分支：flow 不留表、不计连接、已入队数据报被 drop） | `302f80350` | 本轮父仓库提交 | `tunnel` 包覆盖 **76.5% → 82.7%**：`processUDP` 0/100%、`handleUDPConn` 58.1% → 80.6%、`startUDPSender` 0% → 100%、`dialUDPSender` 0% → 89.6%。`go test ./tunnel/ -count=3` 连续三遍通过；子模块全量 104 包 ok；tunnel 四平台 vet exit 0 |

**踩过的坑（已写进测试注释，后续复用）**：① `net.DialUDP` 得到的是**已连接** socket，`WriteTo` 直接报 `use of WriteTo with pre-connected connection`——代理必须用 `net.ListenPacket` 给未连接 socket；② flow key 是源地址 SNAT 键，`tunnel_test.go` 的既有用例在 `require.Eventually` 里用 `natTable.GetOrCreate` 探测，会**留下一个没有 Process 循环的 sender**，同源端口的新测试必须像既有用例那样先 `DeleteForFlow`，否则新数据报入队后无人写；③ 断言「表里没有条目」有竞态（worker 还没处理时表里本来就没有），必须等一个确定终态（数据报被 drop）再查表；④ 自定义错误不在 `shouldStopRetry` 的终态分类里，重试要走满预算（10 次），等待窗口至少 8s。
### 2026-11-11 wrapper IPC 入口覆盖轮次（测试）

`StartServer` 是桌面宿主真正使用的入口（宿主打开管道 -> 把名字交给 Core -> Core 拨号并应答），此前只测了 `dispatchMethodCall`，`dial` 与 `StartServer` 都是 0%。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `ipc_pipe_test.go`（仅 windows 构建）用 go-winio 自开一条随机名管道，交给 `StartServer` 拨号，写一个真实 `connection.count` 调用帧并读回答，宿主断开后 `serve` 返回且全局 conn 归零；测试自存自恢复全局 `conn`，只在本次把 `isInit` 置 false，避免动既有测试的关闭链 | -（仅 wrapper） | `d690a294` | wrapper 覆盖 **93.7% -> 93.9%**：`dial` 0 -> 100%、`readFrame` -> 100%、`serve` 58.1% -> 89.3%、`send` -> 97.1%。全量 `go test . -count=1` 通过 |

**为什么不再往前推**：`ExitOnTermination`（信号驱动、调用 `os.Exit`）、`handleCrash`（就是让进程崩的开发者旋钮）、`initOwnership`（非桌面平台的归属重置）、`encodeResponse` 的 `json.Marshal` 失败分支——都要「让进程死 / 让上游库失败」，按账本「不为凑数写测试」的纪律维持现状。
### 2026-11-11 组的 UDP 数据报路径覆盖轮次（测试）

账本记着子模块 adapter/outboundgroup 的 0%「由 wrapper 与隧道测试在运行时覆盖」——那只是「运行时会走到」，并没有任何测试驱动它。本轮把它变成真事：wrapper 里用现成的 selectorGroup（真 Selector + 兼容 provider + 真实 DIRECT 成员）直接调用组的 ListenPacketContext，与本地 echo 服务器完成一次 UDP 往返。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| udp_group_test.go：规则选组 -> 组选成员 -> 成员承载数据报，真实 Selector 走组自己的 packet 路径 | -（仅 wrapper） | 76c95b55 | 新增 1 例 focused 一次通过；wrapper 全量 go test . -count=1 ok + go vet 零告警。注：组包的覆盖率数字不变（该测试跑在 wrapper，不在 outboundgroup 包内）——把该 0% 从「运行时顺带」变成「有测试驱动」 |

**为什么不在子模块包里测**：adapter/outboundgroup 依赖 adapter -> adapter/outbound -> dns -> tunnel，从 tunnel 包的测试反向 import 会成环；外部测试包（outboundgroup_test）同样成环。可放之处只有 wrapper，那里这些依赖本就齐全（hub_test.go 的组脚手架即出自此处）。

### 2026-11-09 验证矩阵（当前状态，父仓库 main `d43b5bea` / 子模块 `3d6e4cbe8`）

| 验证项 | 命令 | 结果 |
|---|---|---|
| 子模块全量 | `go test ./... -count=1 -p=1`（Clash.Meta） | **104 包 ok，exit 0**（本轮子模块改动后重跑） |
| 子模块 vet | `go vet ./...`（Clash.Meta） | 通过 |
| wrapper 全量 | `go test ./... -count=1`（父仓库 core/） | **ok，coverage 93.9% of statements**（2026-11-09 起点 81.6%；其中 connection.go 18 个函数 100%、log.go 5 个函数 100%、service_rules.go 14 个检查器全部有确定性用例、share_link.go 逐函数 100%、updateListeners 100%、事件批量每批 1 次分配（缓冲池化，-99.70%）、provider 列表代号使答案路径 geomean -35.21%、组文档改由计数器作答：urltest -84.01%、fallback -89.46%、loadbalance -38.06%，再收单代号 -18~-20%、routeRefreshWorker 84.6%、sideUpdateExternalProvider 66.7%） |
| wrapper vet | `go vet ./...` | 通过 |
| wrapper 跨平台 vet | `GOOS=windows/linux/darwin/amd64` 与 `GOOS=android GOARCH=arm64` | 四个目标全部 exit 0 |
| focused race | `go test -race . -run 'TestGroupDoc|TestProxies|TestProxy|TestFrame|TestSpill|TestDispatched|TestConnection|TestRefreshRouteVersions|TestRouteStamp'`（CGO_ENABLED=1，mingw64 在 PATH） | 通过 |
| 本轮 focused race | `go test -race . -run 'Proxy|Group|Proxies|Profile'`（CGO_ENABLED=1，mingw64 在 PATH） | 除既有 `TestRouteVersionsPollLeavesRuleSetsToTheirEvent` 外全绿（2026-11-10，两项性能改动后） |
| 全量 race | `go test . -race -count=1` | 仅 `TestRouteVersionsPollLeavesRuleSetsToTheirEvent` 失败——**基线代码上同样复现**（已单独验证：stash 本轮改动后跑同一用例仍报同一 DATA RACE），属既有问题，见第 7 节 |
| 资料页缓存 focused race | `go test -race . -run 'Profile\|Route\|Base\|Merge'` | 除同一既有 `TestRouteVersionsPollLeavesRuleSetsToTheirEvent` 外全绿（2026-11-10，`profile_cache.go` 改动后） |
| 2026-11-10 当日七轮 \+ 信封证伪（收官） | 见第 2 节各轮次小节 | wrapper 全量 ok；四平台 vet exit 0；focused race 仅既有 `TestRouteVersionsPollLeavesRuleSetsToTheirEvent`（基线对照复现）；**子模块全量 104 包 ok + vet 0**；`ParseProxy` 8.6%→75.9%、`adapter` 62.1%→85.2%、wrapper 93.7%；父仓库 `068dd308` / 子模块 `778e0fb67`，两端远程均已同步 |
| 2026-11-11 outboundgroup `GetProxies` 覆盖（测试轮） | 见第 2 节该轮次 | 新增 5 例 focused 全过（连既有共 7 例）、focused race 通过、原生 `go vet ./...` 与三平台包级 vet exit 0、子模块全量 **104 包 ok**；`GetProxies` 53.5% → 95.8%、包 72.7% → 76.1%；父仓库 `78b830de` / 子模块 `fcaf694ac`，两端远程均已同步 |
| 2026-11-11 数据平面每连接缓冲复用（本会话最大单项） | 见第 2 节该轮次 | `BenchmarkRelayStream` n=7 交替：sec/op **-73.65%**、B/s **+279.50%**、B/op **-99.97%**、allocs **270 → 14**（各 p=0.001）；harness 端到端 13.1 万 → 20.3 万 req/s（+55%）、稳态产品分配归零；focused race、原生与三平台 vet、子模块全量 104 包 ok；新增 3 条 relay 测试（跨流字节一致/每块零分配/缓存前缀先行）；父仓库 `93d6a6e8` / 子模块 `1c78f33f6`，两端远程均已同步 |

| 2026-11-10 组答案代号 | 见第 2 节该轮次 | steady answer geomean **-74.68%**（n=7，p=0.001 各）；miss 路径 +1.55%（p=0.310 噪声内）；分配全项不变；选中变更/provider 刷新两条不变量由既有测试钉住 |
| 2026-11-11 晚间连接轮询稳态免扫描 | 见第 2 节该轮次 | `BenchmarkGetConnectionsDelta` paired n=5：100 连接 **-91.77%**、500 连接 **-98.87%**（p=0.008），geomean **-96.95%**，分配 6 / 内存 308B 不变；`BenchmarkGetConnectionsDeltaWalk` 新增钉住表变动路径；子模块 104 包全量 ok + vet 0 + statistic 四平台 vet exit 0；wrapper 全量 ok + vet 0 + 四平台 vet exit 0 + connection focused race 通过；父仓库 `9e4bbd64` / 子模块 `5018ea4c4` |
**噪声带实测依据**（本轮新增，后续 A/B 准绳）：同一编译产物交替自比 4 轮，benchstat geomean +0.71%，个别场景差异 ±2.5% 且 p 可低至 0.021（loadbalance +2.34%，p=0.021）。因此本机「无差异」判定阈值取 p>0.2 或落在 ±2.5% 内；「有差异」判定沿用仓库规矩（p≤0.02 且幅度 ≥ 仓库认可量级）。

**本轮基准注意**：`BenchmarkHandleGetProxies` / `BenchmarkHandleGetProxiesMiss` 的配置名单已改为生产形态（全部代理名，见「名单按身份做键轮次」），其绝对数值与 2026-11-09 之前的行不可比；跨轮比较只能在本轮同基准内做 A/B。


2026-11-04 本轮性能工作收尾时以下验证全部通过：

``powershell
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
``

对应 paired benchstat（均 n=7）已在各自改动轮次执行；本轮五项优化的基准数据见第 2 节各行。

外部 V2Ray 互操作支持 `MIHOMO_V2RAY_INTEROP_BIN` 复用已构建的版本化二进制；本机使用 `D:\Codex\tools\v2ray-5.51.2\bin\v2ray.exe`。`TestInboundVMess_MKCP_V2RayInterop` 现覆盖默认、seed 和全部 5 种 header，双向共 14 个子用例；普通与 `-race` 全绿。未知 header 现在启动/拨号即报错，不再静默回退 none。

### 2026-11-11 深夜 TCP 主路径覆盖轮次（测试）

`handleTCPConn` 此前 70.7%：没有任何测试让一个字节真的穿过它，`resolveMetadata`/`fixMetadata`/`preHandleMetadata` 及其后的 hosts 映射全靠间接。用 coverprofile 逐块定位后补了五个从真实入口驱动的用例。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| `tcp_round_test.go` + `tcp_sniff_round_test.go`：真监听 echo 服务器 + Direct 模式，覆盖①中继往返 ②fake-ip 记录缺失时由嗅探读出域名并携带拨号（日志可见 `[TCP] mihomo --> sniffed.example.com:443 using DIRECT`）③无人能命名时放弃并不拨号 ④无目的地连接直接关闭 ⑤代理拒绝拨号即结束 | `f964973dd` | 本轮父仓库提交 | `tunnel` 包 **83.1% -> 84.9%**，`handleTCPConn` **70.7% -> 89.1%**、`resolveMetadata` 66.7% -> 75.0%。`go test ./tunnel/ -run TestHandleTCPConn -count=3` 连续三遍通过；子模块全量 104 包 ok + `go vet ./...` 通过 |

**踩过的坑（写进测试注释，后续复用）**：① ClientHello 必须包在 TLS record 头（`0x16 0x03 0x01 len`）里，裸 handshake 嗅探器读不出；② 嗅探要拿到 IP 目的地的接管权，`Config` 必须 `ParsePureIp: true`，要让域名真的替换目的地还要 `Sniffers[TLS].OverrideDest: true`；③ `net.Pipe` 是同步管道，回显可能和 ClientHello 的回显合并成一次读，断言要用「包含标记」而非整串相等；④ 域名经 hosts 映射后 `Pure()` 会清掉 `Host`，嗅探证据留在 `metadata.SniffHost`；⑤ 从 tunnel 包测试不能 import `adapter/outbound`（经 dns 反向成环），成员桩自己实现 `ListenPacketContext`/`DialContext` 即可。

**仍缺的三处**：`NeedHandshake` 预热写路径（要一个需要握手的远端连接，peek_test 里有现成形状）、`fixMetadata` 71.4%（入口参数组合）、`logMetadata` 45.5%（其余 switch 分支，需 Info 级别日志 + SpecialProxy/Group 模式组合）。
### 2026-11-11 TCP 路径覆盖收口轮次（测试，接上一轮）

上一轮留了三个块：入站连接本就是 BufferedConn、SpecialProxy 指向表里没有的代理、以及拨号成功后**预热写失败**的清理路径（后者只在 NeedHandshake 的连接上出现——真实代理如 hysteria2/tuic 都要先写一笔才服务）。

| 优化 | core 提交 | 父仓库提交 | 结果 |
|---|---|---|---|
| 补三例：已缓冲入站连接的复用分支（给它打开嗅逛才会调用 `bufferedConn()`，否则闭包根本不执行）、代理缺失连接的丢弃、预热写失败的两条清理分支（链上是 REJECT 时静默结束、否则作为失败上报并停止重试） | `c7e42d821` | 本轮父仓库提交 | `handleTCPConn` **89.1% -> 100%**，`tunnel` 包 84.9% -> **85.9%**。`go test ./tunnel/` 连续多遍通过，子模块全量 104 包 ok + `go vet ./...` 通过 |

**踩过的坑（写进测试注释）**：① `bufferedConn()` 闭包只在嗅探块和 NeedHandshake 块里被调用——想让「已是 BufferedConn」分支执行，必须打开嗅探或让远端连接需要握手，光传一个缓冲连接不够；② 「预热写失败」要让**拨号成功、写失败**，所以 dial 要指向真实监听器，错误用一个被拒的 TCP 拨号错误（重试循环据此判为终态，一次尝试即结束）；③ 嗅探用例改用**预置缓冲**的连接（`Read` 先吐出自带字节再委托管道），彻底摆脱嗅探 1 秒预读窗口与测试写字节之间的时序耦合——此前 7 次全包里偶发 1 次 5 秒超时，根因就是那个耦合；④ patch 的锚文本在两个用例里相同时会落到第一个，两个用例用了同一段 `UpdateProxies/SetMode`，差点把嗅探配置加错测试。

**至此 tunnel 包的主数据路径全部有测试驱动**：`HandleTCPConn`/`processUDP`/`startUDPSender` 100%，`dialUDPSender` 91.7%、`handleUDPConn` 80.6%、`match` 59.6%、`logMetadata` 45.5%（其余是日志分支与进程查找，属平台/日志级组合）。
### 2026-11-11 正式发布轮次（v1.0.6）

v1.0.5 之后到达路径又落了三个实测轮次（Log 到达免格式化、到达路径批量化、连接行解码内联、融合帧读取、连接环索引、flush 缓冲交换、扫描边界码点比较、键字面量 + 整数解析、字段名字符串 switch），本轮把它们收进一个正式版本。

| 项 | 内容 |
|---|---|
| 版本 | `1.0.6+2026111101`，标签 `v1.0.6`（本地） |
| 收录条目 | Bug Fixes 1 条（wrapper 编译与格式修复 `05f5e29`）+ Performance 12 条（`a05bcb4` / `8347731` / `a78ef86` / `f29bf54` / `9de4ea5` / `1adbfd5` / `4a4154b` / `1860ec8` / `ea7045d` / `b14ea82` / `3a9f22e` / `7a43e94`） |
| 验证 | `changelog build --unreleased` 与 `changelog verify` 均通过；本地核心测试全量失败集仍是 5 个既有问题 |
| 推送 | `main:main` 已推送；**`v1.0.6` 标签未推送**——`build.yaml` 由 `v*` 标签触发，按用户要求不跑 Actions 测试与发布流程 |

### 2026-11-12 原生构建资产守门轮次（发布修复）

`v1.0.6` 发布提交把 `pubspec.yaml` 的 `setup.build_assets` 与 `rust_api.build_assets` 写成 `false` 后，远程 main 的 build run 证明这不是无害开关：Dart 21 个用例因 `librust_api` 缺失挂掉，macOS/Linux/Windows 桌面构建都因 `FlClashCore` 缺失挂掉；同 run 里 Go core job 本身是 success，根因在原生资产配置而不是 Go 代码。上一轮记录过 `43d01ef7` 修复提交，但当前分支、标签与 reflog 里都没有该对象，属于交接状态失真；本轮按当前工作区重建修复。

| 项 | 内容 |
|---|---|
| 修复 | `pubspec.yaml` 两个 `build_assets` 恢复为 `true`；`test/setup_test.dart` 新增工作区守门，防止发布配置再提交关闭状态 |
| 本机验证 | `flutter test test/setup_test.dart` 9 个用例全过；`dart run tool/changelog.dart verify` 通过；`process_probe_test` 单用例重复 10 次全过，另做 10 次真实进程回收采样全部为已退出，判定上一轮唯一本地失败是 Windows 控制台子进程回收偶发，不改生产代码 |
| 远程证据 | run `43068548951`：`Go core` success；`Dart` 失败于 21 个 Editor native library not found；`Desktop macos/linux/windows` 失败于 Core 缺失 |
| 发布 | 修复提交后把 `v1.0.6` 重打到正确 main 提交并推送，让正式版构建读取原生资产开启状态 |

同一修复的 tag run `43087616821` 证明新增的工作区守门与 CI 自身流程冲突：Dart job 先用 `yq` 把 `setup.build_assets` 置为 `false` 再跑全量测试，守门用例随即断言失败；同 run 的 `Go core` success，桌面构建按工作流规则跳过。该用例与 CI 装配流程语义相斥，已删除；保留的参数化守门仍覆盖"两个包都必须开启原生资产"的核心约束。教训：面向工作区的守门不能放进会被 CI 预处理的工作流执行路径，守门应走独立脚本或在 CI 改写前执行。

### 2026-11-12 v1.0.6 正式发布轮次

tag run `43099736561` 全绿：`Dart`/`Go core`/`Android unit tests`/`Plugins`/`Rust`/`Windows helper test` 全部通过，三平台桌面 + Android 正式包构建通过，`upload` job 完成发布；GitHub Release `v1.0.6` 已创建（16 个资产含 SHA256SUMS）。

| 项 | 内容 |
|---|---|
| 测试修复 | `services/helper/src/service/hub.rs` 三个依赖共享 `LOGS` 缓冲的测试加互斥锁串行化：毒化用例的消息会被溢出用例挤出，CI 在 run `43093513202` 暴露了本地未触发的竞态 |
| 发布验证 | Dart 覆盖门槛、changelog 校验、7 个测试 job、8 个构建 job、Release 上传全部通过；tag `v1.0.6` 指向 `ec662f15`，main 与远程一致 |

### 2026-11-11 正式发布轮次（v1.0.5）

按用户要求发正式版：派发 `release-stable.yaml`，由 CI 跑 `tool/release.sh stable --push --yes`（升版本、写 changelog、打标签），再链到 `build.yaml` 构建并发布 GitHub Release。

| 动作 | 结果 |
|---|---|
| 第一次派发 | CI 生成 v1.0.4 标签，但 build 在 **Check format**（Dart）失败——本会话改写的 `tracker_speed_ranker.dart` 与它的测试文件没跑 `dart format`。修复后 push |
| 第二次派发 | build 在 **Go core** 的 `gofmt -l ./*.go ./cmd ./mobile ./platform ./timezone ./tun` 失败：`connection.go`（本会话改的，删字段后没重新对齐）与 `spill_test.go`（上一轮遗留的 import 顺序 + 空行）。修复后 push |
| 第三次派发 | 全绿：main 上 build（Go core / Dart / Rust / Desktop 三平台 / Android / Windows helper / Plugins）全部 success，发布 v1.0.5，**16 个产物 + SHA256SUMS**（Android 三 ABI、Linux 六包、macOS 两 dmg、Windows 四包）。发布说明已回填 25 条 Performance 条目 |

**教训（后续必须遵守）**：① 本机验证的格式检查清单必须和 CI 的门禁逐字一致——CI 的 Go 门禁只 `gofmt -l` `./*.go ./cmd ./mobile ./platform ./timezone ./tun`，Dart 门禁是整仓 `dart format --set-exit-if-changed`；② Windows 上 `gofmt -l` 会因 CRLF 报一片假阳性，校验要按**已提交/暂存的 blob**（`git show :file | gofmt -d`）看，那才是 CI 看到的内容；③ 发布说明的条目按「上一个发布标签以来收集」，失败的发布会把条目消耗掉——v1.0.4 收了全部条目但没构建成功，v1.0.5 只剩 `style` 提交，所以 v1.0.5 的说明是按「产物里实际包含什么」手工回填的（仓库 `changelog.json` 未改，`verify` 依旧通过）。
### 2026-11-11 连接排序稳态免排序轮次（性能，Dart UI isolate）

上一轮把 `rank` 的三张 per-poll map 合成一张状态表后，用端到端探针（`poll_cycle_benchmark_test.dart`：rank → setTrackerInfos → filters.offer/apply → sorter → cellsOf）按「一次轮询的真实链路」重测：1000 行时 `rank` 仍占 947µs（其余各级 <600µs）。插桩拆开：sample 循环 ~10µs、**整套排序 ~420µs**、publish ~85µs——而排序里的大头是「空闲行比较器排序」，但稳态下遍历顺序（上一轮的发布顺序）本身就是比较器顺序。

| 优化 | 父仓库提交 | 结果 |
|---|---|---|
| ① 空闲段排序前加「已有序」单遍校验（`_trafficOrdered`），稳态跳过比较器排序；② 更彻底：把上一轮发布顺序存下来，单遍校验「行集未变 + 桶沿序非降 + 空闲段比较器有序」即整体复用，整套计数排序/桶链/遍历全省；③ sample 的间隔比较从 `Duration` 改微秒算术（每行少一次分配） | `7a43e943` | 1000 行稳态：`rank` **947µs → 358µs（-62%）**，整条轮询链路 ~1.7ms → ~720µs；10000 行稳态一轮 **659µs**（对照组「每行都有流量」仍走慢路径，4206µs，与上轮基线 4087µs 同区间无回退）。新基准 `settledPolls`（1 万行稳态）与 `poll_cycle_benchmark_test.dart`（端到端分阶段）均为 `@Skip` 手动项 |

**正确性论证**：校验规则三条——行集完全一致（长度相等 + 每个下标指向的行 stamp 为本轮）、桶值沿存储序非降（某行桶升高必然破坏非降 → 回退）、空闲相邻对满足比较器。新连接/离开连接由长度与 stamp 检查拦下；同行内顺序天然等于上一轮发布序（`_publish` 按输出序写 position）。反向用例「领头连接停止发送后落队」钉住：speed 逐轮减半、约十余轮后回到空闲，顺序回到按总流量排的初始序——校验失败走慢路径，结果与首轮一致。既有 9 个语义用例全绿，新增 2 个（稳态同序同实例、领头者安静后重排）。
### 2026-11-11 时间戳改纪元微秒轮次（性能，wrapper + 子模块 + Dart，端到端契约变更）

上一轮端到端探针（新增 `test/manager/event_arrival_benchmark_test.dart`：sendEvent 一批 760 个 log/request/dns 事件）量事件到达路径，发现这批要 **10.25ms**：插桩显示 `Log.fromJson` 1.9ms、`TrackerInfo.fromJson` 2.4ms、`DnsQuery.fromJson` 4.4ms，而三者唯一的共性成本是 **`DateTime.parse`**——单独实测 **17.9µs/次**，一批里约 360 次解析就占 ~6.5ms，一帧装不下。

| 优化 | 提交 | 结果 |
|---|---|---|
| 时间戳全线改「纪元微秒 + UTC 构造」：子模块 `TrackerInfo.Start` 改 int64、`AppendJSON` 直写数字；wrapper `DnsQuery.Time`、`ExternalProvider.UpdateAt` 改 int64、手写编码器直写数字；Dart `TrackerInfo.start`/`DnsQuery.time`/`ExternalProvider.updateAt` 加 `dateTimeFromEpoch`/`dateTimeToEpoch` 转换器（`fromMicrosecondsSinceEpoch(isUtc: true)`），build_runner 重生成 | 子模块 `bbf113d6f` / 父仓库 `b14ea82f` | 微基准：时间戳构造 **17.9µs → 0.114µs（-157 倍）**；端到端 `sendEvent x760` **10.25ms → 3.06ms（-70%，min 2.65ms）**；500 行 resync 不再解析 500 个时间戳。`isUtc: true` 是关键：本地时间构造 4.1µs，UTC 只要 0.114µs |

**契约与兼容**：wire 形状从字符串改为数字，三层一起改、不留兼容分支——Go 侧 `ExternalProvider`/`DnsQuery` 字段类型直接改 int64，`json.Marshal` 与手写编码器因此天然一致（provider 两条等价测试**原样通过**）；子模块金标文档同步改微秒。Rust 侧（MITM 模块）不在本仓库源码内，`MitmExchange`/`MitmExchangeSummary`/`MitmExchangeList.since`/`MitmCertificate` 四个字段保持 ISO 字符串，其 fixture 已还原。

**踩坑（后续复用）**：① 本机 build_runner 的 AOT 快照写入必失败（`Unable to write file .dart_tool/build/entrypoint/build.dart.aot`，PowerShell/dart 手工写同路径却成功），加 **`--force-jit`** 即可跑完；② 自定义转换函数必须放在 `part` 指令**之后**，否则整库编译报「Directives must appear before any declarations」；③ Windows 上跑 gofmt 要看**已提交/暂存的 blob**（`git show :file | gofmt -d`），工作副本的 CRLF 会报一片假阳性。

### 2026-11-11 Log 到达免格式化轮次（性能，Dart）

上轮把 wire 时间戳改成纪元微秒后，`sendEvent x760` 还剩 3.06ms；其中日志路径每到来一条就 `DateTime.now().showFull` 全量格式化一遍，只为在到达时拿到一个字符串，而行组件随后又会格式化一次。本轮 `Log.dateTime` 直接持有 `DateTime`，两处显示点改调 `showFull`（Expando 已有缓存，与 `TrackerInfo.start`/`DnsQuery.time` 的显示方式一致），`fromJson`/`Log.app` 只取当下时刻，`toJson` 走 `dateTimeToEpoch`。

| 优化 | 提交 | 结果 |
|---|---|---|
| `Log.dateTime` 由 String 改 DateTime，到达即停（`_logNow`），显示端 `showFull` | `ea7045d3` | 到达基准 `sendEvent x760` **3.06ms -> 0.98ms（min 0.81ms，-68%）**；连同上轮 wire 改造累计 10.25ms -> 0.98ms，**-90%** |

**配套与踩坑**：fixtures 全部改构造 `DateTime`；`test/views/logs_view_test.dart` 的 scrollbar 时间提示断言改为比 `showFull` 文本——`DateTime` 与 `String` 永不相等，该用例在 bundle 与单跑中都必失败，不要误判成 bundle 跨文件干扰。

### 2026-11-11 到达路径批量轮次（性能，Dart，分发契约变更）

上一轮之后端到端量「生产到达路径」（`jsonDecode` → `coreEventsFromData` → 逐个 `sendEvent`，760 事件/批）：1318µs。逐项拆：`CoreEvent.fromJson` 每事件 0.43µs（`$enumDecode` 反查）、`Log.fromJson` 每条约 0.42µs（`DateTime.now()` + `$enumDecodeNullable` + 字段读）、逐事件分发机制约 330ns。本轮三项改动全部用**配对实测**（同一次运行内新旧交替、各 9 组取中位数）验证：

| 优化 | 提交 | 结果 |
|---|---|---|
| 信封解析改手写 `coreEventFrom`：线上名字符串 switch（按频率排序），替掉 `$enumDecode` 反查 | `1860ec80` | 配对：**283µs → 88µs（min 172 → 46），-69%** |
| `logFromData` 手写解码（`logLevelOf` 字符串 switch）+ `sendEvents` 批量分发：一批日志共享一次到达时钟 | `1860ec80` | 每 log 读入 **423ns → 99ns（-77%）** |
| `ServiceListener.onServiceEvent` 契约改批量 `onServiceEvents`；桌面 rpc_client 与 Android service 两条分发链整批交给 manager | `1860ec80` | 端到端配对：**1318µs → 1182µs（median -10%），min 1097 → 810（-26%）** |

**配套与踩坑**：① `coreEventsFromData` 的 `is! Map<String, Object?>` 守卫顺带消灭未类型化 map 的拷贝路径——`jsonDecode` 产出的 `_Map<String, dynamic>` 本就是 `Map<String, Object?>` 的子类型（运行时实测 `is` 为 true），旧代码里的 `Map.from` 拷贝从未真正复制过；② 服务层契约从逐条改批量（onServiceEvent → onServiceEvents），`_MutatingListener` 一类中途注销的语义不变（快照仍在每次派发前取）；③ **分轮测量的中位数噪声可达 ±15%**——同一函数两次独立测到 326µs 与 482µs，信封解码因此一度被误判「无收益」，同运行内配对方才给出可信结论。后续所有微基准一律配对；④ `jsonDecode` 占生产路径约 140µs/760 事件，通用解析器已是该形状下的地板，手写扫描器的风险收益不相称，记账不做。

### 2026-11-11 连接行解码轮次（性能，Dart）

位置化行编组的原型（行改 JSON 数组、metadata 仍为对象）配对实测 **-49%**（232µs → 118µs/95 行），但改 wire 格式要动子模块编码器、`rowAnswerSize` 与两侧契约测试，风险面大；逐段归因发现收益的大头在「外层 9 字段 + chains 分配 + 嵌套 fromJson 调用」，于是只重写 Dart 侧读取器、不碰 wire：`trackerInfoFromData` 内联 metadata 构造，chains 空表共享 `const []`，两个生产调用点（`_addedConnections` 与 request 事件）换用。

| 优化 | 提交 | 结果 |
|---|---|---|
| `trackerInfoFromData` 手写行读取器 + `dnsModeOf` 字符串 switch，与生成版**逐字段等价** | `4a4154bc` | 配对：95 行 **188µs → 133µs（min 158 → 122），-29%**；500 行 resync 每次页面打开约省 290µs |

**等价性钉死**：`test/models/common_test.dart` 新增三组——全字段行同输入对拍、缺省行对拍、含全部 dnsMode 名的对拍，外加 **200 组随机在场性模糊**（确定性种子，每个 metadata 键 50% 概率缺席， uid/dnsMode/geoIP/mitm 按类型生成）。模糊测试当场抓出两处我原本写宽容了的字段（`metadata` 与 `chains` 缺失时生成版直接抛、手写版默认补空）——Go 编码器（`appendPrefixJSON`/`appendSuffixJSON`）保证两者恒在，遂把手写版改成同样严格，语义完全对齐。

**踩坑**：`TrackerInfo.toJson()` 不递归序列化嵌套对象（freezed 原样写 `instance.metadata`），不能拿它做 round-trip 基准；等价测试必须**同一份输入 map 喂两个读取器**。

### 2026-11-11 融合帧读取轮次（性能，Dart，到达路径）

上一轮之后到达路径仍要 ~1.3ms/760 事件（JIT），逐项拆完发现成本不在解析本身，而在**解析的产物**：通用解码器为每条消息造两张 map（信封 + 载荷），模型读取时在这些刚分配、缓存未热的表上做冷查找——同一份数据用热 map 微基准量比生产路径快 2.4 倍。本轮新增 `lib/core/event_json.dart`：一个手写扫描器直接在帧文本上走班，信封、日志行、连接行、DNS 查询、流量计数器在扫描当时就建成，稀少载荷形状（delay/geoUpdate/routeChanged）才切片解码；桌面与 Android 两条传输链都先走它，任何读不整个的帧**整体回落**到解码路径——回落同时是它的安全网，也是测试里的 oracle。

| 优化 | 提交 | 结果 |
|---|---|---|
| `messageBatchFromFrame` 融合读取：信封 + 五类热载荷在扫描时建成，无常驻中间 map | `1adbfd55` | 配对实测（同运行新旧交替各 9 组中位数，两轮复测）：到达路径 **1612µs → 1080µs、1745µs → 1178µs（median -33%），min 1357 → 806（-40%）** |

轮内追加：扫描边界的 _peek() 从「取单字符字符串再比较」改为**读码点与十六进制常量比较**（每字段边界省一次字符串物化，一批里数千次）。同运行配对三轮复测：到达 **1641/1668/1737µs → 1011/1072/851µs（median -36% ~ -51%），min 1329 → 642（-52%）**。

**配套与踩坑（后续复用）**：① 键名分发先过常量表再走 int switch（`_rowKeyCodes`/`_metadataKeyCodes` 等），字符串 switch 是线性比较、元数据 19 个 case 会让每行白跑几百次 `==`；② 跳过未知键必须走 `_skipString()`（只扫不物化）——第一版用 `_readString()` 白分配字符串，仅此一项就让行扫描慢回原点；③ 分发层 `_parseEventPayload` 对已是载荷的 `event.data` 直接放行（每类型一次 `is` 检查 ~5ns），融合路径因此复用同一分发 API，不搞第二套；④ `GeoUpdatePayload` 转公开并补 `==`/`hashCode`；⑤ **基准帧必须是真信封**（`{"method":...,"arguments":[...]}`）——我第一版基准用裸数组，扫描器正确拒识，于是「融合路径」实测量到的其实是回退路径，白忙一轮；配对基准里加一句 `fused reads the frame: true` 防再犯。

**正确性**：`test/core/event_json_test.dart` 新增 6 个用例：全 10 类事件的读取与非消息帧拒识、截断帧整体回落、单对象 arguments、**转义专项**（引号/反斜杠/换行/控制符/CJK/emoji/代理对，载荷里埋 `{"type":"crash"}` 与 `","arguments":[...]}` 陷阱串）、以及 **60 组随机批次与解码路径逐事件对拍**（8 类转义片段随机拼装、种子确定性）。

### 2026-11-11 连接环索引轮次（性能，Dart，含一处既有 bug 修复）

feed flush 分解实测（每 300ms 窗口 400 日志 + 120 连接行 + 240 DNS + 200 流量）：`Requests.addRequests` 占 137µs，其中 FixedList 自己就占 125µs——满环（连接表稳态就是满环）时每次 `appendAll` 都要走一遍整个键索引（`_dropIndexedHead` 遍历全部条目做位移）。本轮把键索引改成**虚拟坐标 + 队头偏移**：键记住行入环时的虚拟位置，丢头只把 `_keyBase` 加一下，O(1)；查不到的键（行已出环）在 `updateByKey` 命中时顺手删除，长时间无查找则由 `_compactKeysIfSparse` 按摊销重建。

| 优化 | 提交 | 结果 |
|---|---|---|
| FixedList 键索引改虚拟坐标 + 队头偏移；顺带修复既有 bug：`add` 在满环溢出分支从未给最新入环的行建键（流量更新会丢掉最新连接），由「满环最新行仍可按键命中」用例钉住 | `9de4ea51` | 满 1600 环 `appendAll x120` **125µs → 26µs（-79%）**；widget 级 feed flush **1299µs → 1088µs（-16%）** |

同轮追加：`_flushFeeds` 的四个入队缓冲从「拷贝 + clear」改为**引用交换**——flush 拿走自己那份，运行期间到达的事件落进新缓冲，语义不变；省掉每次 flush 960 个元素的拷贝与 4 个集合分配，feed flush 1088µs → 1040µs。

**踩坑（后续复用）**：① 量 provider 成本必须**持有 notifier**（照 `requests_update_benchmark_test.dart` 的写法）——无监听者的 autoDispose notifier 每次 `container.read` 都会重建，量出 ~50µs/次的假量子，我第一次分解就被它带偏；② 本轮分解顺序：先用 provider 级部件基准定位热点，再用 FixedList 裸基准确认成本在结构内，最后才动结构。

### 2026-11-11 融合读取键字面量与整数解析轮次（性能，Dart，到达路径）

两个方向一起落地，都只动 `lib/core/event_json.dart`：一是键名字面量优先——信封的 type/data 与日志载荷的 LogLevel/Payload 是核心每次必写的键，用 `_skipKeyIs(literal)` 直接在字节上与字面量比对并跳过，不再先物化成字符串再进常量表或走 ==；二是整数手写解析——删掉 `_readNumber()`（substring 加 num.parse），`_readInt()` 改为码点直接累加，连接行与 DNS 行的每个整数字段省一次子串分配和一次通用数字解析。

| 优化 | 提交 | 结果 |
|---|---|---|
| 信封与日志载荷的键字面量优先 + `_readInt` 手写累加（删 `_readNumber`） | `83477313` | 融合帧读取 median 448 -> 377µs（配对三轮 -9%），解码路径持平；端到端同帧 760 事件 |

配对实测（同一进程内交替、同一 76024 字节信封、400 log + 120 连接行 + 240 dns，合并 9 次取 median）：基线 a78ef866 三轮 490 / 448 / 464µs，本轮 401 / 377 / 374µs；解码路径 611 / 643 / 606µs 对 630 / 776 / 632µs，落在噪声内，说明收益来自读取路径本身而非机器状态。

踩坑（后续复用，两个都是真会再犯的）：一、字面量长度不要手数。data 是 6 字符、LogLevel 是 10、Payload 是 9，我手写偏移写成 7/11/10，光标越过冒号，读取器抛错并把整帧推回落退路径，event_json_test 三个用例同时变红。最终改成 _at += literal.length，并由 _skipKeyIs 连比对带跳过一步完成，偏移没有再次出现的可能。二、字面量优先不能吃掉转义拼写。核心从不写转义键，但调用方可以：整段转义的 Payload 键在第一版里落到 else 分支被静默跳过，payload 变成空串。修法是通用分支照旧 _readString 读出键，拿未转义的名字重新分发，新增用例钉住这个行为；我把该用例改坏后单独复验过：把两个 else if 改成 false，用例立刻变红，说明它是有效护栏而非摆设。

本轮另把两处「读键、对冒号、跳空白」的重复收成 _skipFieldColon，键名相关分支因此各只剩自己真正关心的语义。

### 2026-11-11 字段名分发改字符串 switch 轮次（性能，Dart，到达路径）

上一轮把信封与日志载荷的键改成字面量匹配后，剩下连接行、元数据、DNS 行、流量计数器四个读取器仍走常量表：每读一个字段先 `_readString()` 物化成字符串，再拿它去 `const Map` 里做一次哈希查找拿小整数，最后才 switch。本机微基准：同一个 120 次循环，字符串 switch 是 13µs，走表再加 switch 是 126µs，两者差约 9 倍。四个表全部删掉，四个读取器直接 `switch (key)`。

| 优化 | 提交 | 结果 |
|---|---|---|
| 连接行/元数据/DNS/流量四个读取器改字符串 switch，删掉四张常量键表 | `a05bcb4a` | 10 倍负载（4000 log + 1200 行 + 2400 dns）、21 次取样 median：连接行 1332 -> 1176µs、DNS 1447 -> 1348µs，均在两种先后顺序下同向复现；日志 1001 -> 1079µs 持平 |

配对实测（同一进程、同一 222124 字节行帧与 236524 字节 DNS 帧，各跑 21 次取 median，两种先后顺序各跑一轮）：表版本 1332/1447µs，switch 版本 1176/1348µs；对调顺序再测一遍，表版本 1358/1495µs，switch 版本 1187/1311µs。日志与位移类不明显，因为日志载荷只读两个字段，本来就不怎么查表。

**踩坑（后续复用）**：① 这轮的最初判断来自上一轮的注释「字符串 switch 是线性比较、元数据 19 个 case 会让每行白跑几百次 ==」，那句话本身没有实测支撑；本轮按实测推翻它，常量表的哈希成本在这四条路径上比线性比较贵得多。② 别用 9 次取样的短循环下结论——第一版 120 行/9 次取样时两种实现时快时慢、落在噪声内，把负载拉到 10 倍并加到 21 次取样后才分出方向。③ 测出来没有收益的方向（位移、`_readStringList` 预分配等）本轮全部没动，没有为了凑数改代码。

### 2026-11-12 RecordSorter 增量归并否决轮次（实测后不改）

假设：稳态表格每次 flush 新批次只落在尾部，全量排序 O(N log N) 应可换成已排序前缀与尾段的 O(N) 归并。实测：620 行（500 已排序 + 120 新尾部）全量排序 304µs，手写归并 48µs，6 倍；但放进 `RecordSorter` 里配对复测（基线 428/421µs vs 归并版 433/417µs，两种先后顺序各测一轮），两种实现落在噪声内，没有可复现的收益。

原因：连接表的真实输入不是「500 行已排序 + 120 行新尾部」的静态形状，`FixedList` 每 flush 都换引用，新批次的行也会被下一轮流量更新（`updateByKey`）重建，排序器缓存本来就不可能在两次 flush 之间命中；而 500 行的键列表构建（`sortKey` 500 次调用）在两种实现里都要做，那才是主要成本。归并省下的比较次数被键构建吃掉了。

| 方案 | 配对实测 | 结论 |
|---|---|---|
| 增量归并替换全量排序 | 428 -> 433µs（噪声内） | **否决**：收益被键列表构建淹没，缓存无法跨 flush 存活 |

过程中顺带确认：`_isOrdered` 提取成方法与原内联循环等价（7 个 RecordSorter 用例全过），也没有可测差异，已还原。该路径的键构建成本要再降，只能从 `RecordColumn.sortKey` 的调用侧（列定义）想办法，不属于本轮。

### 2026-11-12 Go core CI gofmt 假阳性修复轮次（构建，非性能）

现象：CI `Go core` job 反复失败（run 43095104093，HEAD `4bf53ce`），本地 `go build`/`go test` 却全绿。逐条复现 CI 步骤后定位：`gofmt -l ./*.go ./cmd ./mobile ./platform ./timezone ./tun` 列出 14 个文件，CI 的 `test -z "$(...)"` 因此判失败。

取证：`git cat-file blob HEAD:core/lib.go` 里 CR 字节数为 0，工作区同文件 CR 字节数 399（`node` 逐个 count）；`git ls-files core` 全量核对，94 个已提交文件 CR 数全部为 0。即仓库存的是 LF，工作区是 CRLF，注入者是本机全局 `core.autocrlf=true`。上一轮 `05f5e29e` 试图绕开但没根治，因为没锁属性。

| 修复 | 提交 | 结果 |
|---|---|---|
| `.gitattributes` 增加 `core/**/*.go text eol=lf` 与 `core/Clash.Meta/**/*.go text eol=lf`，锁死行尾 | `6e83280b` | `git check-attr` 返回 `attr/text eol=lf`，`git ls-files --eol` 显示 `i/lf w/lf`；14 个 core 文件重建为 LF 后字节与 blob 逐字节相同（`Buffer.compare` 返回 0），因此无内容 diff 需要提交 |

CLI `Go core` job 的四个步骤本地全部复跑通过：`gofmt` 输出为空、`go test -count=1 .` ok（15.2s）、`go vet . ./cmd/...` exit 0、`GOOS=linux go vet ./platform` exit 0、`GOOS=android GOARCH=arm64 go vet -tags=with_gvisor . ./mobile ./tun ./platform` exit 0 且无输出。

**踩坑（后续复用）**：① 判 CRLF 别用 `git show ... | Out-String` 数 `\r`——PowerShell 管道会给每行补 CR，结果是假阳性（第一版探针曾得出「blob 也带 CR」的错误结论），要 `git cat-file blob` 重定向到文件后按字节数。② `gofmt -l` 的 glob 在 PowerShell 下不展开（报 `CreateFile ./*.go`），必须显式列文件名或走 `cmd /c`。③ Windows 上跑 `GOOS=linux go vet` 必须显式设 `$env:GOOS`，否则报「build constraints exclude all Go files」的假失败。④ `go mod download all` 会给 `core/go.sum` 补 51 行测试依赖哈希，但不影响 `go build`，提交前用 `git checkout -- core/go.sum` 还原，别混进业务提交。

## 5. 后续优化切入点

### 2026-11-12 连接快照预排序轮次（已落地）

假设：仪表盘每次接收连接快照都在读取路径上复制全表并按 start 重排，而这份顺序由 provider 生成行集合时就已知。本轮把排序下沉到 `Connections`：`_merge` 只在行集合变化时把 `rows.values` 排成 start 倒序，快照与 `_orderedRows` 共用同一份列表；`updateTraffic` 的 counter-only 路径不再复制或重排，直接发布同一列表实例。Dart `LinkedHashMap` 的替换值不改变键的插入位置，所以流量更新不会破坏顺序，这一点由 counter-only 顺序护栏钉住。

配对实测（`connections_feed_benchmark_test.dart`，300 行 ×2000 次，JIT）：旧路径（复制 + 排序 + 计数）19.7µs → 新路径（直接计数）3.7µs（**-81.3%**）。tracker ranker、connections 表格、poll cycle 基准测试全绿；`dart format` 0 changed，`dart analyze --fatal-warnings` 剩余 6 条均为与本轮无关的既有 info（干净基线复跑一致）。基准注解在测量后已按仓库惯例还原为 `@Skip`，账本只留数字。

### 2026-11-12 连接流量槽位闭环轮次（正确性修复，已落地）

假设：上一轮把排序下沉到 provider 后，`updateTraffic` 只替换 `_rows` 里的行对象而不同步 `_orderedRows`，快照发布的是旧行对象；仪表盘 UI 侧也在重复排序一份 provider 已排好的列表。本轮修复两处：

1. `updateTraffic` 现在同步替换有序列表对应槽位的行（`_rows` 与 `_orderedRows` 由 id→槽位索引对齐），counter-only 刷新不再读旧计数器。索引随 `_merge`/`_clear` 重建，单次 traffic 更新是 O(受影响行数) 而非 O(全表)。
2. `connections_table.dart` 的 `_showConnections` 直接读 `snapshot.connections`，删掉 `[...snapshot.connections]..sort(...)` 的复制与重排；provider 已保证 start 倒序。

验证：`test/views/dashboard/connections_table_test.dart` 与 `test/providers/app_test.dart` 54 例全绿；`test/models test/views test/features` 1014 例（13 例手工基准跳过）全绿；`flutter analyze --no-fatal-infos` 0 error / 0 warning（852 条既有 info，全部位于生成 l10n、plugins 与测试文件，与本轮无关）。Go core 侧 `go test .`、`go vet . ./cmd/...`、`GOOS=linux go vet ./platform`、`GOOS=android GOARCH=arm64 go vet -tags=with_gvisor . ./mobile ./tun ./platform` 全部通过。

### 待优化项清单（2026-11-07 全量复核，均在本机实测过基线）

| 位置 | 实测基线（JIT） | 结论 / 下一步 |
|---|---|---|
| 实时连接 feed 的 `[...snapshot.connections]..sort(start 倒序)` | 300 行 19.7µs → 3.7µs（**-81.3%**，2026-11-12 已把排序下沉到 provider） | **已完结**：排序在 `Connections._merge` 重建行集合时做一次，`_orderedRows` 是不可变有序表；2026-11-12 补齐 `updateTraffic` 同步替换有序列表槽位与 id→槽位索引，counter-only 刷新不再发布旧行对象。仪表盘 `_showConnections` 直接读快照，免复制免排序。顺序护栏在 connections_table 的 counter-only 用例，基准 `connections_feed_benchmark_test.dart` 配对实测。剩余成本是每次刷新重建 20 行 ×8 列的 widget，要再降只能自绘表格 |
| `RecordFacet.optionsOf`（剩余） | requests 页 500 行 ×3 个 offered facet：单值化 + 有界选取后约 46.0µs/组；rule 全去重场景 50.7µs/次 | 剩余是 map 计数本身（500 个不同字符串的哈希与插入，约 25µs）与选项终排。「同一列表实例跳过重算」不成立（三个调用点都由节流器在新数据到达时驱动，列表必然已变）；top-k 无法再近似，每个值都必须数到 |
| `RecordSorter.sort` 乱序路径 | 10000 行 ×1000 次同 `record_sorter_benchmark_test.dart`；`Expando` 缓存 sortKey 无效（见第 3 节） | **已否决**：`order`+`sorted` 两个列表是保住「调用方列表不被就地改写」的必要形状，改预分配+索引填充实测已有序路径反慢 +2~3%（见第 3 节本次记录），in-place 置换会写污染 provider/快照列表。该路径剩余成本在 `sortKey` 调用侧（列定义），不属于 sorter 形状 |
| 打包 int64 键替代索引排序（`computeSort`） | 设想：把 (priority,delay,group,index) 打成单个 int64 用 `Int64List.sort()` 免比较器排序。scratch 配对实测（1000 节点 ×500 次，顺序与索引排序完全一致）：172.4µs → 169.4µs（-1.7%，噪声内） | JIT 下 `Int64List.sort()` 并未比 `List<int>.sort(comparator)` 快，比较器本身已不是瓶颈；撤销 |
| `computeSort` 延迟排序（剩余） | 1000 节点：叶子直取后约 280µs/次（此前 424µs，见第 2 节本轮落地行）；`order` 列表 + `List.sort` + 结果列表是余量 | 「已有序免排序」快路已存在；`order`+结果双列表要省需 in-place 置换且不能改调用方列表（上次尝试写反已回退），先写语义测试再上基准 |
| `fixed(decimals: 1)` 改整数路径（`traffic` 显示） | scratch 配对实测：141ns → 53ns（**-63%**），`dashboardTraffic` 176ns → ~88ns | **语义不等价，撤销**：200k 随机值 + 边界值对拍发现 3 处不一致——`0.15` 走 `toStringAsFixed(1)` 得 `0.1`，整数路径因 `0.15*10` 浮点向上进位得 `0.2`；`-0.0` 一边出 `-0` 一边出 `0`。显示的字节数不能为性能改变取值；若只在 `size == size.truncateToDouble()`（整除）时走整数路径则安全，但流量值多非整除、收益有限，未做 |
| 表格行单元格构建（`toUpperCase`、时长文本、`dashboardTraffic` 格式化与单元格 widget） | `test/widgets/row_cells_benchmark_test.dart` JIT n=5（500 行 ×500 次 `RecordTable.cellsOf`）：约 1.40µs/行，其中约一半是 `traffic`/`trackerDurationText` 的字符串格式化，约一半是单元格 widget；20 行可见表格每次刷新约 28µs | 单项拆分已到地板（样式缓存方案见第 3 节，已否决）。再降只剩两条路：按列声明「单元格读什么」做 per-column memo（counter-only 刷新跳过描述性列，约省 40%），或自绘表格 render object（无逐单元格 widget 树）；两者都要动 `RecordColumn`/`TableCells` 的公共 API，风险高于收益，先留基准 |
| `SpeedCard`/`_SpeedTile` 每帧对全部 speed 样本 fold 求 peak | `trafficSampleLength` = 24（`lib/common/constant.dart:190`），即每帧 24 次比较 + 一次 `list` 快照访问，量级为几十 ns | 收益过小，记账备查：`FixedList` 每次 `append` 都 bump revision 生成新实例（共享 `_list`），peak 无法递推到实例上；递推论只能在写入侧按方向维护，那会把两个方向的 UI 选择变成 provider 的固定负担 |
| core/Clash.Meta 侧 P1/P2/P4 | 见下文各小节 | DNS 负回复、本地 DNS serve 全链、UDP 首包均已实测否决或维持不做 |

### 待优化项清单（2026-11-08 核心轮次复核，均在本机实测过）

| 位置 | 实测基线 | 结论 / 下一步 |
|---|---|---|
| `getProxies` 答案的 `groupDocKeyOf` → `Now()` | 剖析：URLTest 场景答案路径 CPU 的约 25%（200 组 × ~90ns/答案） | **2026-11-09 已完结：Selector 场景 -42% ~ -66%，geomean -31.37%**（见「选中代数做键轮次」）。全场景剖析显示 `groupDocKeyOf` 从 69.5% 降到 56.7%；剩余两部分都判定为「必须做」：wrapper 自己的 provider 版本遍历（约 14%）是唯一能抓到「订阅刷新不重建代理表」的读取点，删不得；URLTest/Fallback 的 `Now()` 解析无法用计数器替代——它们的选中会随 fastSingle TTL 到期自行改选，计数器会滞后一个 TTL，UI 会显示过期选中态（这正是本轮只做 Selector 的原因：`setSelected` 是 Selector 选中的唯一写入口，计数完整；URLTest/Fallback 没有这个性质）。若将来要做，唯一正路是子模块提供「选中变更即通知」的主动失效钩子，而不是计数器 |
| `configuredTestTimeout`（`core/delay.go`） | 每次 delay 测试遍历全部 provider，并对每个返回 timeout 的 provider 线性扫成员（`slices.ContainsFunc(pd.Proxies(), …)`）；1000 节点 × N provider 时每次调用 O(providers × members) | 单次成本远小于 URLTest 网络往返，暂不动；若要改，按 `proxy.ProxyInfo().ProviderName` 直接定位 provider（语义差异：同名节点跨 provider 时只认隧道表里那一个，需先确认可接受） |
| `adapter.Proxy` 的 `extra` xsync.Map 读路径初始化 | `BenchmarkHandleGetProxies` 内存剖析：活对象的 30% 来自 `xsync.newMapTable[string,*internalProxyState]`，且**纯读取**（`AliveForTestUrl`/`LastDelayForTestUrl`）就会触发惰性建表 | **2026-11-09 已落地并验证有效**：`hasExtra` 标志由写入路径（`testState`，全部写入收敛于此）在触表前发布，纯读路径先看标志。`BenchmarkHandleGetProxies/groups=200/members=20/nodes=1000/urltest` 的 inuse_space 剖析里 `xsync.newMapTable` 已从存活对象中完全消失（修复前占活对象约 30%）；`BenchmarkWriteFrameLargeDocumentOnAPipe` 之外另测分配 223.5B → 103.0B/答案（-53.91%），基准全过程分配 78.3MiB → 40.8MiB。见「只读代理不再建表轮次」 |
| 连接轮询的 `row.stale(info)` 与 `Manager.Range` | 剖析：stale ~25ns/行；Range 桶遍历约占该基准采样的 10% | **2026-11-11 晚间会话已完结**：`Manager.Generation()` 之外不再需要元数据版本号——stale 整段删除（全子模块 grep 证实 metadata 只有构造期写入，测试已钉住），稳态轮询连 Range 一起短路，500 连接 32.78µs → 371ns（-98.87%）。见第 2 节「连接轮询稳态免扫描轮次」 |
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

### 后续若要继续（2026-11-10 更新：本节原定方向已完工）

**原方向「主动失效钩子」已于 2026-11-10 落地**：子模块 `adapter/outboundgroup.AnswerGeneration()` 在 pin 与自行改选两条写入口上递增，wrapper 快照记住「上一次全量校验前读到的代号」，稳定态答案只做两次原子读——wrapper 每答案的逐组 provider/选中遍历随之消掉，命中路径 geomean -74.68%（见第 2 节「稳定态答案两次读轮次」）。设计上要求的两件事都已具备：一张覆盖矩阵（写入点只有 `announceAnswer`/`bumpAnswer`/`Selector.setSelected` 三处，全部计入）与对应测试（子模块 `TestAnswerGenerationMovesWhenAGroupsAnswerDoes` + wrapper 既有 `TestGroupDocsAnswerWhatTheirGroupsChange` 钉住选中变更与订阅刷新两条路径）。

**当前剩余方向（均已实测，按收益排序）**：① 信封契约改造（**2026-11-10 已实测否决并撤销**）：把信封改成写入处物化，小文档路径 allocs 1→0 且时间 -1.74%，但大文档路径 +22%~+24.6%（id 被 `size()` 与 `appendEnvelope` 重复扫描、分配档 32B→48B），geomean +19.48%。结论见第 3 节该行，勿重做；② `config.GetProxyNameList` 已在原子指针上（子模块 `config/patch.go`，`atomic.Pointer[[]string]` 整表替换），无读锁可省，该条已不适用；③ 连接轮询的 `connectionRows.rows[tracker]` 接口 map 查询（`BenchmarkHandleGetConnectionsDelta` 表变动路径约 8.5%），稳态轮询已被 generation+size 短路（500 连接 371ns），只在有新连接或关闭时付，绝对量约 5µs/2s；④ 子模块 `xsync.Map.Size()` 已是 O(bucket) 而非 O(entry)，`GetConnectionCount` 单次 6.6ns，无进一步空间。Go 侧剩余项均已到地板或收益不抵风险，继续挖应转到 Dart 侧（见 2026-11-12 两轮：连接 feed 与表格单元格）。


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

**结论**：核心（Go 侧）的优化空间已按实测挖到饱和；平台层无独立热点；剩余唯一有实质收益的方向（主动失效钩子）已于 2026-11-10 落地，答案路径命中路径累计 -74.68%；其余方向均按实测否决，见第 5 节「当前剩余方向」。
### 全代码复核覆盖面（2026-11-12 补充轮，Dart UI 侧 + Android 壳层逐文件）

上一节 2026-11-09 覆盖的是 Go 与平台层；本轮把 Dart 的 UI 主路径与 Android 壳层也逐文件过了一遍，证据如下。

| 范围 | 规模（实测） | 本轮复核结论 |
|---|---|---|
| `lib/views/dashboard` + `lib/features/connection` | 两个目录共约 4.4K 行 | 找出并落地三项：`SpeedCard` 整卡 watch 拆三处 select（配对 -17%）、协议列 `toUpperCase()` 改常量 switch（-50~52%）、以及本次否决的 cell 级样式冗余与 `NetworkSpeedCard` 同形状拆分（后者 -2.7% 在噪声内）。第三条把 2026-11-09 的「单元格约一半是 widget」修正为「81% 是字符串格式化，其中 `dashboardTraffic` 占 68%」，并进一步定位到 `toStringAsFixed` 是 VM 内部、Dart 侧绕不过去 |
| `lib/widgets/record_table.dart` | 545 行 | 逐函数过。`RecordSorter.sort` 的 `order`+`sorted` 双列表是为「不改写调用方列表」的必要形状（两个调用方的 `widget.items` 可能是 provider 的不可变列表），已配对否决 in-place 置换。`RecordTable` 的 `rowTextStyle`/`rowShape` memo 机制已存在且正确——曾试图给它加 `mutedTextStyle` 让 cell 复用，但 `RecordColumn.cell` 的签名只有 `(BuildContext, T)`，拿不到 `RecordTable`，方案不成立，已撤销 |
| `lib/common/fixed.dart` | 250 行 | 逐函数过。`update`/`updateByKey` 确实要遍历或按键查表，但都被调用方的 generation+size 短路挡在稳态之外（500 连接 371ns），不是每帧热点；`retainTrimmedHead` 有三个生产调用点，非死代码 |
| `android/app/src/main/kotlin` | 19 文件 / 2436 行 | 逐个搜同步阻塞：`runBlocking` 0 处、`Thread.sleep` 0 处；仅 `SystemCaStore.kt:126` 一处 `readText()`，那是 `su` 的同步执行结果（root/CA 安装路径，必须等），且由用户操作触发、非每帧。`ServiceStateMachine.kt` 是并发状态机，正确性优先，性能上无每帧路径 |
| `windows/runner` | 8 文件 / 533 行 | Flutter 标准样板，无业务逻辑 |

**本轮结论**：`dart analyze` 在 `lib/` 下 0 error / 0 warning（仅 6 条既有 info 全在测试文件），没有 unused/dead code 告警——lib 侧的无效代码已在往轮次清干净。Dart 表格路径的剩余成本全在 VM 的 double 格式化里，`RecordColumn.sortKey` 以「不改变排序语义」为前提已无可动部分；继续挖应等上游出现新的数据形状再议。


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

### 剩余项现状地图（2026-11-10 收口，全部本机实测过）

**性能侧已挖到地板**：

| 路径 | 现状 | 结论 |
|---|---|---|
| 代理表答案（最热 IPC） | 200 组 **118-121ns / 0 alloc / 0 B**（本会话 5.105µ/12 allocs → 0.12µs/0 allocs，约 43 倍）；信封已改为消费点就地构建，`AllProxies` 免锁、`GetProxyNameList` 免锁 | 见「信封就地构建轮次」：唯一权衡是大文档路径多两次 id 扫描换取零分配，实测净胜 |
| 连接轮询（稳态） | 500 连接 **371ns / 308B / 6 allocs**：不扫描。generation 未动且表层数与本地 rows 等长时，直接返回上一次全表已证明的空 delta；`Manager.Generation()` 一次原子读 + `Size()` 一次 O(bucket) 读 | 已见底。`BenchmarkGetConnectionsDeltaWalk`（leave+join 每轮）钉住表变动路径 2.15µs/13 allocs，那里才付 Range 与行编码 |
| 连接轮询（表变动） | 500 连接 2.15µs / 2.31KB / 13 allocs：`xsync.Map.Range` 85% cum（回调占大头）、接口 map 查询 27% cum | metadata 快照自构造后不变（子模块测试钉住），行不再镜像字段；接口 map 的 equal 可省 6.8% 但要 unsafe 取指针，收益不抵 |
| 连接 resync | 206µs / 698KB，GC 占 45% | 三个非缓存 `document()`（Traffic/Delta/ProviderList）可池化，但频率低、绝对量每秒几百字节；`proxiesAnswer` 的缓冲被帧缓存持有，不可池化 |
| 路由刷新 | 13.8µs / 0 allocs：`providerVersionsEqual` 23%、`Selector.selectedProxy` 29% | 均为必要工作（provider 版本是外部推进的，读取不可省；选中缓存命中只需 3 次原子读） |
| 统计计数器 push | striped **2.315ns / 0 allocs**，shared 56.5ns（竞争） | 已到底（每次 2–4 个原子 add） |
| provider 列表答案 | 58µs：`AppendString(view.Path)` 占 68%（一半字节是路径） | 与答案体积成正比，无额外可省 |
| DNS 缓存命中（每查询） | `ExchangeContextCacheHit` **203.9ns / 1 alloc**；`ServeMsgCacheHitWithPack` 1601ns/15 allocs 的分配大头是基准自身的 unpack/pack（生产由监听器与传输层分别做） | `copyCachedMsg` 已有 slab 分配器（`cachedOneASlab`/`cachedASlab`/…），一次分配装下整条记录；真缓存路径已到底 |
| 代理选中 | Selector 大组 **1.468ns / 0 alloc**（并行）、URLTest 大组 131.8ns / 0 alloc、Fallback 大组 124ns / 1 alloc（store 新选择） | 分配只发生在"重选并存新值"，命中路径已由 `TestFallbackCachedSelectionStaysAllocationFree`/`TestURLTestFastCacheHitStaysAllocationFree` 钉住 0 alloc；与 Selector 同一设计 |
| 传输层每包路径 | `PacketConnWriteTo` 34.3ns、`ReadFrom` 32.8ns、`WaitReadFrom` 49.3ns、Relay 写 59.5ns、Quic 读 70.7ns、UoT 读 5.6µ | **全部 0 alloc**；已是每包地板 |
| 数据平面中继拷贝（每条 TCP 连接两个方向） | 稳态 **0 alloc/块**，`BenchmarkRelayStream` 13.1GiB/s（夹具带宽附近）；harness 100 并发 SOCKS5 20.3 万 req/s | 每连接两个 32KB 缓冲，随连接生命周期持有；已见底 |
| 每连接建立路径（新连接，非稳态） | 7.9k 连接样本：113 allocs/连接，其中产品侧约 20（`NewConn` 分层包装 5、dial context 链约 8、relayReader 2、tracker/metadata 其余）；CPU 57% 在 cgocall（connect/accept/握手），产品代码不进 top；goroutine 跑完后剩 6 个（无泄漏） | 系统调用主导，产品分配是每层一个包装/上下文的固有成本；单项去除都要吞并上游逻辑或改语义，无净收益可拿 |
| UDP 数据报路径（SOCKS5 UDP ASSOCIATE 全链） | harness 10 并发 × 10 秒：**79.3 万个数据报往返**（约 8 万/秒，含 nattable、worker 队列、DIRECT 出站、写回）；CPU 55% cgocall（recvfrom/sendto）、产品代码不进 top；分配侧产品侧仅 `newSocksPacket` 每报一次（~106B，37% 的总分配里其余 50% 是回显服务器自身的 stdlib 读） | 每报一个 packet 结构体是 PacketAdapter 契约的固有形态（sender 留最近一个包做写回，池化会让下一个数据报抢走它），`inner`/`tunnel` 各监听器一致；其余环节全池化 |
| 千人并发长连接（1000 连接 × 20s） | 73.9 万请求、36.9k req/s；mutex 竞争总计 5.73s/20s（产品侧占 0.9%，其余是 runtime 内部锁）；block 仅统计管理器 1s ticker 与收尾 Close 0.24s；CPU 35% cgocall + 25% 调度器（2000+ goroutine 的固有成本），产品代码不进 top；稳态分配每请求约 0（其余全部是建连一次性成本） | 每连接 goroutine 模型的固有形态；锁竞争与产品 CPU 均无可动之处 |
| 代理链路两跳（mixed → SOCKS5 上游 → 目标） | harness 100 并发 × 20s：35 万请求、17.4k req/s、0 失败（DIRECT 单跳 20.3 万，多一跳回环符合预期）；CPU 46% cgocall，产品侧 flat CPU 合计约 1%（tcpTracker/relayReader/BufferedConn 的 cum 全是委派 I/O 等待）；稳态分配产品侧 0（其余全是建连一次性成本，含上游握手） | 缓冲复用对代理链同样成立（两跳都走 `net.Relay`）；链上多出的组选择与上游封装都是每连接一次，不在每请求路径 |
| 启动文档解析（800 节点 + 200 组 + 200 规则） | `BenchmarkParseRawConfigBig` **13.59ms / 6.209MB / 104,385 allocs**：YAML 反序列化约 9.3ms（上游 `go.yaml.in/yaml/v3`，占 70%），`ParseRawConfig` 约 4.2ms（YAML 解析 ~30%、`structure.getFold` ~28%、GC ~15%）；`ApplyConfig` 仅 0.25-0.55ms | 反序列化是大头且在库内；`getFold` 折叠缓存实验已测得净负并撤销（见第 3 节）；解析内各点此前多轮已挖 |
| 规则匹配 | `DomainSuffixMatch` 3.7ns、`ClassicalIndexExactHit` 21.8ns、`SuffixHit` 69.2ns、`RuleWrapperHit` 9.1ns、150 条 classical 混合 1.65µ | **全部 0 alloc**；classical 的线性扫描是该规则类型的固有形态 |
| 子模块 `xsync.Map` | Size O(bucket) 不 O(entry)，`GetConnectionCount` 6.6ns/次 | 无进一步空间 |
| wrapper 自身 `groupDocsMu`（答案路径约 3%） | 缓存命中也要拿写锁，只为读 `cachedProxiesFrame`/`groupDocGeneration` | **维持不加锁（2026-11-11 复测）**：`dispatchMethodCall` 走 `safeGo` 起 goroutine，`document()` 确实并发。免锁需把「帧指针+generation」与「快照上的三个戳」一起原子化，且引入「答案在途时选中变更仍报旧选中」的陈旧窗口（现在持锁仅锁内几纳秒）。收益已从 4.4% 降到约 3%，更不值得 |

**覆盖侧剩余缺口（全部结构性，不为凑数写测试）**：

| 范围 | 现状 | 为什么剩下 |
|---|---|---|
| wrapper | 93.7% | 剩 6 个：`StartServer`（IPC 入口，测试走 `dispatchMethodCall`）、`handleCrash`（`core.crash` 就是让进程崩的 dev 旋钮，`TestEveryCoreMethodConstantIsDispatchable` 已单独记账）、`requestTrafficWatch.clear`（桌面构建 `hasEventListener()` 恒 true，该分支 Android 可达）、`dial_pipe.dial`、`ExitOnTermination`、`ownership_other` 三个 |
| 子模块 `adapter` | 86.7% | 剩 `adapter.go` 的 `ListenPacketContext` 转发与 `testState` 部分分支；前者由隧道测试在运行时覆盖 |
| 子模块 `adapter/outboundgroup` | **76.1%** | 0% 全是 `DialContext`/`ListenPacketContext`/`SupportUDP` 一类接口方法，由 wrapper 与隧道测试在运行时覆盖 |
| 子模块 `tunnel` | **76.5%**（本会话 60.5% 推上来） | 剩 `processUDP`/`startUDPSender`/`dialUDPSender`（真 UDP 往返 + 代理拨号）与两个 error 分支（`handleUDPToRemote` 写失败、`ResolveRoute` 的 `preHandleMetadata` 失败） |
| 子模块 `tunnel/statistic` | 94.4% | 剩 `handle()` 的 1s ticker 循环（50%）与 tracker 对裸 conn 的读写（现有方向测试经真 pipe 已驱动） |

### 2026-11-11 晚间会话新增实测与否决（勿重做）

| 位置 / 设想 | 实测 | 结论 |
|---|---|---|
| Dart 侧 core feed flush（`core_manager_feed_benchmark_test.dart`，760 事件/flush） | 全量 1270us。逐段摘除实测归属：logs `addAll` ~140us、dns `addQueries` ~156us、requests `addRequests` ~170us、traffic `updateTraffic` ~36us（两次），**剩余 ~770us 在事件到达路径（`Log.fromJson`/`TrackerInfo.fromJson`/`DnsQuery.fromJson` + 入队）与 pump 期间的 widget 重建** | 结构性成本：事件模型构造与订阅这些 provider 的界面重建。`LogPayload.parse` 已是 `Expando` 惰性解析（不在 feed 路径），无逐事件可削项；要再降只能减少订阅 widget 的重建面（`select` 化），属界面架构议题，收益 <0.5ms/300ms，记账不动 |
| GC 策略（`debug.SetGCPercent`/`SetMemoryLimit` 或 `GOGC` 环境变量） | `GOGC=400` vs 默认，`BenchmarkRelayStream` n=3：247us / 16.4-17.4GB/s -> 257us / 16.0-16.6GB/s（略差，噪声内）；`BenchmarkRelayPacketConn*` 全部 0 alloc 无差别 | **否决**：数据平面稳态 0 分配，GC 不在路径上；唯一 GC 敏感路径（resync 答案、profile 解析）都是低频一次性成本。改 GC 策略只涨 RSS 不涨吞吐，勿重做 |
| 连接轮询 churn 路径改「增量事件日志」（子模块 Manager 记 join/leave 环形缓冲，wrapper 只取上次序号之后的事件） | 已落地「稳态免扫描」后，churn 轮询（每轮 leave+join 两个预建 tracker）500 连接 2.15us / 13 allocs；busy 用户 2000 连接约 130us/2s = 0.006% CPU | **不做**：剩余成本是 O(活跃连接) 遍历，换成 O(变更) 需要子模块新增加速结构 + wrapper 侧行缓存失效语义，绝对收益 0.006% CPU，风险收益不相称 |
| proxies 答案帧的 Dart 侧解码迁 isolate（`Isolate.exit` 零拷回报文） | 账本 2026-11-05 实测 132KB 帧 JIT 解码 874-1282us；AOT 估 ~400us；每次 answers（点选/刷新/测速完成），非每帧 | **不做**：AOT 下 UI 线程成本 ~0.4ms（8ms 预算的 5%），迁 isolate 只省消息开销之后的一小部分，还要改 RPC 消费契约；等 profile build 实测 AOT 数字再议 |
| Dart 侧大表键入搜索的增量收窄（缓存上一次关键词与命中集，新关键词若是旧词的延伸就只过滤命中集） | 1 万行键入实测基数：DNS 查询页（Expando 缓存后）约 1.46ms/键击（JIT），连接/代理页同形状；方案只在底层列表**同一实例**期间有效，而轮询每 2s 就换一次列表、输入法每分钟数次按键，命中窗口小 | **不做**：命中窗口窄 + 需要 (列表身份, 词序, 命中集) 三元缓存与严格的作废语义，复杂度高于 1ms 级收益；现状「词法缓存 + terms.every(contains)」已在账本 2026-11-09 定为最小形状 |
| 连接表 `RecordColumn.sortKey` 的 `toLowerCase()` 三案（守卫降格 / rule 列两段式键 / metadata 锚定缓存） | 三条的完整数据见第 3 节 2026-11-12 三条否决记录：守卫版在 `progress`/`title`/`network` 快 13-18% 但在 `exit`/`rule` 持平或慢 12%，方向不一致；两段式键快了 5.8 倍但穷举 28900 组有 34 组排序 `sign` 不一致（payload 含空格且大小写混合时分叉），是用户可见行为回归；metadata 锚定缓存绕不过 Expando 查找本身 | **全部否决**：`sortKey` 这条路以「不改变排序语义」为前提已无可动的部分，键构建成本是 `Comparable` 契约的必要形状，勿重做 |
| SpeedCard 每次采样整卡重建（`ref.watch(trafficsProvider)` 后计算 current/peak/total） | 拆成三个 `ConsumerWidget` 各自 `select`（`_SpeedFigure` 取 `safeLast`、`_SpeedPeak` 取全窗 fold、`_SpeedTotal` 取方向总量），外壳只保留密度/样式，图表继续收整个 `FixedList`（靠 `LineChart.revision` 增量刷新）。同会话 5 轮交替配对（每轮 120 次采样，两种先后顺序各跑一轮）：新版 2630/2728/2639/2703/2925µs，基线 3251/3221/3384/3240/3190/3240µs，**中位 2684 → 3240，稳定快 17%**，两轮顺序下同向 | **已落地**：`54cf96f8`（83 增 32 删，无兼容分支）。`flutter test` 1014 例全绿，dashboard 172 例全绿，`dart analyze` 0 error / 0 warning。Failing closed：过程中一次 apply_patch 误把 `NetworkSpeedCard.build` 当成插入点，在文件中间留下 90 行孤儿 build 并复制出一份重复类，编译期即被 `Expected a declaration` 抓住，对照 `git show HEAD:` 原版删除孤儿后缝合，未带入任何 diff |
| `NetworkSpeedCard` 同形状拆分（外壳只留静态结构，`_SpeedTile` 改 `ConsumerWidget` 各自 select speed/total，图表仍收整个 `FixedList`） | 同会话交替配对（每轮 120 次采样，两种先后顺序各一轮）：新版 4614/4724/4510µs，基线 5192/4863/4742/4728µs，中位 4614 → 4742，**只快 2.7%，落在噪声内**。且该基线已含上一轮 `SpeedCard` 优化，真实增益更小 | **撤销**：tile 自身每采样必须重建（`LineChart` 要整个 `FixedList` 才能按 revision 增量追加），两处图表的重建成本吃掉了拆掉的 `DashboardCardHeader` 与另一个 tile 的容器，只剩一个小 header 的收益。勿重做——手机端单卡要再降只能动 `LineChart` 的输入契约，那需要跨 `prism_ui` 的公共 API 变更，风险高于收益 |

| 协议列 `metadata.network.toUpperCase()` 每行每帧各造一个新字符串 | 核实取值域后改用常量 `switch`：`NetWork.String()` 只有 `tcp`/`udp`/`all`/`invalid` 四个返回（子模块 `constant/metadata.go`，`MarshalJSON` 同样四路，与 `String()` 逐字对应），所以四路 switch 覆盖全域，`_ =>` 只作安全网。同会话 3 轮交替配对（500 行 ×300 次）：3103/3403/3244µs → 1548/1651/1548µs，**稳定快 50-52%**；counter-only 刷新场景同一方向（2577/2707/2830 → 1437/1539/1611，-44%~-45%）。**已落地** `9c64c9e9`，两处显示点各 1 行改动，`flutter test` 1018 例全绿（新增 4 例把四个取值逐一钉成 `toUpperCase()` 的同值，防止上游加第五种网络类型时静默退化），`dart analyze` 0 error / 0 warning | **已落地**：语义完全等价（不是近似），收益远超 15% 判定门槛；账本第 5 节「单元格约一半是 widget」的判断也由此进一步修正——协议列的 7% 里几乎全是这次消掉的分配 |
### 2026-11-12 表格行单元格实测修正轮次（实测，无代码改动）

第 5 节的「表格行单元格构建」一行写着「约 1.40µs/行，其中约一半是字符串格式化，约一半是单元格 widget」。用同形状基准重测（`RecordTable.cellsOf`，500 行，counter-only 刷新 `copyWith(upload:, download:)`，同进程 5 轮交替取中位）：**单行全 8 列 850ns/行**（旧估值 1.40µs 已因槽位闭环与 `copyWith` 原样保留 metadata 而过时），构成几乎全是字符串格式化。

| 片段（500 行 ×300 次） | µs | 占格式化总量 |
|---|---|---|
| `trackerDurationText` | 27406 | 32% |
| `dashboardTraffic(upload)` + `dashboardTraffic(download)` | 29029 + 28152 | 68% |
| `metadata.network.toUpperCase()` | 5773 | 7% |
| `title`/`progressText`/`ruleText` 三个惰性 getter | 9949 | — |

再拆 `dashboardTraffic`：全链 28547µs 中 `fixed(decimals: 1)` 占 24018（84%），纯 `toStringAsFixed(1)` 占 18682，1024 单位换算循环只占 1709（6%）。`toStringAsFixed` 是 VM 内部的 double→string，Dart 侧绕不过去；账本已记录把它换成整数路径在 200k 随机值对拍下有 3 处取值不一致（`0.15` → `0.1` vs `0.2`、`-0.0` → `-0` vs `0`），**语义不等价，撤销**。

结论：单元格路径剩余成本全在 VM 的 double 格式化里，与 2026-11-09 对 `fixed(decimals: 1)` 的结论一致；本轮不改代码，只修正「一半是 widget」这个过时判断，避免后续再把时间花在 widget 侧。

### 2026-11-12 DNS 查询页筛选 facet 单值化轮次（已落地）

`dnsQueryFacets` 的 initiator/cache/rcode 三个 facet 原来共用一段 `for (final kind in ...)` 循环，每个 facet 的 `valuesOf` 都要跑一遍 `query.resultFilters`——那是一个为每行新建 `List<RecordFilter>`（最多 3 个 `RecordFilter` 对象）的 getter，然后再为每个 facet 包一层 `[for (final filter in ...)]` 列表。DNS 查询页每 300ms 对全表 500 行 offer 一次，「筛选项」这个纯展示开销因此被付了整表建表的价钱。

改法：三个 facet 各自 `RecordFacet.single`，直接读行上的字段（`query.initiator?.label ?? ''`、`query.cached ? l10n.cache : ''`、`query.hasFailureRcode ? query.rcode : ''`），语义逐条对齐 `resultFilters` 里的三条构造。计数与过滤两条路径都因此走单值快路，都不再分配。

配对实测（500 行 ×4 个 offered facet，2000 次/轮，同进程 7 轮交替取中位）：**588.4µs → 186.2µs（-68.4%）**，复跑一轮 192.1µs。这是账本 Dart 侧记录里最大的单笔剩余成本（requests 页同形状只有 47µs，本项是它的 12 倍）。

守护：`test/models/record_filter_test.dart` 新增「the dns facets offer the value resultFilters names」，把三个 facet 的 optionsOf 输出与行自身 `resultFilters` 的值集合对拍，钉住「筛选 chip 命名的值必须是结果列真的渲染的那个」，防止将来 facet 与渲染分叉。注意 `RecordFacetKind.type` 不在 `resultFilters` 里（是行的独立列），所以对拍范围只含本轮改动的三个 facet。验证：`test/models test/views test/features` 1019 例全绿，`dart format` 0 changed，`dart analyze` 0 error / 0 warning。

顺带修正：本轮实测暴露 `resultFilters` 在未加载 l10n 时会断言失败（`currentAppLocalizations` 的 `AppLocalizations.current` 为 null），原 `record_filter_test.dart` 用的是裸 `package:test` 因此无法覆盖 DNS facet；已在测试侧加载 en delegate。

### 2026-11-12 连接流量折叠免整表复制轮次（已落地）

`Connections.updateTraffic` 每次调用都先 `List<TrackerInfo>.of(_orderedRows)` 把整张有序表复制一份，再遍历 traffic 样本找变化槽位；样本一个槽位都没推动时，这份复制纯属浪费（500 行表 = 500 个引用的 memmove）。真实场景里 Core 每秒上报的样本只有少数几行在动，多数轮次几乎是空转。本轮改成「只在第一次真正推动某个槽位时才复制」，无变化的样本直接返回，不分配也不发布新快照。

配对实测（`connections_update_benchmark_test.dart`，500 行表 + 每轮 8 行变化 + 40 个查表未命中，5000 次/轮，同进程 JIT）：**3.46/3.54/3.74µs → 2.93/2.57/2.71µs（约 -21%）**。收益来自两处：省掉同一轮里对同一列表的重复复制，以及变化的槽位数少于全表时不再付全表代价。

守护：`test/views/dashboard/connections_table_test.dart` 新增「a sample that moves nothing publishes nothing」，钉住「未命中任何行的样本与值未变的样本都不发布新快照」（`notifier.state` 保持同一实例）。这个用例在改动前必然失败——原实现无条件复制并发布。

### 2026-11-12 帧读取器键分发改字面量比对轮次（实测否决，勿重做）

曾假设 `_readRow`/`_readMetadata` 的字段分发里 `final key = _readString()` 会为每个键名物化一个 String，而文件里的 `_skipKeyIs(literal)` 正好免掉这次分配，于是把两处最热的行/metadata 读取器改成 18+10 段的 `_skipKeyIs` 链（含逃生分支 `_readString()` 保留非字面量键的语义，`event_json_test.dart` 的「an escaped spelling of a key keeps reaching its field」正是为此而存在）。

配对实测（`event_row_parse_benchmark_test.dart`，500 行 connections 快照帧 ×500 次，同进程 7 轮交替取中位）：**1795/1767/1826µs → 1828/1860/1876/1877/1841/1858/1906µs（+4~5%，方向在 7 轮里完全一致）**。结论：Dart 的 `switch (String)` 是一次跳表/哈希查表，代价与键字符串的物化无关；而 18 个分支的 `_skipKeyIs` 链平均要做约 9 次 `startsWith` 逐字面量比较，反而更贵。这正好复核了 `event_json.dart` 顶部 2026-11-11 留下的既有结论（「a field name goes through one string switch: the table lookups it used to walk cost more than the comparisons they avoided」），本轮把它从 log 读取器扩展证实到最热的行/metadata 路径。**改动已撤销**，`lib/core/event_json.dart` 回到 HEAD 版本。

新基建保留：`test/core/event_row_parse_benchmark_test.dart` 是账本里第一个覆盖 connections 快照帧解析的基准（既有 `event_parse_benchmark_test.dart` 只测 log/loaded，完全不碰每行 18 个字段的 metadata），后续衡量帧读取路径的改动都以它为配对基准。


### 2026-11-12 仪表盘 feed 快照免整表反转轮次（已落地）

`_ConnectionsTableCardState._takeSnapshot` 对 requests 与 dns 两个 feed 都做 `ref.read(xProvider).list.reversed.toList()`：`reversed` 是惰性迭代器，`toList()` 因此为**整张表**建一个倒序副本。而下游 `_Table` 只看得到 `_maxFeedRows = 100` 行，`maxRequestsLength = 1600`、`maxDnsQueriesLength = 2400`，所以一次快照要复制 16～24 倍于实际用量的引用，每 2 秒一次。这与 2026-11-12 已落地的「connections 表格直接读 provider 快照」是同一类问题，只是 requests/dns 两条 feed 漏了。

改法：`_Table` 增加 `reverse` 标志，snapshot 直接交 provider 的不可变快照（零复制零分配），反转与有界 head 都在 `_Table` 内完成。顺序语义逐条对齐原实现：`_sorter.sort` 仍作用于全表（点表头排序依旧正确），head 仍是排序结果的前 `_maxFeedRows` 条，只有没人点过表头（`_sort == null`）时才把 head 反转为「最新在前」。这两个细节都有用例钉住——`tapping a column head sorts the card table` 在我第一版「取尾 head 再反转」和「无条件反转」两种写法下都会失败，正是它们把正确形状逼出来的。

配对实测（`feed_snapshot_benchmark_test.dart`，1600 行 ×20000 次快照，同进程 JIT）：**全量 `reversed.toList()` 14.64/14.39/14.46µs → 有界 head 0.86/0.82/0.87µs（约 -94%）**。

验证：`test/views test/providers` 1163 例全绿；全量 `test/models test/views test/features test/providers test/core test/common test/widgets` 3813 例通过，仅 5 例失败且**与本轮无关**——`test/common/mitm_trust_test.dart`（4 例）与 `test/common/window_test.dart`（1 例）在把本轮改动 stash 掉后的干净 HEAD 上同样失败，属 Windows 主机跑 Linux/窗口平台探针的既有环境性失败；`dart format` 0 changed，`dart analyze` 0 error / 0 warning。

### 2026-11-12 仪表盘颜色持有者按 scheme 缓存轮次（已落地，含一轮否决）

**否决方向**：`RecordFilterController.offer()` 每轮为每个 offered facet 构造 `selected` 列表（`[for (final filter in filters) if (filter.kind == facet.kind) filter.value]`）。实测（`test/models/record_offer_benchmark_test.dart`，500 行 ×2000 次，同进程 JIT）：整个 `offer` 43.05µs（logs 表 29.08µs），而逐 facet 构造 `selected` 列表只占 **0.95µs（requests 表的 2.2%）**。离 15% 判定门槛太远，**不改**；方向本身成立（filters 为空时可免），但收益量级不配一次签名变更。

**落地方向**：`DashboardColors.of(context)` 每卡每次 build 都重算，而 30 个调用点全在 build 里。配对实测（`test/views/dashboard/dashboard_colors_benchmark_test.dart`，200000 次，同进程 JIT）：

| 读法 | ns/次 |
|---|---|
| `DashboardColors.of(context)`（改前） | 396–411 |
| `Theme.of(context).colorScheme` 单次查找 | 427 |
| 三次读 theme，每次都查 | **1112–1140** |
| 三次读 theme，本地持有 scheme | 144–152 |
| 按 scheme 缓存后的 holder 读取 | **24** |

两条结论：（1）颜色构造不是瓶颈，`Theme.of` 的继承查找才是；（2）真正的浪费是同一 build 里重复查 theme——三次读 1112ns vs 持有 scheme 155ns，**7.7 倍**。

改法两段。其一：`DashboardColors.ofScheme(ColorScheme)` 新增，结果按 scheme 挂在 `Expando` 上（颜色角色是 scheme 的纯函数，主题切换即换 key），`of(context)` 保留签名转调，30 个调用点零改动受益——**396 → 251ns**。其二：把已持有 `colorScheme` 的 build 里的 `of(context)` 换成 `ofScheme(colorScheme)`，消掉重复查找，涉及 `card.dart`（`DashboardCard`/`DashboardChip`/`DashboardSwitchRow`）、`connections_table.dart`、`proxy_groups.dart`、`memory_info.dart`、`current_outbound.dart`、`network_takeover.dart`、`edit.dart` 七文件 12 处。`DashboardShadows.e1/e2` 同步加 `Of(scheme)` 变体（它本就返回静态常量，只是别再查一次 theme）。

**教训**：用 PowerShell 全文替换 `DashboardColors.of(context)` 时误伤了 `connections_table.dart:741` 的 `_Source`（那个 build 没有 scheme 局部变量），由编译期报错抓住，回退该行。逐点改时必须核对每处所属的 build 是否真的持有 scheme。

验证：`test/views/dashboard` 175 例全绿；`test/models test/views test/features test/providers test/widgets` 2639 例全绿；`test/core test/common` 1158 过 / 5 失败，失败集与 2026-11-12 上一轮逐字相同（4 个 Linux-only `mitm_trust` + 1 个 `window` 探针），stash 掉本轮改动的干净 HEAD 上同样失败。`dart format` 0 changed，`dart analyze lib` 0 error / 0 warning。新基建：`test/views/dashboard/dashboard_colors_benchmark_test.dart`（`@Skip` 惯例）、`test/views/dashboard/rebuild_card_benchmark_test.dart`（未采用，仪表盘整卡 pump 依赖过多全局状态，形状不成立）、`test/models/record_offer_benchmark_test.dart`（否决方向的证据）。

### 2026-11-12 仪表盘连接 split 与 surface 层级轮次（实测否决两项，无代码改动）

**否决方向一**：`liveProtocolSplit`（`lib/views/dashboard/widgets/connections_table.dart:176`）每行走一次 `equalsIgnoreCase('tcp')`，设想加长度+首字符短路。配对实测（`test/views/dashboard/connections_feed_benchmark_test.dart`，300 行 x2000 次，同进程 JIT，两轮）：**`_replacedSplit`（`toLowerCase()` + `==` 的旧形态）20.13/21.35µs，`_landedSplit`（现在形态）13.26/13.43µs**。注意这个基准把 `sort` 也计进了两个函数，`liveProtocolSplit` 只是其中一段；即便整段比较都省掉也落在个位数 µs 以下。而 `equalsIgnoreCase`（`lib/common/string.dart:166`）本身已做长度短路、零分配。不改。

**否决方向二**：`context.raisedSurfaceLevel` 共 34 处、`context.surfaceLevel` 4 处，设想批量换成持有 scheme 的写法。`SurfaceScope.of(context)` 是一次 `dependOnInheritedWidgetOfExactType`，与 `Theme.of` 同类但更浅（`SurfaceScope` 挂在更近的层级，多数 build 本来就依赖了某个 InheritedWidget），`surfaceLevel.next` 只是枚举 switch。它和 `fcb604bd`/上一轮解决的"同一 build 里查 3 次 `Theme.of`"不是同一性质：这里每处只查一次、返回值是枚举本身，没有任何重复可省。不改，理由记账，免得后续会话按"和 theme 查找一样"的直觉重做。

验证：两轮只跑既有基准（`connections_feed_benchmark_test.dart` 跑后已还原为 `@Skip` 状态，`git diff` 零输出），仓库代码零改动。


### 2026-11-12 仪表盘颜色收口轮次（已落地，15 处 of(context) 转 ofScheme，含一处死代码清理）

`fcb604bd` 把 `DashboardColors` 按 scheme 缓存（`of(context)` 转调 `ofScheme`，读一次约 251ns），但仓库里还剩 15 处 `DashboardColors.of(context)`。它们不是"忘了改"：`of(context)` 内部就是 `context.colorScheme` 的一次继承查找再命中 `Expando`，而 `_SpeedChart`、`_ServiceCell`、`DashboardBlock`、`_Source`、`_MemoryBar`、`_UsageMeter`、`_GroupsFigure`、`_IconStack` 这批 build 自己没有持有 scheme，每次调用都要重新走一遍 `Theme.of`。本轮把这 15 处统一提到 build 顶部做一次 `context.colorScheme`，之后所有颜色读都从局部变量来，与 `fcb604bd` 已改的 12 处同一形状。

覆盖的 build：`dashboard.dart`（Scaffold 背景）、`card.dart`（`DashboardBlock`）、`connections_table.dart`（`ConnectionsTableCard` 的分段按钮底与 `_Source` 字母块）、`memory_info.dart`（`_MemoryBar` 空态）、`outbound_mode.dart`（两处）、`profiles.dart`（`ProfilesCard` 的临期 warn 与 `_UsageMeter` 的 warn+tone2）、`proxy_groups.dart`（`_GroupsFigure` 的环与 `_IconStack` 的 +N 块）、`service_status.dart`（`_ServiceCell` 的徽章底）、`traffic.dart`（`_SpeedChart` 的上行配色）。

**顺带清掉一处死代码**：`TrafficDirection.colorOf(context)`。`_SpeedChart` 改成读本地 colors 后它在仓库与测试里都再无调用者（`rg` 全仓库零命中），是本轮改动催生的死成员，直接删。同枚举的 `glyph`/`glyphColorOf`/`labelOf` 均有真实调用，保留。

**实测**：`of(context)` 单次约 251ns、`Theme.of` 单次查找约 427ns（均已由 `fcb604bd` 那轮钉住）。本轮 15 处中 11 个 build 每次只调一次（省的就是那次 `Theme.of` 查找，约 427ns），4 处同 build 内两次（`profiles.dart` 的 warn+tone2、`proxy_groups.dart` 的 card+tone、`outbound_mode.dart`、`traffic.dart`）。仪表盘整页重放的收益是每 build 数百纳秒量级——金额小，但这批位置本来就该持有一个 scheme，属于把 `fcb604bd` 的结论收口。
## 6. 后续会话推荐流程
### 2026-11-13 延迟表持久化有界化（bug 修复，含崩溃归因）

**症状**：用户报告 Windows 上 FlClash 打开约 3 分钟后自行退出。事件日志实证：

```text
11/13/2026 05:01:58  FlClash.exe 1.0.8.226
  错误模块: flutter_windows.dll
  异常代码: 0xc0000409 (STATUS_STACK_BUFFER_OVERRUN)
11/13/2026 05:02:03  Windows Error Reporting  事件名称: BEX64
```

**归因链**（全部 git 实证，非推测）：

1. `31b2063a`(11-04) 把 delay map 落进 shared_preferences，这是本 fork 自加功能；上游 `chen08209/FlClash` 从未持久化该表，其 `preferences.dart` 无任何 delay 读写。
2. `bbb2958b`(10-16) 原本有两处清理：`core_manager.dart` 的 `invalidateDelayTests()`（provider 重载时）、`setup.dart` `fullSetup()` 开头的 `value = {}`。
3. `6c411bc5`(11-07, merge upstream v0.9.3) 使前者消失；`2e88bad4`(11-07) 使后者消失，注释写明理由是「delay results persist across profile switches」——这是有意的产品决策，且 `setup_action_test.dart` 有测试保护。
4. 两处清理都只挂生命周期事件，从不在「一批新节点延迟写进 map」时触发。用户 04:53 导入 5 万节点订阅，`setDelays` 直接追加，没有任何清理点命中。
5. 故障数据实测：`shared_preferences.json` 共 2,588,257 字节，其中 `flutter.delay_map` 单个 testUrl 下 **51,757** 条代理名，约 2.2MB。`_delayPersistInterval` 每 2 秒将整表 `json.encode` 后经 `AtomicFilePreferencesStore` 原子替换整个偏好文件。
6. 崩溃前 2 秒（05:01:56）正是那次 2.5MB 写盘，随后进程死亡。

**修复**：按序列化字节数给 delay map 设界，读写两侧同一函数。

- `lib/common/preferences.dart` 新增 `_delayMapMaxBytes = 512 << 10`、`_delayMapMaxUrls = 32`，`_boundedDelayMap` 从最旧端裁剪到序列化预算内。按字节而非条数定界，因为实测条目名长 5–48 字符、平均 43 字节，条数上限在不同订阅间差 6 倍。
- `getDelayMap` 现在读到超限数据时就地重写盘上内容：原先只收缩内存，35MB 坏数据会一直躺在盘上等下次保存才缩，而解码该载荷正是读路径的开销。
- `saveDelayMap` 同样过 `_boundedDelayMap`，任何路径长肥都会在下次持久化时收敛。

**实测**（`test/common/delay_map_bound_benchmark_test.dart`，`@Skip` 手工探针，同进程 JIT）：

| 场景 | 无界序列化 | 有界后落盘 | 收敛比 |
|---|---|---|---|
| 1,000 名 | 29,602 B | 29,602 B | 100.0%（预算内不动） |
| 51,757 名（本次崩溃载荷） | 1,731,180 B | 213,838 B | **12.4%** |
| 200,000 名 | 6,953,292 B | 213,838 B | **3.1%** |

即本次事故的写盘载荷从 2.5MB 降到 213KB，每 2 秒的持久化成本随之降一个数量级。

**一处分层否决**：一度考虑进一步「按当前配置裁剪」——`ConfigCounts` 只存数量不存代理名，要拿真实名单必须改 groups provider 的读取时机，且会改变「哪些延迟数字该显示」这一用户可见语义。有界层已能将崩溃载荷压掉 87.6%，语义改动风险不抵剩余收益，**本轮不做**；若后续要消除 213KB 的历史垃圾，方向是在 `setDelays` 时按 `group.all` 的现存名单做白名单，而非动 providers 链路。

**测试**：`test/common/preferences_test.dart` 新增 5 例（超限收敛、盘上超限读时即缩、预算内不重写、按字节丢最旧名、按上限丢最旧 url）+ 保留原有 3 例，共 26 例全绿。

**验证**：`test/common` 957 过 / 5 失败，失败集与干净 HEAD 逐字相同（4 个 Linux-only `mitm_trust` + 1 个 `window` 探针）；`test/providers test/models` 900 例全绿；`test/models test/views test/features test/providers test/widgets test/common test/ui test/database test/enum test/manager` 3869 例，仅上述 5 例环境相关失败。`dart format` 0 changed，`dart analyze lib` 0 error / 0 warning。

### 2026-11-13 代理名单 emoji 扫描记忆化轮次（已落地，含一次语义实测归因）

**背景**：`EmojiText`（`plugins/prism_ui/lib/text.dart` 的 `_spanOf`）每次为一段文本建 span 树都要整扫一遍 emoji pattern。代理列表滚动时同一个组名被反复重建，扫描结果却只由文本本身决定，等于把同一份答案算了一遍又一遍。`_GroupSliverState` 已用 `_rows` 缓存跨 build 的行，所以扫描不在每次滚动都发生，而是在行真正重建时发生一次。

**落地方向**：把 `lib/ui/emoji.dart` 里的裸 `RegExp` 换成一个记忆化 `Pattern`——`MemoizedEmojiPattern` 按文本记住已算出的 emoji 区间，`EmojiText` 因此对每个不同字符串只扫一遍。上限 4096 条、最旧先淘汰，沿用仓库既有惯例（`lib/providers/state/proxies.dart` 的 `_proxySearchTextCacheLimit = 20000`）。pattern 由主仓库注入（`lib/application.dart` 的 `emojiFont`），所以改动全部落在主仓库，没有碰 `plugins/prism_ui` 子模块。`_MatchAt` 只存 `(input, start, end)`，`group(0)` 当场 `substring`，不再持有正则自己的匹配子树。

**语义实测与归因**：新增 `test/common/emoji_pattern_test.dart`（22 例，非 skip），把新 pattern 与原 `RegExp` 逐case 对齐。两处实测发现的语义差异已如实记录，不藏在实现里：

1. `allMatches(text, start)` 里做了 `range.start < start` 的守卫，这只在边界对齐时与 `RegExp.allMatches` 等价（原语义是从 start 重新起扫）。全仓库唯一调用点只传 string 不传 start，所以等价。测试用例 `start=5` 钉住的是边界对齐行为。
2. `matchAsPrefix` 是"锚定在 start"的语义，原 `RegExp` 对以普通字符开头的文本返回 null；记忆化版本返回已算的第一个区间。测试里显式写出这条差异并注明原因，而不是悄悄改掉一方。若日后有调用方依赖锚定语义，这里要改成按 start 重新扫。

**配对实测**（同进程 JIT，`test/common/emoji_scan_benchmark_test.dart` 与 `emoji_row_benchmark_test.dart`，跑法为临时去掉文件首行 `@Skip`）：单名扫描 **442.39ns -> 125.82ns（-71.7%）**；40 行一次行重建（含 span 树构建）**8.55us -> 5.32us（-37.8%）**。两个基准都同时测原 `RegExp` 与记忆化 pattern，避免跨进程比较。基准文件按仓库惯例恢复 `@Skip` 后入库。

**顺带**：那两个基准与 `icon_svg_flag_benchmark_test.dart`、`emoji_pattern_test.dart` 都是 LF 行尾，初次 `dart format --set-exit-if-changed` 会把它们判为需重排；本机必须先真正跑一次 `dart format`（不带 `--output=none`）写回，门禁才归零。这是 CI "Check format" 的老坑，账本已记过，本轮再次印证。

验证：`test/common/emoji_pattern_test.dart` 22 例全绿；`test/models test/views test/features test/providers test/widgets test/common test/core` **3835 例，5 例失败**，失败集与干净 HEAD（stash 后复核）逐字相同——4 个 Linux-only `mitm_trust` 用例 + 1 个 `window` 探针，与本轮改动无关；`dart format` 0 changed，`dart analyze lib` 0 error / 0 warning。

### 2026-11-12 代理列表行高一次性化轮次（已落地，含两轮 Go 侧否决）

**否决方向一**：`RecordFilterController.offer()` 的 `selected` 列表（详见上一节，占 `offer` 总量 2.2%）。

**否决方向二**：`classOfMessage` 每事件一次的字符串 switch（5 个 case）。实测（`core/message_class_bench_test.go`，8 种事件类型各分一次类，同进程 5 轮）：**13.2–13.4ns/次、0 B/op、0 allocs**。即便每秒万事件也只占 130µs（0.013% CPU）。改成 int 枚举或 map 都要动 `Message.Type` 的 wire 契约（`MessageType` 就是一串序列化名），收益不抵风险，**不改**。

**否决方向三**：`_SpeedChart` 每次 build 为 `FixedList<Traffic>` 新建一个 `List<double>`（`trafficSampleLength = 24`）。`LineChart` 内部已按 `revision` 维护 series 与缓存，输入列表只是它的一次性读；24 个 double（约 300B）在 1Hz 采样下的分配可忽略，**不改**。

**落地方向**：`lib/views/proxies/list.dart` 的 `_GroupSliverState` 每个组的 build 里，`getRowExtent(widget.cardType)` 被算两次——一次在 `_rowsExtent(rowCount, ...)` 算 group 高度，一次在 `getItemHeight`。而行高只取决于 cardType。`getItemHeight` 内部跑 3–4 次 `measure.textHeight`（要读度量缓存）。

改法：把 `extent` 提到 `build` 顶部算一次，作为参数传进 `_buildPinnedHeader`（它此前自己又算了一遍同样的 `getRowExtent(widget.cardType)`）。同时把 `_rowExtent` 那个「初值 0 的行高缓存」去掉：它是一个在展开动画期间会算出错误 `rowsExtent` 的无效状态，而 `extent` 每次 build 都能直接算出，缓存本身没有意义——这条是用户「精简代码逻辑、不写无效代码」要求下的清理。

验证：`test/views` 553 例全绿（`proxies_list`/`proxies_group_offsets` 5 例单独绿）；`test/models test/features test/providers test/widgets test/core` 2303 例全绿；`test/common` 957 过 / 5 失败，失败集与上一轮逐字相同（4 个 Linux-only `mitm_trust` + 1 个 `window` 探针）。`dart format` 0 changed，`dart analyze lib` 0 error / 0 warning。新基建：`core/message_class_bench_test.go`（Go 侧基准不走 Dart runner，跑法是 `go test -run '^$' -bench BenchmarkClassOfMessage`）。

``powershell
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
``

修改后按同一基准生成 current，用：

``powershell
D:\Codex\tools\go-bin\benchstat.exe <baseline> <current>
``

只有时间、内存或分配有明确收益才继续；否则恢复改动并记录拒绝原因。

### 2026-11-13 仪表盘数字分组与共享条纹清理轮次（已落地）

**落地方向一：`dashboardCount` 的 intl 通用模式解析换成纯数字分组**（`ad39d4eb`）。`NumberFormat.decimalPattern('en').format` 对每一个值都要解析模式、走 `_formatFixed` 的 floor/幂/字符串拼接通用链路，而这里要的只是英文千分位。`lib/views/dashboard/style.dart` 改为按数字长度每 3 位插逗号，`< 1000` 直接返回原字符串。

配对实测（`test/views/dashboard/dashboard_count_benchmark_test.dart`，同进程两段各 20000×9）：intl 模式 **511 ns/次**，现实现 **312 ns/次**，约 1.6 倍；基准同时用 9 个采样值断言两边输出逐字一致（`< 100000` 全部分组路径）。调用点全是 1–2 秒一次的轮询（`connection_stats.dart`、`connections_table.dart`、`profiles.dart`），单次节约约 200ns，收益要按调用频率衡量而非单次绝对值。`test/views/dashboard` 174 例全绿。

**落地方向二：删除共享计数条纹**（Clash.Meta `a5626213f`，父仓库 `21cc2eda`）。`Manager.PushUploaded` / `PushDownloaded` 把所有推送都记到 `stripes[0]`，即所有连接抢同一条缓存行；而 tracker 早就在连接生命周期内持有自己绑定的条纹。核查确认这两个方法**在生产代码里已无任何调用方**（`tracker.go` 是唯一写入方，走 `tt.stripe`），只剩测试与基准在用。因此连 `sharedStripe()` 和 `BenchmarkManagerPushShared`（它测的形状已不存在）一并删除。计数测试改为显式取一条条纹推送，`TestManagerParallelPushSumsExactlyAcrossStripes` 改为每个 worker `bindStripe()`——这本来就是它声称在测的东西。

参考基线（同机 `BenchmarkManagerPushStriped` 2.21–2.29 ns/op、0 allocs；共享形状被删前约 52 ns/op），差距来自缓存行争用，这也是生产链路早已走每连接条纹的原因。

**覆盖**：`gofmt -l` 空、`go vet` 空、`go test ./tunnel/statistic` 与父层 `go test .`（15.3s）通过。本机无 gcc，`-race` 未跑（需 CGO），记入本节而非静默跳过。

### 2026-11-13 v1.0.9 发布失败归因与修复（发布流程，非性能）

**症状**：`release-stable` run `43320286102` 的 `Build release assets` 步骤失败，链式派发的 build run `43320990647`（tag `v1.0.9`）`Dart` job 失败，`upload` 与 `build` 两个 job 随即 skip，最终 v1.0.9 在 GitHub 上是一个 **0 资产的空 Release**。对照组：v1.0.8 的 tag run `43166990353` 全绿。

**归因链**（全部来自 Actions API 与本地复跑，非推测）：

1. `release-stable.yaml` 的 `Build release assets` 用 `gh workflow run build.yaml --ref v$version` 派发构建，随后 `gh run watch "$run_id" --exit-status` 等待——**build 任一 job 失败都会让这一步非零退出，整个 release job 标红**。所以 release-stable 红不等于 release 脚本本身有问题。
2. build run `43320990647` 的 Dart job 步骤逐个比对：`Check format`/`Analyze`/`Verify changelog` 全部 success，**唯一失败的是 `Run tests`**（第 11 步），`Check coverage` 因前一步失败被 skip。v1.0.8 的 Dart job 12 步全 success。
3. 本地按 CI 原样复现：`dart format --set-exit-if-changed` 0 changed；`dart analyze` 剩 6 条既有 info（全在 `test/core/event_json_test.dart`，与本轮无关）；`dart run tool/test.dart -- --reporter expanded --coverage` 失败集与账本登记的 5 个 Windows 环境性失败逐字相同（4 个 Linux-only `mitm_trust` + 1 个 `window` 探针，CI 为 Linux 会通过）；`check_coverage.dart` 87.67%、每个分组高于 floor。CI 与本地唯一的结构差异因此只能来自新增测试文件本身。
4. v1.0.8..v1.0.9 新增 14 个测试文件。其中两个写成真跑用例（无 `@Skip`）：`test/common/emoji_pattern_test.dart`（`library;`）与 `test/views/dashboard/dashboard_colors_benchmark_test.dart`（`library;`）。把两者各自单独跑、再跑它们所在的 bundle，定位到 `test/lint/design_package_test.dart` 的「the project imports no design library」失败。
5. 根因：`design_package_test` 递归扫描 `lib`/`test`/`tool`/`plugins` 下所有 `.dart`，禁止 `package:flutter/material.dart`，**只豁免 generated 代码，既不豁免 `@Skip` 文件、也不豁免基准文件**。v1.0.9 新加的两个仪表盘基准文件都 import 了 material：`dashboard_colors_benchmark_test.dart`（第 6 行）与 `dashboard_text_benchmark_test.dart`（第 7 行，后者有 `@Skip` 仍被扫到）。这就是让 CI Dart job 挂掉的那两行。
6. 本机为什么没在失败集里暴露它：`tool/test.dart` 把失败文件单独重跑，重跑通过的就归因为「共享 isolate 干扰」并放行。`design_package_test` 在 bundle 里失败、单独重跑**也**失败，但本机全量跑的失败清单被那 5 个环境性失败掩盖，容易被一并当成已知项略过。**教训：本地全量 exit code 非零时必须逐条核对失败清单是否只有登记过的那几项，不能看了数量就跳过。**

**修复**：两个基准文件换成仓库既有的取主题化上下文的写法——`TestApp`（`test/helpers/test_app.dart`，内部是 `PrismApp`）+ `import 'package:prism_ui/prism_ui.dart' show Theme;`。`DashboardColors` 的角色本就构建在 prism_ui 的 `Theme` 上，`Theme.of(context).colorScheme` 走的是它而不是 material 的 `Theme`，语义等价且更贴合被测代码。修复后两个基准文件均可跑并打印数字；两个 lint 全绿；全仓库现已无一处 `package:flutter/material.dart` import（`plugins/prism_ui` 原本也未用）。

**验证**：`test/lint/design_package_test.dart` 绿、`test/lint/typography_test.dart` 绿；`dart run tool/test.dart -- --reporter expanded --coverage` 失败集与登记集逐字相同；`check_coverage.dart` 87.67% 且每组高于 floor；`dart format` 1097 文件 0 changed；`dart analyze` 0 error / 0 warning；`gofmt -l`（CI 的 `./*.go ./cmd ./mobile ./platform ./timezone ./tun`）空输出；`go vet .` 通过。

**发布侧教训（后续必须遵守）**：

1. v1.0.9 那个 0 资产 Release 的条目已被消耗掉。重新发布时 `tool/release.sh` 会按 pubspec 版本自动 bump（当前 `1.0.9+2026111203` 打头，新版本收的是本修复提交），**v1.0.9 的空壳会被新版本覆盖，不需要单独清理**。
2. 派发 `release-stable.yaml` 之后要盯的不只是它这一个 run：它只做改版本号、写 changelog、打 tag、push，然后派发 build。**真正的验证在它链式触发的那个 build run**，任一 job 失败都会让 release-stable 标红。
3. tag 触发的 build 才会跑桌面与 Android 的正式产物构建并创建 Release；`Verify changelog` 这一步只在 `refs/heads/main` 与 `refs/tags/*` 上执行，branch push 不跑。
4. 本地全量 exit code 非零时逐条核对失败清单，而不是看数量。
### 2026-11-13 补全排序小写化外提轮次（已落地，账本首个编辑器路径）

`lib/features/editor/completion_matcher.dart` 的 `completionScore` 原来**对每个候选**都执行一次 `typed.toLowerCase()`：一次 3000 候选的文档词补全就是 3000 次同一个小写化 + 3000 次新 String 分配。`typed` 在一次排序趟里是常量，这纯属可外提的重复工作。把它提到 `rankSuggestions` 的循环外，函数签名改为接收已小写化的 `lowerTyped`（`typed` 本身仍按原样保留用于 `candidate.startsWith(typed)` 的 100 分加成）。

配对实测（`test/features/completion_rank_benchmark_test.dart`，同进程 JIT，200 次调用/轮）：

| 候选集 | 基线 perCallUs | 改后 perCallUs | 收益 |
|---|---|---|---|
| 36 个配置键 | 53.7µs | 49.6µs | -7.6% |
| 3000 个文档词 | 1580µs | 1373/1323/1322/1342µs（三轮复测） | **-15.9%** |

`keep`（200 次调用返回的建议总数）三轮都是 **4020，与基线逐字相同**——排序结果未变，只有速度变。这是纯等价变换，且 15.9% 超过判定门槛。

账本此前未覆盖编辑器路径，本轮补上。此前唯一一次触碰 `completion_matcher.dart` 的记录是 v1.0.9 发布失败归因（只提到 `dashboard_text_benchmark_test.dart` import material），从未量过这条路径。

候选规模说明：`documentWords` 会进入候选集（`clash_completion.dart:198`、`script_completion.dart:201` 两处传 `request.documentNames`），所以 3000 不是虚构形状——大配置下它就是真实基数。

另一处未动的原因：曾评估把 `candidate.toLowerCase()` 也缓存进 `seen` map（按 label→lower 复用）。候选集每次击键都换引用，缓存命中率接近 0，且要引入有界 map 的失效语义，收益不抵复杂度，未做。

守护：新增 `test/features/completion_matcher_test.dart`（4 例）：三级排序（prefix > segment prefix > in-order）、大小写双侧折叠、重复 label 去重、空前缀返回 null。其中两例的初版期望写错过——写成 `['pool', 'path-pool', ...]`，但 `rankSuggestions` 里 `label == typed && snippet == null` 会剔除与输入逐字相同的建议，所以 `pool` 不出现。修正期望后才绿，这条行为由用例名如实描述。

验证：`test/features` + `test/lint` **210 例全绿**（含新 4 例）；全量套件失败集与干净基线**逐字相同**的 5 个 Windows 环境性失败（4 个 Linux-only `mitm_trust` + 1 个 `window` 探针）；`dart format` 1099 文件 0 changed；`dart analyze` 0 error / 0 warning，剩 6 条既有 info 全在 `test/core/event_json_test.dart`；`check_coverage.dart` 87.67%、每组高于 floor。

### 2026-11-13 `fixed()` 开销账本更正（实测否证，勿再沿用过时结论）

账本 4 处旧结论（`§2` 第 1268 行、`§3` 第 1417/1419 行与 2026-11-09 条目）都写着或暗示「`fixed(decimals: 1)` 比裸 `toStringAsFixed(1)` 多付约 35ns」。复核结论：**这条开销不存在**。

配对实测（`test/common/num_benchmark_test.dart` 新增用例，同一批 100000 个值、同进程 JIT、两法交替顺序跑 3 轮取中位）：

| 实现 | perCallUs |
|---|---|
| `value.toStringAsFixed(1)` | 0.1377µs |
| `value.fixed(decimals: 1)` | 0.1509µs |

即 `fixed()` 比裸 VM 调用慢约 **13ns**，而非快 35ns；且另一轮测出方向相反（fixed 0.1493 / raw 0.1641）。13ns 落在 VM double→string 的噪声带内，**结论是 `fixed()` 的修剪开销可忽略，不存在「多付 35ns」这回事**。整条链路的成本就是 VM 的 double→string（账本 84% 结论仍成立，但归因里的「35ns 是 Dart 侧可省的」不成立）。

因此此前两个「用整数路径绕开 `toStringAsFixed`」的实验（`§2` 第 1268 行记录：141ns → 53ns）照样**已因语义不等价被撤销**，这里不复述；只更正开销量级本身。新增的配对基准留在仓库里（`@Skip` 手工项），防止这个错误数字再次被引用。

### 2026-11-13 请求流量探测与死代码扫描轮次（两次实测否决，无代码改动）

本轮沿「账本没量过的路径」扫了两处，两次都被证据否决，如实记账，不留无效代码。

**否决方向一：`request_traffic.collect` 里那条每秒全表 `Range`**

现状：`core/request_traffic.go:69` 每秒走一次 `statistic.DefaultManager.Range`，遍历**全部活跃连接**，只为把 watch 里的请求标记为 alive。账本此前只记录了连接轮询的 generation 短路（`connection.go:135` 同模式），从没记过这条同形的每秒 O(活跃连接) 扫描。

第一版设想（照抄 `connection.go` 的 `Generation()` 短路）：记下上次见到的 generation，未变就跳过 Range。**实测证伪**——`TestRequestTrafficKeepsARequestTheManagerHasNotStoredYet` 立即失败。原因不是快慢而是语义：`alive` 表达的是「本轮是否在表里」，跳过 Range 后改成「上一轮的结论仍然成立」，而该用例的构造（`DefaultManager.Leave(tracker)` 后再 `add`）恰好在第二轮 generation 未变时**要求重新判定为 closing**。这条关闭语义由 5 个既有测试钉死，不值得为一次 Range 改动它。

第二版设想（反转扫描方向）：改用 `Manager.Get(id)` 逐个探问 watch 里的 tracker，把 O(活跃连接) 换成 O(watch 大小)。**未实施即否决**：`Get` 按 id 字符串查（`uuid.FromString(id)` 解析），而 watch 手上只有 `statistic.Tracker`，取 id 要额外调 `tracker.ID()` 做一次 UUID 字符串化；requests 页的 watch 集与活跃连接集同量级（都是当前请求），扫描方向的反转换不来净收益。

第三版设想（通知式关闭）：子模块已有 `DefaultRequestNotify` 在 `Join` 时通知（`tunnel/statistic/manager.go:71`），但 **`Leave` 没有任何钩子**。要根治得给子模块加一个 leave 通知并改所有调用方，属公共 API 扩张，收益不抵风险。维持现状。

结论：这条 Range 保留。它的成本与连接表同阶，而 wrapper 每秒本来就要为连接轮询付一次同形状的 walk，绝对量在既有预算内；`Range` 由子模块 `xsync.Map` 的 bucket 级锁 + 中间切片收集实现，指向它的优化会波及所有调用方。

**否决方向二：私有顶层死代码扫描**

为「精简代码逻辑、不写无效代码」写了一个 `tool/dead_declarations.dart` 探针：扫 `lib/` 下所有 `_`-prefixed 顶层声明，统计全仓库引用数，报 `<=1` 的（`test/lint/dead_file_test.dart` 只能查整个孤儿文件，编译器对「本库内只用一次」的私有声明不报警）。**全仓库仅一个候选，且是误报**：`lib/common/log_payload.dart:3` 的 `_endpoint`，被 `'^$_endpoint --> ...'` 与 `'^dial ...$_endpoint ...'` 两处字符串插值引用，探针只匹配裸标识符所以漏掉了。

该探针是一次性工具，按仓库规矩（脚本收拢、禁止散落一次性脚本）未入库，已删除；这条结论留在账本，后续同类任务不必重写。

结论：Dart 侧无私有顶层死代码可删。这一轮与 2026-11-12 的「`dart analyze` 在 `lib/` 0 告警」互为印证——lib 侧的无效代码已在往轮次清干净，`dart analyze` 的 unused 检查与本次探针的引用计数都指向同一结论。

**本轮同时复核的两个方向（均判定非热点，不是深挖后否决）**：`lib/views/profiles/custom/*` 三个大文件（custom_proxies 1695 行、groups 1371 行、members 818 行）的输入路径全部落在按键/开表单/保存上，没有任何一条接轮询——`customProfileData` 的上游（`customProxiesProvider`/`proxyGroupsProvider`）是数据库 backing provider，只在数据变化时通知；`core/delay.go` 的 `configuredTestTimeout` 每次延迟测试遍历所有 provider，但 `handleTestDelay` 只由 IPC `proxyTestDelay` 单节点触发，不构成批量热路径，且 `timeout <= longest` 已提前跳过未配置的 provider。

### 2026-11-13 代理列表行分块轮次（实测低于门槛，不入库，勿重做）

**背景与实测**：`lib/views/proxies/list.dart` 的 `_buildRows`(388) 与 `_buildUnfoldingRows`(402) 都调 `group.all.chunks(columns)`，而 `chunks` 是 `List.generate` + `sublist`，为整组物化全部子列表。参照基准 pair 测过（`test/views/proxies_row_chunks_benchmark_test.dart`，160 节点 4 列，同进程 JIT 2000 轮）：

| 做法 | µs/次 | 说明 |
|---|---|---|
| `all.chunks(4)` 全组分块 | 10.82 | 物化 40 个子列表 |
| 按需切 `rows[index]` | 4.07 | **-62.4%** |

`chunked == sliced`（320000 == 320000）字节一致，方向本身成立。

**判定：不改，收益低于门槛**。两个调用点都不在每帧路径上：`_buildRows` 的结果被 `_rows` 缓存，`_rows == null || _builtExtent != extent` 才重建，稳态滚动每帧不付；`_buildUnfoldingRows` 每 pump 付一次，但展开动画只有 240ms，单帧 10.8µs 占 8ms 帧预算的 0.13%，累计约 313µs。按账本 15% 判定门槛与 AGENTS.md 的帧预算口径，都不构成改动理由。

**同时暴露的覆盖缺口（记账，留待后续）**：`_buildUnfoldingRows` 这条路径**现有测试为零覆盖**——`test/views/proxies_list_test.dart` 两个用例的 `unfoldSet` 都直接含组名（`_controller.value = 1`），走的是稳态 `_buildRows`，没有一个用例驱动过展开动画中态。补用例时踩到的构造约束（后续复用）：该列表的 groups 来自 `proxiesListStateProvider.select(state.groups)`（由 `currentGroupsStateProvider` + `unfoldSetProvider` 派生），不是 `groupsProvider`；unfold 的写入口是 `proxiesActionProvider.notifier.updateCurrentUnfoldSet(...)`，`unfoldSetProvider` 本身是 `$FunctionalProvider`、没有 `notifier`。当时用例在「组未渲染出 ProxyCard」上失败，两条分支都不建行，说明还有未查明的状态条件（`_controller.isDismissed` 的中态判定），未继续深挖——因为被测路径本身已判定不改。

**清理说明**：按仓库规矩一次性基准不入库，`test/views/proxies_row_chunks_benchmark_test.dart` 与试写的用例均已删除，工作区回到干净 HEAD；上面这组数字是本轮唯一证据，留给后续重估。

### 2026-11-13 代理表答案路径分配归因轮次（实测，无代码改动）

上一轮留下的疑问是「`BenchmarkHandleGetProxies` 的 profile 里 71% CPU 是 GC、`maps.grow/rehash` 占 10ms」，但那次用 `-benchtime 3x`，只有 3 次迭代，profile 落在基准搭建而不是被测路径上，结论方向性不可靠。本轮用「小 benchtime 起步 + 逐步加大」重新归因，每一步都先量后判断。

**实测一：稳态命中路径已是 0 分配**（`workdir=core/`，`-benchtime 2000x -count=3`，groups=200/members=20/nodes=0 族）：

| 场景 | ns/op | B/op | allocs/op |
|---|---|---|---|
| groups=200 无节点（Selector） | 491.1 / 509.5 / 605.7 | 382 | 1 |
| groups=200 urltest | 697.7 / 888.2 / 731.0 | 561 | 2 |
| groups=200 fallback | 697.1 / 687.2 / 705.1 | 567 | 2 |
| groups=200 loadbalance | 577.3 / 476.1 / 527.5 | 377 | 1 |

把 benchtime 提到 `5000x` 后同一组变成 **0 allocs/op**（152–227 B/op 是基准搭建残留）：`BenchmarkHandleGetProxies/groups=200/members=20/nodes=0` 302.3ns、urltest 456.6ns、fallback 352.8ns、loadbalance 268ns。即那 1–2 allocs/op 完全来自 `b.ResetTimer` 之前的建表，稳态答案本身不分配——上一轮「71% CPU 是 GC」的归因是迭代次数不足造成的假象，**不改**。

**实测二：alloc profile 的 100% 归因**（`-alloc_objects` + `-list` 逐行）。`refreshGroupDoc` 的 81221 个分配对象全部落在 `slot.doc = appendGroupDocument(nil, slot.proxy)` 一行，但 `refreshGroupDocs` 的短路条件（`snapshot.validated && snapshot.answersSeen == AnswerGeneration()` 且 provider generation 未动）在同一 profile 里同样大量命中，说明这些分配仍属「建表后第一次全量校验」，不是每答案。

**结论**：`handleGetProxies` 这条最热 IPC 路径确实已到地板（稳态 0 alloc、约 200–500ns/答案），与账本既有结论一致；上一轮的 GC 占比数字作废，如实记录以防后续再被引用。这条路径后续若还要挖，唯一方向是 `document()` 里 `groupDocsMu` 这把全局锁（每答案都取），而不是分配。

### 2026-11-14 筛选标签 l10n 读取缓存轮次（已落地）

上一轮（2026-11-12 facet 单值化）把 DNS 的 cache facet 从「每行建 `resultFilters`」改成逐行单值读取后，那趟 offer pass 剩下的最大一笔就在这行里：`query.cached ? l10n.cache : ''`。生成代码的 `l10n.cache` 是 `Intl.message('Cache', name: 'cache', args: [])`，走 `Intl._lookupMessage` → 全局 `messageLookup.lookupMessage`（locale 解析 + 名字查表），每命中一行付一次。

改法：`cacheFacetLabel` 把字符串缓存在「实例身份」上。`AppLocalizations.load()` 每次装载 locale 都 new 一个新实例并写 `_current`，所以缓存按实例失效——切语言后标签跟着换，不会变陈。DNS 查询页每 300ms 一次 offer，500 行里约一半带 cache 标记，单次 pass 省 86µs。

| 优化 | 父仓库提交 | 配对实测（同进程 7 轮交替取中位） |
|---|---|---|
| cache facet 标签按实例缓存，不再每行过一次 `Intl.message` | `e70eab38` | 单次标签读取（200 万次/轮）**331.8ns → 3.36ns（-99%）**；DNS facet offer pass（500 行 ×4 offered facet，2000 次/轮）**322µs → 236µs（-26.7%）**，复跑 316µs → 233µs |

守护：`test/common/app_localizations_test.dart` 新增「follows a locale reload instead of going stale」——en 下读一次标签，重载 zh_CN 后断言它等于 `AppLocalizations.current.cache` 且与 en 取值不同（tearDown 还原 en），钉住「缓存不跨 locale 装载存活」。

验证：focused（`app_localizations_test`/`record_filter_test`/`common_test`）60 例全绿；整批 `test/models test/views test/features test/providers test/core test/common test/widgets` **3846 通过 / 51 跳过 / 5 失败**，5 例即账本既有的 Windows 平台失败（`mitm_trust_test` 4 例 + `window_test` 1 例），与本轮无关；`dart format --set-exit-if-changed` 0 changed；`dart analyze` 0 error / 0 warning（剩余 6 条 info 全在 `test/core/event_json_test.dart`，既有）。本机跑这批用例时把 `setup.build_assets`/`rust_api.build_assets` 临时置 false（CI 的 Dart job 同形状，绕开要 Go 的构建钩子），跑完已还原，提交里不含该改动。


### 2026-11-14 DNS 发起方标签缓存轮次（已落地）

上一轮把 cache facet 的标签从 `Intl.message` 读到缓存后，同页的 `initiator` 暴露为同一形状：DNS 查询页每一行有四条路径读它——facet 的 `optionsOf`、结果列的筛选 chip、一条搜索文本、两个排序列键——每次读都走一遍生成代码的 `appLocalizations.<x>`（`Intl.message` 的全局 `messageLookup` 查表）。

```dart
extension DnsQueryInitiatorL10n on DnsQueryInitiator {
  String get label => initiatorLabelOf(index);
}
```

五个标签在 `lib/common/app_localizations.dart` 里按 `AppLocalizations` 的实例身份持有列表：`AppLocalizations.load()` 每次都新建实例并替换 `_current`，所以切语言后缓存自然失效。放在这个文件而不是 `l10n_labels.dart` 是必要的——后者被 `common.dart` 作为 export 列出，而 `app_localizations.dart` 经 `constant.dart` 引进整个 barrel，放过去会形成导入环（实测报 ``Undefined class``）。

| 优化 | 父仓库提交 | 配对实测（同进程 7 轮交替取中位） |
|---|---|---|
| initiator 五标签按实例缓存，不再每行走一次 `Intl.message` | `8cb7b4e0` | 单次标签读取（4000 万次读/轮）**251.1ns → 17.8ns（-92.9%）**；500 行 ×4 处读取 ×2000 趟的一轮 **1004ms → 71ms** |

守护：`test/common/app_localizations_test.dart` 新增两个用例——「names every initiator the core writes」把五个索引逐个对拍 `DnsQueryInitiator.label`，防止索引与枚举顺序脱钩（这是按 ``index`` 取表的唯一风险）；「follows a locale reload instead of going stale」与上一轮 cache 那条同形状，en 下读一次、重载 zh_CN 后断言值已换且与 en 不同。

验证：``app_localizations_test`` 21 例全绿；整批 ``test/models test/views test/features test/core test/common test/widgets test/providers`` **3848 通过 / 51 跳过 / 5 失败**，5 例即账本登记的 Windows 平台失败（`mitm_trust_test` 4 例 + `window_test` 1 例）逐字相同；``dart format --set-exit-if-changed`` 0 changed；``dart analyze`` 0 error / 0 warning，剩余 6 条 info 全在 `test/core/event_json_test.dart`。本机跑批时同样把 `setup.build_assets` 与 `rust_api.build_assets` 临时置 false 再还原。

**踩坑**：① 第一次跑基准时忘了基准文件里的旧路径已经走在新的 getter 上，测出 5.2ns vs 5.1ns 的假相等；基准的 old 分支必须把生成代码的 switch 原文抄一份，否则两侧是同一个函数。② 上一条导致基准输出巨大（每次读都打印），PowerShell 宿主被 ``System.OutOfMemoryException`` 打挂——基准只打印一次汇总行。


### 2026-11-14 协议标签与 selected 列表两轮实测否决（无代码改动）

本轮复核两块被账本标记为「可再挖」的位置，都用同进程配对实测收口，两侧各 7 轮交替取中位。

| 位置 | 实测 | 结论 |
|---|---|---|
| `TrackerInfoItem._buildHeader` 的 `metadata.network.toUpperCase()` | 2000 行 ×500 次：32.5ns/读 vs `protocolLabel` 的 35.1ns/读，**旧路径反而快 8%** | 否决。核心只写 `tcp`/`udp`/`all`/`invalid` 四个全小写 ASCII，Dart 的 `toUpperCase` 对此有 VM 内快路径；`protocolLabel` 是一次虚拟调用 + switch。表格单元格路径已由 `9c64c9e9` 与 2026-11-12 修正轮次压到 850ns/行、主要由字符串格式化构成，无第二条可削的量 |
| `RecordFilterController.offer()` 的 `selected` 列表 | 账本 2026-11-12 已记：占 `offer` 全量 2.2% | 维持否决，未重测 |

记录价值：`toUpperCase()` 在这里不是分配问题，把「每行建新字符串」直接换成常量表不一定更快——是否值得改取决于字符串形状。后续若在别的枚举上看到同类写法，先量再动。

## 7. 已知维护事项

- 2026-11-11 `dart run tool/test.dart` 全量第 6 个失败：`test/core/desktop/process_probe_test.dart`「an exited child process is not alive」在满载机器上偶发（探针在子进程退出后仍报存活），单独重跑与安静环境均通过；该测试 kill 掉 `ping` 后立即探测，属时序敏感，与本会话 Dart 改动无交互。已知既有失败集仍是 5 个（4 个 Linux-only mitm + window 探针）。

- 2026-11-11 门禁修复（非性能）：epoch 微秒轮次（`b14ea82f`）把 Go 门禁弄红了两处——`core/dns_query.go`、`core/protocol.go`、`core/provider.go` 被 gofmt 点名（前两个文件尾丢换行，`int64` 字段撑开结构体对齐后未重新对齐）；且 `core/dns_query_test.go`、`core/message_test.go`、`core/message_bench_test.go`、`core/provider_test.go` 仍在给 int64 字段传 `time.Time`（`go vet .` 编译测试时才炸）。已由 `05f5e29e` 修复。教训：改字段类型必须同步所有 `_test.go`——wrapper 的 CI gofmt 只扫 `./*.go ./cmd ./mobile ./platform ./timezone ./tun`，但 `go vet .` 编译测试，类型漂移只在编译期暴露。
- 2026-11-11 环境备忘：本机 `flutter analyze` 必崩（analysis server 在 LSP initialize 消息上报 `FormatException: Unexpected end of input`——`java项目` 路径使 Content-Length 与实际字节数不符），CI（Linux）不复现；本机改用 `dart analyze`（全仓库 No issues found，结论一致）。另：`dart format` 探针文件若拷出仓库（无 pubspec 上游）会按最新语言版本套「高样式」产生假阳性，仓库内 1083 个文件实测 0 changed，勿被误导。

- 2026-11-07 门禁修复（非性能）：`test/lint/prism_list_test.dart`、`test/lint/typography_test.dart` 在 Windows 上误报——`p.relative` 返回反斜杠，而豁免名单与 `_editorSizes` 都按正斜杠写。已按仓库既有写法（`design_package_test.dart`、`platform_layering_test.dart` 等本来就是 `p.relative(...).replaceAll('\', '/')`）统一规范化；`test/lint/dead_file_test.dart` 的 `path.startsWith('lib/')` 在 Windows 上恒为 false、整个测试被跳过，也一并改为规范化后比较，Windows 上首次真正生效（实测无孤儿文件）。Linux 上这些替换均为 no-op，CI 行为不变。
- `miekg/dns` 的 `ClientExchangeUDP` 中 `Context.AfterFunc` 每次分配一个 stop 闭包；单独优化收益小，建议与 P1 一起重构。
- 首次全量验证中 `TestInboundVMess_Mekya` 曾出现偶发 `unexpected EOF / closed pipe`；隔离复跑和后续全量均通过，尚不是稳定失败。
- 任务缓存清理工具此前被执行器安全策略拦截，`D:\Codex\tmp` 下仍有 benchmark/profile 缓存目录；继续前可按任务名确认是否可清理。
- `sqlite3` v3.7.0 的 Windows 原生资产钩子会失败：GitHub release `sqlite3-3.7.0` 的 `sqlite3.x64.windows.dll` 已于 2026-09-30 重新上传（官方 API 摘要 `98b4be67...`），与包内 `asset_hashes.dart` 钉住的 `3a29878d...` 不一致。已在本地 pub 缓存（`D:\Codex\tools\pub-cache-task`）按 GitHub 官方摘要修正该哈希；上游发布新版本前这是环境级阻塞。跑 `dart run tool/test.dart` 还需 `PUB_CACHE=D:\Codex\tools\pub-cache-task`，并把 Flutter 与 Go 的 bin 放进 PATH（`setup` 包的构建钩子要调 `go`）。
- 本轮 `dart run tool/test.dart` 的 32 个 bundle 里有 2 个用例失败，单独重跑同一批文件全部通过（bundle 共享 isolate 的跨文件干扰）；工具的结论是退出码 0。Dart 侧本轮零改动。
- 2026-11-08 在本机复核 `dart run tool/test.dart`：5 个用例失败，且在提交 `3788368c`（本轮改动之前）上同样失败，属既有问题、与 Go 改动无关——`test/common/mitm_trust_test.dart` 的 4 个 `Linux ...` 用例没有 `@TestOn` 限定，在 Windows 上必然失败；`test/common/window_test.dart` 的「an unsupported probe is retried the next time blur is on」期望 4 次平台调用、Windows 实测 3 次。另有一次 `test/providers/clash_providers_action_test.dart`「a set changed while it downloads drops the download of the url it no longer has」在 bundle 里失败、单独重跑 32 个用例全过（既有的 bundle 共享 isolate 跨文件干扰）。其余全部通过。若要在本机跑绿，需给前者加平台注解、后者按平台分支期望
- 2026-11-09 在 wrapper 上跑 `go test . -race -count=1`：`TestRouteVersionsPollLeavesRuleSetsToTheirEvent` 报 DATA RACE 并失败，竞争发生在 `recordRoutes` 的测试清理写与 `routeRefreshWorker` 到 `applyRouteSnapshot` 的写之间（`core/route_test.go` 与 `core/route.go`）。已在基线代码上复现同样竞争与失败，属既有问题，与 2026-11-09 答案传输层重构无关；要修它得给路由刷新 worker 与测试清理约定同一把锁，留作后续独立议题。
