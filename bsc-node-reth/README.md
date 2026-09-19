# BSC 主网节点 Docker 部署

在家里服务器运行 BSC **主网** Fast Node（Chain ID **56**）；P2P 家用直连（`NAT_MODE=any`），RPC 经 **Tailscale** 内网访问。

| 项目 | 值 |
|------|-----|
| 链 | BSC Mainnet（`chainId=56`） |
| P2P / RPC / WS | **30303** / **8545** / **8546** |
| 容器 | `bsc-node` |
| 数据 | `./data/node`、`./config/` |
| 默认同步 | **fast**（48Club 快照 ~420GB） |

## 同机部署主网 + 测试网

| 节点 | 目录 | P2P | RPC | WS |
|------|------|-----|-----|-----|
| **主网** | `bsc-node/` | **30303** | **8545** | **8546** |
| **测试网** | `bsc-testnet/` | **30311** | **8575** | **8576** |

两节点端口、容器名、数据目录完全隔离。Metrics 主网 **6060**、测试网 **16060**。

```bash
ss -tlnp | grep -E '8545|8575|30303|30311'
```

---

## 脚本一览

| 脚本 | 用途 |
|------|------|
| `scripts/deploy.sh` | 一键部署（配置 + 快照 + 启动） |
| `scripts/setup.sh` | 首次初始化 / `repair` 修复配置（**保留已有 StaticNodes**） |
| `scripts/snapshot.sh` | 48Club FastNode 快照下载管理 |
| `scripts/refresh-static-nodes.sh` | peer 少时滚雪球抓取 enode 写入 `StaticNodes` |
| `scripts/reset-data.sh` | 清空链数据 |
| `scripts/start.sh` | 容器入口（由 compose 调用，勿手动运行） |

---

## 第一次启动（完整流程）

**前置：** Docker + Compose v2；磁盘 ≥ **500GB**（fast 推荐 1TB）；内存 ≥ **32GB**（trace 方案建议 64GB）。

```bash
cd bsc-node
chmod +x scripts/*.sh

# 1. 初始化 config + genesis
bash scripts/setup.sh

# 2. 环境变量（deploy.sh 会自动创建并填入 Tailscale IP）
cp .env.example .env
# 编辑 .env：
#   tailscale ip -4  →  HTTP_BIND_ADDR / WS_BIND_ADDR
#   NAT_MODE=any     （家用动态 IP，勿用 extip 固定云 IP）
#   TRIES_IN_MEMORY=15000  （trace 窗口，追块期可临时改 4096）

# 3. 下载快照（推荐后台，可关终端）
bash scripts/snapshot.sh start
bash scripts/snapshot.sh status    # 查看进度
# 日志：data/logs/snapshot-download.log

# 4. 快照完成后启动
docker compose up -d

# 5. 验证
docker compose ps
docker compose logs --tail 50 bsc
```

或一条命令（后台下载快照，下载完再手动 `docker compose up -d`）：

```bash
bash scripts/deploy.sh --bg-download
```

已有快照、跳过下载直接启动：

```bash
bash scripts/deploy.sh --skip-download
```

### 快照命令

| 命令 | 作用 |
|------|------|
| `bash scripts/snapshot.sh start` | 后台下载 + 解压 |
| `bash scripts/snapshot.sh status` | 查看进度 |
| `bash scripts/snapshot.sh log` | 实时日志 |
| `bash scripts/snapshot.sh stop` | 停止后台任务 |
| `bash scripts/snapshot.sh download` | 前台下载（需保持终端） |
| `bash scripts/snapshot.sh repair` | 修复解压目录错位 |

### 首次启动预期

- 快照解压后存在 `data/node/geth/chaindata/CURRENT`
- `eth_chainId` 返回 **`0x38`**（56）
- 监听 **`8545`**（RPC）、**`30303`**（P2P）
- fast 模式启动后进入**追块**（`eth.syncing` 有数据）；家用 NAT 下 peer 初期可能很少，见下文「peer 少」

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  http://127.0.0.1:8545

docker exec bsc-node geth attach --datadir /bsc/node --exec "eth.syncing"
docker exec bsc-node geth attach --datadir /bsc/node --exec "net.peerCount"
docker exec bsc-node geth attach --datadir /bsc/node --exec "eth.blockNumber"
```

追块完成后建议执行一次 StaticNodes 刷新（见「peer 少」）。

---

## 日常操作

### 启动

```bash
cd bsc-node
docker compose up -d
```

链数据在 `data/node/`，**重启后接着追块**，不会从头下载快照。

### 停止

```bash
docker compose down
```

**保留** `data/node/` 链数据。仅停容器用这个即可。

若在后台下载快照：

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

**必须** `down` 再 `up`（`restart` 不会重读端口 / NAT 绑定）：

```bash
docker compose down && docker compose up -d
```

### 查看状态

```bash
docker compose ps
docker compose logs -f --tail 50 bsc
tail -f data/node/bsc.log.*    # 文件日志（按日期）

