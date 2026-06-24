# BTC 主网全节点（Docker Compose）

使用 [Bitcoin Core](https://bitcoincore.org/) 官方 Docker 镜像，通过 Docker Compose 运行比特币主网全节点。

## 架构概览

```text
┌─────────────────────────────────────────┐
│  宿主机                                  │
│  ┌───────────────────────────────────┐  │
│  │  bitcoind (bitcoin/bitcoin)       │  │
│  │  P2P  :8333  ←→  比特币网络        │  │
│  │  RPC  :8332  ←   127.0.0.1 本机    │  │
│  │  数据  Docker volume: btc-node-data │  │
│  └───────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

## 前置要求

| 项目 | 建议 |
|------|------|
| Docker | Docker Engine 24+ 与 Docker Compose v2 |
| 磁盘 | 全节点 **≥ 700GB** 可用空间（SSD 更佳）；当前裁剪模式 `prune=2000` 建议 **≥ 20GB** |
| 内存 | **≥ 4GB** RAM（`dbcache` 会占用部分内存） |
| 带宽 | 稳定网络；初始同步会下载数百 GB 数据 |
| 端口 | 8333/TCP 若需对外提供 P2P 服务，需在防火墙/路由器放行 |

## 快速开始

### 1. 初始化配置

```bash
chmod +x scripts/*.sh
./scripts/setup.sh
```

脚本会：

- 从 `.env.example` 创建 `.env`
- 从 `config/bitcoin.conf.example` 创建 `config/bitcoin.conf`
- 自动生成随机 `rpcpassword`（需已安装 `openssl`）

### 2. 启动节点

```bash
./scripts/start.sh
```

加 `-f` 可启动后直接跟踪日志：

```bash
./scripts/start.sh -f
```

等价于手动执行 `docker compose up -d`；若未初始化，`start.sh` 会自动调用 `setup.sh`。

查看日志：

```bash
docker compose logs -f bitcoind
```

### 3. 检查同步状态

```bash
./scripts/btc-cli.sh getblockchaininfo
```

关注输出中的：

- `blocks`：当前本地区块高度
- `headers`：已下载区块头高度
- `verificationprogress`：同步进度（1.0 表示完成）
- `initialblockdownload`：是否在初始同步中

示例：

```bash
./scripts/btc-cli.sh getblockchaininfo | grep -E '"blocks"|"headers"|"verificationprogress"|"initialblockdownload"'
```

更多 RPC 调用方式（curl、常用 API、远程访问）见下文 [RPC 调用](#rpc-调用) 一节。

## 目录结构

```text
btc-node/
├── docker-compose.yml          # Compose 编排
├── .env.example                # 环境变量模板
├── config/
│   ├── bitcoin.conf.example    # Bitcoin Core 配置模板
│   └── bitcoin.conf            # 实际配置（setup 生成，勿提交）
├── scripts/
│   ├── setup.sh                # 一键初始化
│   ├── start.sh                # 启动节点
│   ├── stop.sh                 # 停止节点
│   ├── status.sh               # 容器与同步状态
│   └── btc-cli.sh              # RPC 命令封装
└── README.md
```

区块链数据保存在 Docker 命名卷 `btc-node-data` 中，不占用项目目录。

配置文件通过 bind mount 挂到容器内 `/home/bitcoin/.bitcoin/bitcoin.conf`（**不要**加 `:ro`，否则 entrypoint 无法 `chown`；**不要**再用 `-conf` 指向其他路径，Bitcoin Core 31 会因 datadir 内残留配置而拒绝启动）。

## 配置说明

### 环境变量（`.env`）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `BITCOIN_VERSION` | `31.0` | 镜像标签，见 [Docker Hub](https://hub.docker.com/r/bitcoin/bitcoin/tags) |
| `P2P_PORT` | `8333` | 宿主机 P2P 端口 |
| `RPC_PORT` | `8332` | 宿主机 RPC 端口（仅绑定 127.0.0.1） |

### Bitcoin Core（`config/bitcoin.conf`）

**裁剪节点（当前默认）**：`config/bitcoin.conf` 已启用：

```ini
prune=2000
```

表示约保留 2000MB 区块数据（实际占用还会包含链状态等，建议预留约 20GB）。裁剪模式与 `txindex=1` 互斥。

**全节点**：注释掉 `prune=2000` 即可，需 **≥ 700GB** 磁盘。

**交易索引（可选）**：需要完整交易历史查询时启用：

```ini
txindex=1
```

会显著增加磁盘占用与同步时间。

修改配置后重启：

```bash
docker compose restart bitcoind
```

## 常用命令

### 节点管理

```bash
# 启动
./scripts/start.sh

# 停止
./scripts/stop.sh

# 状态与同步进度
./scripts/status.sh

# 停止并移除容器（数据卷保留）
docker compose down

# 停止并删除数据卷（⚠️ 会清除区块链数据，需重新同步）
docker compose down -v
```

## RPC 调用

Bitcoin Core RPC 在容器内监听 `8332`，通过 Docker 映射到宿主机 **`127.0.0.1:${RPC_PORT:-8332}`**（仅本机可访问，见 `docker-compose.yml`）。

### 前置条件

- 节点已启动且健康：`docker compose ps` 显示 `healthy`
- 已执行 `./scripts/setup.sh` 生成 `config/bitcoin.conf`（含 `rpcuser` / `rpcpassword`）
- `config/bitcoin.conf` 中 `server=1` 已启用（模板默认已开启）

### 快速验证

```bash
./scripts/status.sh
./scripts/btc-cli.sh getblockchaininfo
```

正常时返回 JSON，且 `verificationprogress` 趋近 `1.0`；同步完成后 `initialblockdownload` 为 `false`。

### 方式一：`btc-cli.sh`（推荐）

项目封装脚本，在宿主机直接调用容器内 `bitcoin-cli`：

```bash
./scripts/btc-cli.sh <命令> [参数...]
```

示例：

```bash
# 链状态与同步进度
./scripts/btc-cli.sh getblockchaininfo

# 当前区块高度
./scripts/btc-cli.sh getblockcount

# 最新区块哈希
./scripts/btc-cli.sh getbestblockhash

# 网络与对等节点
./scripts/btc-cli.sh getnetworkinfo
./scripts/btc-cli.sh getpeerinfo

# 内存池
./scripts/btc-cli.sh getmempoolinfo

# 带参数：按高度查区块（1=含完整交易）
./scripts/btc-cli.sh getblockhash 955119
./scripts/btc-cli.sh getblock "<区块哈希>" 1

# 需 jq 时可管道过滤
./scripts/btc-cli.sh getblockchaininfo | jq '{blocks, headers, verificationprogress, initialblockdownload}'
```

### 方式二：`docker compose exec`

等价于进入容器执行 `bitcoin-cli`：

```bash
docker compose exec bitcoind bitcoin-cli -datadir=/home/bitcoin/.bitcoin -chain=main getblockchaininfo
```

### 方式三：HTTP JSON-RPC（curl / 程序调用）

Bitcoin Core 使用 **JSON-RPC 1.0**（不是 Ethereum 常见的 2.0）。请求格式：

```json
{"jsonrpc":"1.0","id":"<任意标识>","method":"<方法名>","params":[...]}
```

认证方式为 HTTP Basic Auth，用户名与密码来自 `config/bitcoin.conf` 的 `rpcuser` / `rpcpassword`。

**通用模板**（在 `btc-node` 目录下执行）：

```bash
[[ -f .env ]] && source .env
source config/bitcoin.conf

RPC_URL="http://127.0.0.1:${RPC_PORT:-8332}/"

curl -s --user "${rpcuser}:${rpcpassword}" \
  --data-binary '{"jsonrpc":"1.0","id":"1","method":"<方法名>","params":[]}' \
  -H 'content-type: text/plain;' \
  "${RPC_URL}"
```

**常用示例**：

```bash
[[ -f .env ]] && source .env
source config/bitcoin.conf
RPC="http://127.0.0.1:${RPC_PORT:-8332}/"

# 链状态
curl -s --user "${rpcuser}:${rpcpassword}" \
  --data-binary '{"jsonrpc":"1.0","id":"1","method":"getblockchaininfo","params":[]}' \
  -H 'content-type: text/plain;' "${RPC}"

# 区块高度
curl -s --user "${rpcuser}:${rpcpassword}" \
  --data-binary '{"jsonrpc":"1.0","id":"1","method":"getblockcount","params":[]}' \
  -H 'content-type: text/plain;' "${RPC}"

# 最新区块哈希
curl -s --user "${rpcuser}:${rpcpassword}" \
  --data-binary '{"jsonrpc":"1.0","id":"1","method":"getbestblockhash","params":[]}' \
  -H 'content-type: text/plain;' "${RPC}"

# 估算手续费（conf_target=6 表示约 6 个区块内确认，economical=true）
curl -s --user "${rpcuser}:${rpcpassword}" \
  --data-binary '{"jsonrpc":"1.0","id":"1","method":"estimatesmartfee","params":[6,"economical"]}' \
  -H 'content-type: text/plain;' "${RPC}"
```

**成功响应示例**：

```json
{"result":{"chain":"main","blocks":955119,"headers":955119,"verificationprogress":1,"initialblockdownload":false},"error":null,"id":"1"}
```

**失败响应示例**（认证错误）：

```json
{"result":null,"error":{"code":-28,"message":"Loading block index..."},"id":"1"}
```

- `error: null` 表示调用成功
- `code: -28` 常见于节点尚在启动/加载索引，稍后重试即可
- HTTP `401` 表示 `rpcuser` / `rpcpassword` 不匹配

### 常用 RPC 方法

| 方法 | 说明 |
|------|------|
| `getblockchaininfo` | 链状态、同步进度、是否裁剪 |
| `getblockcount` | 当前区块高度 |
| `getbestblockhash` | 最新区块哈希 |
| `getblockhash` | 按高度查区块哈希 |
| `getblock` | 查区块详情（第二参数 `1` 含完整交易） |
| `getrawtransaction` | 查原始交易（裁剪节点仅支持仍在链上的交易） |
| `getnetworkinfo` | 网络连接数、版本等 |
| `getpeerinfo` | 对等节点详情 |
| `getmempoolinfo` | 内存池状态 |
| `estimatesmartfee` | 估算手续费 |
| `sendrawtransaction` | 广播已签名原始交易 |

完整 API 见 [Bitcoin Core RPC 文档](https://developer.bitcoin.org/reference/rpc/)。

### 远程访问

RPC 端口仅绑定 `127.0.0.1`，其他机器无法直接访问。可通过 SSH 隧道转发：

```bash
# 在本地机器执行，将远端 8332 映射到本地 8332
ssh -L 8332:127.0.0.1:8332 user@your-server

# 之后在本地调用
curl -s --user "rpcuser:rpcpassword" \
  --data-binary '{"jsonrpc":"1.0","id":"1","method":"getblockcount","params":[]}' \
  -H 'content-type: text/plain;' http://127.0.0.1:8332/
```

### 裁剪节点限制

当前默认启用 `prune=2000`，可正常调用 RPC 查询**近期区块与仍在链上的交易**；无法 serve 完整历史区块，也不支持 `txindex=1`。若业务需要完整历史，需改为全节点并启用 `txindex=1`（见上文配置说明）。

## 安全建议

1. **RPC 仅本机访问**：`docker-compose.yml` 已将 8332 绑定到 `127.0.0.1`，勿改为 `0.0.0.0`。
2. **强 RPC 密码**：使用 `setup.sh` 自动生成，或自行设置复杂密码。
3. **勿提交密钥**：`config/bitcoin.conf` 与 `.env` 已在 `.gitignore` 中。
4. **防火墙**：若不需要对外提供 P2P，可在 `docker-compose.yml` 中注释 P2P 端口映射；节点仍可通过出站连接同步。
5. **备份**：重要场景请备份 Docker 卷 `btc-node-data` 及 `config/bitcoin.conf`（含钱包时尤其重要）。本配置默认不启用钱包功能。

## 故障排查

### 容器反复重启

```bash
docker compose logs --tail=100 bitcoind
```

常见原因：配置文件语法错误、磁盘空间不足、内存不足。

若日志出现 `chown: ... Read-only file system`：去掉 `docker-compose.yml` 里 `bitcoin.conf` 挂载的 `:ro`。

若日志出现 `contains a "bitcoin.conf" file which is ignored`（Bitcoin Core 31+）：说明曾用 `-conf` 指向其他路径，数据卷里残留了旧配置。先清理再启动：

```bash
docker compose down
docker run --rm -v btc-node-data:/data alpine sh -c 'rm -f /data/bitcoin.conf'
docker compose up -d
```

### 同步极慢

- 检查 `./scripts/btc-cli.sh getpeerinfo` 是否有足够对等节点
- 适当增大 `maxconnections`
- 确认网络带宽与磁盘 I/O

### RPC 连接被拒绝

- 确认容器健康：`docker compose ps`
- 确认 `config/bitcoin.conf` 中 `rpcuser` / `rpcpassword` 与调用方一致
- 等待 `-rpcwait` 完成初始启动（healthcheck 已配置等待）

### 日志里 `incorrect password attempt from 127.0.0.1`

多为 Docker healthcheck 以 root 运行 `bitcoin-cli` 但未指定 `-datadir`，读不到 `bitcoin.conf` 里的 RPC 密码。当前 `docker-compose.yml` 已加 `-datadir=/home/bitcoin/.bitcoin`；更新后重建即可：

```bash
docker compose up -d --force-recreate
```

节点同步本身不受影响，可忽略该警告直至重建。

### 查看磁盘占用

```bash
docker system df -v | grep btc-node-data
```

## 升级 Bitcoin Core

1. 修改 `.env` 中的 `BITCOIN_VERSION`（例如 `31.1`）
2. 拉取新镜像并重建：

```bash
docker compose pull
docker compose up -d
```

Bitcoin Core 一般向后兼容同一 major 版本的数据目录；跨大版本升级请先查阅 [官方发布说明](https://bitcoincore.org/en/releases/)。

## 参考链接

- [Bitcoin Core 文档](https://developer.bitcoin.org/devguide/index.html)
- [bitcoin.conf 参数](https://en.bitcoin.it/wiki/Running_Bitcoin)
- [官方 Docker 镜像](https://hub.docker.com/r/bitcoin/bitcoin)

## 许可证

本项目配置与脚本以 MIT 方式提供；Bitcoin Core 软件遵循其各自的开源许可证。
