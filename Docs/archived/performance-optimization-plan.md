# OrzMusic 全链路性能优化计划

> 状态：已完成（HTTPS/远端 ARM64 部署复验为外部上线检查）
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

模型档位：

- **Auto-Low**：`codex-auto-review` low。纯文档、机械脚本、范围明确且有强验收的低风险任务。
- **Terra-Medium**：`gpt-5.6-terra` medium。常规后端/前端实现、SQL 聚合和测试补充。
- **Sol-High**：`gpt-5.6-sol` high。并发正确性、音频生命周期、迁移查询计划和流式协议等高风险任务。

模型建议是默认起点，不是完成质量的替代品。出现以下情况必须升级一档并停止当前模型继续猜测：测试无法稳定复现、需要改变 API/ABI、涉及取消与并发竞态、真实查询计划与预期不符、浏览器音频生命周期与 mock 不一致。

| ID | 状态 | 优先级 | 任务 | 依赖 | 建议模型 |
|:---|:-----|:-------|:-----|:-----|:---------|
| PERF-001 | 完成 | P0 | 建立可重复性能采集脚本和样本清单 | 无 | Auto-Low |
| PERF-002 | 完成（HTTP） | P0 | 记录部署基线并确定阶段目标 | PERF-001 | Auto-Low |
| PERF-003 | 完成 | P0 | 从列表和搜索请求移除时长补算 | PERF-001 | Terra-Medium |
| PERF-004 | 完成 | P0 | 提供独立的历史时长补算命令 | PERF-003 | Terra-Medium |
| PERF-005 | 完成 | P1 | 用 PostgreSQL 聚合格式统计 | PERF-001 | Terra-Medium |
| PERF-006 | 完成 | P1 | 用数据库聚合播放列表曲目数 | PERF-001 | Terra-Medium |
| PERF-007 | 完成 | P1 | 消除搜索关系 N+1 查询 | PERF-001 | Auto-Low |
| PERF-008 | 完成 | P1 | 增加歌曲列表组合索引迁移 | PERF-002 | Sol-High |
| PERF-009 | 完成 | P1 | 优化搜索 SQL 与 trigram 索引 | PERF-002、PERF-007 | Sol-High |
| PERF-010 | 完成 | P1 | SQL 化当前曲目位置查询 | PERF-008 | Terra-Medium |
| PERF-011 | 完成 | P1 | 固定并同源托管 Alpine | PERF-001 | Auto-Low |
| PERF-012 | 完成（HTTP） | P1 | 配置静态资源压缩与缓存策略 | PERF-002、PERF-011 | Terra-Medium |
| PERF-013 | 完成 | P1 | 延迟加载非首屏播放列表数据 | PERF-006 | Auto-Low |
| PERF-014 | 完成 | P0 | 为服务端解码增加 single-flight | PERF-001 | Sol-High |
| PERF-015 | 完成 | P0 | 增加全局解码并发限制与诊断 | PERF-014 | Sol-High |
| PERF-016 | 完成 | P1 | 增加服务端解码缓存预热入口 | PERF-015 | Terra-Medium |
| PERF-017 | 完成 | P1 | 建立 WAV 缓存容量与清理机制 | PERF-015 | Sol-High |
| PERF-018 | 完成 | P1 | 上报浏览器播放首帧诊断数据 | PERF-001 | Terra-Medium |
| PERF-019 | 完成 | P1 | 复用并按交互预热 WASM Worker | PERF-018 | Sol-High |
| PERF-020 | 完成（停止实现） | P2 | 评估 WASM 增量输入可行性 | PERF-019 | Sol-High |
| PERF-021 | 完成（不实施） | P2 | 评估服务端边解码边响应 | PERF-015、PERF-018 | Sol-High |
| PERF-022 | 完成 | P1 | 生产日志和连接池基线调优 | PERF-002 | Terra-Medium |
| PERF-023 | 完成 | P0 | 完整复测、回归与文档收口 | PERF-003～PERF-022 中已领取项 | Terra-Medium |

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
bash Tests/AppTests/performance-smoke-test.sh
```

**完成记录（2026-07-26）**：

- 新增 `script/performance-smoke.sh`，输出逐请求 JSONL、聚合 JSON 和 Markdown 中位数报告。
- 新增 `Docs/performance.md`，固定采集变量、样本选择和冷/热缓存执行口径。
- 新增 mock 聚焦测试，覆盖纯 API、带四类媒体样本、服务不可达三条路径。
- 本任务只提供采集能力；真实数据基线已随后记录在 PERF-002。

### PERF-002：记录部署基线并确定阶段目标

**目标**：在真实部署环境记录冷、热缓存基线，并为后续任务确定合理预算。

**允许改动**：本计划归档前的基线记录区；性能结果产物不要提交大型二进制。

**实现要求**：

- 记录版本、设备、浏览器、网络、曲库规模、缺失时长数量。
- 冷、热缓存各三次并使用中位数。
- 对三种播放策略选择固定样本。
- 根据结果为首屏 LCP、`/api/songs`、点击到首帧、冷/热 server decode 设置阶段目标。

**非目标**：不在采集任务中顺手修改代码或生产配置。

**验收**：基线数据足以让后续任务判断“改善、无变化或回退”。

**完成记录（2026-07-26）**：

- 环境：`make run` 启动的 macOS 本机 Swift debug 服务，版本 `0.0.2`、commit `unknown`，PostgreSQL 与 CAS 健康。
- 数据：真实曲库 5,533 首；固定样本为 MP3/direct、XM/full WASM、YM/builtin WASM、SC68/server。
- 三次 warm API 中位数：home 32.140ms、songs 420.362ms、formats 7,325.537ms、playlists 199.195ms。
- 三次 warm 媒体首字节中位数：MP3 149.643ms、XM 57.013ms、YM 189.910ms、SC68 129.676ms。
- SC68 冷缓存前两次请求在 30 秒内零字节并超时；缓存生成完成后第三次 TTFB 为 37.731ms。这验证了当前整曲解码后才响应的结构性等待。
- 原始结果位于本机 `/tmp/orzmusic-perf-002-api`、`/tmp/orzmusic-perf-002-warm` 和 `/tmp/orzmusic-perf-002-baseline-4`，不提交临时产物。
- 首阶段目标只用于趋势判断：warm home ≤50ms、songs ≤300ms、formats ≤500ms、playlists ≤100ms、媒体 HTTP 首字节 ≤100ms；server cold 应通过预热命中或后续流式方案降至 5 秒内可听。
- 本任务完成 HTTP 基线。浏览器 FCP/LCP、WASM 编译、Worker ready 和真实点击到首帧不由 curl 推断，留给 PERF-018。
- 未删除浏览器缓存、CAS、Docker volume 或已有 WAV；冷 SC68 测量使用请求前的自然缓存状态。

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

**完成记录（2026-07-26）**：

- 删除 `/api/songs` 和 `/api/songs/search` 对请求内 `backfillDurations` 的调用，并移除该私有补算实现。
- 新增真实 PCM WAV CAS 样本回归测试，确认列表和搜索返回 `duration: null`，数据库也保持未修改。
- 聚焦测试通过：`swift test --filter testSongListAndSearchDoNotBackfillMissingDuration`，1 test、0 failures。
- 未实现独立历史补算命令；该工作仍由 PERF-004 承担。

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

**完成记录（2026-07-26）**：

- 新增独立 `OrzDurationBackfill` executable 和 `make backfill-durations` 入口，支持 `BATCH_SIZE`、`CONCURRENCY`、`LIMIT` 与 `DRY_RUN=1`。
- 抽取 `AudioDurationProbe` 供扫描器和回填命令复用：优先走 OrzAudioCore C ABI，失败时使用带 5 秒超时的 `ffprobe`。
- 回填仅查询 `duration IS NULL`，采用有界批次与并发；成功项逐条有界写回，CAS 缺失和探测失败输出歌曲 ID、格式与原因。
- SQLite/CAS 聚焦测试覆盖 dry-run 不写库、有效 WAV 回填、缺失文件不中断以及成功项重跑自动排除。
- 验证通过：`swift build --product OrzDurationBackfill`；`swift test --filter testDurationBackfillIsDryRunSafeAndToleratesMissingCASFiles`，1 test、0 failures。

### PERF-005：用 PostgreSQL 聚合格式统计

**目标**：`/api/songs/formats` 不再把全部歌曲格式读入 Swift 内存。

**允许改动**：

- `Sources/App/Controllers/SongController.swift`
- 对应 API 测试

**实现要求**：使用数据库 `GROUP BY` 和 `COUNT` 返回 total 与分格式数量；保持现有 JSON 和小写格式语义。

**非目标**：首版不增加进程内缓存，不改变侧边栏协议。

**验收**：空库、多格式、大小写历史值的结果与当前接口兼容，并记录真实库查询耗时。

**完成记录（2026-07-26）**：

- `/api/songs/formats` 改为单条 SQL：`LOWER(file_format)`、`GROUP BY`、`COUNT(*)`，不再将全部歌曲格式加载到 Swift 内存。
- 保持原有 JSON、按格式排序和小写合并语义；SQLite 测试覆盖空库、多格式及 `ym`/`YM` 历史值合并。
- 聚焦测试通过：`swift test --filter testSongFormatSummaryAndEmptyLibrary`，1 test、0 failures。
- 真实 PostgreSQL 曲库共 5,533 首、25 种格式：改造后 5 次请求首次 64.264 ms，热请求中位数 14.565 ms；原热基线为 7,325.537 ms，下降约 99.8%。响应 `total` 与分组求和均为 5,533。

### PERF-006：用数据库聚合播放列表曲目数

**目标**：`GET /api/playlists` 不再加载全部 pivot 模型。

**允许改动**：

- `Sources/App/Controllers/PlaylistController.swift`
- 对应 API 测试

**实现要求**：通过聚合查询得到每个 playlist 的 song count；空播放列表必须返回 0。

**非目标**：不改变播放列表 DTO、权限或用户隔离。

**验收**：播放列表数量和 pivot 数量扩大时，返回模型数量不再与全部 pivot 数量绑定。

**完成记录（2026-07-26）**：

- `GET /api/playlists` 保留播放列表模型查询，但将全量 pivot 加载改为 `GROUP BY playlist_id` 与 `COUNT(*)` 聚合；返回数据规模只与播放列表数量相关。
- 回归测试同时覆盖包含 2 首歌曲的播放列表与空播放列表，分别返回 `songCount = 2` 和 `0`。
- 聚焦测试通过：`swift test --filter testPlaylistIndexReportsSongCountForAtomicSave`，1 test、0 failures。
- 真实 PostgreSQL 当前无播放列表：改造后 5 次请求首次 40.523 ms，热请求中位数 9.447 ms；原热基线为 199.195 ms。真实环境尚缺大量 playlist/pivot 数据的规模化压测。

### PERF-007：消除搜索关系 N+1 查询

**目标**：搜索结果的 artist 和 album 使用有界 eager loading。

**允许改动**：

- `Sources/App/Controllers/SongController.swift`
- 搜索 API 测试

**实现要求**：保持当前最多 50 条和响应结构；不得为每首歌曲顺序执行 artist/album load。

**非目标**：不在本任务修改搜索匹配语义或增加数据库扩展。

**验收**：有/无 artist、album 的结果兼容；测试或诊断证明查询数量不随结果数线性增加。

**完成记录（2026-07-26）**：

- 搜索主查询增加 artist 与 album eager loading，移除结果循环内每首歌曲各两次的顺序关系加载；最多 50 条结果时关系查询固定为两条。
- 艺术家名匹配由 `LEFT JOIN` 改为等价的 `artist_id IN (subquery)`，避免 JOIN 行解码与 optional-parent eager loading 相互干扰。
- 回归测试覆盖按标题、按艺术家名搜索，以及同时存在完整 artist/album 和两者均缺失的歌曲。
- 聚焦测试通过：`swift test --filter testSongSearchEagerLoadsOptionalArtistAndAlbum`，1 test、0 failures。

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

**完成记录（2026-07-26）**：

- 在真实 5,533 行 PostgreSQL 数据上先采集旧计划：默认列表为 Seq Scan + top-N sort，执行 2.493 ms、147 shared buffers；候选索引事务内验证后才固化。
- 新增可回滚 `CreateSongListIndexes` migration，稳定索引名为 `idx_songs_created_at_id_desc` 与 `idx_songs_format_created_at_id_desc`；SQLite 测试验证创建及回滚。
- 真实迁移已成功应用。默认列表改用 `idx_songs_created_at_id_desc`，执行 0.531 ms、3 shared buffers；`ahx` 格式列表改用组合索引，执行 0.306 ms、10 shared buffers，对照禁用索引时为 2.086 ms、147 shared buffers。
- 两个索引实际大小分别为 240 KiB 和 288 KiB，共 528 KiB；每次歌曲插入会额外维护两个 B-tree，更新 `file_format`、`created_at` 或 `id` 时也有相应写放大。当前表统计为 5,533 inserts、0 updates、0 deletes。
- 聚焦测试通过：`swift test --filter testSongListIndexMigrationCreatesAndRevertsStableIndexes`，1 test、0 failures。

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

**完成记录（2026-07-26）**：

- 搜索条件改用 SQLKit bind 参数，标题与艺术家包含匹配通过 `UNION` 合并 ID，保持大小写不敏感、包含搜索和最多 50 条语义；引号标题可正常命中，`' OR 1=1 --` 返回 0 条。
- 新增 PostgreSQL 专用、可回滚 migration：启用 `pg_trgm`，创建 `lower(title)` 与 `lower(artists.name)` GIN 索引，并增加 `songs.artist_id` B-tree；SQLite 测试环境安全跳过。
- 真实迁移已应用。`winrar` 标题搜索从 Seq Scan、6.114 ms、148 buffers，变为 `idx_songs_lower_title_trgm` Bitmap Index Scan、0.690 ms、43 buffers；`fairlight` 联合搜索为 0.392 ms，并使用 `idx_songs_artist_id`。
- 当前 artists 仅 713 行，优化器判断 7-buffer Seq Scan 比 GIN 更便宜；事务内禁用 Seq Scan 验证 `idx_artists_lower_name_trgm` 可用并返回相同 2 行。三个新索引分别为 752 KiB、152 KiB、80 KiB。
- 真实端点返回 `winrar` 40 条、`fairlight` 12 条，5 次热请求中位数分别为 30.017 ms 和 17.316 ms；聚焦测试通过，1 test、0 failures。

