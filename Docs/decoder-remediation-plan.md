# 统一音频解码修复计划

目标：同一套 C/C++ 解码核心同时服务 native 与 WASM；浏览器端稳定流式播放；所有解码器的输出不依赖调用方的 render 分块大小；不引入 brew/apt 运行时依赖。

优先级说明：P0 会导致格式误判、错误音频、崩溃或无法实时播放；P1 影响性能、时序或生命周期；P2 是架构和体验优化。难度按 S/M/L/XL 标记。

## 已完成的第一批（P0/P1）

- [x] P0 / S：建立真实样本的 native 解码回归入口，并加入不同 render 分块的输出一致性测试。
- [x] P0 / S：移除 BP → AdPlug 的错误注册。当前 BP 明确返回不可解码，不再产生假成功或错误音频。
- [x] P1 / S：OpenMPT 改用 interleaved stereo API，去掉左右声道临时缓冲和二次交织拷贝。
- [x] P0 / S：ASAP 按源文件实际声道数生成 PCM；单声道在统一 ABI 边界复制为双声道。
- [x] P0 / M：AdPlug 使用连续采样时钟，只在 tick 边界调用 `update()`，保留不足一个 tick 的余量。
- [x] P0 / S：AHX 移除 wrapper 对 `tickReplayer()` 的重复调用，由 `paulaOutputSamples()` 在准确采样边界推进。
- [x] P0 / S：AHX 初始化顺序改为 `ahxInit → ahxLoadFromRAM`，并修正失败清理与重复销毁。

## 下一批：正确性优先

- [x] P0 / M：修复 AHX/Paula 重载污染。初始化时显式清空 `blep`、Paula voice 和音频状态；补丁同时进入 native/WASM 构建，并通过跨重载分块一致性测试。
- [x] P0 / L：重写 MIDI 时间线。
  - 格式 1 多轨事件按绝对 tick 全局稳定排序。
  - tempo 事件使用连续 tick 时钟，避免变速时播放位置跳变。
  - Note Off 按 channel+note 匹配；补齐 running status、VLQ、header/track/SysEx 边界检查。
  - duration 从完整 tempo map 积分计算，并添加多轨、变速、分块一致性和截断 VLQ 测试。
- [x] P0 / L：修复 YM5/YM6 解析与合成。
  - 按规范解析 `LeOnArD!` header、interleaved 属性、extra data、digidrum、字符串和帧数据偏移。
  - 使用文件内 master clock/frame rate 和 YM2149 tone/noise/envelope 分频关系。
  - 内置 level-0 LH5 解压，native/WASM 可直接播放仓库真实压缩 YM，移除服务端和构建阶段的系统 `lha` 依赖。
  - 添加两种帧布局、时长、分块一致性、截断元数据和真实压缩样本测试。
- [x] P0 / M：统一 ABI 输入上下限和 render 乘法溢出保护；全后端 tiny/truncated/oversized corpus、MIDI VLQ、YM metadata、BP section 边界均失败闭合且无崩溃。

## 第三批：结束条件、时长与生命周期

- [x] P1 / M：扩展 Decoder ABI：解码生命周期使用实例句柄，消除服务端解码请求之间的全局单例与静态状态串扰。
  - [x] 增加兼容式 `OrzDecoderHandle` API，保留旧入口。
  - [x] OpenMPT 迁移为真正的实例上下文，并覆盖双实例交错渲染测试。
  - [x] GME、ASAP、SID、AdPlug、V2M、YM、MIDI 全部迁移为独立上下文。
  - [x] AHX 核心可变全局改为线程局部状态，并通过可复现补丁在 native/WASM 构建中保存、恢复每个 handle 的 Paula/replayer 快照。
  - [x] SC68 因上游 libsc68 API 只允许单核心实例，在创建阶段串行物化最多 3 秒 PCM；创建后的 handle 完全独立且可并发 render。后续核心替换仍归入下方 SC68 性能任务。
  - [x] Swift `CDecoderBridge` 移除全局串行队列，服务端每个请求直接持有独立 handle；12 路 Swift 并发解码及全后端并发 render 无串扰。
  - [x] 浏览器播放器切换到 `orz_decoder_*` handle API；重建 WASM，并通过 Node 双 handle 同时创建/渲染 smoke test。
