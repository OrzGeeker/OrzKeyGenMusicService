# OrzAudioCore SDK

OrzAudioCore 是 OrzMusic 下沉的跨平台解码边界。SDK 只负责格式探测、元数据、subsong/seek 和 PCM 解码；播放设备、队列、HTTP、CAS 与 WAV 缓存仍属于应用层。

## 稳定接口

公共 ABI 位于 `orz_audio_core.h`，当前 ABI 为 1.0。所有公共结构都包含 `struct_size` 与 `abi_version`；调用端必须先填写这两个字段。ABI major 不一致时返回 `ORZ_ERROR_ABI_MISMATCH`。

句柄拥有创建后仍需使用的输入字节，因此调用端在 `orz_decoder_create_memory` 返回后即可释放输入。不同句柄可以并行，同一句柄由调用端串行访问。PCM 输出为 decoder 原生采样率、interleaved float32，SDK 不做隐式重采样。

旧的 `orz_load/orz_render` 和早期 handle API 只作为一个迁移周期的兼容入口。新代码必须使用 `orz_decoder_create_memory`、`orz_decoder_get_stream_info` 和 `orz_decoder_render_f32`。

## 能力与版本

`decoder-manifest.json` 是 decoder ID、版本、分类、profile 和导航能力的单一数据源。manifest 由 OrzAudioCore 独立仓库管理。

`orz_build_info()` 返回 SDK semver、ABI 和缓存 fingerprint；OrzMusic 服务端把 fingerprint 写入 PCM WAV 缓存键。

播放策略不属于 SDK。`directFile/wasmDecode/serverDecode` 由 OrzMusic 根据浏览器能力和性能要求决定。

## 构建与消费

OrzAudioCore 的 CMake 构建、WASM 编译和 SDK 打包在独立仓库 [OrzGeeker/OrzAudioCore](https://github.com/OrzGeeker/OrzAudioCore) 中完成。OrzMusic 通过 Release artifacts 消费已发布的 SDK：

```bash
# 安装/更新服务端 SDK
./script/update-audio-core-server.sh

# 安装/更新 Web WASM SDK
./script/update-audio-core-web.sh

# Swift Package 产品
swift build --product OrzAudioCore
```

`orz_build_info()` 返回的 SDK fingerprint 由 OrzMusic 写入 PCM WAV 缓存键，升级 SDK 后旧缓存自动失效。CMake 输出 `OrzAudioCore::OrzAudioCore` target；Swift 使用 `AudioDecoder`。

## 发布规则

- ABI 破坏性修改：major。
- 新格式、能力或向后兼容字段：minor。
- decoder 修复：patch。
- OrzMusic 通过 `audio-core-sdk.lock.json` 固定依赖 SDK 版本；升级后旧缓存因 fingerprint 变化自动失效，可通过依赖版本直接回滚。