### PERF-010：SQL 化当前曲目位置查询

**目标**：定位歌曲时不把全部歌曲 ID 拉入应用内存。

**允许改动**：

- `SongController.swift`
- 位置接口测试

**实现要求**：使用与 `(created_at DESC, id DESC)` 完全一致的 SQL 计数位置；相同 created_at 时以 id 稳定排序。

**非目标**：不改变位置接口 DTO、页面编号或前端定位流程。

**验收**：第一页、边界、末页、相同时间戳结果与原实现一致；应用内存不随曲库总量线性增长。

**完成记录（2026-07-26）**：

- 位置接口不再加载全库歌曲 ID；读取目标歌曲后，使用参数绑定的 SQL `COUNT(*)` 统计 `(created_at DESC, id DESC)` 排在目标之前的行。
- 对异常的历史 `created_at IS NULL` 行保留 SQL window fallback，同样不把全量 ID 返回应用。
- 全部 7 个 SongLocation 测试通过，覆盖首页、分页边界、末页、同时间戳 ID tie-break、404、非法 per 及与列表 API 一致性。
- 真实 5,533 首曲库最末歌曲返回 `index = 5532`、`page = 111`；5 次请求首次 39.601 ms，热请求中位数 11.296 ms。最坏位置的 COUNT 仍需扫描 5,532 个索引条目，但应用侧内存由 O(曲库总量) 降为 O(1)。

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