docker exec bsc-node geth attach --datadir /bsc/node --exec "eth.blockNumber"
docker exec bsc-node geth attach --datadir /bsc/node --exec "eth.syncing"
docker exec bsc-node geth attach --datadir /bsc/node --exec "net.peerCount"
```

同步完成：`eth.syncing` 为 `false`，`blockNumber` 接近链头。

---

## peer 少 / 同步慢

家用宽带常见 **对称 NAT + 动态公网 IP**，UDP discovery 不稳定，**inbound≈0 是正常的**。本方案靠 **DialRatio=1** + **StaticNodes 主动外连** 兜底。

> 官方 bootnodes 只做 UDP 发现、不接受 RLPx TCP 连接，**不能**直接当 StaticNodes。

### 1. 先确认节点正常

```bash
docker compose ps                    # 应为 Up，非 Restarting
ss -tlnp | grep 30303
docker exec bsc-node geth attach --datadir /bsc/node --exec "net.peerCount"
docker compose logs --tail 30 bsc | grep -E 'nat=|Started P2P'
```

日志里 enode 应显示**家里真实公网 IP**，而不是已废弃的 FRP 云 IP。

### 2. 滚雪球刷新 StaticNodes（核心操作）

节点跑起来并有过 peer 后：

```bash
# 抓取当前 peer enode 写入 config（不重启）
bash scripts/refresh-static-nodes.sh

# 写入并立即重启生效
RESTART=1 bash scripts/refresh-static-nodes.sh
```

多抓几轮（对称 NAT 推荐）：

```bash
ROUNDS=24 INTERVAL=5 bash scripts/refresh-static-nodes.sh
RESTART=1 bash scripts/refresh-static-nodes.sh
```

等 1～2 分钟后再查 peer。

### 3. `.env` 调优

```bash
MAX_PEERS=120          # 可提高到 100~160
MAX_PEND_PEERS=100
NAT_MODE=any           # 动态 IP 必须用 any，勿 extip 固定过期 IP
```

```bash
# 查看 inbound 占比（家用通常几乎全是 false）
docker exec bsc-node geth attach --datadir /bsc/node \
  --exec "admin.peers.map(p=>p.network.inbound)"
```

### 4. 仍无 peer

- 确认 `P2P_PORT=30303`、路由器放行 **TCP+UDP 30303**（可选，outbound 通常也能慢慢连上）
- 节点尽量插网线（WiFi 易断流）
- 勿在 `.env` 里保留 `NAT_EXTIP=<云服务器 IP>`（已取消 FRP 时）

---

## NAT / P2P 配置

`.env` 推荐（家用直连）：

```bash
NAT_MODE=any
P2P_PORT=30303
# 删除或注释 NAT_EXTIP=43.x.x.x 这类 FRP 云 IP
```

### 可选：FRP 穿透（legacy）

<details>
<summary>仅在使用 FRP 时需要</summary>

1. 云服务器 `frps.toml` → `allowPorts` 加入 `{ single = 30303 }`
2. 家里 `frpc.toml` → 参考 `frpc-bsc.example.toml`
3. 云安全组放行 **TCP + UDP 30303**
4. `.env`：`NAT_MODE=extip`，`NAT_EXTIP=<FRP 云公网 IP>`

</details>

---

## 同步模式

| 模式 | 磁盘 | 说明 |
|------|------|------|
| **fast**（默认） | ~420GB | 48Club FastNode 快照，推荐 |
| snap | 逐渐增长 ~3TB+ | 从网络同步，无需预下载 |
| incr | ~120~200GB | 配置复杂，不推荐 |
| pruned | ~1.6TB | 官方裁剪快照，见 [bsc-snapshots](https://github.com/bnb-chain/bsc-snapshots) |

切换模式需清空数据后重新部署：

```bash
docker compose down
bash scripts/reset-data.sh
bash scripts/deploy.sh
```

---

## 配置说明

### `.env` 常用项

| 变量 | 默认 | 说明 |
|------|------|------|
| `BSC_SYNC_MODE` | `fast` | 主网推荐 fast |
| `NAT_MODE` | `any` | 家用动态 IP |
| `P2P_PORT` | `30303` | 勿与测试网 30311 混 |
| `HTTP_BIND_ADDR` | Tailscale IP | `tailscale ip -4` |
| `TRIES_IN_MEMORY` | `15000` | trace 窗口；追块期可临时 `4096` |
| `MAX_PEERS` | `120` | peer 少时可提高 |

远程 RPC 改完后：

```bash
docker compose down && docker compose up -d
```

### `config/`

| 文件 | 说明 |
|------|------|
| `genesis.json` | `setup.sh` 从官方 `mainnet.zip` 下载 |
| `config.toml` | `NetworkId=56`，`DialRatio=1`，`StaticNodes` 由 refresh 脚本维护 |
| `config.toml.template` | 干净骨架（StaticNodes 为空） |

配置损坏或容器重启循环：

```bash
bash scripts/setup.sh repair    # 重写骨架，自动保留已有 StaticNodes
```

---

## debug_trace 窗口（fast 模式）

fast 快照下 `history.state` **不生效**，trace 窗口由 `TRIES_IN_MEMORY` 控制：

| 参数 | 推荐值 | trace 窗口（BSC ~0.45s/块） |
|------|--------|---------------------------|
| `TRIES_IN_MEMORY` | `15000` | ~112 分钟 |
| `CACHE_MB` | `2048` | 为状态层让出内存 |

trace 请求需带 `reexec`：

```javascript
debug.traceBlockByNumber(n, {reexec: 15000})
```

重启后验证：

```bash
docker exec bsc-node geth attach --datadir /bsc/node --exec "
  var h=eth.blockNumber; try{debug.traceBlockByNumber(h-5000);print('5000 blocks: OK');}
  catch(e){print('5000 blocks: FAIL', e.message);}
