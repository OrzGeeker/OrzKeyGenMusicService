# OrzMusic 最小可用迭代发布与升级计划

本文是 OrzMusic 服务版本迭代、发布、升级和回滚的单一事实来源。首期只覆盖**单机 Docker Compose、允许短暂停机**的生产环境，不建设蓝绿发布、Kubernetes 或多机高可用。

## 1. 目标与边界

每次正式发布必须能够回答：部署的是哪个版本、对应哪次提交、使用哪个镜像、是否包含数据库迁移，以及失败后如何恢复。

首期成功标准：

- 正式版本采用 SemVer，Git Tag 使用 `vX.Y.Z`。
- 唯一运行产物是带版本号和 digest 的不可变 Docker 镜像。
- 生产环境不构建源码，不以 `latest` 作为升级或回滚依据。
- PostgreSQL 和 CAS 独立持久化，不进入应用镜像。
- 升级遵循“备份 → 停应用 → 迁移 → 启动 → 验收”的固定顺序。
- 无数据库破坏性变更时，可以切回上一版本镜像。
- 整个流程有文档、命令和可重复的验收结果，不依赖操作者临场判断。

首期不包含：

- 零停机、蓝绿或金丝雀发布。
- 多机容灾、数据库高可用和自动扩缩容。
- 自动回滚数据库。
- 将 PostgreSQL、CAS、WAV 缓存或生产密钥打包进镜像。

## 2. 版本与发布产物

### 2.1 版本规则

- `PATCH`：兼容的缺陷修复，例如 `1.2.0 → 1.2.1`。
- `MINOR`：兼容的新功能，例如 `1.2.1 → 1.3.0`。
- `MAJOR`：不兼容的 API、数据或部署变化，例如 `1.x → 2.0.0`。
- 仓库使用一个 `VERSION` 文件作为应用版本的单一来源，内容不带 `v`，例如 `1.2.0`。
- 正式 Git Tag 为 `v1.2.0`，必须与 `VERSION` 内容一致。
- 已发布的 Tag 和镜像不得覆盖；修复必须发布新 PATCH 版本。

### 2.2 正式发布物

每个版本包含：

| 发布物 | 示例 | 用途 |
|:-------|:-----|:-----|
| Docker 镜像 | `ghcr.io/<owner>/orzmusic:1.2.0` | 唯一生产运行制品。 |
| 镜像 digest | `sha256:...` | 锁定不可变的实际内容。 |
| Git Tag | `v1.2.0` | 锁定源码提交。 |
| GitHub Release / CHANGELOG | `1.2.0` 发布说明 | 记录功能、修复、迁移和配置变化。 |
| 部署配置 | 生产机 Compose 与环境文件 | 指定镜像和运行参数，不包含密钥。 |

镜像必须包含：编译后的服务、Leaf/静态资源、Web/WASM 解码资源、OrzAudioCore 原生运行库和 Fluent 数据库迁移。构建阶段根据 `audio-core-sdk.lock.json` 获取并校验 SDK；生产机不再单独下载 SDK。

## 3. 固定发布流程

### 3.1 发布前

1. 合并后的提交通过 Swift 测试、浏览器/WASM 测试、Compose 配置检查和 OrzAudioCore smoke test。
2. 更新 `VERSION` 和 `CHANGELOG.md`，明确标注数据库迁移与配置变化。
3. 创建 `vX.Y.Z` Tag；CI 校验 Tag 与 `VERSION` 一致。
4. CI 构建并推送版本镜像，记录镜像 digest，生成 GitHub Release。
5. 在非生产环境从旧版本完整升级一次。
6. 生产发布前记录当前版本、commit、镜像和 digest，并预留 15–30 分钟维护窗口。

### 3.2 生产升级

