# OrzMusic

<p align="center">
  <img src="Resources/Public/brand/orz-logo.svg" alt="OrzMusic Logo" width="64" height="64">
</p>

Backend Service About [KeyGen Music](http://keygenmusic.org/)

OrzMusic 是一个现代化的芯片音乐/模块音乐播放服务，支持 28 种音频格式。项目优先使用浏览器原生播放或 WASM 实时解码，仅将不适合浏览器实时处理的格式交给服务端。

页面采用深色资料库界面，包含格式分类与曲目数量、搜索、播放队列、服务端播放列表、键盘快捷键和响应式播放控制面板。品牌图标与 `OrzMusic` 标题显示在左侧导航顶部。

## 架构

解码能力通过版本化的 **OrzAudioCore ABI v1** 提供。当前仓库消费已发布的 OrzAudioCore v1.2.4 SDK（含全部 11 个解码器），不再内嵌 C 解码器源码。详细接口说明见 [Docs/orz-audio-core.md](Docs/orz-audio-core.md)，非阻塞后续任务见 [Docs/orz-audio-core-backlog.md](Docs/orz-audio-core-backlog.md)。

```
OrzAudioCore SDK（已发布，校验锁定）
  ├── 原生库（服务端，.dylib/.so）
  └── WASM（浏览器端，orz_audio_builtin.js/.wasm）
              ↓
      OrzAudioKit（纯 Swift ABI 封装）
              ↓
    App（Vapor web 服务，含 CAS 存储）  
```

## 支持的格式

| 解码方式 | 格式 | 解码库 | 数量 |
|---------|------|--------|------|
| 浏览器原生 | mp3, ogg, flac, m4a, aac | `<audio>` 直接播放 | 41 |
| WASM 解码 | xm, mod, it, s3m, mo3, mtm, fc13, fc14 | libopenmpt | 2562 |
| WASM 解码 | nsf, spc | Game Music Emu | 7 |
| WASM 解码 | sap | ASAP | 32 |
| WASM 解码 | sid | libsidplayfp | 33 |
| WASM 解码 | rad, d00, hsc, **amd** | AdPlug | 43 |
| WASM 解码 | v2m | v2m-player | 87 |
| 服务端解码（具备 WASM 构建能力） | sc68 | libsc68 | 36 |
| WASM 解码 | ym | YM2149 emu | 16 |
| WASM 解码 | **ahx** | **ahx2play** | 41 |
| WASM 解码 | mid | **wavetable synth** | 54 |
| WASM 解码 | bp | 内置 SoundMon V.2 解码器 | 3 |
| 服务端转码 | wav (ADPCM/GSM) | 原生管线 / ffmpeg 回退 | 8 |
| **合计** | **28 种格式** | | **2963** |

## 播放策略

1. **directFile** — 浏览器 `<audio>` 直接播放
2. **wasmDecode** — Worker/WASM 解码 → SharedArrayBuffer → AudioWorklet（同一份 C 源码编译）
3. **serverDecode** — 服务端原生解码或 ffmpeg 回退，输出 PCM WAV 并缓存；当前用于 SC68 和需要转码的 WAV

CAS 中保存的是导入时的原始音频文件，路径由 SHA-256 决定。服务端生成的 PCM WAV 属于独立解码缓存，不会覆盖 CAS 原文件。

## Web 播放器

- 左侧按模块音乐、复古主机、芯片/合成和常规音频分组，并显示实时格式曲目数。
- 搜索可以与格式筛选组合使用；桌面端显示标题、艺术家、专辑、格式、大小和时长。
- 单击选择曲目，双击或点击行内播放按钮开始播放。
- 底部控制面板支持播放/暂停、上一首/下一首、拖动进度和音量/静音。
- 当前队列仅存在于页面运行状态；保存后的播放列表存储在服务端数据库，刷新或更换浏览器后仍可读取。当前播放列表没有用户隔离，部署为多用户服务时需在上层补充鉴权与归属关系。

快捷键：

| 按键 | 操作 |
|:-----|:-----|
| `Space` | 播放 / 暂停 |
| `←` / `→` | 后退 / 前进 5 秒；按住 `Shift` 为 15 秒 |
| `↑` / `↓` | 音量增减 5% |
| `M` | 静音或恢复上次音量 |
| `N` / `P` | 下一首 / 上一首 |
| `/` 或 `Cmd/Ctrl+K` | 聚焦搜索 |
| `Q` | 打开或关闭播放队列 |
| `?` 或 `H` | 显示快捷键帮助 |
| `Esc` | 关闭面板或清空搜索 |

## 快速启动

```bash
# 安装/更新服务端 native SDK 与浏览器 WASM SDK
make setup

# 原生构建与启动（需要本机 PostgreSQL）
make build
make run

# 查看/停止/重启服务
make status
make stop
make restart

# 本地开发服务扫描（服务由 make run 提供）
make scan-local SOURCE=/absolute/path/to/music

# Docker 部署
make docker-up

# Docker 扫描服务（默认把 ./keygenmusic 挂载为 /sources/keygen）
make scan-docker
make scan-docker-run
```

常用 Makefile 入口：

| 命令 | 用途 |
|:-----|:-----|
| `make setup` | 安装/更新 OrzAudioCore native SDK 与 Web/WASM SDK |
| `make sdk-server` | 只更新服务端 native SDK |
| `make sdk-web` | 只更新浏览器 WASM SDK |
| `make status` | 查看 8080/8081 端口占用和 Docker 服务状态 |
| `make run` | 本机启动 Vapor 服务 |
| `make stop` | 停止本机 OrzMusic 服务和 Docker 服务 |
| `make restart` | 停止本机 OrzMusic 服务后重新启动 |
| `make scan-local SOURCE=/path` | 调用本机 `8080` 服务扫描本机路径 |
| `make docker-up` | 通过 Docker 启动 PostgreSQL 与服务 |
| `make docker-restart` | 重启 Docker 服务栈 |
| `make scan-docker` | 启动 Docker 扫描服务，监听 `8081` |
| `make scan-docker-run` | 调用 Docker 扫描服务扫描容器路径，默认 `/sources/keygen` |
| `make test` | 运行 Swift、浏览器和 Docker compose 配置检查 |

扫描路径说明：

- 本地开发模式使用本机路径，例如 `make scan-local SOURCE=/Users/joker/Music/keygenmusic`。
- Docker 模式使用容器路径，默认 `make scan-docker-run` 扫描 `/sources/keygen`。
- Docker 扫描服务默认把本机 `./keygenmusic` 只读挂载为容器内 `/sources/keygen`；需要换目录时可设置 `KEYGEN_DIR=/path/to/music make scan-docker`。

## API

- `GET /api/songs` — 歌曲列表（分页，支持 `?format=` 过滤）
- `GET /api/songs/formats` — 总曲目数和各格式曲目数
- `GET /api/songs/search?q=xxx&format=ym` — 搜索，可与格式筛选组合
- `GET /api/songs/:id/stream` — 音频流
- `GET /api/songs/:id/raw` — 原始文件下载
- `GET /api/artists` — 艺术家列表
- `GET /api/albums` — 专辑列表
- `GET /api/playlists` — 播放列表管理
- `POST /api/scan` — 扫描音乐文件

## 技术栈

- **后端**: Vapor 4 (Swift 6.0)
- **数据库**: PostgreSQL + Fluent ORM
- **前端**: Alpine.js + Worker + SharedArrayBuffer + AudioWorklet/WASM
- **WASM 编译**: OrzAudioCore SDK（含 Emscripten 编译的 WASM bundle）
- **解码器**: OrzAudioCore ABI v1.0，校验锁定的外置 SDK