"
```

期望输出 `5000 blocks: OK`。

---

## RPC 访问（Tailscale）

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://100.90.122.73:8545
```

RPC 绑定 Tailscale IP，**不要**暴露到公网。

---

## 清空数据 / 重下快照

```bash
docker compose down
bash scripts/reset-data.sh          # 交互确认
bash scripts/snapshot.sh start      # 重新下载
# 完成后
docker compose up -d
```

---

## 故障排查

### 节点重启循环

```bash
docker compose logs --tail 30 bsc
bash scripts/setup.sh repair
```

常见原因：`genesis.json` 缺失、`config.toml` 权限/语法错误。

### BAD BLOCK + `execution aborted (timeout = 5s)`

**不是链上坏块**，而是本机 5 秒内没跑完区块执行（CPU/内存/磁盘不足，或 trace 索引器争抢资源）。

**1. 追块期临时降内存参数**

```bash
# .env
TRIES_IN_MEMORY=4096
HISTORY_STATE=4096
CACHE_MB=4096
MEM_LIMIT=32g
MEMSWAP_LIMIT=48g

docker compose down && docker compose up -d
```

**2.** 追块期间暂停 heavy `debug_*` / internal tx 索引器。

**3.** 检查磁盘与负载：

```bash
df -h data/node
docker stats bsc-node --no-stream
```

**4.** 同步完成后改回 `TRIES_IN_MEMORY=15000` 并重启。

**5.** 仍卡同一高度 → 快照/本地数据可能损坏，执行「清空数据 / 重下快照」。

### 快照 404

```bash
bash scripts/snapshot.sh download    # 脚本自动从 48Club 获取最新 URL
```

### 其他

| 现象 | 处理 |
|------|------|
| `chainId` 不是 `0x38` | `bash scripts/setup.sh repair` |
| 8575 在监听、8545 没有 | 确认在 `bsc-node` 目录，容器名为 `bsc-node` |
| 误用测试网配置/端口 | `repair` 会把 `ListenAddr` 30311 修回 30303 |
| 服务器非 git 仓库 | 从开发机同步 `scripts/`、`config/` 后 `bash scripts/setup.sh repair` |

---

## 目录结构

```
bsc-node/
├── docker-compose.yml
├── .env
├── config/
│   ├── config.toml.template
│   ├── config.toml
│   └── genesis.json
├── data/
│   ├── node/              # 链数据
│   ├── incr/              # incr 模式用
│   └── logs/              # 快照下载日志
└── scripts/
    ├── deploy.sh
    ├── setup.sh
    ├── refresh-static-nodes.sh
    ├── snapshot.sh
    ├── reset-data.sh
    └── start.sh
```

---

## 安全提示

- RPC **8545** 仅绑定 Tailscale，勿暴露公网
- P2P **30303** 可走路由器端口转发或 FRP（legacy）
- `.env` 含机器 IP，勿提交敏感信息到公开仓库

---

## 参考

- [BSC Docker 文档](https://docs.bnbchain.org/bnb-smart-chain/developers/node_operators/docker/)
- [BSC Releases（mainnet.zip）](https://github.com/bnb-chain/bsc/releases)
- [48Club 快照](https://github.com/48Club/bsc-snapshots)
- [BSC 官方快照](https://github.com/bnb-chain/bsc-snapshots)
