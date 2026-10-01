# BSC 主网 Reth 节点（源码镜像 · 创世同步 · 静态 18 个月 / state 17 个月 · debug）

独立机部署 **reth-bsc**（源码构建或拉取自建镜像），默认 **从 block 0 创世同步**；`reth.toml` 自定义裁剪：交易、回执等静态数据保留 **18 个月**，state 历史保留 **17 个月**；RPC 可开 **debug / trace**。

| 项目 | 值 |
|------|-----|
| 链 | BSC Mainnet（`chainId=56`） |
| 同步 | **`RETH_SYNC_MODE=genesis`**（默认，无快照） |
| 静态数据（交易/回执/交易索引/sender） | **18 个月** ≈ `105192000` 块 @ 0.45s/块 |
| state 历史（账户/存储） | **17 个月** ≈ `99348000` 块 @ 0.45s/块 |
| 镜像 | `.env` 中 **`RETH_IMAGE`**（如 `ghcr.io/<你>/bsc-reth:v0.1.2`） |
| 日志 | 默认 **`RETH_DEBUG=false`** + `RUST_LOG=info,...`；RPC 仍含 debug/trace API |
| 数据 | `./data/reth/`（含 `db/`、`reth.toml`、`known-peers.json`） |

**勿**使用 CLI **`--full`**（仅 ~1 万块 history）；裁剪以 **`data/reth/reth.toml`** 为准。

