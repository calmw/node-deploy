# BSC 节点 Docker 部署（家用直连 / Tailscale RPC）

在家里服务器运行 BSC Fast Node；P2P 直连（`NAT_MODE=any`），RPC 经 Tailscale 访问。

## 脚本一览

| 脚本 | 用途 |
|------|------|
| `scripts/deploy.sh` | 一键部署（配置 + 快照 + 启动） |
| `scripts/setup.sh` | 初始化 / 修复 config 骨架（`repair` 自动保留已有 enode） |
| `scripts/refresh-static-nodes.sh` | 滚雪球抓取真实 peer enode，刷新 `StaticNodes`（对称 NAT 必备） |
| `scripts/snapshot.sh` | 快照下载管理 |
| `scripts/reset-data.sh` | 清空链数据 |
| `scripts/start.sh` | 容器入口（勿手动运行） |

---

## 一键部署（Fast 模式，推荐）

**前置条件：** 磁盘 ≥ 500GB、Docker 已安装；路由器放行或转发 **TCP+UDP 30303**（可选，StaticNodes 可兜底 outbound）

```bash
cd bsc-node

# 推荐：后台下载快照
bash scripts/deploy.sh --bg-download

# 或分步
bash scripts/setup.sh
bash scripts/snapshot.sh start    # 后台下载，可关终端
bash scripts/snapshot.sh status   # 查看进度
docker compose up -d            # 下载完成后启动
```

### 快照命令

| 命令 | 作用 |
|------|------|
| `bash scripts/snapshot.sh start` | 后台下载+解压 |
| `bash scripts/snapshot.sh status` | 查看进度 |
| `bash scripts/snapshot.sh log` | 实时日志 |
| `bash scripts/snapshot.sh stop` | 停止任务 |

日志：`data/logs/snapshot-download.log`

---

## 方案选择

