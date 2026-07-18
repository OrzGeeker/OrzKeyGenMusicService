# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 解码能力

同一份 C 源码 → WASM 浏览器端 + 原生服务端，零 brew/apt 依赖。

## Build & Test

```bash
# Build (debug)
swift build

# Build (release)
swift build -c release

# Run tests (tests use SQLite in-memory, no Postgres needed)
swift test

# Run a single test
swift test --filter testPlayStrategy

# Run server (requires PostgreSQL)
swift run Run
# Or via Docker:
docker compose up --build -d
```

## WASM Build

```bash
# Build OrzAudioKit WASM binary (for browser-side decoding)
./script/build-wasm.sh

# Build native decoder .a libraries (zero brew/apt dependency)
./script/build-native-libs.sh --only-openmpt
```

## Architecture — Unified C Decoder + Swift Orchestration

### Target Dependency Chain

```
App (Vapor) → OrzAudioKit (Swift) → OrzAudioKitCXX (C/C++)
```

- **OrzAudioKitCXX** — pure C/C++ target. Same source code compiles to both WASM (browser via emscripten) and native (server via SPM). Decoders organized by format category under `Sources/OrzAudioKitCXX/`.
- **OrzAudioKit** — pure Swift target. Wraps C decoders via `CDecoderBridge.swift`, falls back to ffmpeg CLI for unsupported formats.
- **App** — Vapor web server. Contains routes, models, migrations, CAS storage, scanner.

### C Decoder Architecture

All C decoders implement a unified `Decoder` interface (`include/audio_engine.h`):

```c
typedef struct {
    const char *name;
    int  (*load)(const unsigned char *data, int len);
    double (*get_duration)();
    int   (*get_sample_rate)();
    int   (*get_channels)();
    int   (*render)(float *out, int frames);  // stereo float32 interleaved
    void  (*destroy)();
} Decoder;
```

Public calls use the versioned `orz_audio_core.h` ABI (`orz_decoder_create_memory`, `orz_decoder_render_f32`, and related functions). An immutable descriptor table generated from `decoder-manifest.json` maps formats to instance vtables. The old `orz_load/orz_render` API is hidden, deprecated compatibility code for one release cycle only.

### Decoder Categories

| Directory | Format | Library | Self-contained |
|-----------|--------|---------|:---:|
| `openmpt/` | xm, mod, it, s3m, mo3, mtm, fc13, fc14 | libopenmpt 0.8.0 | ✗ |
| `gme/` | nsf, spc | game-music-emu 0.6.3 | ✗ |
| `sidplayfp/` | sid | libsidplayfp 3.0.2 | ✗ |
| `adplug/` | rad, d00, hsc, **amd** | adplug 2.4 + libbinio 1.5 | ✗ |
| `ym6/` | ym | Built-in YM2149 emulator | ✅ |
| `midi/` | mid | Built-in wavetable synth (sine/square/saw/triangle) | ✅ |
| `sc68/` | sc68 | libsc68 | ✅ |
| `asap/` | sap | ASAP | ✅ |
| `uade/` | ahx | ahx2play (8bitbubsy C port) | ✅ |
| `v2m/` | v2m | v2m-player | ✅ |

### Static Libraries

Pre-compiled .a files and third-party headers live in `Libraries/OrzAudioKit/`:

```
Libraries/OrzAudioKit/
├── native/          ← .a files (gitignored, built by build-native-libs.sh)
│   ├── libopenmpt.a
│   ├── libgme.a
│   ├── libsidplayfp.a
│   ├── libadplug.a
│   └── libbinio.a
└── thirdparty/      ← Library headers (committed to git)
    ├── libopenmpt/
    ├── gme/
    ├── sidplayfp/
    ├── adplug/
    └── binio/
```

`Package.swift` resolves the repository-local native library directory from the package path. The portable SDK build and installation entry point is CMake; SwiftPM remains the OrzMusic integration build.

### Three Play Strategies

- **`directFile`** — Browser `<audio>` plays natively (mp3, ogg, flac, m4a, aac)
- **`wasmDecode`** — Browser Worker/WASM decodes → SharedArrayBuffer → AudioWorklet (xm, mod, it, sid, mid, ym, bp, ...)
- **`serverDecode`** — Server-side native decoder/ffmpeg fallback → WAV cache (sc68, wav with ADPCM/GSM)

### Content-Addressed Storage (CAS)

Files stored by SHA-256 hash: `{CAS_ROOT}/{sha256[:2]}/{sha256}.{ext}` (default `./data/music/`).

DB stores only `sha256` + `fileFormat` (no `filePath`). `CasStorageService.swift` handles store/resolve/delete.

### Key Files

| File | Purpose |
|------|---------|
| `Package.swift` | SPM targets + C library linkage |
| `Sources/OrzAudioKitCXX/include/orz_audio_core.h` | Stable, versioned public C ABI |
| `decoder-manifest.json` | Single source of truth for formats and capabilities |
| `Sources/OrzAudioKitCXX/dispatch/audio_engine.c` | Immutable generated format registry |
| `Sources/OrzAudioKitCXX/dispatch/orz_dispatch.c` | ABI handles, lifecycle, probing and rendering |
| `Sources/OrzAudioKit/AudioDecoder.swift` | Official Swift ABI wrapper |
| `Sources/OrzAudioKit/CDecoderBridge.swift` | OrzMusic compatibility facade over `AudioDecoder` |
| `Sources/OrzAudioKit/AudioFormat.swift` | Play strategy definitions |
| `Sources/App/Services/CasStorageService.swift` | Content-addressed file storage |
| `script/build-wasm.sh` | WASM build (emscripten, ~4.5MB wasm) |
| `script/build-native-libs.sh` | Native static lib build (clang) |
| `Resources/Public/audio/player.js` | Frontend WASM decode + playback |

## Frontend

- Single-page app with `Resources/Views/player.leaf` (Alpine.js + Leaf template)
- UI brand is **OrzMusic**; the sidebar combines the abstract O/wave logo with the brand title.
- Format navigation counts come from `GET /api/songs/formats`; search accepts an optional `format` filter.
- The unsaved queue is page memory; saved playlists are persisted in the server database and currently are not user-scoped.
- WASM bridge in `Resources/Public/audio/orz_audio.js` (generated by emscripten)
- Playback loads the ABI-v1 WASM runtime in a Worker; the Worker calls `orz_decoder_*` and feeds the AudioWorklet ring buffer.
