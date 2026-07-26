# OrzMusic 全链路性能优化计划

> 状态：待实施
>
> 最后更新：2026-07-26
>
> 适用范围：OrzMusic Vapor 服务、PostgreSQL 查询、静态资源交付、浏览器首屏和三种音频播放策略

本文是 OrzMusic 性能改进的单一执行清单。任务围绕已完成的静态代码审计拆分；审计结论不等同于线上测量结果，因此先建立基线，再逐项优化并用相同口径复测。

## 1. 目标

- 消除首次打开曲目列表时同步探测音频时长造成的请求阻塞。
- 降低首屏静态资源、第三方依赖和数据库全量查询带来的等待。
- 分别降低 `directFile`、`wasmDecode`、`serverDecode` 的点击到首帧时间。
- 防止首次服务端解码的重复并发、无界并发和 WAV 缓存持续膨胀。
- 建立可复现的冷缓存、热缓存性能基线，避免只凭主观感受优化。
- 保持当前单机 Docker Compose 架构，不为性能优化引入微服务、队列集群或 Kubernetes。

## 2. 当前已知瓶颈

以下问题可从当前代码直接确认：

- `/api/songs` 和搜索接口在返回前同步补算缺失时长，并逐条更新数据库。
- `/api/songs/formats` 把全部格式值读入应用内存后聚合。
- `/api/playlists` 把全部 playlist-song pivot 读入应用内存后计数。
- 搜索完成后逐首加载 artist 和 album，存在 N+1 查询。
- 歌曲表只有 `sha256` 唯一约束，缺少列表过滤和排序的组合索引。
- `serverDecode` 首次请求要等整首 WAV 生成后才能发送媒体响应。
- 同一首未缓存歌曲的并发请求没有 single-flight 合并。
- WASM 路径在启动 Worker 前先把完整源文件读成 `ArrayBuffer`。
- Alpine 通过外部 CDN 加载，是页面初始化的跨域硬依赖。
- 项目未定义静态资源长期缓存、压缩和 WAV 缓存容量治理策略。
- 前端已有 `firstFrameMs`、`decodeRate`、`underruns` 等数据，但没有统一采集出口。

以下内容必须通过部署环境验证，不能在实施前视为已证实：

- Traefik 当前是否已经启用 Brotli/gzip、HTTP/2 和条件缓存。
- 生产曲库规模、缺失时长数量、PostgreSQL 查询计划和磁盘性能。
- 三种播放策略各自的真实首帧分布及最慢格式。
- 2.9 MB 完整 WASM 在目标网络和设备上的下载、编译成本。
- 单机可安全承受的并发解码数和 WAV 缓存容量。

## 3. 性能预算与测量口径

首轮任务只建立基线，不用未经实测的数字阻断发布。完成基线后，在 `PERF-002` 中记录目标值。至少区分：

| 场景 | 必测指标 |
|:-----|:---------|
| 首屏冷缓存 | TTFB、FCP、LCP、首屏传输字节、静态资源请求数、三个初始化 API 耗时 |
| 首屏热缓存 | TTFB、FCP、LCP、304/内存缓存命中、API 耗时 |
| `directFile` | 点击到 `playing`、媒体 TTFB、Range 响应、首帧时间 |
| `wasmDecode` | 源文件下载、WASM 下载/编译、Worker ready、`firstFrameMs`、underruns |
| `serverDecode` 冷缓存 | 排队、解码、缓存提交、媒体首字节、CPU、输出大小 |
| `serverDecode` 热缓存 | cache hit、缓存校验、媒体首字节、Range 响应 |

统一规则：

- 冷、热缓存各运行至少三次，记录中位数，并保留原始结果。
- 记录部署版本、commit、设备、浏览器、网络、曲库数量和样本歌曲。
- 每项优化只与同一环境、同一数据、同一歌曲的基线比较。
- 首轮以本地/内网诊断为主，不引入外部监控 SaaS。

## 4. 任务总览

