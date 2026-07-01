# Bitcoin Signet 测试网节点

基于 Bitcoin Core Docker 镜像运行 **Signet** 公共测试链，供团队开发联调。与 `btc-node/` 主网节点 **端口、数据卷、容器名完全隔离**。

| 项目 | 值 |
|------|-----|
| P2P / RPC | **38333** / **38332** |
| 容器 / 数据卷 | `bitcoind-signet` / `btc-testnet-data` |
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
| 删目录后重来 | 同首次部署；链数据卷可能仍在（不删卷则不用重新同步） |
| 改 `.env` / `bitcoin.conf` | `docker compose down && docker compose up -d`（勿只用 restart） |
| 完全清空 | `docker compose down -v` → 删 `.env` 与 `config/bitcoin.conf` → 再 setup |

镜像拉取失败：`./scripts/pull-image.sh` 或 `./scripts/pull-image.sh --build`（详见 `.env.example` 注释）。

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

## 配置

### `.env`

| 变量 | 默认 | 说明 |
|------|------|------|
| `P2P_PORT` | `38333` | 宿主机 P2P |
| `RPC_PORT` | `38332` | 宿主机 RPC |
| `RPC_BIND_ADDR` | `127.0.0.1` | RPC 绑定 IP（见下） |
| `RPC_HOST` | — | 给同事文档用的地址（可选） |
| `BITCOIN_IMAGE` | `bitcoin/bitcoin:31.0` | 镜像 |

#### `RPC_BIND_ADDR`

Docker 映射 **`RPC_BIND_ADDR:RPC_PORT → 容器 38332`**。**只影响 RPC 谁能连，与 P2P 区块同步无关。**

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
ss -tlnp | grep 38332    # 应看到 100.x.x.x:38332
```

### `config/bitcoin.conf`

- Core 31+：`rpcbind`、`rpcallowip` 等写在 **`[signet]`** 段
- 端口：容器内外均为 Signet 默认 **38333 / 38332**
- 已含 `onlynet=ipv4`、`addnode`（利于云服务器同步）
- 勿提交 git

## 验证

```bash
./scripts/status.sh
bash scripts/btc-rpc-test.sh --url http://127.0.0.1:38332/          # 服务器本机
bash scripts/btc-rpc-test.sh --url http://100.x.x.x:38332/ \        # 开发机远程
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
docker compose down        # 保留数据卷
docker compose down -v     # 删除链数据
```

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
