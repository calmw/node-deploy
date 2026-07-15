# node-deploy

多链节点部署

| 目录 | 链 | 说明 |
|------|-----|------|
| [btc-node](./btc-node) | Bitcoin 主网 | Bitcoin Core 全节点 / 裁剪节点 |
| [btc-testnet](./btc-testnet) | Bitcoin Signet | 团队测试网；RPC **48332**（主网占 8332） |
| [bsc-node](./bsc-node) | BNB Smart Chain 主网 | BSC 全节点；RPC **8545** |
| [bsc-testnet](./bsc-testnet) | BSC Chapel 测试网 | Chain ID 97；RPC **8575** |
| [sepolia](./sepolia) | Ethereum L1 Sepolia | Geth + Lighthouse（快照 + 历史裁剪） |
| [base-node](./base-node) | Base (L2) | base-reth-node + base-consensus（默认 Pruned ~31 天） |
