# 播放页全息声场与当前曲目定位实施计划

> 状态：待实施
>
> 最后更新：2026-07-22
>
> 适用模型：GPT-5.5、GPT-5.4、DeepSeek V4 Flash 等低成本编码模型

本文是播放页“全息声场”实时音波和“定位正在播放”功能的单一事实来源。任务按依赖顺序拆成小范围改动，后续每次只领取一个任务编号，不把相邻任务合并执行。

## 1. 目标与范围

本轮交付：

- 在底部播放栏上方增加可展开、可折叠的独立全息声场面板。
- 使用真实音频分析数据绘制镜像频谱、连续光带、峰值粒子和轻量余辉。
- 为当前曲目增加“定位”入口；必要时清除筛选、直接加载目标页并滚动高亮。
- 保持 `directFile`、`wasmDecode`、`serverDecode` 三种播放策略、队列、音量、暂停、切歌和 seek 行为不变。

本轮不包含：

- 收藏、账号、用户隔离或数据库迁移。
- WebGL、第三方可视化/动画库、音频数据上传或持久化。
- 播放队列持久化、播放顺序或搜索 API 重设计。
- 根据效果图重做整个页面布局；效果图只约束音波面板和定位入口的视觉方向。

## 2. 已锁定的设计

### 2.1 全息声场

- 面板是播放栏上方的独立圆角浮层，不作为播放栏背景，不遮挡曲目列表。
- 首次开始播放时默认展开；用户可以折叠为紧凑按钮，刷新页面后恢复默认状态。
- 动画由四层组成：中心上下镜像频谱、后方连续时域光带、稀疏峰值粒子、半透明余辉。
- 色彩以品牌绿 `#39e58c` 为主，允许青、紫、橙黄作为频段过渡色。
- 采用 Canvas 2D；桌面显示完整效果，移动端减少采样柱和粒子数量。
- 暂停后能量平滑衰减并停止循环；折叠、页面隐藏、无曲目时不持续请求动画帧。
- `prefers-reduced-motion` 下只显示静态或低频刷新的低亮度频谱。
- 可视化失败只隐藏面板并记录控制台警告，绝不能阻断播放。

### 2.2 当前曲目定位

- “定位”按钮位于底部当前曲目信息旁；无当前曲目时禁用。
- 曲目已在 DOM 中时直接平滑滚动、聚焦并短暂脉冲高亮。
- 曲目不在当前结果中时，清空搜索与格式筛选，调用位置接口，直接加载所在页后定位。
- 定位不暂停播放、不改变当前时间、不改队列。
- 远程定位失败时恢复操作前的搜索词、格式筛选、页码、歌曲列表和分页状态，并显示 toast。

## 3. 接口与实现约束

### 3.1 曲目位置接口

新增：

```http
GET /api/songs/:id/location?per=50
```

成功响应：

```json
{
  "songId": "00000000-0000-0000-0000-000000000000",
  "index": 74,
  "page": 2,
  "per": 50
}
```

- `index` 为全部曲目默认排序中的零基位置；`page` 为一基页码。
- `per` 必须是整数 `1...100`；缺省为 `50`，无效值返回 `400`。
- 未知或格式错误的曲目 ID 返回 `404`。
- `/api/songs` 与位置接口统一使用 `createdAt DESC, id DESC`，不得各自复制不同排序规则。
- 不改变现有 `/api/songs` 响应结构。

### 3.2 浏览器音频图

目标链路：

```text
音频源 -> AnalyserNode -> masterGain -> AudioContext.destination
```

- WASM、AudioWorklet、AudioBufferSource 路径继续通过 `_outputNode()` 接入；其返回值改为共享分析器。
- `<audio>` 直放路径只创建一次 `MediaElementAudioSourceNode`，并复用同一分析器。
- `AnalyserNode` 只连接一次 `masterGain`，`masterGain` 只连接一次 destination。
- 直放成功接入 Web Audio 后由 `masterGain` 控制音量，避免同时衰减 `audioEl.volume`；若接入失败则保留原生 `<audio>` 音量作为回退。
- 提供只读 `getAnalyser()`，返回可用分析器或 `null`；UI 不直接操作音频节点连接。
- 不在构造器中创建 `AudioContext`，仍只在用户触发播放后初始化。

### 3.3 前端职责边界

- `player.js` 只负责音频图、播放和暴露分析器，不绘制 Canvas。
- 新增 `visualizer.js`，只负责采样转换、绘制和动画生命周期，不发请求、不控制播放。
- `app.js` 管理 Alpine 状态、定位流程和可视化组件启停。
- `player.leaf` 只声明面板、Canvas、控制按钮和可定位的曲目行标记。
- `app.css` 负责桌面、移动端、折叠态、定位高亮和 reduced-motion 样式。

