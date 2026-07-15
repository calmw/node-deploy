# Bitcoin Signet 测试网节点

基于 Bitcoin Core Docker 镜像运行 **Signet** 公共测试链，供团队开发联调。与 `btc-node/` 主网节点 **端口、数据卷、容器名完全隔离**。

| 项目 | 值 |
|------|-----|
| P2P / RPC（宿主机） | **38333** / **48332** |
| 容器内 Signet RPC | **38332**（勿改 bitcoin.conf 中的 rpcport） |
| 容器 / 数据目录 | `bitcoind-signet` / `./data` |
| 磁盘 | 约 **3~5GB**（`prune=2000`，非归档） |

## 前置要求

- Docker Engine 24+、Docker Compose v2
- 磁盘 ≥ **10GB**；内存建议 ≥ **4GB**

## 部署

**必须先 `setup.sh` 再 `start.sh`**，否则 `config/bitcoin.conf` 可能被误建为目录导致挂载失败。

```bash
cd btc-testnet
chmod +x scripts/*.sh

./scripts/setup.sh          # 生成 .env、config/bitcoin.conf（含随机 RPC 密码）
./scripts/start.sh -f       # 拉镜像并启动
./scripts/status.sh
```

| 场景 | 操作 |
|------|------|
| 删目录后重来 | 同首次部署；`data/` 若备份过可拷回，否则重新同步 |
| 改 `.env` / `bitcoin.conf` | `docker compose down && docker compose up -d`（勿只用 restart） |
| 完全清空 | `docker compose down` → `rm -rf data` → 删 `.env` 与 `config/bitcoin.conf` → 再 setup |

镜像拉取失败：`./scripts/pull-image.sh` 或 `./scripts/pull-image.sh --build`（详见 `.env.example` 注释）。

## 同机部署主网 + Signet

与 `btc-node/` 主网同机运行时，端口分工如下（互不冲突）：

| 节点 | 目录 | P2P（宿主机） | RPC（宿主机） |
|------|------|---------------|---------------|
| **主网** | `btc-node/` | **8333** | **8332**（Bitcoin 默认） |
| **Signet** | `btc-testnet/` | **38333** | **48332**（映射到容器 38332） |

主网占 **8332/8333**；测试网 RPC 用 **48332**，避免与主网混淆。改 `.env` 的 `RPC_PORT` 后须 `docker compose down && docker compose up -d`。

```bash
# btc-testnet/.env 示例（与主网同机）
RPC_PORT=48332
RPC_BIND_ADDR=100.75.33.104   # Tailscale，与主网可相同 IP、不同端口

ss -tlnp | grep -E '8332|48332'
```

## 同步进度

Signet 首次同步含 **header 预同步**（Bitcoin Core 31）。此阶段：

- 日志里 `Pre-synchronizing blockheaders, height: xxxxx` **持续增长** → 正常
- RPC 里 `headers` / `blocks` / `getblockcount` **可能长期为 0** → 正常，**不要仅凭 RPC 判断卡住**

### 怎么确认在同步

**看日志，不要只看 `getblockcount`：**

```bash
docker compose logs --tail=500 bitcoind | grep 'Pre-synchronizing'
```

实时跟踪：

```bash
docker compose logs -f bitcoind | grep 'Pre-synchronizing'
```

或：

```bash
./scripts/status.sh    # 会显示 RPC 状态与最近一条预同步进度
```

### 同步完成标志

- 日志中 `Pre-synchronizing` 消失，出现 `UpdateTip: ... height=311xxx`
- `./scripts/btc-cli.sh getblockchaininfo`：`headers` ≈ 链头，`verificationprogress` → `1`，`initialblockdownload` 为 `false`

预同步约 31 万 header，通常 **30~60 分钟**（视网络而定）；之后块下载较快。

## 数据目录

链数据在项目内 **`data/`**（Signet 区块等在 `data/signet/`），`config/bitcoin.conf` 仍单独放在 `config/` 并由 Compose 挂载。

```bash
ls -la data/signet          # blocks、chainstate 等
du -sh data/signet          # 占用空间
```

`.gitignore` 已忽略 `data/`，勿提交 git。

若此前用过 Docker 卷 `btc-testnet-data`，迁移一次即可：

