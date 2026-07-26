# 服务端边解码边响应评估

> 结论日期：2026-07-26  
> 目标环境：ARM64 单机、低并发个人/家庭曲库  
> 结论：保持“原子整曲 WAV 缓存 + 显式预热”；暂不替换生产 `/stream`。

## 当前证据

- PERF-002 的自然冷缓存 SC68 前两次请求在 30 秒内零字节并超时；缓存完成后同曲请求 TTFB 为 37.73 ms。
- 当前 fingerprint 的 12 个真实缓存：源文件合计 1,811,015 bytes，PCM WAV 合计 235,699,956 bytes，放大 130.15 倍。
- 7 个 SC68 样本各生成 31,752,044-byte、约 180 秒的 WAV；16-bit/44.1kHz/双声道 PCM 固定约 176,400 bytes/s（约 1.41 Mbps）。
- 选取一个 31,752,044-byte SC68 WAV 在本机 ARM64 重新压缩：

| 输出 | 大小 | 编码 wall time | 用户 CPU |
|:-----|-----:|---------------:|---------:|
| PCM WAV | 31,752,044 | 已缓存 | — |
| Opus 96 kbps | 1,945,305 | 1.79 s | 1.47 s |
| MP3 128 kbps | 2,881,035 | 2.25 s | 2.14 s |

压缩格式显著降低带宽和存储，但不会消除 SC68 自身冷解码瓶颈；若先整曲解码再压缩，反而增加等待。只有真正 pipeline 才可能改善首帧。

## 方案比较

| 方案 | 冷首帧 | 热 Range/seek | CPU/带宽 | 缓存与失败恢复 | 结论 |
|:-----|:-------|:-------------|:---------|:---------------|:-----|
| 原子整曲 WAV | 慢，解码完成后响应 | 最佳；Vapor 文件响应原生支持 206、ETag | 解码一次；PCM 约 1.41 Mbps | 临时文件完成后原子提交，最简单可靠 | 保留 |
| 预热整曲 WAV | 用户首帧接近热缓存 | 与当前完全相同 | 低峰消耗 CPU/磁盘 | 已由 PERF-016/017 提供幂等预热与容量治理 | 当前推荐 |
| 流式 PCM WAV | 可在首批 PCM 后响应 | 直播阶段不能稳定随机 Range；完成后才可恢复文件语义 | PCM 带宽高 | 需预测长度或使用兼容性不一的未知长度 header；tee 与断线恢复复杂 | 不实施 |
| 流式 Opus/MP3 | 理论首帧最佳、带宽低 | 浏览器可顺序播放，但未完成资源的任意 seek/Range 受限 | 增加实时编码 CPU | 解码、编码、广播、临时缓存四段错误与背压 | 仅保留隔离原型候选 |

## WAV header、chunked 与 Range

经典 RIFF/WAV header 在发送 PCM 前就需要 32-bit RIFF size 和 `data` size。OrzAudioCore 可在 decoder info 中给出 duration、sample rate、channels，但：

- duration 是估计值，实际 render frame 数可能不同；当前代码正是完成后回写 header。
- ffmpeg fallback 的最终 frame 数同样要到输出完成才可靠。
- 使用 `0xffffffff`、RF64 或未知长度 chunk 会改变格式/兼容性，必须逐浏览器验证，不能视为普通 WAV。
- HTTP chunked transfer 只解决 HTTP body 长度，不会自动修复 WAV 容器内声明长度。

流式进行时没有一个稳定、不可变的完整文件，无法正确响应任意 `Range`。若收到 seek，只能等待缓存完成、重新启动 decoder 到目标时间，或设计新的 session 协议；这都超出当前 `/stream` 的文件语义。

## 取消、single-flight 与 tee

当前整曲解码 Task 不隶属于某个 HTTP 等待者：一个请求取消不会破坏其他同 key 等待者需要的缓存。流式方案必须额外解决：

1. decoder 输出同时写临时缓存并广播给多个响应。
2. 慢客户端不能反压并阻塞全局 decoder；每个订阅者需要有界 buffer 与丢弃/断开策略。
3. 一个客户端断线时，若仍有等待者或需要完成缓存，应继续；最后一个订阅者离开时才评估 cancel。
4. C decoder handle 必须暴露给结构化任务，客户端/服务关闭时调用 `orz_decoder_cancel`；当前 `decodeToWAVFile` 的局部 handle 不支持请求级取消。
5. 只有 decoder 正常结束、header 最终化、fsync 和原子 move 后，缓存才可标为有效。任何中途错误都只能删除临时文件，不能把截断流当 cache hit。
6. 压缩 pipeline 还要区分 decoder error、encoder error、客户端断线和缓存写失败；向客户端已发送 200 后无法改写 HTTP 状态。

这些不是简单把 `Response.Body` 改为 chunked 就能满足的条件。

## ARM64 单机决策

单机默认 `SERVER_DECODE_CONCURRENCY=1` 已限制冷解码资源竞争。对低并发曲库：

- 预热把几十秒 SC68 成本移到低峰，用户请求维持标准文件、Range 和缓存行为。
- PERF-017 可报告/约束 130 倍 WAV 放大，避免无限增长。
- Opus/MP3 能把一个 31.75 MB WAV 降到约 1.95/2.88 MB，但还需约 1.5～2.1 CPU 秒；当前主要问题是冷 SC68 解码而非局域网热传输。
- 引入实时广播和流式缓存的正确性成本明显高于单机低并发收益。

因此生产决策是继续使用预热缓存，不实现流式 endpoint。

## 重新启动实现的门槛

只有以下条件全部成立才创建隔离原型：

- PERF-018 在目标设备/真实网络证明预热后仍有不可接受的 P95 首帧。
- 热缓存传输带宽而非冷解码成为主要瓶颈。
- 至少一个目标格式能在 500 ms 内稳定产出首批 PCM，并可响应结构化 cancel。
- 原型通过双客户端、慢客户端、快速断线、decoder/encoder 失败、缓存写满、进程终止和 seek 行为测试。
- 明确选择新的媒体 endpoint/协议，不悄悄改变现有可 Range WAV URL。

当前证据不满足门槛，本任务只形成决策，不改生产 endpoint。