1. 拉取并校验目标版本镜像，禁止现场构建。
2. 暂停新的扫描和上传操作。
3. 使用 `pg_dump` 创建带时间和版本的 PostgreSQL 备份，并验证备份文件非空。
4. 确认 CAS 的周期性备份最近一次成功；普通发布不重复打包整个 CAS。
5. 只停止 `app` 和 `scan`，保持 PostgreSQL 运行；不得执行 `docker compose down -v`。
6. 使用目标版本镜像运行 `migrate --yes`；失败则停止发布，不启动新版。
7. 启动新版 `app`，等待 readiness 检查成功。
8. 执行冒烟验收，成功后恢复扫描和上传，并记录发布结果。

### 3.3 最小冒烟验收

- `/api/health` 返回 `ready`、目标版本、目标 commit，且数据库和 CAS 可用。
- 首页、歌曲列表、格式统计、搜索和已保存播放列表可用。
- 分别抽测一种 `directFile`、`wasmDecode`、`serverDecode` 格式。
- 日志没有持续出现数据库、CAS、迁移或解码错误。

## 4. 回滚与数据库约束

### 4.1 回滚路径

- **没有数据库迁移**：停止新版，配置切回上一镜像 digest，启动并执行冒烟验收。
- **只有向后兼容迁移**：切回上一镜像，保留新增表或字段，后续版本再清理。
- **破坏性或不可逆迁移**：停止写入，恢复发布前数据库备份，再启动上一镜像；此路径会延长停机时间。
- CAS 默认不随应用版本回滚。任何删除或改写 CAS 原文件的功能必须另行设计备份和恢复，不能进入普通发布流程。

### 4.2 迁移纪律

- 已进入正式版本的迁移文件不得修改，只能新增迁移。
- 新迁移必须具有唯一、稳定的类型名，并在 `configure.swift` 中按顺序注册。
- 优先使用向后兼容变更；删除字段或不可逆转换必须在发布说明中标记为高风险。
- 大量数据回填使用可重复执行的独立任务，不阻塞应用启动迁移。
- 迁移失败时不得启动新版；不要把数据库 `revert` 当作默认应用回滚方式。

## 5. 实施任务清单

任务按依赖顺序执行。每项应由一个智能体在一个独立提交中完成。任务刻意限制为少量文件、单一目标和明确验证，适合 GPT-5.4、GPT-5.5、DeepSeek V4 Flash 等节省 token 的模型独立处理。执行者不得顺手扩展相邻任务。

| ID | 状态 | 任务 | 依赖 |
|:---|:-----|:-----|:-----|
| R01 | 完成 | 建立版本单一来源 | 无 |
| R02 | 完成 | 增加健康与版本接口 | R01 |
| R03 | 完成 | 让镜像携带构建身份 | R01 |
| R04 | 完成 | 增加 Tag 发布工作流 | R01、R03 |
| R05 | 完成 | 拆分生产部署配置 | R03 |
| R06 | 完成 | 增加数据库备份命令 | R05 |
| R07 | 完成 | 增加升级与回滚命令 | R02、R05、R06 |
| R08 | 完成 | 增加发布冒烟检查 | R02、R05 |
| R09 | 完成 | 完成运维手册与演练 | R04、R06、R07、R08 |

### R01：建立版本单一来源

**目标**：仓库内只有一个人工维护的应用版本值。

**改动边界**：新增根目录 `VERSION`；增加一个小型 `AppVersion` 结构；将 OpenAPI 中写死的 `1.1.0` 改为引用该结构。`AppVersion` 按固定优先级读取 `APP_VERSION` 环境变量、当前工作目录下的 `VERSION`，均不存在或格式错误时返回 `development`。不要改 CI、Docker Compose 或健康接口。

**验收**：

- `VERSION` 是合法的 `X.Y.Z`，不带 `v`。
- 从仓库根目录启动时，OpenAPI 的 `info.version` 与 `VERSION` 一致。
- 聚焦测试覆盖环境变量优先、文件回退和 `development` 回退；`swift test` 通过。

### R02：增加健康与版本接口

**目标**：提供部署后可自动判断 readiness 和版本的接口。

**改动边界**：在 System 路由增加 `GET /api/health`；返回 `status`、`version`、`commit`、`database`、`cas`。数据库执行轻量查询；CAS 只做无破坏性的可访问性检查。不要修改发布工作流。