- [x] P1 / M：GME 使用 metadata/play-length、标准 8 秒 fade 和 `gme_track_ended()`，NSF/SPC 不再无限输出。
- [x] P1 / M：SID 保存 fractional cycle 余数，并用固定生成量子 FIFO 解耦 CPU 批次与 render block；PSID/RSID 本身没有时长，当前明确采用 180 秒播放策略上限，后续可接 Songlengths 数据库替换。
- [x] P1 / M：V2M 直接使用 `Length()`、`IsPlaying()` 和精确输出帧上限，移除“文件较大且小于 5 秒就伪造 120 秒”的启发式。
- [x] P1 / M：SC68 建立性能基准（load、首帧、实时倍速、指令热点），结论记录于 `Docs/sc68-performance.md`：
  - 优先裁剪 libsc68 非播放功能、优化编译参数和批量执行；
  - 若仍不能在中低端浏览器达到稳定 >1.5x realtime，再评估 Musashi/Cyclone 等 68k 核的适配成本；
  - native 与 WASM 保持相同高层 SC68/IO/混音逻辑；当前实测 2375.8× realtime，无需引入第二 CPU core。
- [x] P1 / S：修正静态库部署目标。构建脚本固定并验证 macOS 13 minos，清理旧对象后重建；老 libtool 不稳定的 libbinio 使用确定性的直接归档回退。

## 第四批：BP 与服务端音频管线

- [x] P0 / M：收集并分类 BP 样本，确认 Brian Postma SoundMon V.2/V.3、端序及 section 布局，记录于 `Docs/soundmon-bp-format.md`；不再错误回退 AdPlug。
- [x] P0 / XL：实现 BP/SoundMon V.2 解码器：严格 parser、4 声道 Paula sample/synthetic waveform、ADSR/LFO/EG、effect 0–9、float32 stereo 与实例 ABI；通过 4 个真实样本分块/畸形测试。未验证的 V.3 明确拒绝，不做有风险的 V.2 兼容猜测。
- [x] P1 / M：WAV 使用 RIFF chunk walker，支持非 44-byte header、扩展 fmt、LIST/JUNK、奇数字节 padding 和 data 对齐；明确区分 PCM/float/ADPCM。
- [x] P1 / S：PCM/IEEE-float WAV 直接交给浏览器，只有 ADPCM/GSM 等压缩 WAV 才走服务端解码。
- [x] P1 / S：WAV 缓存使用原子落盘、读取前结构校验，并在缓存键加入 decoder version，避免半文件和旧解码结果复用。
- [x] P1 / M：C 解码器以固定 4096-frame 缓冲边解码、边量化、边写临时 WAV，结束后回填 RIFF/data 长度并原子提交；失败不会留下目标文件。
- [x] P1 / M：AVFoundation 逐 CMSampleBuffer 写 WAV；Linux/模块回退由 ffmpeg 直接写同目录临时缓存，校验后原子提交，不再把转码结果重新读回 `Data`。
- [x] P2 / S：实例 ABI 增加 subsong/seek 导航（OpenMPT 首个实现），Swift/HTTP 接受 subsong；缓存 v3 键显式包含 rate/channels 策略与 subsong，浏览器 Worker 支持 seek 后清空 ring 重填。

## 第五批：浏览器实时播放

- [x] P1 / L：WASM 解码移入 Worker；AudioWorklet 只消费 SharedArrayBuffer ring buffer，主线程不再参与隔离环境下的同步解码，并保留兼容降级路径。
- [x] P1 / M：加入 150ms 启播水位、500ms ring、欠载计数、背压、generation 丢弃与实例 seek API；支持导航的解码器可原位 seek 并清空 ring 重填。
- [x] P1 / L：按格式延迟加载：BP/MIDI/YM 使用 40,792-byte dependency-free bundle，其余格式使用 full bundle；两者共享同一 Worker/handle 协议。
- [x] P2 / M：首帧延迟、实时倍速、ring 内存峰值、缓冲上限和 underrun 暴露为 `player.diagnostics` 开发指标。

## 验收门槛

- 每种格式至少一个合法样本、一个截断/畸形样本；关键格式包含多版本样本。
- 127、128、512、4096 frames 分块输出一致（允许有明确记录的量化抖动误差）。
- native 与 WASM 前 10 秒 PCM hash/误差对齐。
- 浏览器连续播放 10 分钟无 underrun；目标机器解码速度至少 1.5x realtime，SC68 单独报告。
- AddressSanitizer/UndefinedBehaviorSanitizer 跑 parser corpus 无错误。

## 最终验证结果

- 常规 native/Swift 回归：51 tests，0 failures。
- AddressSanitizer：tiny/truncated/oversized 全后端输入、BP section 边界、MIDI VLQ、YM metadata、WAV chunk 边界共 5 tests，0 failures，0 sanitizer diagnostics。
- UndefinedBehaviorSanitizer：同一 parser corpus 共 5 tests，0 failures，0 sanitizer diagnostics。
- WASM：full 与 40KB builtin bundle 均完成 Node smoke；BP 双 handle、SC68 完整物化通过。
- 浏览器：cross-origin isolated、Worker、SharedArrayBuffer、AudioWorklet 均实际创建；BP 首批 PCM 约 20.9ms，初始 underrun 为 0。