**完成记录（2026-07-26）**：

- 将浮动的 jsDelivr `alpinejs@3.x.x` 替换为同源 `/vendor/alpinejs/alpine-3.15.12.min.js`，保留 `defer` 与现有 `x-cloak` 初始化行为。
- 固定 npm integrity、上游 tag、MIT 许可证和 vendored SHA-256；生产文件 SHA-256 为 `57b37d7cae9a27d965fdae4adcc844245dfdc407e655aee85dcfff3a08036a3f`。
- 浏览器 smoke 新增同源 URL、无外部 Alpine CDN 和内容校验测试；全部 Browser 测试通过：60 tests、0 failures。
- 本机服务 HTML 仅引用同源 Alpine，静态 URL 返回 200、46,346 bytes，下载内容 SHA-256 与 vendored 记录一致；首屏初始化不再依赖外网 DNS/TLS/CDN。

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

**完成记录（2026-07-26）**：

- Vapor 对可压缩类型启用响应压缩；缓存 middleware 区分 HTML、API、版本化资源和普通静态资源，音频不做动态压缩。
- release smoke 覆盖 HTML `no-cache`、版本化 Alpine 的 immutable 与压缩、WASM MIME 与 immutable；应用测试覆盖 ETag、Last-Modified、CORP 和 Vary 保留。
- 本机首屏关键资源 gzip 46,940 bytes，对比 identity 155,819 bytes，减少 69.9%；增强 release smoke 在 5,533 首真实曲库通过。
- 真实浏览器点击 XM 曲目后显示“WASM 实时解码”，进度推进且无错误/降级日志。
- 当前 `make run` 仅提供 HTTP 应用入口；HTTPS 反向代理链未在本机出现，因此 HTTPS 响应头与实播留给 PERF-023 在部署入口复测，不将 HTTP 结果冒充 HTTPS 证据。

