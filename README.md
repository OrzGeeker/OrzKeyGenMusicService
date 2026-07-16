# OrzKeyGenMusicService

<p align="center">
  <img src="/favicon.png" alt="OrzPlayer Icon" width="64" height="64">
</p>

Backend Service About [KeyGen Music](http://keygenmusic.org/)

一个现代化的芯片音乐/模块音乐播放服务，支持 28 种音频格式，通过 WASM 在浏览器端实时解码。

## 架构

```
同一份 C 源码 → WASM 浏览器端 + 原生服务端，零 brew/apt 依赖。

Sources/
├── OrzAudioKitCXX/       ← 纯 C/C++ 解码器，按格式分类
│   ├── openmpt/          ← libopenmpt（xm/mod/it/s3m/...）
│   ├── gme/              ← Game Music Emu（nsf/spc）
│   ├── sidplayfp/        ← libsidplayfp（sid）
│   ├── adplug/           ← AdPlug（rad/d00/hsc/amd）
│   ├── ym6/              ← YM2149 自包含模拟器（ym）
│   ├── midi/             ← wavetable 合成器（mid）
│   ├── sc68/             ← libsc68（sc68）
│   ├── asap/             ← ASAP（sap）
│   ├── uade/             ← ahx2play（ahx）
│   ├── v2m/              ← v2m-player（v2m）
│   ├── dispatch/         ← 注册表 + 调度
│   └── helpers/          ← C++ 异常安全包装
│
├── OrzAudioKit/           ← 纯 Swift，解码编排
│
└── App/                  ← Vapor 服务
```

## 支持的格式

| 解码方式 | 格式 | 解码库 | 数量 |
|---------|------|--------|------|
| 浏览器原生 | mp3, ogg, flac, m4a, aac | `<audio>` 直接播放 | 52 |
| WASM 解码 | xm, mod, it, s3m, mo3, mtm, fc13, fc14 | libopenmpt | 2556 |
| WASM 解码 | nsf, spc | Game Music Emu | 7 |
| WASM 解码 | sap | ASAP | 32 |
| WASM 解码 | sid | libsidplayfp | 33 |
| WASM 解码 | rad, d00, hsc, **amd** | AdPlug | 43 |
| WASM 解码 | v2m | v2m-player | 88 |
| WASM 解码 | sc68 | libsc68 | 36 |
| WASM 解码 | ym | YM2149 emu | 16 |
| WASM 解码 | **ahx** | **ahx2play** | 41 |
| WASM 解码 | mid | **wavetable synth** | 54 |
| 服务端转码 | wav (ADPCM), bp | ffmpeg | 11 |
| **合计** | **28 种格式** | | **~3000** |

## 播放策略

1. **directFile** — 浏览器 `<audio>` 直接播放
2. **wasmDecode** — WASM 解码 → AudioContext（同一份 C 源码编译）
3. **serverDecode** — 服务端 ffmpeg 转 PCM WAV 并缓存

## 快速启动

```bash
# 原生构建（macOS）
swift build
swift run

# 构建 WASM 解码器（前置：安装 Emscripten SDK）
./script/build-wasm.sh

# 构建原生静态库（首次需要）
./script/build-native-libs.sh

# Docker 部署
docker compose up --build -d
```

## API

- `GET /api/songs` — 歌曲列表（分页，支持 `?format=` 过滤）
- `GET /api/songs/search?q=xxx` — 搜索
- `GET /api/songs/:id/stream` — 音频流
- `GET /api/songs/:id/raw` — 原始文件下载
- `GET /api/artists` — 艺术家列表
- `GET /api/albums` — 专辑列表
- `GET /api/playlists` — 播放列表管理
- `POST /api/scan` — 扫描音乐文件

## 技术栈

- **后端**: Vapor 4 (Swift 6.0)
- **数据库**: PostgreSQL + Fluent ORM
- **前端**: Alpine.js + WASM
- **WASM 编译**: Emscripten 6.0
- **解码器**: 全部源码编译，零系统库依赖