| ID | 状态 | 优先级 | 任务 | 依赖 |
|:---|:-----|:-------|:-----|:-----|
| PERF-001 | 待实施 | P0 | 建立可重复性能采集脚本和样本清单 | 无 |
| PERF-002 | 待实施 | P0 | 记录部署基线并确定阶段目标 | PERF-001 |
| PERF-003 | 待实施 | P0 | 从列表和搜索请求移除时长补算 | PERF-001 |
| PERF-004 | 待实施 | P0 | 提供独立的历史时长补算命令 | PERF-003 |
| PERF-005 | 待实施 | P1 | 用 PostgreSQL 聚合格式统计 | PERF-001 |
| PERF-006 | 待实施 | P1 | 用数据库聚合播放列表曲目数 | PERF-001 |
| PERF-007 | 待实施 | P1 | 消除搜索关系 N+1 查询 | PERF-001 |
| PERF-008 | 待实施 | P1 | 增加歌曲列表组合索引迁移 | PERF-002 |
| PERF-009 | 待实施 | P1 | 优化搜索 SQL 与 trigram 索引 | PERF-002、PERF-007 |
| PERF-010 | 待实施 | P1 | SQL 化当前曲目位置查询 | PERF-008 |
| PERF-011 | 待实施 | P1 | 固定并同源托管 Alpine | PERF-001 |
| PERF-012 | 待实施 | P1 | 配置静态资源压缩与缓存策略 | PERF-002、PERF-011 |
| PERF-013 | 待实施 | P1 | 延迟加载非首屏播放列表数据 | PERF-006 |
| PERF-014 | 待实施 | P0 | 为服务端解码增加 single-flight | PERF-001 |
| PERF-015 | 待实施 | P0 | 增加全局解码并发限制与诊断 | PERF-014 |
| PERF-016 | 待实施 | P1 | 增加服务端解码缓存预热入口 | PERF-015 |
| PERF-017 | 待实施 | P1 | 建立 WAV 缓存容量与清理机制 | PERF-015 |
| PERF-018 | 待实施 | P1 | 上报浏览器播放首帧诊断数据 | PERF-001 |
| PERF-019 | 待实施 | P1 | 复用并按交互预热 WASM Worker | PERF-018 |
| PERF-020 | 待实施 | P2 | 评估 WASM 增量输入可行性 | PERF-019 |
| PERF-021 | 待实施 | P2 | 评估服务端边解码边响应 | PERF-015、PERF-018 |
| PERF-022 | 待实施 | P1 | 生产日志和连接池基线调优 | PERF-002 |
| PERF-023 | 待实施 | P0 | 完整复测、回归与文档收口 | PERF-003～PERF-022 中已领取项 |

## 5. 细粒度任务

### PERF-001：建立可重复性能采集脚本和样本清单

**目标**：不改业务行为，提供首屏、API 和三种播放策略的统一采集入口。

**允许改动**：

- 新增 `script/performance-smoke.sh`。
- 新增 `Docs/performance.md`，只记录稳定的测量方法。
- 可新增轻量测试夹具或脚本测试。

**实现要求**：

- 采集首页、`/api/songs`、`/api/songs/formats`、`/api/playlists` 的状态码、TTFB 和总耗时。
- 支持用环境变量指定服务 URL、歌曲 ID、重复次数和输出目录。
- 不在脚本中硬编码账号、生产域名或音乐文件。
- 输出机器可读结果和简短 Markdown 汇总。
- 样本至少覆盖 `directFile`、完整 WASM、builtin WASM、`serverDecode`。

**非目标**：不设置发布阻断阈值，不安装监控平台，不修改应用代码。

**验收**：

- 同一环境连续运行三次可生成可比较结果。
- 缺少歌曲 ID 时仍能完成首屏/API 测量并明确跳过播放项。
- 脚本错误时返回非零退出码。

**最小验证**：

```bash
bash -n script/performance-smoke.sh
```

### PERF-002：记录部署基线并确定阶段目标

**目标**：在真实部署环境记录冷、热缓存基线，并为后续任务确定合理预算。

**允许改动**：`Docs/backlog/performance-optimization-plan.md` 的基线记录区；性能结果产物不要提交大型二进制。

**实现要求**：

- 记录版本、设备、浏览器、网络、曲库规模、缺失时长数量。
- 冷、热缓存各三次并使用中位数。
- 对三种播放策略选择固定样本。
- 根据结果为首屏 LCP、`/api/songs`、点击到首帧、冷/热 server decode 设置阶段目标。

**非目标**：不在采集任务中顺手修改代码或生产配置。

**验收**：基线数据足以让后续任务判断“改善、无变化或回退”。

### PERF-003：从列表和搜索请求移除时长补算

