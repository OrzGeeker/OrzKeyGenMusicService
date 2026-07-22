# OrzMusic 服务迁移指南

本文用于把 OrzMusic 从一台服务器迁移到另一台服务器，覆盖 Docker 与 native 两种部署方式。

## 迁移对象

OrzMusic 的运行状态主要由以下几部分组成：

| 对象 | 是否必须迁移 | 说明 |
|:-----|:-------------|:-----|
| PostgreSQL 数据库 | 必须 | 保存曲目元数据、格式、SHA-256、播放列表等。 |
| CAS 音频目录 | 必须 | 保存导入时的原始音频文件。数据库只保存内容哈希，不保存源路径。 |
| `CAS_ROOT/.cache/wav/` | 可选 | 服务端解码生成的 PCM WAV 缓存；不迁移也可自动重建。 |
| 应用代码 | 必须 | 建议迁移到与线上一致的 Git commit。 |
| OrzAudioCore SDK | 必须 | 由 `make setup` 或 SDK 更新脚本安装 native 与 Web/WASM 制品。 |
| 源音乐目录 | 可选 | 只有需要重新扫描或继续导入新文件时才需要。 |

> CAS 中保存的是原始音频文件，不是转码后的播放文件。数据库和 CAS 必须成对迁移，否则页面可能能看到曲目，但播放时找不到文件。

## Docker 迁移

Docker 是推荐的生产迁移方式。当前 `docker-compose.yml` 使用两个持久化 volume：

- `db_data`：PostgreSQL 数据。
- `cas_data`：CAS 原始音频文件，以及 `CAS_ROOT/.cache/wav/` 服务端解码缓存。

### 1. 旧服务器导出数据库

```bash
docker compose exec db pg_dump -U vapor_username vapor_database > orzmusic.sql
```

如果数据库运行在 compose 外部，使用对应 PostgreSQL 连接参数执行 `pg_dump`。

### 2. 旧服务器打包 CAS volume

先确认实际 volume 名称：

```bash
docker volume ls
```

然后打包 CAS。以下命令中的 `service_cas_data` 需要替换成实际 volume 名称：

```bash
docker run --rm \
  -v service_cas_data:/data \
  -v "$PWD":/backup \
  alpine tar czf /backup/cas_data.tar.gz -C /data .
```

### 3. 新服务器恢复

拉取项目并进入服务目录：

```bash
git clone <repo-url>
cd Service
```

启动数据库以创建 volume：

```bash
docker compose up -d db
```

恢复数据库：

```bash
cat orzmusic.sql | docker compose exec -T db psql -U vapor_username vapor_database
```

恢复 CAS。以下命令中的 `service_cas_data` 同样替换成新服务器上的实际 volume 名称：

```bash
docker run --rm \
  -v service_cas_data:/data \
  -v "$PWD":/backup \
  alpine sh -c "cd /data && tar xzf /backup/cas_data.tar.gz"
```

启动服务：

```bash
make docker-up
```

### 4. Docker 验收

```bash
curl http://127.0.0.1:8080/api/songs/formats
```

重点确认：

- 总曲目数与旧服务器一致。
- 各格式数量与旧服务器一致。
- 页面可以打开。
- directFile、wasmDecode、serverDecode 代表格式均可播放。
- 已保存播放列表存在。

## Native 迁移

native 迁移适合开发机或轻量部署。生产环境如果没有特殊约束，优先使用 Docker。

### 1. 新服务器准备

需要安装：

- Swift toolchain。
- PostgreSQL。
- Git。
- `ffmpeg`，用于标准音频 fallback 和部分工具链。
- `fpcalc` / chromaprint，可选，用于常规容器音频指纹。

### 2. 拉取代码并安装 SDK

```bash
git clone <repo-url>
cd Service
make setup
swift build -c release
```

### 3. 恢复数据库

创建数据库和用户后导入：

```bash
psql -h localhost -U vapor_username vapor_database < orzmusic.sql
```

运行时可通过环境变量覆盖默认数据库配置：

```bash
export DATABASE_HOST=localhost
export DATABASE_PORT=5432
export DATABASE_NAME=vapor_database
export DATABASE_USERNAME=vapor_username
export DATABASE_PASSWORD=<password>
```

### 4. 迁移 CAS

把旧服务器的 CAS 根目录同步到新服务器。例如使用独立数据盘：

```bash
rsync -a /old/orzmusic/data/music/ new-server:/data/orzmusic/music/
```

启动服务前指定：

```bash
export CAS_ROOT=/data/orzmusic/music
```

如果不设置 `CAS_ROOT`，默认使用当前项目目录下的 `./data/music`。

### 5. 启动服务

```bash
swift run OrzMusicService serve --env production --hostname 0.0.0.0 --port 8080
```

本地开发也可以使用：

```bash
make run
```

生产环境建议交给 systemd、supervisor 或容器平台托管，不建议长期依赖手动终端进程。

## 是否需要重新扫描

完整迁移数据库和 CAS 后，通常不需要重新扫描。

需要重新扫描的情况：

- 新服务器有新的源音乐目录。
- 数据库或 CAS 迁移不完整。
- 需要继续导入新增文件。
- 需要重新补齐某些元数据。

重新扫描不会依赖原始源路径修复已有曲目；已有曲目的播放依赖数据库中的 SHA-256 和 CAS 中对应原始文件。

## 切换前检查清单

- [ ] 新服务器磁盘空间足够容纳数据库、CAS 和缓存增长。
- [ ] 使用与旧服务器一致的 Git commit 或已验证的新版本。
- [ ] 已安装或随 Docker 镜像包含 OrzAudioCore SDK。
- [ ] 数据库导入成功。
- [ ] CAS 文件恢复成功。
- [ ] `/api/songs/formats` 总数和格式数量符合预期。
- [ ] 代表格式播放通过：`mp3/ogg`、`xm/mod/it`、`ym/v2m/bp`、`sc68`、压缩 `wav`。
- [ ] 播放列表、搜索、格式筛选、上一首/下一首、进度条和音量控制正常。
- [ ] 如对外开放，已配置反向代理、HTTPS、备份和数据库密码。