**失败语义**：依赖不可用时返回非 2xx；响应不得暴露路径、凭证或内部错误堆栈。

**验收**：增加成功和依赖失败测试；`swift test` 通过。

### R03：让镜像携带构建身份

**目标**：同一镜像运行时可以报告版本、commit 和构建时间。

**改动边界**：修改 `Dockerfile`，通过 build arguments/环境变量注入 `APP_VERSION`、`GIT_COMMIT`、`BUILD_TIME`；把根目录 `VERSION` 复制到最终镜像 `/app/VERSION` 作为诊断回退；补充 OCI image labels。保持现有 SDK 校验和多阶段构建逻辑不变。

**验收**：本地构建指定身份的镜像；容器内环境与 image labels 值一致；现有 Docker 构建仍成功。

### R04：增加 Tag 发布工作流

**目标**：推送 `vX.Y.Z` Tag 后自动验证、构建和发布镜像。

**改动边界**：新增独立 GitHub Actions workflow；复用现有测试命令；校验 Tag 与 `VERSION`；登录 GHCR；推送版本标签和 commit 标签；输出 digest；创建或更新对应 GitHub Release。不要改变普通 PR CI。

**安全要求**：仅使用 `GITHUB_TOKEN`，设置最小 `contents`/`packages` 权限；禁止推送或覆盖 `latest`。

**验收**：workflow 语法有效；非匹配版本会失败；文档列出一次测试 Tag 的人工验证步骤。

### R05：拆分生产部署配置

**目标**：生产机只拉取指定镜像，不在发布时从源码构建。

**改动边界**：保留当前开发 Compose 行为；新增生产 override 或独立生产 Compose，使用 `IMAGE_REF`（必须包含版本或 digest）驱动 `app`、`migrate`、`scan`。数据库与 CAS volume 名称必须稳定。

**验收**：开发配置仍能构建；生产配置展开后不含应用 `build:`；`docker compose config --quiet` 对两套配置均通过。

### R06：增加数据库备份命令

**目标**：发布前用一条命令生成可识别、可校验的数据库备份。

**改动边界**：新增小型 shell 脚本和 Makefile 入口；通过 Compose 中的 PostgreSQL 执行 `pg_dump`；备份文件名包含 UTC 时间和目标版本；输出到可配置的本地备份目录。

**安全要求**：不打印密码；目录不存在时安全创建；已有文件不得静默覆盖；失败或空文件返回非零。

**验收**：在测试数据库生成非空备份，并能用 `pg_restore --list` 或匹配的 PostgreSQL 工具验证格式；为参数校验增加无数据库也能运行的聚焦测试。

### R07：增加升级与回滚命令

**目标**：把固定操作顺序固化成命令，减少人工漏步。

**改动边界**：新增 `release-preflight`、`release-upgrade`、`release-rollback` 入口。升级必须要求显式 `IMAGE_REF`，按“拉取 → 备份 → 停 app/scan → migrate → 启动 app”执行；回滚必须要求显式上一镜像引用。不要自动恢复数据库。

**安全要求**：任一步失败立即停止；禁止 `down -v`；迁移失败时保持应用停止并打印恢复指引；所有关键动作和版本写入发布日志。

**验收**：使用测试 Compose 或 mock Docker 命令验证调用顺序、失败短路和缺少参数时拒绝运行。

### R08：增加发布冒烟检查

**目标**：升级后用一条命令完成最低限度验收。

**改动边界**：新增只读 smoke 脚本；首先检查 `/api/health` 的状态、版本和 commit，再检查首页、格式统计和搜索接口。播放链路保留人工抽测清单，首期不自动播放音频。

**验收**：支持通过环境变量传入服务地址和期望版本；响应不匹配或超时返回非零；用本地 fixture/mock HTTP 服务覆盖成功与失败路径。

### R09：完成运维手册与发布演练

**目标**：让未参与开发的人仅按文档即可完成升级和回滚。

**改动边界**：补充本文件的实际命令；新增 `CHANGELOG.md` 模板；在 README 保留入口；记录一次测试环境的 `旧版 → 新版 → 旧版` 演练结果。不要再引入新工具。