### PERF-013：延迟加载非首屏播放列表数据

**目标**：首次页面初始化不等待用户尚未打开的播放列表数据。

**允许改动**：

- `Resources/Public/audio/app.js`
- 前端测试

**实现要求**：首次打开 queue/playlist 面板时加载一次；保存、删除后仍正确刷新；并发打开只产生一个请求。

**非目标**：不改变队列内存语义、服务端播放列表协议或 UI 布局。

**验收**：首屏不请求 `/api/playlists`；首次打开加载；失败可重试且有现有 toast。

**完成记录（2026-07-26）**：

- 首屏初始化只并行加载格式统计和曲目列表，不再请求 `/api/playlists`。
- 点击或快捷键首次打开队列面板时才加载播放列表；已成功加载后重复打开不再请求。
- 共享中的请求 Promise 合并并发打开；失败会清除加载状态、显示既有错误 toast，并允许下次打开重试。
- 保存和删除成功后强制刷新播放列表，且对非 2xx 响应按失败处理。
- 新增前端单元测试覆盖延迟加载、并发合并、失败重试、toast 和保存/删除刷新；浏览器测试全量 63 项通过。

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

**完成记录（2026-07-26）**：

- 新增应用级 actor coordinator；cache key 明确包含 SHA-256、SDK fingerprint、格式、采样率语义、声道语义和 subsong。
- 同 key 共享不隶属于单个 HTTP 请求的解码 Task；单个等待者取消不会取消其他等待者需要的共享工作。
- 成功和失败均按 flight ID 清理记录，失败后的请求可重新执行；不同 subsong/key 独立运行。
- 加入 coordinator 前和取得执行权后均校验 PCM WAV，避免竞态；现有各 decoder 继续使用同目录临时文件和 move/replace 原子提交，提交后再次校验。
- Swift 6 聚焦并发测试覆盖 20 个同 key、不同 key、共享失败重试和单等待者取消，共 4 项全部通过。

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