## 4. 实施任务清单

| ID | 状态 | 任务 | 依赖 | 建议模型 |
|:---|:-----|:-----|:-----|:---------|
| PVL01 | 完成 | 增加稳定排序和曲目位置接口 | 无 | GPT-5.4 / DeepSeek V4 Flash |
| PVL02 | 完成 | 实现前端当前曲目定位流程 | PVL01 | GPT-5.4 / GPT-5.5 |
| PVL03 | 完成 | 统一浏览器音频分析链路 | 无 | GPT-5.5 |
| PVL04 | 完成 | 建立可视化纯函数与 Canvas 基础组件 | PVL03 | GPT-5.4 / GPT-5.5 |
| PVL05 | 完成 | 接入镜像频谱和连续光带 | PVL04 | GPT-5.4 / DeepSeek V4 Flash |
| PVL06 | 完成 | 增加峰值粒子、余辉和模式切换 | PVL05 | GPT-5.4 / DeepSeek V4 Flash |
| PVL07 | 完成 | 完成页面面板与桌面视觉样式 | PVL04 | GPT-5.4 / DeepSeek V4 Flash |
| PVL08 | 完成 | 完成移动端、无障碍和生命周期降级 | PVL05、PVL06、PVL07 | GPT-5.4 / GPT-5.5 |
| PVL09 | 完成 | 完整回归、验收和文档收口 | PVL02、PVL03、PVL08 | GPT-5.5 |

### PVL01：增加稳定排序和曲目位置接口

**目标**：后端能用一次请求返回曲目在默认资料库排序中的准确页码。

**允许改动**：`Sources/App/Controllers/SongController.swift`、`Tests/AppTests/AppTests.swift`。不要修改模型、迁移、播放列表或搜索语义。

**固定实现**：在 `SongController` 内建立一个被 `index` 和 `location` 共用的默认排序方法；顺序固定为 `createdAt DESC, id DESC`。注册 `GET /api/songs/:id/location`，DTO 字段严格为 `songId/index/page/per`。位置计算可以读取按默认顺序排列的 ID 列表后查找目标，首版优先正确性，不引入数据库方言专用 SQL。

**必须测试**：第一首、`per` 分页边界、最后一页、相同 `createdAt` 的稳定顺序、未知 ID、`per=0`、`per=101`、非数字 `per`，以及响应页确实能从 `/api/songs?page=...&per=...` 找到目标。

**验收命令**：

```bash
swift test --filter AppTests
```

**提交建议**：`feat(PVL01): add song location endpoint`

### PVL02：实现前端当前曲目定位流程

**目标**：定位按钮能够在当前列表或远程分页中找到正在播放的曲目。

**允许改动**：`Resources/Views/player.leaf`、`Resources/Public/audio/app.js`、`Resources/Public/audio/app.css`、一个新的 `Tests/Browser/ui-location.test.mjs`。不要修改播放器音频节点或后端。

**固定实现**：为曲目行增加 `data-song-id`；新增 `locateCurrentSong()`、`scrollToSong(id)` 和加载指定页的 `loadSongPage(page)`。本地命中时不得发位置请求。远程定位前复制搜索、格式、页码、歌曲数组、总数和 `hasMore`；失败时完整恢复。成功时清除筛选、请求位置、加载目标页、等待 Alpine 更新后滚动和聚焦。重复点击期间禁用按钮。

**视觉要求**：按钮文字为“定位”；成功定位行增加约 1.2 秒脉冲描边，不改变现有 `.active` 播放高亮。

**必须测试**：本地命中不请求接口；远程定位使用返回页码；清除筛选；失败恢复快照；无当前曲目无操作；定位不调用播放、暂停或队列方法。

**验收命令**：

```bash
node --test Tests/Browser/ui-location.test.mjs Tests/Browser/ui-shortcuts.test.mjs
```

**提交建议**：`feat(PVL02): locate current song in library`

### PVL03：统一浏览器音频分析链路

**目标**：三种播放策略均能安全提供同一个 `AnalyserNode`，且不改变听感和控制行为。

**允许改动**：`Resources/Public/audio/player.js`、`Tests/Browser/player-switch.test.mjs`。不要增加 UI、Canvas 或依赖。

**固定实现**：增加 `analyser`、`mediaElementSource` 和连接状态字段；实现幂等的音频图初始化；`_outputNode()` 返回 analyser；新增 `getAnalyser()`。直放路径在用户播放调用内尝试创建/恢复 `AudioContext` 并绑定媒体元素。任何 `createAnalyser` 或 `createMediaElementSource` 失败都回到当前原生播放路径。

