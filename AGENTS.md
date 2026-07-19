# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## 解码能力

OrzAudioCore v1.2.3 作为外置 SDK 消费。解码逻辑封装在 `OrzAudioCoreSDK`（C system library），
通过稳定 ABI v1 暴露。同一份 SDK 编译为 WASM（浏览器端）和原生库（服务端），零 brew/apt 依赖。

## Build & Test

```bash
# Build (debug)
swift build

# Build (release)
swift build -c release

# Run tests
swift test

# Run a single test
swift test --filter testPlayStrategy

# Run server (requires PostgreSQL)
swift run Run
# Or via Docker:
docker compose up --build -d
```

## SDK 更新

```bash
# 安装/更新服务端 SDK（从 Release 下载，含校验）
./script/update-audio-core-server.sh

# 安装/更新 Web WASM SDK
./script/update-audio-core-web.sh
```

## Architecture

### Target Dependency Chain

```
App (Vapor) → OrzAudioKit (Swift) → OrzAudioCoreSDK (C system library)
```

- **OrzAudioCoreSDK** — 已发布的 OrzAudioCore v1.2.3 system library target。包含所有 C 解码器（openmpt、gme、sidplayfp、adplug、ym6、midi、sc68、asap、ahx2play、v2m、bp）。
  通过 `audio-core-sdk.lock.json` 锁定版本和校验和，由 CI 自动下载。
- **OrzAudioKit** —纯 Swift target。封装 `OrzAudioCoreSDK` 的稳定 ABI，对不支持格式 fallback 到 ffmpeg CLI。
- **App** — Vapor web 服务器。包含路由、模型、迁移、CAS 存储、扫描器。

### 三种播放策略

- **`directFile`** — 浏览器 `<audio>` 原生播放（mp3, ogg, flac, m4a, aac）
- **`wasmDecode`** — Worker/WASM 解码 → SharedArrayBuffer → AudioWorklet（xm, mod, it, sid, mid, ym, bp, ...）
- **`serverDecode`** — 服务器端原生解码 / ffmpeg 回退 → WAV 缓存（sc68, wav with ADPCM/GSM）

### Content-Addressed Storage (CAS)

文件按 SHA-256 哈希存储：`{CAS_ROOT}/{sha256[:2]}/{sha256}.{ext}`（默认 `./data/music/`）。

数据库只存 `sha256` + `fileFormat`（不存路径）。`CasStorageService.swift` 负责 store/resolve/delete。

### 关键文件

| File | Purpose |
|------|---------|
| `Package.swift` | SPM targets + OrzAudioCoreSDK system library linkage |
| `audio-core-sdk.lock.json` | OrzAudioCore 版本锁定 + 制品校验和 |
| `Sources/OrzAudioKit/AudioDecoder.swift` | 官方 Swift ABI 封装 |
| `Sources/OrzAudioKit/AudioEngine.swift` | 流策略解析 + 解码编排 |
| `Sources/App/Services/CasStorageService.swift` | 内容寻址存储 |
| `script/update-audio-core-server.sh` | 服务端 SDK 安装/更新 |
| `script/update-audio-core-web.sh` | Web WASM SDK 安装/更新 |
| `Resources/Public/audio/player.js` | 前端 WASM 解码 + 播放 |

## Frontend

- 单页应用 `Resources/Views/player.leaf`（Alpine.js + Leaf 模板）
- 品牌为 **OrzMusic**；侧边栏显示抽象 O/波浪 Logo + 品牌标题
- 格式导航曲目数来自 `GET /api/songs/formats`；搜索支持可选 `format` 过滤
- 未保存队列在页面内存中；保存的播放列表持久化在服务端数据库，当前无用户隔离
- WASM bridge 在 `Resources/Public/audio/orz_audio_builtin.js`（由 OrzAudioCore SDK 提供）
- 播放加载 ABI-v1 WASM runtime 到 Worker；Worker 调用 `orz_decoder_*` 并写入 AudioWorklet ring buffer