**完成记录（2026-07-26）**：

- `SERVER_DECODE_CONCURRENCY` 提供 1～32 的全局上限，默认 1；Compose、README 和性能文档已同步。
- permit 位于 single-flight 共享 Task 内：同 key 的所有等待者只占一个槽；有效 PCM WAV 在进入 coordinator 前直接返回，不占 permit。
- 结构化成功日志记录 cache hit、格式、排队毫秒、解码毫秒和输出大小；失败额外记录不含源路径的错误类别。
- permit 在成功和失败路径释放；单个 HTTP 等待者取消不取消共享工作，排队等待者取消测试结束后 active/queued 均归零。
- 12 个不同 key、并发上限 2 的压力测试观测最大活跃数严格为 2；聚焦并发测试共 6 项全部通过。

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

**完成记录（2026-07-26）**：

- 新增 `OrzDecodeCacheWarmup` 与 `make warm-decode-cache`，支持单个/重复 `--id`、逗号分隔 `--ids`、`--format`、`--recent`、`--concurrency` 和 `--dry-run`。
- CLI 强制至少一个选择器，组合选择器取交集，不允许隐式全库预热；失败输出安全摘要并以退出码 2 结束。
- Web 与 CLI 共用 `DecodedAudioCacheService`，因此 cache key、SDK fingerprint、PCM 校验、原子提交和 single-flight 语义一致。
- 运行前解析真实播放策略，仅处理 `serverDecode`，direct/WASM 计入 skipped；有效缓存计入 cache hit 并不解码。
- 新产品构建通过；3 项聚焦测试覆盖显式 ID dry-run 零写入、格式+最近导入筛选、重复运行幂等及 Web 共用 cache hit。
- 真实 PostgreSQL/CAS dry-run 选择最近一首 SC68：selected=1、eligible=1、零失败；实际运行命中已有缓存，cache_hits=1。

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