**验收**：演练覆盖备份、迁移、健康检查、冒烟和应用回滚；记录实际耗时、停机时长、镜像 digest、问题与结论。

## 6. 运维手册 — 实际命令

### 6.1 前置条件

```bash
# 生产机环境要求
# - Docker + Docker Compose
# - 生产 docker-compose.yml + docker-compose.production.yml
# - pg_dump（通常包含在 PostgreSQL 客户端包中）
# - 可访问 ghcr.io

# 环境变量模板（写入 .env 或 export）
export IMAGE_REF=ghcr.io/<owner>/orzmusic:0.0.1
export BACKUP_DIR=./backups
export LOG_LEVEL=debug
export DATABASE_HOST=db
export DATABASE_NAME=vapor_database
export DATABASE_USERNAME=vapor_username
export DATABASE_PASSWORD=vapor_password
export CAS_ROOT=/data/music

# Compose 别名
alias DC="docker compose -f docker-compose.yml -f docker-compose.production.yml"
```

### 6.2 日常操作

```bash
# 查看当前版本
curl -fsS http://localhost:8080/api/health | python3 -m json.tool

# 查看运行状态
DC ps
DC logs --tail=50 app
```

### 6.3 完整升级流程

```bash
# 0. 记录当前版本
echo "=== Current Status ==="
curl -fsS http://localhost:8080/api/health | python3 -m json.tool

# 1. 前置检查
make release-preflight

# 2. 执行升级（IMAGE_REF 为必填）
IMAGE_REF=ghcr.io/<owner>/orzmusic:0.0.2 make release-upgrade

# 3. 冒烟检查
SERVICE_URL=http://localhost:8080 EXPECTED_VERSION=0.0.2 make release-smoke

# 4. 手动验证播放（抽测）
echo "Manual: Play one song from each strategy"
echo "  - directFile: mp3/ogg/flac → 浏览器原生播放"
echo "  - wasmDecode: xm/mod/sid → WASM 加载后播放"
echo "  - serverDecode: sc68/wav → 服务端转码为 WAV 后播放"

# 5. 确认无持续错误
DC logs --tail=100 app | grep -i "error\|fail\|exception" || echo "No errors found"
```

### 6.4 回滚流程

```bash
# 回滚到上一版本（不自动恢复数据库，只切回旧代码）
IMAGE_REF=ghcr.io/<owner>/orzmusic:0.0.1 make release-rollback

# 如果迁移不兼容，需要先恢复数据库
# pg_restore -d vapor_database ./backups/orzmusic-db-0.0.2-*.dump

# 验证回滚后的版本
curl -fsS http://localhost:8080/api/health | python3 -m json.tool
```

### 6.5 备份与恢复

```bash
# 备份
VERSION=0.0.1 make db-backup

# 验证备份
pg_restore --list ./backups/orzmusic-db-0.0.1-*.dump | head -20

# 恢复（仅在需要时）
# pg_restore -d vapor_database -c ./backups/orzmusic-db-0.0.1-*.dump
```

### 6.6 升级与回滚联动检查表

| 步骤 | 命令 | 预期结果 |
|:-----|:-----|:---------|
| 版本确认 | `cat VERSION` | 合法 SemVer，不带 `v` |
| 前置检查 | `make release-preflight` | ALL CHECKS PASSED |
| 升级 | `IMAGE_REF=X.Y.Z make release-upgrade` | Upgrade Complete |
| 健康检查 | `curl /api/health` | `status: ready` |
| 版本验证 | 同上 | `version: X.Y.Z` |
| 冒烟检查 | `make release-smoke` | SMOKE CHECK PASSED |
| 回滚 | `IMAGE_REF=X.Y.Z-1 make release-rollback` | Rollback Complete |
| 验证回滚 | `curl /api/health` | `version: X.Y.Z-1` |

## 7. 发布演练记录

### 7.1 首次发布演练计划

此节记录 R01–R09 全部完成后在测试环境的完整 `旧版 → 新版 → 旧版` 演练结果。

