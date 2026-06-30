# Bitcoin Signet 测试网节点

基于 Bitcoin Core Docker 镜像运行 **Signet** 公共测试链，供开发联调（广播交易、查近期区块等）。默认 `prune=2000`（裁剪，非归档），磁盘约 **3~5GB**；**不启用钱包**，测试币在各端钱包 / 水龙头领取。

| 项目 | 值 |
|------|-----|
| P2P | **38333** |
| RPC | **38332** |
| 容器 / 数据卷 | `bitcoind-signet` / `btc-testnet-data` |

## 前置要求

- Docker Engine 24+、Docker Compose v2
- 磁盘 ≥ **10GB**；内存建议 ≥ **4GB**

## 部署

```bash
cd btc-testnet
./scripts/setup.sh
./scripts/start.sh -f
./scripts/status.sh
```

同步完成：`verificationprogress` 趋近 `1`，`initialblockdownload` 为 `false`。

## 常用命令

```bash
./scripts/btc-cli.sh getblockchaininfo
./scripts/btc-cli.sh getblockcount
./scripts/show-rpc-info.sh
./scripts/stop.sh
docker compose logs -f bitcoind
docker compose down        # 保留数据卷
docker compose down -v     # 删除链数据，需重新同步
```

Signet 测试币：搜索 “Bitcoin signet faucet”，向各端钱包地址领取。