**目标**：`GET /api/songs` 和搜索响应不再等待解码器、`ffprobe` 或数据库修复。

**允许改动**：

- `Sources/App/Controllers/SongController.swift`
- `Tests/AppTests/AppTests.swift`

**实现要求**：

- 删除列表和搜索请求路径中的同步 `backfillDurations` 调用。
- 缺少 duration 的歌曲正常返回 `null`。
- 不改变分页、排序、格式过滤或响应结构。
- 增加测试证明列表请求不会启动外部时长探测。

**非目标**：不在本任务实现后台任务、扫描器重构或迁移。

**验收**：

- 旧数据存在空 duration 时列表仍立即返回。
- 现有歌曲、搜索和播放 API 测试通过。
- 与 PERF-002 相同环境下 `/api/songs` 耗时显著下降或确认原环境没有缺失时长。

**最小验证**：

```bash
swift test --filter AppTests
```

### PERF-004：提供独立的历史时长补算命令

**目标**：把历史 duration 修复变成显式、可限速、可重跑的维护操作。

**允许改动**：

- `Package.swift`
- 新增一个独立 Swift executable target
- 必要的 `Sources/` 服务复用
- `Docs/performance.md`

**实现要求**：

- 只处理 `duration IS NULL` 且 CAS 文件存在的歌曲。
- 支持批次大小、并发数和 dry-run。
- 保留外部进程超时保护。
- 成功结果批量或有界写回；失败项记录 ID、格式和原因。
- 重跑只处理仍缺失的记录。

**非目标**：不自动在 Web 服务启动时运行，不引入任务队列。

**验收**：dry-run 不写库；中断后可重跑；不存在的 CAS 文件不会阻塞整批。

### PERF-005：用 PostgreSQL 聚合格式统计

**目标**：`/api/songs/formats` 不再把全部歌曲格式读入 Swift 内存。

**允许改动**：

- `Sources/App/Controllers/SongController.swift`
- 对应 API 测试

**实现要求**：使用数据库 `GROUP BY` 和 `COUNT` 返回 total 与分格式数量；保持现有 JSON 和小写格式语义。

**非目标**：首版不增加进程内缓存，不改变侧边栏协议。

**验收**：空库、多格式、大小写历史值的结果与当前接口兼容，并记录真实库查询耗时。

### PERF-006：用数据库聚合播放列表曲目数

**目标**：`GET /api/playlists` 不再加载全部 pivot 模型。

**允许改动**：

- `Sources/App/Controllers/PlaylistController.swift`
- 对应 API 测试

**实现要求**：通过聚合查询得到每个 playlist 的 song count；空播放列表必须返回 0。

**非目标**：不改变播放列表 DTO、权限或用户隔离。

**验收**：播放列表数量和 pivot 数量扩大时，返回模型数量不再与全部 pivot 数量绑定。

### PERF-007：消除搜索关系 N+1 查询

**目标**：搜索结果的 artist 和 album 使用有界 eager loading。

**允许改动**：

- `Sources/App/Controllers/SongController.swift`
- 搜索 API 测试

**实现要求**：保持当前最多 50 条和响应结构；不得为每首歌曲顺序执行 artist/album load。

**非目标**：不在本任务修改搜索匹配语义或增加数据库扩展。

**验收**：有/无 artist、album 的结果兼容；测试或诊断证明查询数量不随结果数线性增加。

### PERF-008：增加歌曲列表组合索引迁移

**目标**：为默认排序和格式过滤分页提供匹配索引。

**允许改动**：

- 新增 Fluent migration
- `Sources/App/configure.swift`
- migration/API 测试

**候选索引**：

```sql
(created_at DESC, id DESC)
(file_format, created_at DESC, id DESC)
```

**实现要求**：

- 先保存真实数据上的 `EXPLAIN (ANALYZE, BUFFERS)`。
- 确认 PostgreSQL 实际使用候选索引后再固化。
- migration 可回滚，索引名稳定。

**非目标**：不修改分页协议，不一次增加所有猜测索引。

**验收**：默认列表和格式过滤查询计划改善；写入成本和索引大小有记录。

### PERF-009：优化搜索 SQL 与 trigram 索引

**目标**：改善 `title` 和 artist name 的包含搜索，同时移除字符串拼接 SQL。

**允许改动**：