**完成记录（2026-07-26）**：

- 新增 `OrzDecodeCacheMaintenance` 与 `make maintain-decode-cache`；无策略时只报告文件数、总字节及 fingerprint 分组。
- 支持最大容量按最旧优先选择、旧 fingerprint 选择、最小文件年龄、dry-run 和必须显式给出的 `APPLY=1`。
- 仅扫描 `CAS_ROOT/.cache/wav` 直属 WAV，初始化和执行时双重拒绝符号链接逃逸；未知命名只报告、不自动删除。
- Web 对 serverDecode WAV 从响应创建到流完成持有跨进程共享 lease；清理必须取得排他非阻塞 lease，正在流式读取的文件计为 busy 并跳过。生成过程仍使用隐藏临时文件和原子提交，且默认保护最近 300 秒文件。
- 4 项隔离目录测试覆盖 fingerprint/dry-run、容量实际删除、流式占用保护和符号链接逃逸，全部通过。
- 真实缓存只读报告：51 个文件、840,728,128 bytes；当前 fingerprint 12 个/235,699,956 bytes。旧 fingerprint dry-run 选择 39 个/605,028,172 bytes，deleted_files=0、零失败；未对真实缓存执行删除。

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

**完成记录（2026-07-26）**：

- 播放器按 play generation 采集统一字段：策略、格式、资源 fetch、WASM ready、Worker ready、first frame、点击到 playing、underruns 和 fallback；不适用阶段为 null。
- 首帧上报只含格式与性能数字，不含歌曲 ID、标题、媒体 URL/路径或用户标识；后端执行策略、格式字符和 0～600 秒数值边界校验。
- `PLAYBACK_DIAGNOSTICS_ENABLED` 默认 false；关闭时客户端不设置回调、无持续或额外网络请求，endpoint 返回 404。启用时每次成功首帧发送一条同源 POST 并写结构化日志。
- 3 项新增浏览器测试覆盖匿名 payload、三种策略相同字段集合和旧 generation 取消隔离；浏览器全量 66 项通过。3 项后端测试覆盖默认关闭、合法匿名指标和越界/路径格式拒绝。
- 真实浏览器验证：WASM XM 72.73ms（fetch 9.94ms、Worker ready 67.37ms）、direct MP3 67.20ms、热缓存 serverDecode SC68 15.74ms，三者均产生对应策略日志且无标题/路径。
- 验收后已恢复默认关闭服务；首页注入 `ORZ_PLAYBACK_DIAGNOSTICS_ENABLED = false`。

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

