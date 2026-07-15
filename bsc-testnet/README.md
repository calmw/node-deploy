# BSC Chapel 测试网节点

BSC **Chapel Testnet**（Chain ID **97**），与 `bsc-node/` 主网 **端口、容器名、数据目录完全隔离**，可同机部署。

| 项目 | 值 |
|------|-----|
| 链 | Chapel Testnet（`chainId=97`） |
| P2P / RPC / WS | **30311** / **8575** / **8576** |
| 容器 | `bsc-testnet-node` |
| 数据 | `./data/node`、`./config/` |
| 默认同步 | **snap**（无需预下载快照） |

## 同机部署主网 + 测试网

| 节点 | 目录 | P2P | RPC | WS |
|------|------|-----|-----|-----|
| **主网** | `bsc-node/` | **30303** | **8545** | **8546** |
| **测试网** | `bsc-testnet/` | **30311** | **8575** | **8576** |

测试网官方 RPC 为 **8575/8576**，与主网 **8545/8546** 不冲突；Metrics 测试网 **16060**、主网 **6060**。

```bash
ss -tlnp | grep -E '8545|8575|30303|30311'
```

---

## 脚本一览

| 脚本 | 用途 |
|------|------|
| `scripts/setup.sh` | 首次初始化 / `repair` 修复配置 |
| `scripts/deploy.sh` | 一键部署（setup + .env + 启动） |
| `scripts/fix-config.sh` | 强制重写 `config.toml` 并重启 |
| `scripts/status.sh` | 容器、端口、RPC、同步状态 |
| `scripts/refresh-static-nodes.sh` | peer 少时抓取 enode 写入配置 |
| `scripts/reset-data.sh` | 清空链数据 |
| `scripts/snapshot.sh` | ⚠️ 仅主网 48Club 快照，测试网勿用 |

---

## 第一次启动（完整流程）

**前置：** Docker + Compose v2；磁盘建议 ≥ **100GB**（snap 随链增长）。

```bash
cd bsc-testnet
chmod +x scripts/*.sh

# 1. 初始化：下载 testnet genesis + 写入 config.toml
bash scripts/setup.sh

# 2. 环境变量
cp .env.example .env
# 编辑 .env（Tailscale 远程访问示例）：
#   HTTP_BIND_ADDR=100.x.x.x
#   WS_BIND_ADDR=100.x.x.x
#   HTTP_VHOSTS=localhost,127.0.0.1,100.x.x.x

# 3. 启动
docker compose up -d

# 4. 验证
bash scripts/status.sh
```

或一条命令：

```bash
bash scripts/deploy.sh
```

### 首次启动预期

- 日志出现 `Enabled snap sync`、`Block synchronisation started` → 正常
- `eth_chainId` 返回 **`0x61`**（97）
- 监听 **`8575`**（RPC）、**`30311`**（P2P）
- snap 从零同步需 **数小时～一天+**（视带宽与 peer）；日志里 `Syncing: chain download in progress` 持续增长即正常

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  http://127.0.0.1:8575

docker exec bsc-testnet-node geth attach --datadir /bsc/node --exec "eth.syncing"
docker exec bsc-testnet-node geth attach --datadir /bsc/node --exec "net.peerCount"
```

### 从主网配置迁过来

若目录曾是主网拷贝，**必须先**：

```bash
bash scripts/setup.sh repair    # 重写 testnet genesis + config
# 若 data/node 是主网链数据：
bash scripts/reset-data.sh      # 确认后清空
docker compose up -d
```

---

## 日常操作

### 启动

```bash
cd bsc-testnet
docker compose up -d
```

链数据在 `data/node/`，**重启后接着同步**，不会从头再来。

### 停止

```bash
docker compose down
```

**保留** `data/node/` 链数据。仅停容器、不删数据用这个即可。

若在后台下载快照（一般测试网不需要）：

```bash
bash scripts/snapshot.sh stop
```

### 日常重启（未改配置）

```bash
docker compose restart
# 或
docker compose down && docker compose up -d
```

### 改 `.env` 或 `config/` 后重启

**必须** `down` 再 `up`（`restart` 不会重读端口绑定）：

```bash
docker compose down && docker compose up -d
```

### 查看状态

```bash
bash scripts/status.sh

docker compose ps
docker compose logs -f --tail 50 bsc
tail -f data/node/bsc.log.*    # 文件日志（按日期）