- 新增 migration
- `SongController.swift`
- 搜索测试和部署说明

**实现要求**：

- 使用参数绑定。
- 评估并按需启用 PostgreSQL `pg_trgm`。
- 为 `lower(title)` 和 `lower(artists.name)` 建立实际可用的 GIN 索引。
- 保持包含匹配和大小写不敏感语义。

**非目标**：不引入 Elasticsearch，不改变为前缀搜索，不增加模糊排序产品逻辑。

**验收**：恶意引号输入安全；真实曲库查询计划使用索引；结果与现有语义一致。

### PERF-010：SQL 化当前曲目位置查询

**目标**：定位歌曲时不把全部歌曲 ID 拉入应用内存。

**允许改动**：

- `SongController.swift`
- 位置接口测试

**实现要求**：使用与 `(created_at DESC, id DESC)` 完全一致的 SQL 计数位置；相同 created_at 时以 id 稳定排序。

**非目标**：不改变位置接口 DTO、页面编号或前端定位流程。

**验收**：第一页、边界、末页、相同时间戳结果与原实现一致；应用内存不随曲库总量线性增长。

### PERF-011：固定并同源托管 Alpine

**目标**：移除首屏对 jsDelivr 可用性和额外 TLS 往返的依赖。

**允许改动**：

- `Resources/Public/vendor/` 下固定版本的 Alpine 生产产物
- `Resources/Views/player.leaf`
- 浏览器 smoke 测试
- 第三方许可证说明

**实现要求**：

- 固定具体版本和校验来源。
- 使用同源 URL。
- 保持 `defer`、`x-cloak` 和当前初始化行为。

**非目标**：不引入 npm 构建链，不重写 Alpine 页面，不升级其他前端代码。

**验收**：断开外网后首屏仍能初始化；许可证和版本可追溯；现有浏览器测试通过。

### PERF-012：配置静态资源压缩与缓存策略

**目标**：让带版本的静态资源长期缓存，并压缩文本资源。

**允许改动**：

- 生产 Compose/Traefik 配置或部署文档
- 必要的响应头 middleware
- release smoke 脚本

**实现要求**：

- HTML 和 API 使用短缓存或 `no-cache`。
- 内容版本化的 JS/CSS/SVG/WASM 使用长期 immutable。
- JS/CSS/SVG/JSON 启用 Brotli 或 gzip。
- 大型音频不做动态 gzip。
- `.wasm` 返回 `application/wasm`。
- 保留 Range、ETag/Last-Modified 和跨源隔离响应头。

**非目标**：不引入 CDN，不把 CAS 音频复制到 Public。

**验收**：用 `curl -I` 和压缩请求验证响应头；冷/热首屏体积与耗时有复测；HTTPS 和 WASM 播放不回退。

### PERF-013：延迟加载非首屏播放列表数据

**目标**：首次页面初始化不等待用户尚未打开的播放列表数据。

**允许改动**：

- `Resources/Public/audio/app.js`
- 前端测试

**实现要求**：首次打开 queue/playlist 面板时加载一次；保存、删除后仍正确刷新；并发打开只产生一个请求。

**非目标**：不改变队列内存语义、服务端播放列表协议或 UI 布局。

**验收**：首屏不请求 `/api/playlists`；首次打开加载；失败可重试且有现有 toast。

### PERF-014：为服务端解码增加 single-flight

**目标**：同一 cache key 的并发冷请求只执行一次完整解码。

**允许改动**：

- 新增应用级 decode cache coordinator
- `Application` 扩展
- `SongController.swift`
- 并发测试

**实现要求**：

- cache key 包含 sha256、SDK fingerprint、格式、采样语义和 subsong。
- 同 key 请求共享一个 `Task`。
- 完成或失败后移除 in-flight 记录。
- 不同 key 可以并行。
- 保持临时文件原子提交。

**非目标**：不实现跨进程分布式锁，不改变解码格式。

**验收**：20 个同 key 并发请求只触发一次 decoder；失败后后续请求可以重试；不同 key 不互相错误复用。

### PERF-015：增加全局解码并发限制与诊断

**目标**：防止多首冷缓存歌曲同时耗尽 CPU、内存和磁盘。

**允许改动**：

- decode coordinator
- 环境变量配置
- 健康/诊断响应或结构化日志
- 并发测试和部署文档