> 创世同步 BSC 主网需 **数周**，磁盘随同步增长，**4TB 需监控**。若要尽快可用 RPC，见 [快照模式](#快照模式加速非默认)。

---

## 目录与前置

```
bsc-node-reth/
├── .env                 # 本地配置（勿提交；从 .env.example 复制）
├── docker-compose.yml   # host 网络，入口 scripts/start.sh
├── config/
│   ├── reth.toml.template
│   └── trusted-peers.txt
├── data/reth/           # 链数据（git 忽略）
└── scripts/             # 见下文「脚本说明」
```

| 角色 | 需要 |
|------|------|
| **构建机** | Docker、git、python3；磁盘空闲约 **30GB+**（编译缓存） |
| **节点机** | Docker Compose v2、4TB NVMe、**≥32GB** 内存；使用 `deploy.sh` / `refresh-trusted-peers.sh` 时宿主机需 **python3**（`setup.sh` 不需要） |

首次在节点目录：

```bash
cd bsc-node-reth
chmod +x scripts/*.sh
cp .env.example .env
# 必改: HTTP_BIND_ADDR / WS_BIND_ADDR（Tailscale: tailscale ip -4）
# 必改: RETH_IMAGE=你的镜像
# 自建镜像: RETH_COMPOSE_PULL=false
```

---

## 生命周期：启动 / 停止 / 重启 / 状态 / 日志

所有命令在 **`bsc-node-reth` 目录**下执行。修改 `.env` 或 `config/trusted-peers.txt` 后，一般 **`docker compose up -d`** 或 **`restart`** 即可；改 **`reth.toml` 裁剪参数** 需先 `setup.sh init` 再重启。

### 启动

| 场景 | 命令 |
|------|------|
| 已配置 `.env` + 已有 `data/reth/reth.toml` | `docker compose up -d` |
| 首次部署（生成 toml、可选构建镜像） | `bash scripts/deploy.sh` |
| 首次 + 本地构建镜像 | `bash scripts/deploy.sh --build --ref v0.1.2` |
| 仅拉远程镜像后启动 | 确认 `RETH_IMAGE` / `RETH_COMPOSE_PULL`，再 `docker compose up -d` |

启动前检查：

```bash
test -f .env && test -f data/reth/reth.toml || bash scripts/setup.sh init
grep -E '^RETH_IMAGE=|^HTTP_BIND_ADDR=' .env
```

### 停止

```bash
docker compose down          # 停止并移除容器（不删 data/reth）
docker compose stop reth     # 仅停止，不删容器
```

若在后台下载快照，一并停止：

```bash
bash scripts/snapshot.sh stop
docker compose down
```

### 重启

```bash
docker compose restart reth
# 或
docker compose down && docker compose up -d
```

改 **`PRUNE_*` / 模板** 后：

```bash
bash scripts/setup.sh init
docker compose down && docker compose up -d
```

改 **`reth.toml` 异常或节点起不来** 时可用 repair（会 down + up）：

```bash
bash scripts/setup.sh repair
```

### 状态与健康

```bash
bash scripts/status.sh       # 容器、磁盘、端口、RPC、eth_syncing、最近日志
docker compose ps
```

手动 RPC（地址以 `.env` 的 `HTTP_BIND_ADDR:HTTP_PORT` 为准）：

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
  "http://127.0.0.1:8545/"
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  "http://127.0.0.1:8545/"
```

创世同步早期 **`eth_blockNumber` 可能长期为 0x0**（Execution 未追上）；可看日志里 headers / pipeline 进度。

### 日志

```bash
docker compose logs -f --tail 100 reth
```

- 默认 **不写文件**，只看 Docker 日志（`start.sh` 未设 `RETH_LOG_FILE_DIR`）。
- 需要容器内文件日志：`.env` 设置 `RETH_LOG_FILE_DIR=/data/logs`（需镜像内可写；数据在 `./data/reth` 挂载下）。
- 深度排查：`.env` 设 `RETH_DEBUG=true` 与 `RUST_LOG=info,reth=debug,reth_bsc=debug`，再 `docker compose up -d`。

---

## 脚本说明

### 总览

| 脚本 | 用途 |
|------|------|
| `scripts/deploy.sh` | 一键：可选构建镜像 → `setup.sh` → 快照或 genesis → `docker compose up -d` |
| `scripts/setup.sh` | 从模板生成 `data/reth/reth.toml`（裁剪距离） |
| `scripts/start.sh` | **容器入口**（compose 挂载，一般勿手跑） |
| `scripts/status.sh` | 节点状态与 RPC 探测 |
| `scripts/reset-data.sh` | **清空** `data/reth`（需确认，不可恢复） |
| `scripts/snapshot.sh` | 官方 Full 快照下载/解压 |
| `scripts/build-from-source.sh` | 拉 reth-bsc 源码构建 Docker 镜像 |
| `scripts/publish-image.sh` | 构建并 **push** 到远程仓库 |
| `scripts/sync-from-github.sh` | 非 git 部署目录时同步脚本/配置（不覆盖 `data/`、`.env`） |
| `scripts/repair-env.sh` | 修复被污染的 `.env`（如误写入 docker push 输出） |
| `scripts/load-env.sh` | 供其他脚本 `source` 的安全加载 `.env` |
| `scripts/refresh-trusted-peers.sh` | 从 RPC / known-peers 写入 `config/trusted-peers.txt` |
| `scripts/update-extip.sh` | 家宽动态 IP：公网 IP 变化时更新 `NAT_EXTIP` 并重建容器 |

---

### `scripts/deploy.sh`

默认读取 `.env` 的 `RETH_SYNC_MODE`（**genesis** 不下载快照）。

```bash
bash scripts/deploy.sh -h

# 常见
bash scripts/deploy.sh
bash scripts/deploy.sh --build --ref v0.1.2
bash scripts/deploy.sh --build --push --registry ghcr.io/<你>/bsc-reth --ref v0.1.2

# 快照
bash scripts/deploy.sh --with-snapshot --bg-download   # 后台下载，暂不启容器
bash scripts/deploy.sh --with-snapshot --skip-download # 已有 data/reth/db

# 只准备配置、不启容器
bash scripts/deploy.sh --skip-docker
```

流程概要：`[1]` 可选构建 → `[2]` setup → `[3]` `.env` / Tailscale IP → `[4]` genesis 或 snapshot → `[5]` `docker compose up -d`。

---

### `scripts/setup.sh`

```bash
bash scripts/setup.sh init    # 默认：写入 data/reth/reth.toml
bash scripts/setup.sh repair  # 重渲染 reth.toml + docker compose down/up
```

裁剪分两组，块数来源（优先级从高到低）：

| 分组 | reth 段 | 直接指定块数 | 按月换算（默认） |
|------|---------|--------------|------------------|
| 静态数据 | `bodies_history`、`receipts`、`transaction_lookup`、`sender_recovery` | `PRUNE_STATIC_HISTORY_DISTANCE` | `PRUNE_STATIC_HISTORY_MONTHS=18` |
| state 历史 | `account_history`、`storage_history` | `PRUNE_STATE_HISTORY_DISTANCE` | `PRUNE_STATE_HISTORY_MONTHS=17` |

换算：`块数 = 月数 × 365.25/12 × 86400 / BLOCK_TIME_SEC`（默认 `0.45`，即 BSC 2026-01-14 Fermi 硬分叉后的出块间隔）。旧变量 `PRUNE_HISTORY_DISTANCE` / `PRUNE_HISTORY_DAYS` 已废弃，`setup.sh` 会提示并忽略。

裁剪按“链头往前 N 块”计算。Fermi 之前的块间隔更长（0.75s / 1.5s / 3s），因此在 Fermi 满 18 个月（约 2027-07）之前，同样块数覆盖的实际时间会超过 18 / 17 个月，占用空间也更大。

---

### `scripts/snapshot.sh`

仅当 **`RETH_SYNC_MODE=snapshot`** 或 deploy 带 **`--with-snapshot`** 时使用。官方 Full 约 **3.23 TiB**：[bsc-snapshots Source-4](https://github.com/bnb-chain/bsc-snapshots#source-4-bsc-reth-snapshots)。

```bash
bash scripts/snapshot.sh start      # 后台下载并解压到 data/reth/
bash scripts/snapshot.sh status
bash scripts/snapshot.sh log        # tail 下载日志
bash scripts/snapshot.sh stop
bash scripts/snapshot.sh download   # 前台下载+解压

# 完成后
bash scripts/setup.sh init
docker compose up -d
```

`.env` 可改 **`RETH_SNAPSHOT_URL`**。磁盘建议 **≥3.5TB** 可用空间。

---

### `scripts/reset-data.sh`

**删除全部链数据**（含 `db/`、`static_files/` 等），并尝试停止 compose 与快照任务。

```bash
bash scripts/reset-data.sh   # 交互确认 [y/N]
```

之后：

- 创世：`bash scripts/setup.sh init && docker compose up -d`
- 快照：`bash scripts/deploy.sh --with-snapshot --bg-download` 或 `snapshot.sh start`

---

### `scripts/build-from-source.sh` / `publish-image.sh`

```bash
bash scripts/build-from-source.sh -h

bash scripts/build-from-source.sh --ref v0.1.2 --update-env
bash scripts/build-from-source.sh --ref v0.1.2 --push --registry ghcr.io/<你>/bsc-reth --update-env
bash scripts/build-from-source.sh --method native --ref v0.1.2   # 宿主机 cargo，Hub 不可达时

bash scripts/publish-image.sh ghcr.io/<你>/bsc-reth v0.1.2
```

**Docker Hub 超时（国内常见）**：

```bash
export RETH_DOCKER_HUB_MIRROR=docker.1ms.run   # 设为 off 则只直连 Hub
bash scripts/publish-image.sh ghcr.io/<你>/bsc-reth v0.1.2
```

**GitHub clone TLS 失败**：脚本会自动重试；可设 `RETH_BSC_REPO` 为可用镜像 URL。

构建成功后确认 `.env`：

```bash
grep -E '^RETH_IMAGE=|^RETH_COMPOSE_PULL=' .env
# RETH_IMAGE=ghcr.io/<你>/bsc-reth:v0.1.2
# RETH_COMPOSE_PULL=false
```

若 `.env` 损坏（`source .env` 报 `push: command not found`）：

```bash
bash scripts/repair-env.sh
```

长时间编译请用 **tmux/screen**。

---

### `scripts/sync-from-github.sh`

部署目录 **不是 git 仓库**（只有 rsync 过来的文件）时更新脚本：

```bash
cd /data2/bsc-node-reth   # 你的路径
bash scripts/sync-from-github.sh
# 不覆盖: data/、.env、.build/
docker compose restart reth
```

可选环境变量：`NODE_DEPLOY_REPO`、`NODE_DEPLOY_REF`（默认 `main`）。

---

### `scripts/refresh-trusted-peers.sh`

需 RPC 已可用且 **`HTTP_API` 含 `admin`**（`.env.example` 已包含）。

```bash
bash scripts/refresh-trusted-peers.sh
RESTART=1 bash scripts/refresh-trusted-peers.sh

# 可选
ROUNDS=10 INTERVAL=5 bash scripts/refresh-trusted-peers.sh
MAX_TRUSTED=30 bash scripts/refresh-trusted-peers.sh   # 默认最多 50 个
grep -v '^#' config/trusted-peers.txt
```

只收录 `admin_peers` 里已握手成功的 BSC peer，不读 `known-peers.json`（里面是 discovery 见过的数千个节点，含错链）。`start.sh` 启动时最多合并 `RETH_TRUSTED_PEERS_MAX`（默认 64）个，避免 `Argument list too long`。

宿主机需 **python3**（仅本脚本；容器内 `start.sh` 合并 trusted peers 为纯 bash）。

---

### `scripts/update-extip.sh`

内网机器（如家里 `192.168.x.x`）用 `NAT_MODE=any` 时 enode 可能宣告 `0.0.0.0:30303`，其他节点无法回连，peer 很少。需宣告真实公网 IP，并在路由器把 `30303/tcp`、`30303/udp` 转发到本机。

公网 IP 会变时，用本脚本检测并自动写入 `.env`（`NAT_MODE=extip`、`NAT_EXTIP=<IP>`），变化时 `docker compose up -d` 重建容器：

```bash
bash scripts/update-extip.sh          # 手动执行一次
crontab -e                             # 每 5 分钟检测
*/5 * * * * cd /data3/bsc-node-reth && bash scripts/update-extip.sh >> data/logs/extip.log 2>&1
```

IP 未变时什么都不做。开启 Tailscale exit node 时查到的是出口节点 IP，不要同时使用。路由器 WAN 口若是 `100.64.x.x` / `10.x` 等运营商内网地址（CGNAT），端口转发无效，需向运营商申请公网 IP。

---

## 典型工作流

### A. 节点机只跑已推送镜像（推荐）

```bash
cp .env.example .env
# RETH_IMAGE=ghcr.io/<你>/bsc-reth:v0.1.2
# HTTP_BIND_ADDR=<Tailscale IP>
docker pull "$RETH_IMAGE"   # 或 RETH_COMPOSE_PULL=true 时 compose pull
bash scripts/setup.sh init
docker compose up -d
bash scripts/status.sh
```

### B. 构建机：构建 → 推送 → 节点拉取

```bash
docker login ghcr.io
bash scripts/publish-image.sh ghcr.io/<你>/bsc-reth v0.1.2
```

### C. 创世同步（默认）

保持 `RETH_SYNC_MODE=genesis`，空 `data/reth/db` 首次启动从 0 同步。已有 `db/` 则 **断点续传**。

### D. 从快照导入后再追块

```bash
# .env: RETH_SYNC_MODE=snapshot
bash scripts/deploy.sh --with-snapshot --bg-download
bash scripts/snapshot.sh status    # 直到完成
bash scripts/setup.sh init && docker compose up -d
```

### E. 换镜像版本

```bash
# 改 .env RETH_IMAGE
docker compose pull   # 若 RETH_COMPOSE_PULL=true
docker compose down && docker compose up -d
```

跨大版本可能需 [MIGRATE_V2.md](https://github.com/bnb-chain/reth-bsc/blob/main/MIGRATE_V2.md) 的 db 迁移。

---

## 环境变量要点（`.env`）

| 变量 | 默认 | 说明 |
|------|------|------|
| `RETH_SYNC_MODE` | `genesis` | `snapshot` 时配合 `snapshot.sh` / deploy `--with-snapshot` |
| `RETH_IMAGE` | `bsc-reth-local:latest` | 远程节点改为 `ghcr.io/...` |
| `RETH_COMPOSE_PULL` | `false` | 自建镜像保持 false |
| `RETH_DEBUG` | `false` | `true` 时提高 RUST_LOG debug，日志更吵 |
| `RUST_LOG` | `info,reth=info,reth_bsc=info` | 与 `RETH_DEBUG` 配合 |
| `RETH_LOG_FILE_DIR` | （空） | 非空则容器写文件日志 |
| `RETH_NODE_EXTRA_ARGS` | （空） | 额外 reth 参数（v0.1.2 勿填已废弃 prefetch 类） |
| `PRUNE_STATIC_HISTORY_MONTHS` | `18` | 交易/回执等静态数据保留月数 |
| `PRUNE_STATE_HISTORY_MONTHS` | `17` | state 历史保留月数 |
| `BLOCK_TIME_SEC` | `0.45` | 月数换算块数用的出块间隔 |
| `RETH_TRUSTED_PEERS` | （空） | 非空则 **整表覆盖** 默认 + 文件合并前的 base |
| `RETH_REGISTRY` / `RETH_BSC_REF` | （空） | 构建/发布用 |

完整列表见 **`.env.example`**。

---

## 持久化 Peer

| 方式 | 说明 |
|------|------|
| **自动** | `data/reth/known-peers.json`（discv，随 `data/reth` 备份） |
| **优先连接** | 内置 4 个 BSC 官方 enode + **`config/trusted-peers.txt`**（`start.sh` 合并去重） |
| **整表覆盖** | `.env` **`RETH_TRUSTED_PEERS=enode://...,enode://...`** |

手动追加：编辑 `config/trusted-peers.txt`（每行一个 `enode://...`），`docker compose restart reth`。

---

## 故障排查速查

| 现象 | 处理 |
|------|------|
| `未找到 reth.toml` | `bash scripts/setup.sh init` |
| `python3: command not found`（**容器**内 start.sh） | 同步最新 `start.sh`（已改为 bash）；`docker compose restart reth` |
| `python3` 缺失（**宿主机** deploy） | `apt install python3`；只生成配置可直接 `bash scripts/setup.sh init`（不依赖 python3） |
| `.env` 语法错误 / 混入 push 日志 | `bash scripts/repair-env.sh` |
| 镜像不对 / 本地 tag | 检查 `RETH_IMAGE`，必要时 `repair-env` + 手动改 |
| 日志 FCU / genesis WARN 刷屏 | `RETH_DEBUG=false`，保持 `RUST_LOG=info,...` |
| 同步极慢、peer 少 | `admin_nodeInfo` 看 enode 是否 `0.0.0.0` → `update-extip.sh` + 路由器转发 30303；再 `refresh-trusted-peers.sh` |
| 要重来 | `reset-data.sh` → 再 deploy 或 compose up |

---

## 与 `--full` 的区别

| 模式 | 历史 state |
|------|------------|
| `reth-bsc node --full` | ~10,064 块 |
| **本方案**（`reth.toml`） | 静态 ~**105.2M** 块（18 个月）/ state ~**99.3M** 块（17 个月） |

---

## 参考

- [reth-bsc](https://github.com/bnb-chain/reth-bsc)
- [Reth 裁剪](https://reth.rs/run/storage/pruning/)
- [MIGRATE_V2.md](https://github.com/bnb-chain/reth-bsc/blob/main/MIGRATE_V2.md)