docker exec bsc-testnet-node geth attach --datadir /bsc/node --exec "eth.blockNumber"
docker exec bsc-testnet-node geth attach --datadir /bsc/node --exec "eth.syncing"
docker exec bsc-testnet-node geth attach --datadir /bsc/node --exec "net.peerCount"
```

同步完成：`eth.syncing` 为 `false`，`blockNumber` 接近链头。

---

## peer 少 / 同步慢

测试网 peer 靠 **`start.sh` 内置 bootnodes**（Chapel 官方 4 个 enode）+ 网络发现。启动初期 `peercount=0` 常见，若随后出现 `chain download in progress` 则已在同步。

### 1. 先确认在跑且 P2P 正常

```bash
docker compose ps                    # 应为 Up，非 Restarting
ss -tlnp | grep 30311
docker exec bsc-testnet-node geth attach --datadir /bsc/node --exec "net.peerCount"
```

### 2. 刷新 StaticNodes（对称 NAT / 家里网络推荐）

节点跑起来并有过 peer 后：

```bash
# 抓取当前 peer 的 enode 写入 config（不重启）
bash scripts/refresh-static-nodes.sh

# 写入并立即重启生效
RESTART=1 bash scripts/refresh-static-nodes.sh
```

可多拉几轮：

```bash
ROUNDS=24 INTERVAL=5 bash scripts/refresh-static-nodes.sh
```

### 3. 检查 NAT

`.env` 默认 `NAT_MODE=any`（动态公网 IP / 家用推荐）。固定公网 IP 才用 `NAT_MODE=extip` + `NAT_EXTIP`。

### 4. 仍无 peer

- 确认 `P2P_PORT=30311`、防火墙放行 **TCP+UDP 30311**（可选，有 outbound 通常也能慢慢连上）
- 查日志：`grep -i peer data/node/bsc.log.*`
- 勿把 `BSC_SYNC_MODE` 设成 `fast`（那是主网快照）

---

## 配置说明

### `.env` 常用项

| 变量 | 默认 | 说明 |
|------|------|------|
| `BSC_SYNC_MODE` | `snap` | 测试网推荐 |
| `P2P_PORT` | `30311` | 勿与主网 30303 混 |
| `HTTP_PORT` / `WS_PORT` | `8575` / `8576` | 官方测试网端口 |
| `HTTP_BIND_ADDR` | `127.0.0.1` | 改 Tailscale IP 供团队远程 RPC |
| `NAT_MODE` | `any` | 家用动态 IP 用 `any` |

远程 RPC 示例：

```bash
# .env
HTTP_BIND_ADDR=100.75.33.104
WS_BIND_ADDR=100.75.33.104
HTTP_VHOSTS=localhost,127.0.0.1,100.75.33.104

docker compose down && docker compose up -d
```

### `config/`

| 文件 | 说明 |
|------|------|
| `genesis.json` | `setup.sh` 从官方 `testnet.zip` 下载，`chainId=97` |
| `config.toml` | `NetworkId=97`；`StaticNodes = []`（peer 走 bootnodes + refresh 脚本） |

配置损坏或 `line 42: invalid TOML`：

```bash
bash scripts/fix-config.sh
# 等同 bash scripts/setup.sh repair
```

---

## 同步模式

| 模式 | 适用 | 说明 |
|------|------|------|
| **snap**（默认） | 测试网开发 | 无需预下载，首 sync 较慢 |
| **pruned** | 想加速 | 官方 testnet 裁剪快照 ~180GB，[bsc-snapshots](https://github.com/bnb-chain/bsc-snapshots) |
| **fast** | ❌ | 48Club 仅主网，勿用于本目录 |

---

## 清空数据 / 换模式

```bash
docker compose down
bash scripts/reset-data.sh    # 交互确认，删 data/node/*
docker compose up -d          # snap 重新同步
```

---

## 测试币

[BNB Chain 测试网水龙头](https://testnet.bnbchain.org/zh-CN/faucet-smart) 领取 tBNB（`chainId=97` 地址）。

---

## 故障排查

| 现象 | 处理 |
|------|------|
| `config.toml line 42: invalid TOML` | `bash scripts/fix-config.sh` |
| 容器 `Restarting` | `docker compose logs --tail 50 bsc` |
| `chainId` 不是 `0x61` | `bash scripts/setup.sh repair`；必要时 `reset-data.sh` |
| 8575 无响应，只有主网 8545 | 确认在 `bsc-testnet` 目录 `docker compose ps` 为 `bsc-testnet-node` |
| repair 报 `.env not found` | `cp .env.example .env` 后 `docker compose up -d` |
| 服务器非 git 仓库 | 从开发机同步 `scripts/setup.sh` 等文件后 `bash scripts/setup.sh repair` |

---

## 参考

- [BSC Docker 文档](https://docs.bnbchain.org/bnb-smart-chain/developers/node_operators/docker/)
- [BSC Releases（testnet.zip）](https://github.com/bnb-chain/bsc/releases)
- [BSC 官方快照](https://github.com/bnb-chain/bsc-snapshots)
