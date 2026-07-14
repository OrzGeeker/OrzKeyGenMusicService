# OrzKeyGenMusicService

<p align="center">
  <img src="/favicon.png" alt="OrzPlayer Icon" width="64" height="64">
</p>

Backend Service About [KeyGen Music](http://keygenmusic.org/)

一个现代化的芯片音乐/模块音乐播放服务，支持 25+ 种音频格式，通过 WASM 在浏览器端实时解码。

## 支持的格式

| 解码方式 | 格式 | 解码库 | 数量 |
|---------|------|--------|------|
| 浏览器原生 | mp3, ogg, wav, flac, mid, m4a, aac | — | 186 |
| WASM 解码 (已集成) | xm, mod, it, s3m, mo3, mtm | libopenmpt | 4881 |
| WASM 解码 (已集成) | nsf, spc | game-music-emu | — |
| WASM 解码 (已集成) | sap | ASAP | — |
| WASM 解码 (已集成) | sid | libsidplayfp (sidlite) | 48 |
| WASM 待集成 | sc68, ym | libsc68 | 141 |
| WASM 待集成 | v2m | v2m-player | 130 |
| WASM 待集成 | ahx, amd, fc13, fc14 | uade | 100 |
| WASM 待集成 | rad, d00, hsc | adplug | 41 |
| 服务端转码 | bp | ffmpeg | 4 |
| **合计** | **~25 种格式** | | **~5530** |

## 快速启动

```bash
# 构建 & 启动
docker compose up --build -d

# 初始化数据库 & 扫描音乐
docker compose exec app /app/.build/release/Run --env production scan

# 默认监听 8080 端口
open http://localhost:8080
```

## API

- `GET /api/songs?per=2000` — 获取所有歌曲
- `GET /api/songs/search?q=xxx` — 搜索歌曲
- `GET /api/songs/:id/stream` — 流式播放
- `GET /api/artists` — 获取艺术家
- `GET /api/albums` — 获取专辑
- `GET /api/playlists` — 播放列表管理

## 架构

```
                  ┌──────────────────────────────────────┐
                  │          Browser (WASM)               │
                  │  ┌──────────────────────────────┐    │
                  │  │  OrzAudioKit (WASM)           │    │
                  │  │  ├─ libopenmpt → xm/mod/it   │    │
                  │  │  ├─ Game Music Emu → nsf/spc │    │
                  │  │  ├─ ASAP → sap               │    │
                  │  │  └─ ...                      │    │
                  │  └──────────────────────────────┘    │
                  └──────────┬───────────────────────────┘
                             │ HTTP API
                  ┌──────────▼───────────────────────────┐
                  │     Vapor (Swift) Server              │
                  │  ├─ 歌曲管理 / 搜索 / 播放列表        │
                  │  ├─ ffmpeg CLI 转码 (仅 bp 格式)      │
                  │  └─ PostgreSQL (音乐元数据)           │
                  └──────────────────────────────────────┘
```

## 播放策略

1. **directFile** — 浏览器原生支持格式，直接 `<audio>` 播放
2. **wasmDecode** — WASM 实时解码，浏览器端输出 PCM → AudioContext
3. **serverDecode** — 仅 bp 格式，ffmpeg CLI 转 WAV

## 技术栈

- **后端**: Vapor 4 (Swift 6.0)
- **数据库**: PostgreSQL + Fluent
- **前端**: Alpine.js + OrzAudioKit WASM
- **WASM 编译**: Emscripten 6.0
- **解码库**: libopenmpt, game-music-emu, ASAP