**完成记录（2026-07-26）**：

- 首屏不预热；仅曲目 hover、键盘 focus 或选择后，通过 `requestIdleCallback`（无支持时零延时任务）触发对应 WASM bundle。
- `bp/mid/ym` 与其他格式分别使用 builtin/full Worker 池，每类最多一个空闲 Worker，禁止跨 bundle 复用。
- Worker 新增显式 warmup/warmed/warmup-error 协议。失败 Worker 立即终止并清除 Promise，后续交互可重试。
- stop 保留 generation cancel、decoder cancel/destroy 和 stopped 确认；只有收到 stopped 或自然 ended 后才回池。新曲在旧 Worker 尚未 stopped 时会使用另一 Worker，避免共享全局 decoder 竞态；seek generation 逻辑保持不变。
- 新增 5 项相关测试覆盖 bundle 区分、同 bundle 复用、预热失败重试、停止回池、Worker 不 close 且销毁 decoder；浏览器全量 71 项通过。
- 真实浏览器先选择 XM 触发 full bundle 预热，再连续播放两首 XM；两次均进入 WASM 实时解码、暂停态与进度正常，控制台无 error/warn。

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

**完成记录（2026-07-26）**：

- 评估结论见 [WASM 增量输入可行性评估](../wasm-incremental-input-evaluation.md)。
- ABI v1 只有完整内存 `orz_decoder_create_memory`，无 feed/read-at/need-data；当前全部 WASM adapter 在创建 decoder 前都需要完整 `arrayBuffer()`。
- libopenmpt 虽有同步 seek/read stream callbacks，但浏览器 WASM 不能在同步 C callback 中等待异步 Range；其他 adapter 也尚未暴露增量能力。
- 真实曲库 XM 中位数 43,783 bytes/P95 769,439 bytes，IT P95 1,120,975 bytes；多数格式远小于 full WASM bundle。最大 5,506,935-byte XM 的本机完整下载中位数 16.14ms，64/256KiB Range 约 3.96/3.82ms，但分片无法交给 ABI v1，首帧无实际改善。
- 明确内存、seek、subsong、取消、稀疏 chunk 和 decoder capability 要求，并登记 SDK 候选 `AUDIOCORE-INCREMENTAL-001` 及重新启动门槛。
- 因触发公共 ABI 停止条件，本仓库不实现原型、不改变生产播放路径；任务以“完成评估、停止实现”收口。

### PERF-021：评估服务端边解码边响应

**目标**：比较“整曲 WAV 缓存”“流式 WAV”“流式压缩格式”和“预热缓存”的成本。

**允许改动**：设计/基准文档和隔离原型；不直接替换生产 endpoint。

**评估项**：

- WAV header 长度、chunked transfer、Range 和 seek 兼容性。
- 客户端中断时 decoder 取消。
- 同时写缓存与向客户端发送的错误恢复。
- ARM64 单机 CPU、输出带宽和存储成本。

**决策原则**：个人/家庭低并发场景优先选择可运维的预热缓存；只有实测证明整曲等待仍不可接受时才实现流式转码。

**完成记录（2026-07-26）**：