**必须测试**：重复切歌只创建一次媒体元素源；所有 Web Audio source 连接同一 analyser；analyser/masterGain/destination 各只连接一次；音量不发生双重衰减；缺少 `createAnalyser`、缺少 `createMediaElementSource` 和抛异常时仍能播放；现有切歌、seek、暂停测试保持通过。

**验收命令**：

```bash
node --test Tests/Browser/player-switch.test.mjs Tests/Browser/decoder-wasm.test.mjs
```

**风险**：这是本计划风险最高的任务。若 mock 与真实浏览器行为不一致，停止并报告，不顺手修改 UI 或解码器。

**提交建议**：`refactor(PVL03): expose shared audio analyser`

### PVL04：建立可视化纯函数与 Canvas 基础组件

**目标**：提供可独立测试、尚未追求最终特效的可视化组件骨架。

**允许改动**：新增 `Resources/Public/audio/visualizer.js` 和 `Tests/Browser/visualizer.test.mjs`；只在 `player.leaf` 增加脚本引用。不要修改音频图和最终 CSS。

**固定接口**：导出 `OrzAudioVisualizer` 类和可单测的 `normalizeBins`、`buildMirroredBars`、`buildWavePoints`。类只接受 `{canvas, analyser, reducedMotion}`，提供 `start()`、`stop()`、`resize()`、`setMode(mode)`、`destroy()`；重复调用必须幂等。首版只画低亮度占位频谱。

**必须测试**：空数据、全零数据、极值钳制、镜像对称、不同 Canvas 尺寸、重复 start/stop、destroy 后取消动画帧、缺少 analyser 时安全退出。

**验收命令**：

```bash
node --test Tests/Browser/visualizer.test.mjs
```

**提交建议**：`feat(PVL04): add visualizer canvas foundation`

### PVL05：接入镜像频谱和连续光带

**目标**：从真实频域与时域采样绘制效果图中的主体动画。

**允许改动**：`visualizer.js`、`visualizer.test.mjs`。不要改页面布局或音频图。

**固定实现**：频域数据经平滑和对数分组生成中心上下镜像柱；时域数据生成后方连续曲线；颜色按横向位置在绿、青、紫、橙黄之间插值。不得每帧创建随柱数线性增长的大对象数组；优先复用 typed array 和缓存。

**必须测试**：固定输入产生确定的柱高与波形点；静音输入逐步衰减；尺寸变化后坐标有效；颜色插值输出合法；单帧函数不依赖 DOM 全局对象。

**验收命令**：

```bash
node --test Tests/Browser/visualizer.test.mjs
```

**提交建议**：`feat(PVL05): render mirrored audio spectrum`

### PVL06：增加峰值粒子、余辉和模式切换

**目标**：补齐全息声场的动态层次，同时保留低性能模式。

**允许改动**：`visualizer.js`、`visualizer.test.mjs`。不要修改 Alpine、HTML 或播放器。

**固定实现**：只在频段能量越过动态阈值时生成粒子；限制桌面粒子总数和单帧新增数，移动/简化模式使用更低上限；粒子按固定寿命回收。模式固定为 `holographic` 与 `spectrum` 两种，未知模式回退 `holographic`。余辉使用半透明清屏，不无限累积亮度。

**必须测试**：阈值以下不生成粒子、上限不突破、寿命结束会回收、模式切换清理不兼容缓存、未知模式回退、静音后能停止刷新。

**验收命令**：

```bash
node --test Tests/Browser/visualizer.test.mjs
```

**提交建议**：`feat(PVL06): add holographic visualizer effects`

### PVL07：完成页面面板与桌面视觉样式

**目标**：把 Canvas 组件装入播放栏上方的可折叠独立面板。

**允许改动**：`player.leaf`、`app.js`、`app.css`、`Tests/Browser/ui-cloak.test.mjs`。不要改 `player.js` 或绘图算法。

**固定实现**：增加 `visualizerOpen`、`visualizerMode` 和组件引用；首次成功播放时展开；折叠后保留一个有明确 `aria-label` 的展开按钮；提供模式切换和折叠按钮。面板高度由 CSS 变量控制，展开时同步增加 `.main-content` 底部空间，不能盖住最后几行曲目。脚本加载顺序固定为 `player.js`、`visualizer.js`、`app.js`。

**必须测试**：`x-cloak` 防闪烁；无曲目不展示展开面板；首次播放展开；折叠停止组件；再次展开恢复；切歌复用组件而非新增 Canvas；按钮有可访问名称。

**验收命令**：

```bash
node --test Tests/Browser/ui-cloak.test.mjs Tests/Browser/ui-shortcuts.test.mjs
```

**提交建议**：`feat(PVL07): mount visualizer panel in player UI`

### PVL08：完成移动端、无障碍和生命周期降级