```bash
docker compose down
mkdir -p data
docker run --rm -v btc-testnet-data:/from -v "$(pwd)/data:/to" alpine cp -a /from/. /to/
docker compose up -d
# 确认正常后可删旧卷：docker volume rm btc-testnet-data
```

## 配置

### `.env`

| 变量 | 默认 | 说明 |
|------|------|------|
| `P2P_PORT` | `38333` | 宿主机 P2P |
| `RPC_PORT` | `48332` | 宿主机 RPC（→ 容器 38332） |
| `RPC_BIND_ADDR` | `127.0.0.1` | RPC 绑定 IP（见下） |
| `RPC_HOST` | — | 给同事文档用的地址（可选） |
| `BITCOIN_IMAGE` | `bitcoin/bitcoin:31.0` | 镜像 |

#### `RPC_BIND_ADDR`

Docker 映射 **`RPC_BIND_ADDR:RPC_PORT → 容器 38332`**（宿主机默认 **48332**，容器内仍为 Signet 默认 38332）。

| 取值 | 用途 |
|------|------|
| `127.0.0.1` | 仅服务器本机 |
| 云内网 IP / Tailscale IP（如 `100.x.x.x`） | 团队远程访问 |

远程 RPC 示例（Tailscale）：

```bash
# .env
RPC_BIND_ADDR=100.75.33.104
RPC_HOST=100.75.33.104

# config/bitcoin.conf [signet] 段取消注释：
# rpcallowip=100.64.0.0/10

docker compose down && docker compose up -d
ss -tlnp | grep 48332    # 应看到 100.x.x.x:48332
```

### `config/bitcoin.conf`

- Core 31+：`rpcbind`、`rpcallowip` 等写在 **`[signet]`** 段
- 端口：容器内 Signet 默认 **38333 / 38332**；宿主机 RPC 由 `.env` 的 `RPC_PORT` 映射（默认 **48332**）
- 已含 `onlynet=ipv4`、`addnode`（利于云服务器同步）
- 勿提交 git

## 验证

```bash
./scripts/status.sh
bash scripts/btc-rpc-test.sh --url http://127.0.0.1:48332/          # 服务器本机
bash scripts/btc-rpc-test.sh --url http://100.x.x.x:48332/ \        # 开发机远程
  --user btc_signet_rpc --pass '<rpcpassword>'
```

预同步期间 RPC 测试可能出现 WARN（height=0），**FAIL=0 且 HTTP/peers 通过即表示部署正常**。

## 常用命令

```bash
./scripts/btc-cli.sh getblockchaininfo
./scripts/btc-cli.sh getblockcount
./scripts/show-rpc-info.sh
./scripts/stop.sh
docker compose logs -f bitcoind
docker compose down        # 保留 data/
# 删除链数据：docker compose down && rm -rf data
```

## 测试币

Signet 测试币无价值，仅用于开发。节点默认 `disablewallet=1`，需用外部钱包（如 Sparrow，网络选 Signet）生成 **`tb1...`** 地址后再领。

| 水龙头 | 说明 |
|--------|------|
| **[faucet.coinbin.org](https://faucet.coinbin.org/)** ✅ 实测可用 | 单次约 0.001–0.09 sBTC，填 Signet 地址即可 |
| [signetfaucet.com](https://signetfaucet.com/) | 备选，单次约 0.00001–0.01 sBTC |

到账可在 [mempool.space/signet](https://mempool.space/signet) 查地址；节点同步中也可能先用 `getrawtransaction <txid> true` 看到交易。

## 故障排查

| 现象 | 处理 |
|------|------|
| `bitcoin.conf` 是目录 / mount 失败 | `docker compose down && rm -rf config/bitcoin.conf && ./scripts/setup.sh` |
| 远程 RPC `Couldn't connect` | 改 `RPC_BIND_ADDR` + `rpcallowip`，再 `down && up -d` |
| 镜像拉取失败 | `./scripts/pull-image.sh --build` |
| 有 peer 但长期无 `Pre-synchronizing` | 查 `onlynet=ipv4`、`addnode`；对比 `config/bitcoin.conf.example` 后重新 setup |
| RPC 显示 headers=0 但有预同步日志 | **正常**，继续等 |

## 参考

- [Signet](https://en.bitcoin.it/wiki/Signet)
- [Bitcoin Core RPC](https://developer.bitcoin.org/reference/rpc/)