- 评估结论见 [服务端边解码边响应评估](../server-streaming-evaluation.md)，生产决策为保留原子整曲 WAV + PERF-016 低峰预热。
- 当前 fingerprint 的 12 个真实缓存由 1,811,015-byte 源文件放大为 235,699,956-byte PCM，130.15 倍；SC68 单曲约 31.75MB/180s、1.41Mbps。
- 同一真实 WAV 转 Opus 96kbps 为 1,945,305 bytes、1.79s wall/1.47s CPU；MP3 128kbps 为 2,881,035 bytes、2.25s wall/2.14s CPU。压缩显著省带宽，但不消除 SC68 冷解码，非 pipeline 还会增加等待。
- 明确 RIFF data length、HTTP chunked、Range/seek、请求取消、single-flight 多订阅者、tee 原子提交和已发送 200 后错误恢复边界。
- ARM64 单机默认并发 1，加上预热与容量治理，收益/复杂度优于新增流式协议；已定义重新启动隔离原型的五项门槛，本任务不改生产 endpoint。

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

**完成记录（2026-07-26）**：

- Compose 生产默认从 `LOG_LEVEL=debug` 调整为 `info`；请求、迁移和服务端解码 info 日志保留，debug 级 SQL 诊断默认被抑制，仍可显式覆盖为 debug。
- 驱动源码确认默认每个 EventLoop 最多 1 条连接、等待上限 10 秒；本机 8 个 EventLoop 实际持有 8 条空闲连接，PostgreSQL `max_connections=100`。
- `/api/songs?limit=20` 的 200 次、并发 32 真实请求全部成功：平均 53.5ms、P50 40.2ms、P95 137.5ms、最大 165.1ms，无 10 秒级连接等待。
- 当前连接数仅占 PostgreSQL 上限的 8%，没有等待或过量连接证据，因此遵守任务约束，不覆盖连接池默认参数。
- 健康检查和列表并发已实测；迁移、扫描、三类媒体播放将在 PERF-023 全量回归统一验证。

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

**完成记录（2026-07-26）**：

- 同一 MacBook Air、Swift debug、本机 PostgreSQL/CAS、5,533 首曲库，固定 MP3/MOD/WAV 样本，各运行三次。结果已收口到 [性能测量](../performance.md)。
- cold 标签中位数：home 5.261ms、songs 12.357ms、formats 6.981ms、playlists 3.126ms、direct 3.626ms、WASM 源文件 3.731ms、server 热缓存 4.875ms。
- warm 标签中位数：home 4.801ms、songs 16.310ms、formats 6.128ms、playlists 2.602ms、direct 5.114ms、WASM 源文件 3.584ms、server 热缓存 4.299ms。
- 相对 PERF-002，首页与三项初始化 API、direct/WASM/server warm HTTP 首字节均改善；songs warm 的 16.310ms 比本轮 cold 12.357ms 略慢 3.953ms，属低毫秒抖动，已保留而未过滤。
- 明确未改善项：脚本不删除 WAV，故不能把 cold 标签的 server 值当冷解码；真实同机 server cold 仍沿用 PERF-002 的两次 30 秒超时结论。当前解法是预热与缓存治理，不宣称冷路径已流式化。
- 浏览器真实首帧样本为 direct 67.20ms、WASM 72.73ms、server warm 15.74ms；各一次，仅作链路验证，不冒充三次中位数。
- `swift test` 74 项、Browser 71 项、performance/release smoke 自测、真实 release smoke、Compose config、fingerprint 抽样 3/3 和 `git diff --check` 全部通过。
- 真实 release smoke：版本 0.0.2、database/CAS healthy、格式总数 5,533，首页、压缩/缓存、WASM MIME、格式统计和搜索均通过。扫描策略由 Swift 回归与 fingerprint audit 覆盖；未再次写入真实曲库。
- 剩余外部验证：当前环境只有 HTTP；HTTPS 反向代理、真实远端网络与目标 ARM64 生产主机需要在部署入口复测。

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
历史执行时从 Docs/archived/performance-optimization-plan.md 中领取任务 PERF-xxx。

先阅读 AGENTS.md、Docs/archived/performance-optimization-plan.md，以及任务列出的允许改动文件。
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

2026-07-26：PERF-001～PERF-023 已逐项完成；其中 PERF-020 因公共 ABI 边界停止实现，PERF-021 经实测决定不实施流式转码。完整性能数字、回退项、验证集合和剩余外部验证见各任务完成记录及 [性能测量](../performance.md)。