**目标**：可视化在低性能与辅助功能场景下可控、不会后台耗电。

**允许改动**：`visualizer.js`、`app.js`、`app.css`、相关 Browser 测试。不要改变后端或音频图。

**固定实现**：小于 `720px` 时降低面板高度、频谱柱数和粒子上限；监听 `visibilitychange`、`resize` 和 reduced-motion media query；隐藏、折叠、无曲目、暂停能量归零后停止 RAF；恢复条件满足时只启动一个 RAF。Canvas 标记为装饰性，不进入键盘焦点；所有控制按钮保留可见焦点环。

**必须测试**：可见性切换、媒体查询变化、移动端配置、暂停衰减、重复恢复不产生多个 RAF、destroy 移除监听器。检查现有 `@media(prefers-reduced-motion:reduce)` 不被破坏。

**验收命令**：

```bash
node --test Tests/Browser/*.test.mjs
```

**提交建议**：`fix(PVL08): harden visualizer lifecycle and accessibility`

### PVL09：完整回归、验收和文档收口

**目标**：确认两项功能达到交付标准，并留下可重复验收记录。

**允许改动**：本文件状态/验收记录、必要的聚焦测试修正。不要在此任务新增功能、改视觉方向或重构播放代码。

**固定验收**：运行全部 Swift 与 Browser 测试；人工验证桌面和移动宽度；各抽测一种 `directFile`、`wasmDecode`、`serverDecode` 曲目；验证切歌、暂停、seek、音量、队列、筛选、搜索和定位。开发者工具确认折叠或切到后台后没有持续 RAF，切歌后没有重复音频连接或音量叠加。

**验收命令**：

```bash
swift test
node --test Tests/Browser/*.test.mjs
```

**记录要求**：在本文“验收记录”中写明日期、commit、通过命令、人工抽测格式、已知限制；将 PVL01–PVL09 状态更新为完成或明确保留项。

**提交建议**：`test(PVL09): complete player feature regression`

## 5. 低成本模型执行模板

领取任务时，将下面整段与对应任务小节一起交给执行模型：

```text
请领取 Docs/backlog/player-visualizer-location-plan.md 中的任务 <PVL编号>。

执行规则：
1. 先完整阅读 AGENTS.md、本计划的第 1–3 节、任务总表和指定任务小节。
2. 只修改“允许改动”列出的文件；发现必须越界时停止并报告，不自行扩大范围。
3. 开始前运行 git status --short，保留用户已有的无关改动。
4. 严格采用任务中写明的固定接口、状态名、错误语义和降级方式，不重新设计方案。
5. 先阅读现有实现和相邻测试，再修改代码；不得删除或弱化现有断言来让测试通过。
6. 运行任务指定的验收命令。若因环境依赖无法运行，报告准确命令和错误，不猜测通过。
7. 完成后只报告：改动文件、行为变化、测试结果、遗留风险、是否满足任务完成定义。
8. 不执行 git commit、push、发布或部署，除非主协调者另行明确要求。
```

模型选择建议：

- DeepSeek V4 Flash：优先领取纯后端 DTO/测试、纯绘图算法、CSS 和文档收口任务。
- GPT-5.4：优先领取前端状态编排、Canvas 组件和响应式适配任务。
- GPT-5.5：优先领取 PVL03 音频图重构、PVL08 生命周期收口和 PVL09 综合回归。
- 如果模型在同一任务中连续两次无法通过聚焦测试，停止继续试错，交回主协调者处理。

## 6. 各任务统一完成定义

一个任务只有同时满足以下条件才可标记“完成”：

- 没有超出任务允许改动范围。
- 任务规定的正向、失败和降级测试均已增加且通过。
- 原有相关测试未被删除、跳过或放宽。
- 没有新增依赖、数据库迁移、账号或收藏逻辑。
- 没有遗留调试日志、定时器、重复事件监听或未释放的动画帧。
- 对外接口、DOM 可访问名称和错误提示符合本文约定。
- 验收结果已写入下面的记录区。

## 7. 验收记录

| 日期 | 任务 | Commit | 自动验证 | 人工验证 | 备注 |
|:-----|:-----|:-------|:---------|:---------|:-----|
| — | — | — | — | — | — |
| 2026-07-23 | PVL01–PVL09 | 本提交 | `swift test`：53/53；`node --test Tests/Browser/*.test.mjs`：57/57；`git diff --check` | 桌面 1280px、移动 390px；MP3 `directFile`、YM `wasmDecode`、SC68 `serverDecode`；筛选后定位、暂停衰减、折叠与移动端避让 | Swift 首次构建需为 Clang/SwiftPM 指定可写临时模块缓存；SC68 真实样本持续播放至 3:00 时长，进度与音波正常 |
