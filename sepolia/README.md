# Ethereum L1 Sepolia 节点

Geth（执行层）+ Lighthouse（共识层），**省磁盘**运行 Sepolia 测试网，供 Base Sepolia 等 L2 提供 L1 RPC / Beacon API。

| 项目 | 值 |
|------|-----|
| 链 | Ethereum Sepolia |
| EL RPC / WS | **8545** / **8546** |
| Beacon REST | **5052** |
| EL P2P / CL P2P | **30303** / **9000** |
| 数据目录 | `./data/geth`、`./data/lighthouse` |
| 容器 | `sepolia-geth`、`sepolia-lighthouse` |

## 磁盘策略（对比全量 Archive）

| 组件 | 策略 | 大致占用 |
|------|------|----------|
| **Geth** | ethPandaOps **快照** + `snap` 续同步 + **历史裁剪** | 稳态约 **300~500GB**（随链增长） |
| **Lighthouse** | **Checkpoint sync**（非全量 CL 历史） | 约 **5~30GB** |

Geth 裁剪参数（`.env` 可调）：

- `HISTORY_BLOCKS=360000` — 只保留近期区块状态
- `HISTORY_TRANSACTIONS=0` — 不保留旧交易索引
- `--history.logs.disable` — 关闭 logs 索引

> Sepolia 全量 EL+CL 自建常需 **700GB~1TB+**；本方案通过快照起点 + 历史窗口 + CL checkpoint 显著降低占用与首 sync 时间。

## 前置要求

- Docker Engine 24+、Docker Compose v2
- **snapshot 模式**：磁盘 ≥ **350GB** 可用（建议 500GB+）；`zstd`、`curl`
- **snap 模式**：无需预下载快照，但首 sync 慢，磁盘仍会较大
- 内存：建议 **≥16GB**（Geth 16G + Lighthouse 8G 容器 limit，可按机器调整）

## 快速部署

```bash
cd sepolia
chmod +x scripts/*.sh

./scripts/setup.sh
./scripts/deploy.sh --bg-download    # 后台下载 ethPandaOps Geth 快照
bash scripts/snapshot.sh status      # 查看快照进度

docker compose up -d                 # 快照完成后
./scripts/status.sh
```

一键前台（阻塞下载）：

```bash
./scripts/deploy.sh
```

已有 chaindata、跳过快照：

```bash
./scripts/deploy.sh --skip-download
```

纯网络 snap（不下载快照，首 sync 慢）：

```bash
# .env
SEPOLIA_SYNC_MODE=snap
docker compose up -d
```

## 目录结构

```text
sepolia/
├── docker-compose.yml
├── .env.example
├── config/
│   └── jwtsecret              # setup 生成，EL↔CL 认证
├── data/
│   ├── geth/sepolia/geth/     # Geth 链数据
│   ├── lighthouse/            # Lighthouse 数据
│   └── logs/
└── scripts/
    ├── setup.sh
    ├── deploy.sh
    ├── snapshot.sh            # ethPandaOps Geth 快照
    ├── geth-start.sh          # Geth 启动参数（历史裁剪）
    ├── status.sh
    └── reset-data.sh
```

## 配置

### 同步模式

| `SEPOLIA_SYNC_MODE` | 说明 |
|---------------------|------|
| `snapshot`（默认） | 先 `snapshot.sh` 导入 [ethPandaOps Sepolia Geth 快照](https://ethpandaops.io/data/snapshots/)，再 snap 追块 |
| `snap` | 从网络 snap 同步，无需预下载 |

### RPC 绑定（Tailscale）

```bash
tailscale ip -4
# 编辑 .env
HTTP_BIND_ADDR=100.x.x.x
WS_BIND_ADDR=100.x.x.x
BEACON_BIND_ADDR=100.x.x.x
HTTP_VHOSTS=localhost,127.0.0.1,100.x.x.x

docker compose down && docker compose up -d
```

供 **Base Sepolia** 使用：

```ini
BASE_NODE_L1_ETH_RPC=http://100.x.x.x:8545
BASE_NODE_L1_BEACON=http://100.x.x.x:5052
```

### 历史窗口

```bash
# .env — 更小磁盘可酌减（过小会影响部分 debug/trace）
HISTORY_BLOCKS=360000
HISTORY_TRANSACTIONS=0
```

修改后 `docker compose down && docker compose up -d`。

## 验证

```bash
./scripts/status.sh

# 区块高度
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://127.0.0.1:8545

# Beacon 同步
curl -s http://127.0.0.1:5052/eth/v1/node/syncing | jq .
```

`eth_syncing` 为 `false` 且 Lighthouse `is_syncing: false` 即完全就绪。

## 常用命令

```bash
docker compose logs -f geth
docker compose logs -f lighthouse
docker compose down
bash scripts/reset-data.sh          # 清空链数据
bash scripts/snapshot.sh status
```

## 故障排查

| 现象 | 处理 |
|------|------|
| geth 启动报需快照 | `bash scripts/snapshot.sh start` 或改 `SEPOLIA_SYNC_MODE=snap` |
| aria2 显示 0% 但 du 很大 | 可能是残留 partial 数据；`bash scripts/snapshot.sh stop && bash scripts/snapshot.sh clean` 后重试 |
| 下载速度 <1MiB/s | ethPandaOps 源可能很慢；默认已改 **curl 流式**（`.env` 中 `SNAPSHOT_USE_ARIA2=0`） |
| 解压后找不到 chaindata | `bash scripts/snapshot.sh repair` |
| lighthouse 连不上 geth | 确认 `config/jwtsecret` 存在且两容器挂载一致 |
| CL 一直 syncing | 查 `CHECKPOINT_SYNC_URL`；换 `https://sepolia.beaconstate.info` 试 |
| 磁盘不足 | 减 `HISTORY_BLOCKS`；勿用 Archive；`du -sh data/*` 监控 |

## 参考

- [ethPandaOps Snapshots](https://ethpandaops.io/data/snapshots/)
- [Geth sync modes](https://geth.ethereum.org/docs/fundamentals/sync-modes)
- [Lighthouse checkpoint sync](https://lighthouse-book.sigmaprime.io/checkpoint-sync.html)