| 模式 | 磁盘 | 说明 |
|------|------|------|
| **fast（默认）** | ~420GB | 48Club FastNode 快照，推荐 |
| snap | 逐渐增长 | 从网络同步，无需预下载 |
| incr | ~120~200GB | 配置复杂，不推荐 |
| pruned | ~1.6TB | 官方裁剪快照，见 [bsc-snapshots](https://github.com/bnb-chain/bsc-snapshots) |

**硬件建议：** 磁盘 ≥ 500GB（1TB 足够 fast 模式）、内存 ≥ 32GB（方案 A 建议 64GB）、CPU 4 核+

### debug_trace 窗口（fast 模式 / 方案 A）

fast 快照下 `history.state` **不生效**，trace 窗口由 `TRIES_IN_MEMORY` 控制：

| 参数 | 推荐值 | trace 窗口（BSC 0.45s/块） |
|------|--------|---------------------------|
| `TRIES_IN_MEMORY` | `15000` | ~112 分钟 |
| `CACHE_MB` | `2048` | 为状态层让出内存 |

`.env` 示例见 `.env.example`。重启后验证：

```bash
docker exec bsc-node geth attach --datadir /bsc/node --exec "
  var h=eth.blockNumber; try{debug.traceBlockByNumber(h-5000);print('5000 blocks: OK');}
  catch(e){print('5000 blocks: FAIL', e.message);}
"
```

期望输出 `5000 blocks: OK`（不再出现 `reexec=128`）。

---

## NAT / P2P 配置

**已取消 FRP 时，不要用云服务器 IP 做 NAT。**

`.env` 推荐：

```bash
NAT_MODE=any
P2P_PORT=30303
# 删除或注释 NAT_EXTIP=43.160.200.71 这类 FRP 云 IP
```

重启后日志里 enode 应显示**家里真实公网 IP**（例如 `223.88.44.23`），而不是 `43.160.200.71`。

若 peer 仍少，执行滚雪球刷新 StaticNodes：

```bash
bash scripts/refresh-static-nodes.sh
docker compose restart
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

## 常用命令

```bash
docker compose logs -f
docker exec bsc-node geth attach --datadir /bsc/node --exec "eth.syncing"
docker exec bsc-node geth attach --datadir /bsc/node --exec "net.peerCount"
docker compose restart
docker compose down
```

## RPC 访问（Tailscale）

```bash
curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://100.90.122.73:8545
```

---

## 故障排查

### 节点重启循环

```bash
docker compose logs --tail 30 bsc
bash scripts/setup.sh repair    # 修复 config 骨架 + 权限 + 重启
```

常见原因：`genesis.json` 缺失、`config.toml` 权限/语法错误。
`repair` 会重写 `config.toml` 骨架，但**自动保留**其中已有的 `StaticNodes`，不会丢掉收集到的 enode。

### peer 数量偏少（家用 NAT / 对称 NAT）

**两层根因：**

1. geth 默认 `DialRatio=3`，只有 `MaxPeers/3` 的槽位用于主动外连，其余等永远不来的 inbound，peer 卡在约 1/3。
2. 家用宽带是**对称 NAT + 动态公网 IP**，UDP discovery 的 endpoint proof（bond）无法稳定建立，inbound≈0，discovery 基本失效。

**彻底方案：绕过 discovery，直接静态连真实全节点。**

- `DialRatio = 1`（已写入 `config.toml` 骨架）：全部 `MaxPeers` 槽位都用于主动外连。
- `StaticNodes = [...]`：用滚雪球脚本抓取**当前真实在线的全节点** enode，持续主动重连。
  > 注意：官方 bootnodes 只做 UDP 发现、不接受 RLPx TCP 连接，**不能**直接当 StaticNodes。

```bash
# 滚雪球收集在线 peer 的 enode 并写入 config.toml 的 StaticNodes
bash scripts/refresh-static-nodes.sh
docker compose restart          # 应用后等 1~2 分钟再查 peer
```

`.env` 建议：`MAX_PEERS=100~160`、`MAX_PEND_PEERS=100`

```bash
# 查看 peer 总数 / inbound 占比
docker exec bsc-node geth attach --datadir /bsc/node --exec "net.peerCount"
docker exec bsc-node geth attach --datadir /bsc/node \
  --exec "admin.peers.map(p=>p.network.inbound)"
```

### BAD BLOCK + `execution aborted (timeout = 5s)`

日志反复出现同一高度，例如：

```text
########## BAD BLOCK #########
Block: 105617727 (0xcf01b4...)
Error: execution aborted (timeout = 5s)
Synchronisation failed, dropping peer ... err="retrieved hash chain is invalid: execution aborted (timeout = 5s)"
```

**这不是链上坏块**，而是本机在同步验证时 **5 秒内没跑完区块执行**（CPU / 内存 / 磁盘 I/O 不足，或 trace 索引器与追块争抢资源）。节点会误判为 BAD BLOCK 并不断踢 peer，高度卡住不动。

**处理顺序：**

**1. 追块期降低内存参数（最常见有效）**

编辑 `.env`，追块完成前临时调低 `TRIES_IN_MEMORY`，并适当增大 cache：

```bash
TRIES_IN_MEMORY=4096      # 追块期；同步完成后改回 15000
HISTORY_STATE=4096
CACHE_MB=4096             # 原 2048 时可提高，加快导入
```

确认容器内存上限与物理内存匹配（32G 机器示例）：

```bash
MEM_LIMIT=32g
MEMSWAP_LIMIT=48g
```

重启：

```bash
docker compose down && docker compose up -d
docker compose logs -f bsc
```

**2. 追块期间暂停 trace 索引器 / 大量 RPC**

若有 internal tx 索引器或 heavy `debug_*` 调用，追块完成前暂停，避免与 geth 争抢 CPU / 内存。

**3. 检查磁盘与负载**

```bash
# 磁盘空间与 I/O（建议 NVMe SSD，追块期 iowait 不宜长期 >30%）
df -h data/node
docker stats bsc-node --no-stream
docker exec bsc-node geth attach --datadir /bsc/node --exec "eth.syncing"
docker exec bsc-node geth attach --datadir /bsc/node --exec "eth.blockNumber"
```

**4. 同步完成后恢复 trace 窗口**

```bash
# .env 改回
TRIES_IN_MEMORY=15000
HISTORY_STATE=15000
docker compose restart
```

**5. 仍卡在同一高度 → 快照/本地数据可能损坏**

```bash
docker compose down
bash scripts/reset-data.sh
bash scripts/snapshot.sh start    # 重新下载 48Club 快照
# 下载完成后
docker compose up -d
```

### 快照 404

脚本自动从 48Club 获取最新 URL，重新下载即可：

```bash
bash scripts/snapshot.sh download
```

### 切换同步模式

```bash
docker compose down
bash scripts/reset-data.sh
bash scripts/deploy.sh
```

---

## 目录结构

```
bsc-node/
├── docker-compose.yml
├── .env
├── config/
│   ├── config.toml.template   # 配置骨架模板（StaticNodes 为空）
│   ├── config.toml            # 运行时生成（含动态 StaticNodes）
│   └── genesis.json
├── data/node/                 # 链数据
└── scripts/
    ├── deploy.sh
    ├── setup.sh
    ├── refresh-static-nodes.sh
    ├── snapshot.sh
    ├── reset-data.sh
    └── start.sh
```

## 安全提示

- P2P 30303 走 FRP 公网出口
- RPC 8545 绑定 Tailscale IP，**不要**暴露到公网
