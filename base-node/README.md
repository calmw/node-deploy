# Base 主网 / Sepolia 节点（Docker Compose · Pruned）

使用 [Base 官方 node-reth 镜像](https://github.com/base/node) 运行 Base L2 节点，包含：

- **execution**（`base-reth-node`）：执行层，提供 JSON-RPC / WebSocket
- **consensus**（`base-consensus`）：共识层，连接 L1 以太坊并驱动执行层同步

**默认模式：Pruned（裁剪）**，保留约最近 **1_339_200 块（≈31 天）** 的状态与索引，显著节省磁盘；与官方 pruned 快照一致。

## 架构概览

```text
┌──────────────────────────────────────────────────────────────┐
│  宿主机                                                       │
│  ┌─────────────────────┐    ┌─────────────────────────────┐  │
│  │  base-execution     │◄──►│  base-consensus             │  │
│  │  base-reth-node     │JWT │  base-consensus             │  │
│  │  RPC  :8545 (本机)  │    │  依赖 L1 RPC + Beacon       │  │
│  │  WS   :8546 (本机)  │    └──────────────┬──────────────┘  │
│  │  P2P  :30303        │                   │                 │
│  └─────────────────────┘                   ▼                 │
│                              Ethereum L1（必填，自备）        │
│  数据卷: base-node-data → /data (reth chaindata)             │
└──────────────────────────────────────────────────────────────┘
```

## 前置要求

| 项目 | Pruned（默认） | Archive（可选） |
|------|----------------|-----------------|
| Docker | Engine 24+ / Compose v2 | 同左 |
| 内存 | **≥ 32GB**（推荐 64GB） | 同左 |
| 磁盘 | **≥ 200GB**（建议 300GB+；可用 pruned 快照） | **数百 GB～1TB+** |
| L1 节点 | 主网 / Sepolia **RPC + Beacon**（必填） | 同左 |

> Base 是 OP Stack L2，**必须**配置可用的 L1 以太坊节点。

## 快速开始

### 1. 初始化配置

```bash
cd base-node
chmod +x scripts/*.sh
./scripts/setup.sh
```

脚本会创建 `.env` 与 `config/network.env`（**已含 Pruned 参数**）。

### 2. 配置 L1 端点

编辑 `config/network.env`：

```ini
BASE_NODE_L1_ETH_RPC=https://your-eth-mainnet-rpc
BASE_NODE_L1_BEACON=https://your-eth-beacon-api
```

### 3. 启动节点

```bash
./scripts/start.sh
# 或
./scripts/start.sh -f
```

### 4. 检查同步

```bash
./scripts/status.sh
./scripts/base-rpc.sh eth_syncing
```

## Pruned 能力边界

| 能力 | Pruned（默认，~31 天） | Archive |
|------|------------------------|---------|
| 最新 RPC / 发交易 | ✅ | ✅ |
| 近期交易 / logs | ✅ 窗口内 | ✅ 全链 |
| `debug_trace` / 内部交易 | ✅ 窗口内 | ✅ 全链 |
| 磁盘占用 | 较小 | 很大 |

配合 **实时 trace 落库** 索引 internal tx 时，Pruned 通常足够；老于 ~31 天的数据需 Archive 或第三方 RPC。

> **节点类型在首次同步后不可更改**（Pruned ↔ Archive 需清数据重建）。见 [reth pruning FAQ](https://reth.rs/run/faq/pruning/)。

## 目录结构

```text
base-node/
├── docker-compose.yml
├── .env.example
├── config/
│   ├── env.mainnet.example          # 主网 Pruned（默认模板）
│   ├── env.sepolia.example          # Sepolia Pruned
│   ├── env.mainnet.archive.example  # 主网 Archive（可选）
│   ├── env.sepolia.archive.example
│   └── network.env                  # 实际配置（setup 生成）
├── scripts/
│   ├── setup.sh
│   ├── start.sh
│   ├── stop.sh
│   ├── status.sh
│   ├── reset-data.sh                # 清卷重建（切换模式时用）
│   └── base-rpc.sh
└── README.md
```

## 配置说明

### Pruned 参数（`config/network.env`）

默认已启用：

```ini
RETH_PRUNING_ARGS=--prune.senderrecovery.distance=1339200 --prune.transactionlookup.distance=1339200 --prune.receipts.distance=1339200 --prune.accounthistory.distance=1339200 --prune.storagehistory.distance=1339200 --prune.bodies.distance=1339200
```

`1339200` 与 [官方 pruned 快照](https://docs.base.org/base-chain/node-operators/snapshots) 一致（Base ~2 秒/块 ≈ **31 天**）。

### 切换为 Archive 全节点

```bash
./scripts/stop.sh
bash scripts/reset-data.sh          # 或 docker compose down -v
cp config/env.mainnet.archive.example config/network.env
# 编辑 L1 RPC / Beacon
./scripts/start.sh
```

Archive 配置 **不要** 设置 `RETH_PRUNING_ARGS`。

### 从 Archive 改为 Pruned

若曾以 Archive 跑过，必须清数据后重来：

```bash
./scripts/stop.sh
bash scripts/reset-data.sh
cp config/env.mainnet.example config/network.env   # 或手动恢复 RETH_PRUNING_ARGS
# 填写 L1 端点
./scripts/start.sh
```

### 其他可选配置

- **Flashblocks**：`RETH_FB_WEBSOCKET_URL=wss://mainnet.flashblocks.base.org/ws`
- **固定 P2P IP**：`BASE_NODE_P2P_ADVERTISE_IP=...`

## 快照加速（推荐 Pruned）

从头 sync 较慢，建议导入 **pruned 快照**（勿用 archive 快照配 pruned 参数）：

1. `./scripts/stop.sh`
2. 从 [Base Snapshots 文档](https://docs.base.org/base-chain/node-operators/snapshots) 下载 **pruned** 快照
3. 解压到卷 `base-node-data` 的 `/data` 目录
4. `./scripts/start.sh`

## 常用命令

```bash
./scripts/start.sh
./scripts/stop.sh
docker compose logs -f execution
docker compose down -v              # 停止并删数据卷
bash scripts/reset-data.sh          # 交互式清卷
```

## 故障排查

### 已有 Archive 数据，改成 Pruned 后启动异常

Pruned 与 Archive 数据不兼容 → `bash scripts/reset-data.sh` 后重新 sync 或导入 pruned 快照。

### consensus 无法获取公网 IP

在 `config/network.env` 设置 `BASE_NODE_P2P_ADVERTISE_IP`。

### L1 连接错误

确认 `BASE_NODE_L1_ETH_RPC` / `BASE_NODE_L1_BEACON` 与 `NETWORK`（mainnet/sepolia）一致。

## 参考链接

- [Base 官方节点仓库](https://github.com/base/node)
- [Base 快照](https://docs.base.org/base-chain/node-operators/snapshots)
- [Base 节点文档](https://docs.base.org/base-chain/node-operators/run-a-base-node)

## 许可证

本项目配置与脚本以 MIT 方式提供；Base 软件遵循其各自的开源许可证。
