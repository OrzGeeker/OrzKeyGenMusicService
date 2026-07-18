# OrzAudioCore 独立仓库迁移清单

正式仓库：<https://github.com/OrzGeeker/OrzAudioCore>

独立仓库已于 2026-07-18 建立 `main`，初始 SDK 提交为 `5fe6d07`。

当前稳定版本为 `v1.0.0`。OrzMusic 通过根目录
`audio-core-sdk.lock.json` 固定 Web builtin-lite 制品、提交与 SHA-256；更新时运行
`script/update-audio-core-web.sh`。同一锁文件也固定 Linux full/server 制品，使用
`script/update-audio-core-server.sh` 安装到被忽略的 `.audio-core-sdk/server` 目录，随后运行
`script/verify-audio-core-server-sdk.sh` 校验版本、ABI consumer 链接调用和公共导出符号。
Linux CI 会对锁定的 Release 制品执行同一套验证，防止应用升级到无法消费的 SDK 包。
设置 `ORZ_AUDIO_CORE_EXTERNAL=1` 时，SwiftPM 会让 `OrzAudioKit` 导入系统模块
`OrzAudioCoreSDK` 并链接 `.audio-core-sdk/server`，不再编译 `OrzAudioKitCXX`。
`OrzAudioCoreSmoke` 在 CI 中通过该模式创建 Decoder 并渲染有声 MIDI PCM。
生产 Dockerfile 已使用这一外部模式：构建阶段按 lock 下载并校验 full/server SDK，运行镜像
只复制 `libOrzAudioCore.so`、decoder manifest、SBOM 和许可证，通过 `LD_LIBRARY_PATH` 加载。
1.0.0 同时发布 Linux x86_64 与 arm64 full 制品。安装脚本根据目标环境的 `uname -m`
自动选择并校验对应 SDK，Docker 默认使用宿主/目标平台的原生 Swift 镜像，不要求 QEMU。
Linux 1.0.0 的最低运行基线为 Ubuntu 24.04（glibc 2.38），因此构建与运行镜像均使用 noble。
ARM 开发机可先运行 `docker build --target audio-core-smoke .`，快速验证真实 Linux arm64
动态链接、SDK 版本和 PCM 输出；完整 Vapor release 可在对应架构上原生构建。
本地开发暂以默认内嵌模式作为一个发布周期的回退路径。
CI 还会从音乐子模块选择 22 种格式的固定代表曲目，分别通过当前内嵌核心与锁定 SDK
渲染前 5 秒 float32 PCM。`script/verify-audio-core-pcm.sh` 对采样率、声道、帧数和
逐样本误差进行比较，并发布 `pcm-conformance.json`；THX 暂与 AHX 共用解码器但缺少独立样本。
SID 因芯片上电状态在独立进程间不保证逐样本确定性，使用帧结构、峰值和均方能量误差验证；
其余 21 种格式使用逐样本浮点误差阈值。
生产 Docker 构建已切换到外部 full SDK；SwiftPM 默认模式暂保留内嵌核心，供双轨验证和
一个发布周期内快速回退。PCM 报告通过并完成线上回归后，再删除内嵌源码与旧构建脚本。

当前仓库已经将 SDK 边界固定，迁移时应保留以下目录和文件：

- `Sources/OrzAudioKitCXX/`：核心、decoder 和公共 C ABI。
- `Sources/OrzAudioKit/`：官方 Swift binding；迁移后删除 OrzMusic 专用的兼容 facade。
- `SDK/Web/`：TypeScript binding 和 npm package。
- `decoder-manifest.json` 与 `script/generate-decoder-manifest.mjs`。
- `CMakeLists.txt`、`CMakePresets.json`、`cmake/` 和 SDK build/package scripts。
- `Tests/SDK/` 及从 `DecoderInvariantTests` 拆出的 PCM fixtures/conformance tests。
- 根 `LICENSE`、所有第三方 license 及 decoder 来源历史。

## 首个独立版本门禁

1. 在 macOS 与 Linux 运行 builtin-lite ABI、12 实例和 ASan/UBSan tests。
2. 构建 full macOS SDK、lite XCFramework 和 full/lite WASM。
3. 编译 Swift、TypeScript 和安装后 Linux CMake consumer。
4. 为相同 fixtures 生成旧内嵌核心与 SDK ABI v1 PCM 报告。
5. 运行 `package-sdk.sh`，校验 manifest、SBOM、license 和 checksum。
6. 发布 `1.0.0-rc.1`，OrzMusic 通过不可变 tag/checksum 固定依赖。

## OrzMusic 双轨期

- 双轨期不少于一个 release cycle。
- 每个 decoder 至少一个真实 fixture，整数路径比较 hash，浮点路径记录最大绝对误差。
- 持续验证连续切歌、seek、cancel、12 路并行和缓存失效。
- 只有当 SDK 可独立回滚且 PCM 报告达标后，才删除 OrzMusic 中的 decoder 源码、旧 ABI 和重复构建脚本。

Android/Windows 不阻塞 1.0；它们作为后续 minor release，不改变 C ABI major。

## 可重复导出

从 OrzMusic 工作树导出独立仓库内容：

```bash
./script/export-audio-core.sh /path/to/empty/OrzAudioCore
```

导出只包含核心 C/C++ 源码、官方 Swift/TypeScript binding、第三方头文件、
构建发布脚本、manifest、SDK 测试与文档。Vapor、CAS、播放器 UI 和旧 Swift
兼容 facade 不会进入独立仓库。导出目录应先通过 CMake 与 SwiftPM 测试，再
创建 tag 或发布制品。
