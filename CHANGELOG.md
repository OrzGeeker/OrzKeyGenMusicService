# Changelog

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
