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
```

# 停止并移除容器（数据卷保留）
docker compose down

# 停止并删除数据卷（⚠️ 会清除区块链数据，需重新同步）
docker compose down -v
```

### RPC 示例

```bash
# 网络信息
./scripts/btc-cli.sh getnetworkinfo

# 连接的对等节点
./scripts/btc-cli.sh getpeerinfo

# 内存池
./scripts/btc-cli.sh getmempoolinfo

# 估算同步剩余（需 jq）
./scripts/btc-cli.sh getblockchaininfo | jq '{blocks, headers, verificationprogress, initialblockdownload}'
```

也可直接进入容器：

```bash
docker compose exec bitcoind bitcoin-cli -chain=main getblockchaininfo
```

### 从宿主机调用 RPC（curl）

若配置了 `rpcuser` / `rpcpassword`：

```bash
source config/bitcoin.conf 2>/dev/null || true
curl --user "${rpcuser}:${rpcpassword}" \
  --data-binary '{"jsonrpc":"1.0","id":"curl","method":"getblockchaininfo","params":[]}' \
  -H 'content-type: text/plain;' \
  http://127.0.0.1:8332/
```

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
