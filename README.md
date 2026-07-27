# OrzMusic

<p align="center">
  <img src="Resources/Public/brand/orz-logo.svg" alt="OrzMusic Logo" width="64" height="64">
</p>

OrzMusic 是一个面向 KeyGen Music、芯片音乐和模块音乐资料库的 Web 播放服务。它把曲库管理、搜索、播放队列、格式分类和多格式音频播放整合在一个简洁的深色界面中。

项目优先使用浏览器原生播放或 WASM 实时解码；不适合浏览器实时处理的格式由服务端解码为 PCM WAV 缓存后播放。

## 品牌图标

OrzMusic 使用圆角近黑底、暖白圆环与薄荷绿五柱音频波形作为统一项目图标。可编辑主文件为
[`Resources/Public/brand/orz-logo.svg`](Resources/Public/brand/orz-logo.svg)，favicon、PNG 和单色空状态版本均由该设计派生；更新图标时应同步全部品牌制品，避免单独修改某个尺寸。

## 架构概览

解码能力由外置 **OrzAudioCore SDK** 提供。OrzMusic 只消费已发布并校验锁定的 SDK，不再内嵌第三方 C/C++ decoder 源码。

```
OrzAudioCore SDK
  ├── Native library（服务端）
  └── WASM bundle（浏览器）
              ↓
OrzAudioKit（Swift ABI 封装）
              ↓
App（Vapor API、扫描、CAS、播放策略）
              ↓
Web Player（Alpine.js、Worker、AudioWorklet）
```

核心边界：

- OrzAudioCore：格式探测、元数据、PCM 解码。
- OrzAudioKit：Swift 层 ABI 封装和 fallback 编排。
- App：数据库、CAS、扫描、搜索、播放列表和 HTTP API。
- Web Player：界面、快捷键、队列、WASM Worker 和 AudioWorklet 播放。

## 单一事实来源

README 只保留项目入口信息。易变化或需要精确口径的内容维护在专项文档中：

| 文档 | 内容 |
|:-----|:-----|
| [Docs/format-support.md](Docs/format-support.md) | 当前支持格式、格式数量、播放策略和存储/缓存口径。 |
| [Docs/orz-audio-core.md](Docs/orz-audio-core.md) | OrzAudioCore SDK ABI、能力边界、版本与发布规则。 |
| [Docs/deployment.md](Docs/deployment.md) | GitHub Release 镜像 + 轻量部署包的生产部署流程。 |
| [Docs/migration.md](Docs/migration.md) | Docker/native 服务迁移流程与验收清单。 |
| [Docs/performance.md](Docs/performance.md) | 首屏、API 与三类播放链路的测量口径、生产基线和运维参数。 |
| [Docs/backlog/](Docs/backlog/) | 待推进完成的计划、任务清单与可独立执行的实施项。 |
| [CHANGELOG.md](CHANGELOG.md) | 版本变更日志。 |
| [AGENTS.md](AGENTS.md) | 智能体协作、项目结构和维护约定。 |

## 快速启动

```bash
# 安装/更新 OrzAudioCore native SDK 与 Web/WASM SDK
make setup

# 本机开发：需要可用的 PostgreSQL
make build
make run

# Docker 部署：包含 PostgreSQL 与服务
make docker-up

# 生成生产轻量部署包（Release workflow 会自动执行）
make package-deploy

# 查看所有维护命令
make help
```

常用操作：

```bash
# 查看端口和服务状态
make status

# 停止本机/Docker 服务
make stop

# 调用本机服务扫描音乐目录
make scan-local SOURCE=/absolute/path/to/music

# Docker 扫描服务，默认把 ./keygenmusic 挂载为 /sources/keygen
make scan-docker
make scan-docker-run

# 测试
make test
```

## 运行配置

常用环境变量：

| 变量 | 默认值 | 说明 |
|:-----|:-------|:-----|
| `DATABASE_HOST` | `localhost` / Docker 中为 `db` | PostgreSQL 主机。 |
| `DATABASE_PORT` | `5432` | PostgreSQL 端口。 |
| `DATABASE_NAME` | `vapor_database` | 数据库名。 |
| `DATABASE_USERNAME` | `vapor_username` | 数据库用户。 |
| `DATABASE_PASSWORD` | `vapor_password` | 数据库密码。 |
| `CAS_ROOT` | `./data/music` / Docker 中为 `/data/music` | CAS 原始音频存储根目录。 |
| `SERVER_DECODE_CONCURRENCY` | `1` | 同时执行的冷缓存服务端解码数；限制为 1～32，低并发单机建议保持 1。 |
| `PLAYBACK_DIAGNOSTICS_ENABLED` | `false` | 是否接收匿名浏览器首帧指标；默认关闭。 |

CAS 保存导入时的原始音频文件；服务端解码产生的 WAV 缓存在 `CAS_ROOT/.cache/wav/` 下，可删除后自动重建。

低峰期可用 `make warm-decode-cache FORMAT=sc68 DRY_RUN=1` 预览服务端解码缓存预热范围；去掉 `DRY_RUN=1` 执行。也可使用 `SONG_ID`、逗号分隔的 `SONG_IDS` 或 `RECENT` 限定范围，命令不会隐式预热全库。

`make maintain-decode-cache` 只读报告 WAV 缓存占用；通过 `MAX_BYTES` 或 `REMOVE_OLD_FINGERPRINTS=1` 选择清理范围时仍默认为 dry-run，只有再设置 `APPLY=1` 才会删除。

## API 入口

- `GET /api/songs` — 曲目列表，支持分页与 `format` 过滤。
- `GET /api/songs/formats` — 总曲目数和各格式曲目数。
- `GET /api/songs/search?q=...&format=...` — 搜索，可组合格式过滤。
- `GET /api/songs/:id/stream` — 播放流。
- `GET /api/songs/:id/raw` — 原始文件下载。
- `GET /api/playlists` — 播放列表管理。
- `POST /api/scan` — 扫描并导入音乐文件。

完整接口细节以代码和运行中的 OpenAPI/System API 返回为准。

## 技术栈

- Swift 6 / Vapor 4
- PostgreSQL / Fluent
- Leaf / Alpine.js
- Worker + SharedArrayBuffer + AudioWorklet
- OrzAudioCore ABI v1 native/WASM SDK