**实现要求**：

- 并发上限可配置，默认值适合单机低并发。
- 记录排队时间、解码时间、cache hit、格式、输出大小和失败原因。
- 等待请求取消时不泄漏 permit。
- 不在日志中输出完整本机源路径。

**非目标**：不引入 Redis、消息队列或单独转码服务。

**验收**：压力测试中活跃解码数不超过上限；热缓存不占用解码 permit。

### PERF-016：增加服务端解码缓存预热入口

**目标**：允许运维在发布后或低峰期预生成常用 serverDecode 缓存。

**允许改动**：

- 独立 CLI 或受保护的运维命令
- decode coordinator 复用
- 部署文档和测试

**实现要求**：

- 支持单曲、格式、最近导入或明确 ID 列表。
- 支持 dry-run、并发上限和失败汇总。
- 已有有效缓存直接跳过。

**非目标**：不在 Web 服务启动时全库预热，不默认扫描全部音乐。

**验收**：重复执行幂等；预热后首次 Web 请求成为 cache hit；不会影响 direct/WASM 曲目。

### PERF-017：建立 WAV 缓存容量与清理机制

**目标**：防止 `.cache/wav` 无界增长耗尽 CAS 磁盘。

**允许改动**：

- 缓存元数据/清理 CLI
- 部署文档
- 测试

**实现要求**：

- 可报告文件数、总字节和不同 SDK fingerprint 占用。
- 支持 dry-run、最大容量和旧 fingerprint 清理。
- 默认不清理正在生成或正在流式读取的文件。
- 删除范围必须限定在 `CAS_ROOT/.cache/wav`。

**非目标**：不删除原始 CAS 文件，不自动执行高风险全盘清理。

**验收**：测试目录中按策略选择正确文件；dry-run 零删除；路径逃逸被拒绝。

### PERF-018：上报浏览器播放首帧诊断数据

**目标**：把已有客户端诊断变成可比较的结构化数据。

**允许改动**：

- `Resources/Public/audio/player.js`
- `Resources/Public/audio/app.js`
- 可选只在开发/诊断模式启用的后端 endpoint
- 浏览器测试和 `Docs/performance.md`

**实现要求**：

- 记录策略、格式、资源 fetch、WASM ready、Worker ready、first frame、underruns。
- directFile/serverDecode 也记录点击到 `playing`。
- 默认不上传歌曲标题、路径或用户标识。
- 诊断关闭时不产生持续网络请求。

**非目标**：不接入第三方分析平台，不把性能数据用于用户追踪。

**验收**：三种策略字段口径一致；切歌取消不会把旧请求数据归到新歌曲。

### PERF-019：复用并按交互预热 WASM Worker

**目标**：减少 WASM 曲目首次播放的 Worker 创建、模块下载和编译等待。

**允许改动**：

- `Resources/Public/audio/player.js`
- `orz-decoder-worker.js`
- 浏览器 WASM 测试

**实现要求**：

- 仅在空闲、hover/选择或首次用户交互后预热；不能无条件阻塞首屏。
- 区分 builtin 约 39 KB WASM 与完整约 2.9 MB WASM。
- Worker 可安全复用；切歌 generation、取消、seek 和 decoder destroy 语义保持正确。
- 失败后能重新创建 Worker。

**非目标**：不在本任务改 SDK ABI 或实现流式输入。

**验收**：第二首同 profile 曲目不重复加载模块；快速切歌不串音；首屏未操作时不下载完整 WASM。

### PERF-020：评估 WASM 增量输入可行性

**目标**：确认能否避免播放前完整 `arrayBuffer()`，只形成设计结论和后续边界。

**允许改动**：调研文档、最小实验分支或独立原型；默认不合入生产播放路径。

**必须回答**：

- ABI v1 是否支持增量输入或需要新增 ABI。
- 哪些 decoder 必须随机访问完整文件。
- Range 分片是否实际改善目标格式首帧。
- 内存、seek、subsong 和取消语义如何保持。

**停止条件**：若需要修改 OrzAudioCore 公共 ABI，停止 OrzMusic 实现并转为 SDK backlog。

### PERF-021：评估服务端边解码边响应

**目标**：比较“整曲 WAV 缓存”“流式 WAV”“流式压缩格式”和“预热缓存”的成本。

