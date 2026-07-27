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
    ├── release-smoke.sh
    └── release-scan.sh
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

## 扫描音频文件

生产环境推荐使用部署包里的 `make scan`。它会临时启动 scanner 服务，把宿主机音频目录只读挂载到容器内 `/sources/keygen`，触发扫描，然后停止临时 scanner 容器。

```bash
export IMAGE_REF=ghcr.io/orzgeeker/orzmusic@sha256:<digest>
MUSIC_DIR=/absolute/path/to/music make scan
```

示例：

```bash
export IMAGE_REF=ghcr.io/orzgeeker/orzmusic@sha256:32db66e1e7c0d0b0301c0ed31647a3f8d9b9d568439c9377399c2baaf9fb8c9a
MUSIC_DIR=/mnt/music make scan
```

参数说明：

| 变量 | 说明 |
|:-----|:-----|
| `MUSIC_DIR` | 宿主机上的真实音频目录，必须是绝对路径。 |
| `IMAGE_REF` | 当前生产镜像引用，建议使用 Release 页面提供的 digest。 |
| `SCAN_SOURCE` | 容器内扫描路径，默认 `/sources/keygen`，通常不需要改。 |
| `SCAN_URL` | scanner 服务地址，默认 `http://127.0.0.1:8081`。 |

扫描完成后可检查格式统计：

```bash
curl -fsS "http://127.0.0.1:8080/api/songs/formats"
```

如果需要手动启动 scanner，也可以使用 Compose：

```bash
KEYGEN_DIR=/absolute/path/to/music \
docker compose -f docker-compose.yml -f docker-compose.production.yml \
  run --rm --service-ports scan
```

另一个终端触发扫描：

```bash
curl -fsS -X POST "http://127.0.0.1:8081/api/scan" \
  -H "Content-Type: application/json" \
  -d '{"sources":["/sources/keygen"]}'
```

注意：API 里的路径是容器内路径，不是宿主机路径。比如宿主机目录 `/mnt/music` 挂载为 `/sources/keygen` 后，请求体里就写 `/sources/keygen`。

## 重要约束

- 不要在生产机执行源码构建。
- 不要执行 `docker compose down -v`，避免删除数据库和 CAS volume。
- 发布镜像优先使用 digest，而不是浮动标签。
- 升级前必须确认数据库备份成功。
