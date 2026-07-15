# BSC Chapel 测试网节点

BSC **Chapel Testnet**（Chain ID **97**），与 `bsc-node/` 主网 **端口、容器名、数据目录完全隔离**，可同机部署。

| 项目 | 值 |
|------|-----|
| 链 | BSC Chapel Testnet（`chainId=97`） |
| P2P / RPC / WS | **30311** / **8575** / **8576** |
| 容器 | `bsc-testnet-node` |
| 默认同步 | **snap**（无需预下载快照） |

## 同机部署主网 + 测试网

| 节点 | 目录 | P2P | RPC | WS |
|------|------|-----|-----|-----|
| **主网** | `bsc-node/` | **30303** | **8545** | **8546** |
| **测试网** | `bsc-testnet/` | **30311** | **8575** | **8576** |

官方测试网 RPC 本就使用 **8575/8576**，与主网 **8545/8546** 不冲突；P2P 为 **30311** vs **30303**。Metrics 测试网用 **16060**（主网 6060）。

```bash
ss -tlnp | grep -E '8545|8575|30303|30311'
```

## 快速开始

```bash
cd bsc-testnet
chmod +x scripts/*.sh

bash scripts/setup.sh          # 下载 testnet.zip → genesis + config
cp .env.example .env           # 按需改 HTTP_BIND_ADDR
bash scripts/deploy.sh
# 或
docker compose up -d
```

### 验证

```bash
docker compose logs -f --tail 50
docker exec bsc-testnet-node geth attach --datadir /bsc/node --exec "eth.syncing"
docker exec bsc-testnet-node geth attach --datadir /bsc/node --exec "net.peerCount"

curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  http://127.0.0.1:8575
# 期望: "0x61" (97)
```

## 配置

### `.env`

| 变量 | 默认 | 说明 |
|------|------|------|
| `BSC_SYNC_MODE` | `snap` | 测试网推荐；`fast` 为**主网专用** |
| `P2P_PORT` | `30311` | Chapel P2P |
| `HTTP_PORT` / `WS_PORT` | `8575` / `8576` | 官方测试网 RPC 端口 |
| `METRICS_PORT` | `16060` | 避免与主网 6060 冲突 |
| `HTTP_BIND_ADDR` | `127.0.0.1` | Tailscale IP 供团队远程访问 |

### `config/`

- `setup.sh` 从 [bnb-chain/bsc releases](https://github.com/bnb-chain/bsc/releases) 下载 **testnet.zip**
- `genesis.json`：`chainId=97`
- `config.toml`：`NetworkId=97`，含官方 **StaticNodes**（端口 30311）

若当前是主网配置，执行：

```bash
bash scripts/setup.sh repair
```

## 同步模式

| 模式 | 说明 |
|------|------|
| **snap**（默认） | 网络 snap 同步，磁盘随链增长，适合测试网 |
| **pruned** | 官方 testnet 裁剪快照 ~180GB，见 [bsc-snapshots](https://github.com/bnb-chain/bsc-snapshots) |
| **fast** | ❌ 48Club 快照仅主网，`snapshot.sh` 勿用于测试网 |

## 常用命令

```bash
bash scripts/refresh-static-nodes.sh    # peer 少时刷新 StaticNodes
docker compose down
bash scripts/reset-data.sh              # 清空链数据
bash scripts/setup.sh repair
```

## 测试币

Chapel 测试网 BNB 水龙头：搜索 “BSC testnet faucet” 或 [testnet.bnbchain.org](https://testnet.bnbchain.org/zh-CN/faucet-smart)。

## 故障排查

| 现象 | 处理 |
|------|------|
| `chainId` 不是 97 | `bash scripts/setup.sh repair` 重新拉 testnet.zip |
| 无 peer | `bash scripts/refresh-static-nodes.sh`；确认 `P2P_PORT=30311` |
| 与主网端口冲突 | 对照上表，主网勿改 8545/30303 |
| 误用主网快照 | 清空 `data/node` 后 snap 重来 |

## 参考

- [BSC Docker 文档](https://docs.bnbchain.org/bnb-smart-chain/developers/node_operators/docker/)
- [BSC testnet.zip](https://github.com/bnb-chain/bsc/releases)