**允许改动**：设计/基准文档和隔离原型；不直接替换生产 endpoint。

**评估项**：

- WAV header 长度、chunked transfer、Range 和 seek 兼容性。
- 客户端中断时 decoder 取消。
- 同时写缓存与向客户端发送的错误恢复。
- ARM64 单机 CPU、输出带宽和存储成本。

**决策原则**：个人/家庭低并发场景优先选择可运维的预热缓存；只有实测证明整曲等待仍不可接受时才实现流式转码。

### PERF-022：生产日志和连接池基线调优

**目标**：减少无必要日志 I/O，并按单机能力验证数据库连接池。

**允许改动**：

- Compose 环境默认值
- Vapor/PostgreSQL 配置
- 部署文档和 smoke

**实现要求**：

- 生产默认 `LOG_LEVEL=info`。
- 记录当前连接池默认行为、连接等待和 PostgreSQL上限。
- 只有实测存在等待或过量连接时才修改 pool 参数。

**非目标**：不盲目增大连接池，不修改 PostgreSQL 持久化架构。

**验收**：健康检查、迁移、扫描和媒体播放正常；日志量与连接数有前后对比。

### PERF-023：完整复测、回归与文档收口

**目标**：用 PERF-001 的同一口径验证已实施任务，并把稳定结论移入正式文档。

**允许改动**：

- 本文状态和验收记录
- `Docs/performance.md`
- 必要的 README/部署交叉链接

**实现要求**：

- 冷、热缓存各三次，使用同设备、同数据、同歌曲。
- 分开报告首屏、API、direct、WASM、server cold、server warm。
- 报告未改善或回退项，不只记录成功项。
- 运行现有 Swift、Browser、release smoke 和 fingerprint audit 中与改动相关的集合。

**验收命令候选**：

```bash
swift test
node --test Tests/Browser/*.test.mjs
make audit-fingerprints
git diff --check
```

## 6. 推荐推进批次

### 批次 A：建立证据并解除首屏阻塞

1. PERF-001
2. PERF-002
3. PERF-003
4. PERF-005
5. PERF-006
6. PERF-007

完成条件：列表请求不再执行音频探测；三个初始化 API 都有基线和优化后结果。

### 批次 B：数据库与静态交付

1. PERF-008
2. PERF-009
3. PERF-010
4. PERF-011
5. PERF-012
6. PERF-013
7. PERF-022

完成条件：真实查询计划使用必要索引；页面离线于第三方 CDN；缓存和压缩响应头可验证。

### 批次 C：服务端播放首帧与缓存安全

1. PERF-014
2. PERF-015
3. PERF-016
4. PERF-017
5. PERF-018

完成条件：同 key 只解码一次、总并发有上限、缓存可统计可清理、冷/热首帧可测。

### 批次 D：WASM 与高级流式评估

1. PERF-019
2. PERF-020
3. PERF-021

完成条件：Worker 复用经快速切歌回归；是否扩展 ABI 或实现服务端流式转码有明确证据和决策。

## 7. 全局非目标

- 不以迁移到 Hummingbird、Axum 或其他框架代替具体瓶颈修复。
- 不引入微服务、Redis、Kafka、Kubernetes、分布式转码集群。
- 不改变 OrzAudioCore ABI，除非独立评估任务确认并转入 SDK 仓库。
- 不以通过单元测试宣称生产性能达标；必须有部署环境复测。
- 不在一个任务中顺手完成相邻任务。

## 8. 单任务交接模板

```text
请领取 Docs/backlog/performance-optimization-plan.md 中的任务 PERF-xxx。

先阅读 AGENTS.md、Docs/backlog/performance-optimization-plan.md，以及任务列出的允许改动文件。
只实现该任务，保留工作区中所有无关改动；不要合并相邻 PERF 任务。

开始前记录与本任务直接相关的基线。实现后运行任务中的最小验证，并更新：
1. 任务状态；
2. 实际改动文件；
3. 验收命令和结果；
4. 优化前后数据；
5. 未验证项或风险。

若实现需要越过“非目标”、修改 OrzAudioCore ABI、改变 API 协议或新增基础设施，停止并报告，不自行扩大范围。
```

## 9. 验收记录

尚未开始。每完成一个任务，在对应任务下追加日期、commit、命令结果、优化前后中位数和剩余风险；不要用“测试通过”代替性能数据。