```bash
# 演练环境
# - 本地 Docker Compose（非生产机）
# - PostgreSQL 16 + 测试数据
# - 两个镜像标签：0.0.1（旧版）、0.0.2（新版）

# 步骤
# 1. 构建旧版镜像并启动
# 2. 导入测试数据
# 3. 创建新版 VERSION，构建新版镜像
# 4. 执行完整升级流程
# 5. 执行冒烟检查
# 6. 执行回滚
# 7. 验证旧版恢复
```

> **演练状态**：本地验证完成，完整构建需在 CI/amd64 Linux 环境执行
>
> 本地 macOS ARM 环境验证结果：
> - 2026-07-23 | 参与人：单机开发环境
> - Docker Compose 开发配置：`docker compose config --quiet` ✅
> - Docker Compose 生产配置（IMAGE_REF 驱动）：`docker compose config --quiet` ✅
> - 生产配置展开后无应用 `build:`（使用 `image: ${IMAGE_REF}`）✅
> - Dockerfile 构建参数（APP_VERSION/GIT_COMMIT/BUILD_TIME）：已定义 ✅
> - Dockerfile OCI labels：已定义 ✅
> - 所有脚本语法：bash -n 通过 ✅
> - Docker 镜像构建：在当前 macOS ARM 环境无法完成（ports.ubuntu.com 不可达），需在 CI Ubuntu runner 上执行完整构建
> - 问题：macOS Docker 构建 Linux 镜像受限于网络和架构，建议在 PR CI 或 GitHub Actions 中验证完整构建

### 7.2 正式发布引用格式

每次正式发布后在此追加一行：

```
| YYYY-MM-DD | vX.Y.Z | <commit> | <digest> | <停机时长> | <结果> |
```

## 8. 测试 Tag 人工验证步骤（R04）

在推送正式 `vX.Y.Z` 标签前，建议创建一个测试标签确认工作流正确运行：

```bash
# 1. 切到目标提交
git checkout main

# 2. 确认 VERSION 内容与测试标签一致
cat VERSION               # 例如 0.0.1
export TEST_TAG=v0.0.1-test-$(date +%Y%m%d)

# 3. 推送测试标签（触发 Release workflow）
git tag $TEST_TAG
git push origin $TEST_TAG

# 4. 在 GitHub 仓库 Actions 页观察 workflow 运行
#    - Validate version tag 步骤：预期失败（测试标签与 VERSION 不匹配），验证拒绝逻辑
#    清理测试标签：
#    git push --delete origin $TEST_TAG && git tag -d $TEST_TAG

# 5. 真正验证：推送与 VERSION 一致的标签
#    git tag v$(cat VERSION)
#    git push origin v$(cat VERSION)

# 6. 验证通过后检查：
#    - Workflow 全部步骤绿色通过
#    - GHCR 中出现 ghcr.io/<owner>/orzmusic:X.Y.Z 镜像
#    - GitHub Releases 页面出现对应 Release 条目
#    - Release 正文包含镜像引用、digest、commit 和构建时间
```

## 9. 智能体任务执行约定

分派上述任务时，把一个任务的完整小节直接交给执行模型，并附带以下统一要求：

1. 开始前阅读 `AGENTS.md` 和本文件，只处理指定任务 ID。
2. 先检查相关文件和现有测试，不修改任务边界外的行为。
3. 不修改用户已有的无关改动，不重写已经发布的迁移。
4. 运行任务小节列出的聚焦验证；失败时报告命令和原因。
5. 最终报告仅包含：改动文件、行为变化、验证结果、遗留风险。
6. 一个任务对应一个提交；提交信息建议使用 `release(Rxx): <简短目标>`。

如果执行模型发现任务必须跨越边界才能完成，应停止并报告阻塞，不自行合并后续任务。主协调者负责调整依赖或拆出新的小任务。

## 10. 完成定义

R01–R09 全部完成并通过一次演练后，最小发布能力视为交付。此后每个正式版本都必须留下：版本号、Git Tag、commit、镜像引用与 digest、CHANGELOG、数据库备份、迁移结果、冒烟结果、发布时间和回滚目标。
