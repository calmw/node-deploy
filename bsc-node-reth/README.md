# BSC 主网 Reth 节点（一年 state 裁剪）

独立机器运行 **bnb-reth**（`ghcr.io/bnb-chain/bsc-reth`），通过 `reth.toml` **自定义裁剪**，保留约 **365 天**历史 state（按 **0.45s/块** ≈ `PRUNE_HISTORY_DISTANCE=71_000_000`）。

| 项目 | 值 |
|------|-----|
| 链 | BSC Mainnet（`chainId=56`） |
| P2P / RPC / WS | **30303** / **8545** / **8546** |
| 容器 | `bsc-node-reth` |
| 数据 | `./data/reth/`（`db/`、`static_files/`、`reth.toml`） |
| 磁盘建议 | **4TB**（官方 Reth Full 快照约 **3.23 TiB** + 余量） |
| 与 geth | **不同机**；本目录不再使用 geth / 48Club 快照 |

## 和 `--full` 的区别

| 模式 | 历史 state 窗口 |
|------|-----------------|
| `reth-bsc node --full` | 约 **10,064** 块（0.45s 下 ~1.3 小时） |
| **本方案**（`reth.toml` distance） | 约 **71M** 块（~**365 天**） |

**勿**在启动参数里加 `--full`；裁剪规则以 `data/reth/reth.toml` 为准。

### 快照 + 一年窗口（重要）

推荐用 [官方 Reth Full 快照](https://github.com/bnb-chain/bsc-snapshots#source-4-bsc-reth-snapshots) 快速追到链头。该快照由 **Full 节点**导出，库内**更早**的历史 state **不一定**已有 365 天。

节点追块并稳定运行后，会按 `distance` **滚动保留链头往前约 1 年**；超出窗口的数据会被 prune 掉且**不可恢复**。

若必须从创世就保留完整 1 年窗口，只能**不用快照、从 genesis 同步**（耗时长，4TB 需密切监控磁盘）。

---

## 脚本一览

| 脚本 | 用途 |
|------|------|
| `scripts/setup.sh` | 生成 `data/reth/reth.toml` |
| `scripts/deploy.sh` | 配置 + 快照 + 启动 |
| `scripts/snapshot.sh` | 下载/解压 Reth Full `.tar.zst` |
| `scripts/status.sh` | 容器、磁盘、RPC、同步 |
| `scripts/reset-data.sh` | 清空 `data/reth/` |
| `scripts/start.sh` | 容器入口（勿手跑） |

---

## 第一次启动

**前置：** Docker Compose v2、`zstd`、**≥3.5TB 可用空间**、内存 **≥32GB** 推荐。

```bash
cd bsc-node-reth
chmod +x scripts/*.sh

cp .env.example .env
# 编辑: HTTP_BIND_ADDR / WS_BIND_ADDR = tailscale ip -4
# 可选: PRUNE_HISTORY_DISTANCE、RETH_SNAPSHOT_URL、RETH_IMAGE 固定版本

# 后台下载快照（约 3.23 TiB，可关终端）
bash scripts/deploy.sh --bg-download

bash scripts/snapshot.sh status
bash scripts/snapshot.sh log

# 快照完成后
docker compose up -d
bash scripts/status.sh
```

一条命令（前台下载，占满终端）：

```bash
bash scripts/deploy.sh
```

已有 `data/reth/db`：

```bash
bash scripts/deploy.sh --skip-download
```

### 验证

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  http://127.0.0.1:8545
# 期望 0x38

curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
  http://127.0.0.1:8545
```

---

## 日常操作

```bash
# 启动 / 停止
docker compose up -d
docker compose down          # 保留 data/reth

# 改 .env 或 reth.toml 后
bash scripts/setup.sh init
docker compose down && docker compose up -d

# 状态
bash scripts/status.sh
docker compose logs -f --tail 50 reth
```

---

## 裁剪配置

`.env`：

| 变量 | 默认 | 说明 |
|------|------|------|
| `PRUNE_HISTORY_DISTANCE` | `71000000` | 保留最近 N+1 块相关数据 |
| `PRUNE_HISTORY_DAYS` | （可选） | 与 `BLOCK_TIME_SEC` 由 setup 计算块数 |
| `BLOCK_TIME_SEC` | `0.45` | 估算窗口天数用 |

修改后：

```bash
bash scripts/setup.sh init
docker compose down && docker compose up -d
```

**缩小** `distance` 会 prune 更多历史且不可恢复；**放大**只会影响之后保留范围，不会补回已删数据。

模板：`config/reth.toml.template` → 输出 `data/reth/reth.toml`。

---

## RPC 能力（预期）

在 **1 年窗口内**（且快照/同步已具备对应段数据）：

- `eth_getBalance` / `eth_getStorageAt` 带历史 block tag
- `eth_getLogs`（配置了 `receipts` distance）
- `eth_getTransactionByHash`（配置了 `transaction_lookup` distance）

窗口外返回错误或最新态。**Archive 级**全链查询需 7TB+ 快照，4TB 机器不适用。

`debug_*` / `trace_*` 能力取决于 reth-bsc 版本与是否 archive；深度 trace 请单独压测。

---

## 磁盘与 4TB 规划

| 阶段 | 占用 |
|------|------|
| 下载 `.tar.zst` | 与压缩包相当（解压后脚本会删包） |
| 解压后 Full 快照 | ~**3.2TB+** |
| 运行 + 1 年窗口 | 预留 **300GB~1TB** 余量 |

空间紧张时：快照下载目录与 `data/reth` 可同盘；确保 `df -h` 在解压前 **≥3500GB 可用**。

---

## 故障排查

| 现象 | 处理 |
|------|------|
| 启动报无 `reth.toml` | `bash scripts/setup.sh init` |
| 镜像内无 `reth-bsc` | 检查 `RETH_IMAGE` 标签，见 [bsc-reth packages](https://github.com/bnb-chain/reth-bsc/pkgs/container/bsc-reth) |
| v1→v2 存储 | 按官方 [MIGRATE_V2.md](https://github.com/bnb-chain/reth-bsc/blob/main/MIGRATE_V2.md) 执行 `db migrate-v2` |
| 换快照 / 重配 prune | `bash scripts/reset-data.sh` 后重新 `deploy` |

---

## 参考

- [reth-bsc](https://github.com/bnb-chain/reth-bsc)
- [BSC Reth 快照](https://github.com/bnb-chain/bsc-snapshots#source-4-bsc-reth-snapshots)
- [Reth 裁剪配置](https://reth.rs/run/storage/pruning/)
