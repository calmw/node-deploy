# Base 主网 / Sepolia 节点（Docker Compose）

使用 [Base 官方 node-reth 镜像](https://github.com/base/node) 运行 Base L2 全节点，包含：

- **execution**（`base-reth-node`）：执行层，提供 JSON-RPC / WebSocket
- **consensus**（`base-consensus`）：共识层，连接 L1 以太坊并驱动执行层同步

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

| 项目 | 建议 |
|------|------|
| Docker | Docker Engine 24+ 与 Docker Compose v2 |
| 内存 | **≥ 32GB**（官方推荐 64GB） |
| 磁盘 | NVMe SSD；全量同步需 **数百 GB**（可用官方快照加速） |
| L1 节点 | **必填**：Ethereum 主网（或 Sepolia）全节点 **RPC + Beacon** |
| 带宽 | 稳定网络；初始同步流量较大 |

> Base 是 OP Stack L2，**必须**配置可用的 L1 以太坊节点，否则 consensus 无法工作。

## 快速开始

### 1. 初始化配置

```bash
cd base-node
chmod +x scripts/*.sh
./scripts/setup.sh
```

脚本会创建 `.env` 与 `config/network.env`。

### 2. 配置 L1 端点

编辑 `config/network.env`，填入你的 L1 节点地址：

```ini
BASE_NODE_L1_ETH_RPC=https://your-eth-mainnet-rpc
BASE_NODE_L1_BEACON=https://your-eth-beacon-api
```

可使用自建以太坊全节点，或 Alchemy / Infura 等（需同时提供 execution RPC 与 consensus/beacon API）。

### 3. 启动节点

```bash
./scripts/start.sh
```

加 `-f` 可启动后直接跟踪日志：

```bash
./scripts/start.sh -f
```

### 4. 检查同步状态

```bash
./scripts/status.sh
./scripts/base-rpc.sh eth_blockNumber
./scripts/base-rpc.sh eth_syncing
```

## 目录结构

```text
base-node/
├── docker-compose.yml
├── .env.example
├── config/
│   ├── env.mainnet.example    # 主网配置模板
│   ├── env.sepolia.example    # Sepolia 配置模板
│   └── network.env            # 实际配置（setup 生成，勿提交）
├── scripts/
│   ├── setup.sh               # 一键初始化
│   ├── start.sh               # 启动节点
│   ├── stop.sh                # 停止节点
│   ├── status.sh              # 容器与同步状态
│   └── base-rpc.sh            # JSON-RPC 封装
└── README.md
```

区块链数据保存在 Docker 命名卷 `base-node-data` 中。

## 配置说明

### 环境变量（`.env`）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `BASE_NODE_IMAGE` | `ghcr.io/base/node-reth` | 官方镜像 |
| `BASE_NODE_VERSION` | `v1.1.1` | 镜像标签，见 [releases](https://github.com/base/node/releases) |
| `NETWORK` | `mainnet` | `mainnet` 或 `sepolia`（仅 setup 时使用） |
| `HTTP_PORT` | `8545` | 执行层 JSON-RPC（绑定 127.0.0.1） |
| `WS_PORT` | `8546` | 执行层 WebSocket |
| `P2P_EXEC_PORT` | `30303` | 执行层 P2P |
| `P2P_CONSENSUS_PORT` | `9222` | 共识层 P2P |

### 切换测试网

1. 修改 `.env` 中 `NETWORK=sepolia`
2. 删除 `config/network.env` 后重新 `./scripts/setup.sh`
3. 填写 Sepolia L1 RPC / Beacon
4. `./scripts/start.sh`

### 可选功能

在 `config/network.env` 中取消注释即可：

- **Flashblocks**：`RETH_FB_WEBSOCKET_URL=wss://mainnet.flashblocks.base.org/ws`
- **裁剪节点**：`RETH_PRUNING_ARGS=...`（首次同步前设置，之后不可更改节点类型）
- **固定 P2P 公网 IP**：`BASE_NODE_P2P_ADVERTISE_IP=你的公网IP`

## 常用命令

```bash
# 启动 / 停止
./scripts/start.sh
./scripts/stop.sh

# 日志
docker compose logs -f execution
docker compose logs -f consensus

# RPC 示例
./scripts/base-rpc.sh eth_chainId
./scripts/base-rpc.sh eth_getBlockByNumber '["latest", false]'

# 停止并删除容器（数据卷保留）
docker compose down

# 停止并删除数据卷（⚠️ 需重新同步）
docker compose down -v
```

## 快照加速

全量从头同步耗时很长。可使用官方快照 bootstrap，详见 [Base 文档 - Snapshots](https://docs.base.org/base-chain/node-operators/snapshots)。

大致步骤：

1. 停止节点：`./scripts/stop.sh`
2. 按文档下载并解压快照到卷 `base-node-data` 的 `/data` 目录
3. 重新启动：`./scripts/start.sh`

## 故障排查

### consensus 无法启动 / 获取公网 IP 失败

consensus 启动时会自动探测公网 IP 用于 P2P 广播。若环境无外网或探测失败，在 `config/network.env` 中手动设置：

```ini
BASE_NODE_P2P_ADVERTISE_IP=你的公网或 Tailscale IP
```

### execution 一直等待 / RPC 不可用

consensus 需等待 execution 的 Engine API（8551）就绪。查看日志：

```bash
docker compose logs --tail=50 execution
docker compose logs --tail=50 consensus
```

### L1 连接错误

确认 `BASE_NODE_L1_ETH_RPC` 与 `BASE_NODE_L1_BEACON` 可访问，且与所选网络（mainnet / sepolia）一致。

### 升级节点版本

1. 修改 `.env` 中 `BASE_NODE_VERSION`（参考 [base/node releases](https://github.com/base/node/releases)）
2. 执行：

```bash
docker compose pull
docker compose up -d
```

## 安全建议

1. **RPC 仅本机访问**：`docker-compose.yml` 已将 8545/8546 绑定到 `127.0.0.1`
2. **勿提交密钥**：`.env` 与 `config/network.env` 已在 `.gitignore` 中
3. **L1 RPC 密钥**：若使用第三方 RPC，注意配额与 IP 白名单

## 参考链接

- [Base 官方节点仓库](https://github.com/base/node)
- [Base 节点文档](https://docs.base.org/base-chain/node-operators/run-a-base-node)
- [Base V1 / Azul 升级说明](https://docs.base.org/base-chain/node-operators/base-v1-upgrade)

## 许可证

本项目配置与脚本以 MIT 方式提供；Base 软件遵循其各自的开源许可证。
