# OrzMusic 生产部署说明

生产环境推荐使用 GitHub Release 中的轻量部署包，不需要在生产机拉取完整 Git 仓库，也不需要在生产机编译 Swift 服务。

## 发布制品

每个正式版本的 GitHub Release 应包含：

| 制品 | 用途 |
|:-----|:-----|
| Docker 镜像 | 服务运行制品，例如 `ghcr.io/orzgeeker/orzmusic:0.0.2`。 |
| 镜像 Digest | 推荐生产部署使用的不可变镜像引用，例如 `ghcr.io/orzgeeker/orzmusic@sha256:...`。 |
| 部署包 | `orzmusic-deploy-<version>.tar.gz`，包含生产 Compose、发布脚本和部署文档。 |

部署包只包含生产机需要的运维文件，不包含源码、Swift 构建产物、测试、SDK 下载缓存或样例音乐。

## 部署包内容

```text
orzmusic-deploy-<version>/
├── DEPLOYMENT.txt
├── VERSION
├── CHANGELOG.md
├── README.md
├── Makefile                 # 生产专用命令入口
├── docker-compose.yml
├── docker-compose.production.yml
├── Docs/
│   ├── deployment.md
│   └── migration.md
└── script/
    ├── db-backup.sh
    ├── release-preflight.sh
    ├── release-upgrade.sh
    ├── release-rollback.sh
    └── release-smoke.sh
```

## 首次部署

1. 在生产机安装 Docker 和 Docker Compose。
2. 从 GitHub Release 下载对应版本的部署包。
3. 解压部署包：

```bash
tar -xzf orzmusic-deploy-0.0.2.tar.gz
cd orzmusic-deploy-0.0.2
```

4. 指定镜像。生产环境推荐使用 Release 页面里的 digest：

```bash
export IMAGE_REF=ghcr.io/orzgeeker/orzmusic@sha256:<digest>
```

5. 启动数据库并执行升级流程：

```bash
docker compose -f docker-compose.yml -f docker-compose.production.yml up -d db
make release-preflight
make release-upgrade
EXPECTED_VERSION=0.0.2 make release-smoke
```

## 日常升级

日常升级不需要拉仓库，只需要下载新版本部署包并指定新镜像：

```bash
tar -xzf orzmusic-deploy-0.0.3.tar.gz
cd orzmusic-deploy-0.0.3

export IMAGE_REF=ghcr.io/orzgeeker/orzmusic@sha256:<new-digest>
make release-preflight
make release-upgrade
EXPECTED_VERSION=0.0.3 make release-smoke
```

`release-upgrade` 会按固定顺序执行：

1. 前置检查
2. 拉取镜像
3. 数据库备份
4. 停止 `app` 和 `scan`
5. 执行数据库迁移
6. 启动 `app`

## 回滚

回滚时使用上一版本镜像：

```bash
export IMAGE_REF=ghcr.io/orzgeeker/orzmusic@sha256:<previous-digest>
make release-rollback
EXPECTED_VERSION=0.0.2 make release-smoke
```

注意：回滚脚本不会自动恢复数据库。若失败原因是数据库迁移不兼容，应先根据备份恢复数据库，再启动上一版本镜像。

## 重要约束

- 不要在生产机执行源码构建。
- 不要执行 `docker compose down -v`，避免删除数据库和 CAS volume。
- 发布镜像优先使用 digest，而不是浮动标签。
- 升级前必须确认数据库备份成功。
