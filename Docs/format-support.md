# OrzPlayer 格式支持状态

> 最后更新：2026-07-15

## 总览

- **支持格式：** 22 / 24 种音频格式 ✅
- **总文件数：** ~5,500 首（keygenmusic 目录）
- **不可用格式：** 2 种（17 + 4 首 = 21 首）

---

## 格式支持详情

### 模块跟踪器 — libopenmpt

| 格式 | 文件数 | 解码器 | WASM | 验证状态 |
|:-----|------:|:-------|:----:|:--------|
| `xm` | 3396 | libopenmpt 0.8.0 | ✅ | ✅ 已验证音频输出 |
| `mod` | 1093 | libopenmpt 0.8.0 | ✅ | ✅ 已验证 |
| `it` | 254 | libopenmpt 0.8.0 | ✅ | ✅ 已验证 |
| `s3m` | 92 | libopenmpt 0.8.0 | ✅ | ✅ 已验证 |
| `mo3` | 5 | libopenmpt 0.8.0 | ✅ | 未单独验证（逻辑同 xm） |
| `mtm` | 1 | libopenmpt 0.8.0 | ✅ | 未单独验证 |
| `fc13` | 4 | libopenmpt 0.8.0 | ✅ | FutureComposer 1.3 |
| `fc14` | 16 | libopenmpt 0.8.0 | ✅ | FutureComposer 1.4 |

### 游戏主机仿真 — Game Music Emu

| 格式 | 文件数 | 解码器 | WASM | 验证状态 |
|:-----|------:|:-------|:----:|:--------|
| `nsf` | 5 | GME 0.6.3 | ✅ | ✅ 已验证 |
| `spc` | 3 | GME 0.6.3 | ✅ | ✅ 已验证 |

### Commodore 64 — libsidplayfp

| 格式 | 文件数 | 解码器 | WASM | 验证状态 |
|:-----|------:|:-------|:----:|:--------|
| `sid` | 48 | libsidplayfp 3.0.2 | ✅ | ✅ 已验证（小批量渲染，4K-5K 帧） |

### Atari ST — libsc68 / YM2149

| 格式 | 文件数 | 解码器 | WASM | 验证状态 |
|:-----|------:|:-------|:----:|:--------|
| `sc68` | 120 | libsc68 (photonstorm) | ✅ | ✅ 已验证音频输出 |
| `ym` | 21 | ym6_impl.c (YM2149) | ✅ | ✅ 已验证（需 LHa 解压） |
| `hsc` | 18 | adplug (OPL2) | ✅ | ✅ 已验证 |

### Atari POKEY — ASAP

| 格式 | 文件数 | 解码器 | WASM | 验证状态 |
|:-----|------:|:-------|:----:|:--------|
| `sap` | 32 | ASAP | ✅ | ✅ 已验证 |

### Amiga — uade (UAE 68000 仿真)

| 格式 | 文件数 | 解码器 | WASM | 验证状态 |
|:-----|------:|:-------|:----:|:--------|
| `ahx` | 63 | UAE Amiga 500 + AbyssHighestExperience | ✅ | ✅ **刚完成，已验证音频输出** |
| `thx` | — | UAE Amiga 500 + AbyssHighestExperience | ✅ | AHX 变体，同解码器 |
| `amd` | 17 | — | **❌** | 非标准格式，无对应 Amiga 播放器 |

### AdLib OPL2/3 — AdPlug

| 格式 | 文件数 | 解码器 | WASM | 验证状态 |
|:-----|------:|:-------|:----:|:--------|
| `rad` | 13 | adplug + libbinio | ✅ | ✅ 已验证 |
| `d00` | 10 | adplug + libbinio | ✅ | ✅ 已验证 |

### Farbrausch V2 — v2m-player

| 格式 | 文件数 | 解码器 | WASM | 验证状态 |
|:-----|------:|:-------|:----:|:--------|
| `v2m` | 130 | v2m-player | ✅ | ✅ 已验证 |

### 浏览器原生播放 (directFile)

| 格式 | 文件数 | 策略 | 备注 |
|:-----|------:|:-----|:-----|
| `mp3` | 15 | directFile | 浏览器原生支持 |
| `ogg` | 41 | directFile | 浏览器原生支持 |
| `wav` | 20 | directFile | 浏览器原生支持 |
| `mid` | 110 | directFile | 浏览器原生 MIDI |

### 不可用

| 格式 | 文件数 | 原因 |
|:-----|------:|:-----|
| `amd` | 17 | 非标准 Amiga 格式。文件头为纯文本（模块名/作曲者），不符合 AmigaOS 可执行格式。`eagleplayer.conf` 中无 amd 映射。无法用 uade 或其他解码器播放。 |
| `bp` | 4 | 服务端解码 (`serverDecode`) 未实现。私有自定义格式。 |

### 非音频文件（已过滤）

| 扩展名 | 文件数 | 说明 |
|:-------|------:|:-----|
| `md` | 2 | 文档 |
| `nfo` | 1 | 发布信息 |
| `jpg` | 1 | 图片 |
| `ico` | 1 | 图标 |
| `git` | 1 | Git 文件 |

---

## WASM 构建

- **构建脚本：** `script/build-wasm.sh`
- **产物：** `Resources/Public/audio/orz_audio.wasm`（~4.5MB）
- **JS 胶水：** `Resources/Public/audio/orz_audio.js`
- **包含库：**
  - libopenmpt 0.8.0
  - Game Music Emu 0.6.3
  - libsidplayfp 3.0.2
  - libsc68 (photonstorm)
  - ASAP
  - adplug + libbinio
  - v2m-player
  - ym6_impl.c (YM2149 内嵌仿真)
  - UAE Amiga 500 仿真核心（2MB 生成 CPU 表）

---

## 播放流程

```
浏览器请求 /api/songs/:id/stream
  ↓
SongController.stream()
  ↓
AudioEngine.resolveStreamStrategy()
  ├─ directFile  → 直接返回原始文件
  ├─ wasmDecode  → 返回原始文件，浏览器端 WASM 解码
  └─ serverDecode → 服务端解码为 WAV
```

浏览器端 WASM 解码流程：
```
fetch → ArrayBuffer → orz_load(format, data, len)
  → orz_render(out, frames) → AudioContext.play()
```
