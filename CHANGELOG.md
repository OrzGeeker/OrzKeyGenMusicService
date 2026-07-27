# Changelog

## [未发布]

### 修复
- 修正生产 Compose 覆盖配置中 scanner 服务丢失音乐源目录挂载的问题。
- 新增生产扫描脚本和部署包内 `make scan` 入口，支持
  `MUSIC_DIR=/absolute/path/to/music make scan` 一键临时启动 scanner 并触发扫描。
- 更新生产部署文档，明确扫描时宿主机路径与容器内 `/sources/keygen` 的对应关系。

## [0.0.4] — 2026-07-27

### 修复
- 修正 `GET /api/songs/:id/location` 的位置计算：改为使用与列表接口一致的
  `ROW_NUMBER() OVER (ORDER BY created_at DESC, id DESC)` 计算位置，避免
  SQLite 测试环境中直接比较绑定时间戳导致 index 偏移。

### 发布说明
- `v0.0.3` 已触发发布工作流，但在 Swift 测试阶段失败，未形成可用 Release 制品。
- `v0.0.4` 作为后续修复版本继续执行发布流程。

## [0.0.3] — 2026-07-27

### 新增
- GitHub Release 除 Docker 镜像外，新增轻量部署包
  `orzmusic-deploy-<version>.tar.gz`，生产机可不拉取完整仓库即可部署。
- 新增生产部署说明文档，明确部署包内容、首次部署、日常升级和回滚流程。
- 新增性能优化计划和任务拆分文档，便于后续按小粒度任务推进。

### 优化
- 优化初始加载和音频播放体验。
- 更新 OrzMusic 项目图标。
- 本机 ARM 主机默认使用 `linux/arm64` Docker 构建平台，避免 Apple Silicon 上
  amd64 模拟构建触发 Swift 依赖编译崩溃。
- Makefile 优先使用 PATH 中的 Docker CLI，提高不同本机 Docker 安装路径的兼容性。

### 修复
- 修正歌曲位置排序测试依赖随机 UUID 的问题，使用确定性 UUID 覆盖
  `createdAt DESC, id DESC` 次级排序，避免 Linux CI 偶发失败。
- 稳定播放状态图标显示，避免播放/暂停状态切换时图标表现不一致。

## [0.0.2] — 2026-07-23

### 修复
- 修正 Release workflow 的 GHCR 镜像名为全小写，避免 Docker buildx 拒绝 `ghcr.io/OrzGeeker/orzmusic`。

### 发布说明
- `v0.0.1` 已触发发布工作流但镜像构建阶段失败，未形成可用 Release 制品。
- `v0.0.2` 作为首个可用发布候选继续执行发布流程。

## [0.0.1] — 2026-07-23

### 新增
- 首次正式发布基础设施
- 版本单一来源：`VERSION` 文件 + `AppVersion` 结构（R01）
- 健康与版本接口：`GET /api/health`（R02）
- 镜像构建身份注入：`APP_VERSION` / `GIT_COMMIT` / `BUILD_TIME`（R03）
- Tag 发布工作流：推送 `vX.Y.Z` 标签自动构建、推送 GHCR、生成 Release（R04）
- 生产部署配置：`docker-compose.production.yml`（R05）
- 数据库备份命令：`make db-backup`（R06）
- 升级与回滚命令：`release-upgrade` / `release-rollback`（R07）
- 发布冒烟检查脚本：`release-smoke`（R08）
- 运维手册与演练计划（R09）

### 技术变更
- 迁移从 `swift:6.1-noble` 构建
- 运行时镜像基于 `swift:6.1-noble-slim`
- 正式镜像标签格式：`ghcr.io/<owner>/orzmusic:X.Y.Z`
