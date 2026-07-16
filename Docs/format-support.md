# OrzPlayer 格式支持状态

> 最后更新：2026-07-16

## 总览

- **支持格式：** 28 / 28 种音频格式 ✅
- **总文件数：** ~3000 首（keygenmusic 目录）
- **源码编译，零系统依赖**

---

## 格式支持详情

### 模块跟踪器 — libopenmpt

| 格式 | 文件数 | 解码器 | WASM | SPM 原生 |
|:-----|------:|:-------|:----:|:--------:|
| `xm` | 1680 | libopenmpt 0.8.0 | ✅ | ✅ |
| `mod` | 664 | libopenmpt 0.8.0 | ✅ | ✅ |
| `it` | 144 | libopenmpt 0.8.0 | ✅ | ✅ |
| `s3m` | 54 | libopenmpt 0.8.0 | ✅ | ✅ |
| `mo3` | 5 | libopenmpt 0.8.0 | ✅ | ✅ |
| `mtm` | 1 | libopenmpt 0.8.0 | ✅ | ✅ |
| `fc13` | 2 | libopenmpt 0.8.0 | ✅ | ✅ |
| `fc14` | 12 | libopenmpt 0.8.0 | ✅ | ✅ |

### 游戏主机仿真 — Game Music Emu

| 格式 | 文件数 | 解码器 | WASM | SPM 原生 |
|:-----|------:|:-------|:----:|:--------:|
| `nsf` | 5 | GME 0.6.3 | ✅ | ✅ |
| `spc` | 2 | GME 0.6.3 | ✅ | ✅ |

### Commodore 64 — libsidplayfp

| 格式 | 文件数 | 解码器 | WASM | SPM 原生 |
|:-----|------:|:-------|:----:|:--------:|
| `sid` | 33 | libsidplayfp 3.0.2 | ✅ | ✅ |

### Atari ST — libsc68 / YM2149

| 格式 | 文件数 | 解码器 | WASM | SPM 原生 |
|:-----|------:|:-------|:----:|:--------:|
| `sc68` | 36 | libsc68 | ✅ | ✅ |
| `ym` | 16 | ym6_impl.c (YM2149) | ✅ | ✅ |

### AdLib OPL2/3 — AdPlug

| 格式 | 文件数 | 解码器 | WASM | SPM 原生 |
|:-----|------:|:-------|:----:|:--------:|
| `rad` | 11 | adplug + libbinio | ✅ | ✅ |
| `d00` | 3 | adplug + libbinio | ✅ | ✅ |
| `hsc` | 12 | adplug + libbinio | ✅ | ✅ |
| **`amd`** | **17** | **adplug + libbinio** | ✅ | **✅ 新修复** |

### Atari POKEY — ASAP

| 格式 | 文件数 | 解码器 | WASM | SPM 原生 |
|:-----|------:|:-------|:----:|:--------:|
| `sap` | 32 | ASAP | ✅ | ✅ |

### Amiga — ahx2play（替代 UAE 全仿真）

| 格式 | 文件数 | 解码器 | WASM | SPM 原生 |
|:-----|------:|:-------|:----:|:--------:|
| **`ahx`** | **41** | **ahx2play（8bitbubsy C 移植）** | ✅ | **✅ 新替换** |

### Farbrausch V2 — v2m-player

| 格式 | 文件数 | 解码器 | WASM | SPM 原生 |
|:-----|------:|:-------|:----:|:--------:|
| `v2m` | 88 | v2m-player | ✅ | ✅ |

### MIDI — wavetable 合成器

| 格式 | 文件数 | 解码器 | WASM | SPM 原生 |
|:-----|------:|:-------|:----:|:--------:|
| **`mid`** | **54** | **wavetable（sine/square/saw/triangle）** | ✅ | **✅ 自包含** |

### 浏览器原生播放（directFile）

| 格式 | 文件数 | 策略 | 备注 |
|:-----|------:|:-----|:-----|
| `mp3` | 6 | directFile | 浏览器原生 |
| `ogg` | 35 | directFile | 浏览器原生 |
| `flac` | 0 | directFile | 浏览器原生 |
| `m4a` | 0 | directFile | 浏览器原生 |
| `aac` | 0 | directFile | 浏览器原生 |

### 服务端转码（serverDecode）

| 格式 | 文件数 | 策略 | 备注 |
|:-----|------:|:-----|:------|
| `wav` | 8 | serverDecode | ADPCM/GSM 编码需 ffmpeg 转 PCM |
| `bp` | 3 | serverDecode | 私有自定义格式 |

---

## 架构

```
同一份 C 源码 → 两种编译方式：

  Sources/OrzAudioKitCXX/
    ├── dispatch/         ← 调度 + 注册表
    ├── openmpt/          ← libopenmpt 包装器
    ├── gme/              ← GME 包装器
    ├── sidplayfp/        ← libsidplayfp 包装器
    ├── adplug/           ← AdPlug 包装器
    ├── sc68/             ← libsc68 包装器
    ├── asap/             ← ASAP 包装器
    ├── uade/             ← ahx2play 包装器
    ├── v2m/              ← v2m-player 包装器
    ├── ym6/              ← YM2149 自包含模拟器
    ├── midi/             ← wavetable 合成器
    └── helpers/          ← C++ 异常安全包装

         ↓ Emscripten           ↓ clang + SPM
    orz_audio.wasm        libOrzAudioKit.a（静态链接）
    （浏览器端）              （服务端原生）
```

## 构建说明

```bash
# WASM 构建（浏览器端）
./script/build-wasm.sh

# 原生静态库（服务端）
./script/build-native-libs.sh

# 服务端构建
swift build
```

## 播放流程

```
浏览器请求 /api/songs/:id/stream
  ↓
SongController.stream()
  ↓
AudioEngine.resolveStreamStrategy()
  ├─ directFile   → 返回原始文件给 <audio>
  ├─ wasmDecode   → 返回原始文件，浏览器端 WASM 解码
  └─ serverDecode → 服务端 ffmpeg 转 PCM WAV 并缓存
```

浏览器端 WASM 解码：
```
fetch → ArrayBuffer → orz_load(format, data, len)
  → orz_render(out, frames) → AudioContext.play()
```
