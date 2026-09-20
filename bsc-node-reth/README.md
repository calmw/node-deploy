# BSC 主网 Reth 节点（源码镜像 · 创世同步 · 1.5 年 state · debug）

独立 4TB 机部署 **reth-bsc**（源码构建镜像），**不从快照导入**，空数据目录 **从 block 0 同步**；`reth.toml` 自定义裁剪保留约 **1.5 年**历史 state；RPC 开启 **debug / trace**。

| 项目 | 值 |
|------|-----|
| 链 | BSC Mainnet（`chainId=56`） |
| 同步 | **`RETH_SYNC_MODE=genesis`**（默认，无快照） |
| 历史 state | **`PRUNE_HISTORY_DISTANCE=106500000`**（~548 天 @ 0.45s/块） |
| 镜像 | **`bsc-reth-local`** 或 push 到 `RETH_REGISTRY` |
| Debug | `RETH_DEBUG=true`，`HTTP_API` 含 `debug,trace` |
| 数据 | `./data/reth/` |

**勿**使用 CLI **`--full`**（仅 ~1 万块 history）；裁剪以 **`data/reth/reth.toml`** 为准。

> 创世同步 BSC 主网需 **数周**，磁盘随同步增长，**4TB 需监控**。若要从快照加速，见下文「快照模式」。

---

## 脚本一览

| 脚本 | 用途 |
|------|------|
| `scripts/build-from-source.sh` | 拉 reth-bsc 源码构建 Docker 镜像 |
| `scripts/publish-image.sh` | 构建并 **push** 到远程仓库 |
| `scripts/deploy.sh` | 构建 + 配置 + 启动（默认 genesis） |
| `scripts/setup.sh` | 生成 `data/reth/reth.toml` |
| `scripts/start.sh` | 容器入口 |
| `scripts/status.sh` | 状态检查 |
| `scripts/snapshot.sh` | 可选：官方 Full 快照（`--with-snapshot`） |
| `scripts/reset-data.sh` | 清空链数据 |

---

## 推荐：构建镜像 → 推送 → 从 0 同步

**构建机**：Docker、git、约 **30GB** 空闲（编译缓存）。**节点机**：4TB NVMe、**≥32GB** 内存。

```bash
cd bsc-node-reth
chmod +x scripts/*.sh

cp .env.example .env
# 编辑:
#   HTTP_BIND_ADDR / WS_BIND_ADDR = tailscale ip -4
#   RETH_REGISTRY=ghcr.io/<你>/bsc-reth   # 若要 push
#   docker login ghcr.io

# 构建 + 推送 + 写入 .env 的 RETH_IMAGE
bash scripts/publish-image.sh ghcr.io/<你>/bsc-reth v0.1.2
# 或仅本地构建:
bash scripts/build-from-source.sh --ref v0.1.2 --update-env

# 部署（genesis，不下载快照）
bash scripts/deploy.sh

# 或一步：构建并启动（不 push）
bash scripts/deploy.sh --build --ref v0.1.2
```

**另一台机器** 仅运行节点时：复制 `.env`，`RETH_IMAGE=ghcr.io/<你>/bsc-reth:v0.1.2`，`docker compose up -d`（需已 `docker pull`）。

---

## 环境变量要点（`.env`）

| 变量 | 默认 | 说明 |
|------|------|------|
| `RETH_SYNC_MODE` | `genesis` | `genesis` 不下载快照；`snapshot` 走 snapshot.sh |
| `RETH_IMAGE` | `bsc-reth-local:latest` | 构建后 `--update-env` 会改 |
| `RETH_COMPOSE_PULL` | `false` | 本地/自建镜像设为 false |
| `RETH_DEBUG` | `true` | 日志 debug + debug/trace RPC |
| `PRUNE_HISTORY_DISTANCE` | `106500000` | 1.5 年窗口 |
| `RETH_REGISTRY` | （空） | publish-image 用 |

改裁剪或 debug 后：

```bash
bash scripts/setup.sh init
docker compose down && docker compose up -d
```

---

## 构建与上传镜像

```bash
# 最新 GitHub Release + 本地 tag
bash scripts/build-from-source.sh --update-env

# 指定版本 + 推送
bash scripts/build-from-source.sh \
  --ref v0.1.2 \
  --push \
  --registry ghcr.io/you/bsc-reth \
  --update-env

bash scripts/publish-image.sh ghcr.io/you/bsc-reth v0.1.2
```

---

## 日常操作

```bash
docker compose up -d
docker compose down
bash scripts/status.sh
docker compose logs -f --tail 50 reth

curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
  http://127.0.0.1:8545
```

---

## 可选：快照模式（加速，非默认）

```bash
# .env: RETH_SYNC_MODE=snapshot
bash scripts/deploy.sh --with-snapshot --bg-download
# 完成后 docker compose up -d
```

官方 Full 快照约 **3.23 TiB**：[bsc-snapshots Source-4](https://github.com/bnb-chain/bsc-snapshots#source-4-bsc-reth-snapshots)。

---

## 与 `--full` 的区别

| 模式 | 历史 state |
|------|------------|
| `reth-bsc node --full` | ~10,064 块 |
| **本方案**（`reth.toml`） | ~**106.5M** 块（1.5 年） |

---

## 参考

- [reth-bsc](https://github.com/bnb-chain/reth-bsc)
- [Reth 裁剪](https://reth.rs/run/storage/pruning/)
- [MIGRATE_V2.md](https://github.com/bnb-chain/reth-bsc/blob/main/MIGRATE_V2.md)
