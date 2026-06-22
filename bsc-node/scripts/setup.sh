#!/usr/bin/env bash
# BSC 配置管理：init（初始化）| repair（修复 config 并重启）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${ROOT_DIR}/config"
DATA_DIR="${ROOT_DIR}/data/node"
INCR_DIR="${ROOT_DIR}/data/incr"
TEMPLATE="${CONFIG_DIR}/config.toml.template"
BSC_VERSION="${BSC_VERSION:-1.7.3}"

usage() {
  cat <<'EOF'
用法: bash scripts/setup.sh [命令]

命令:
  init     初始化 config/（默认）
  repair   修复 config.toml / genesis.json / 权限，并重启容器

示例:
  bash scripts/setup.sh
  bash scripts/setup.sh repair
EOF
}

fix_config_perms() {
  [[ -d "${CONFIG_DIR}" ]] || return 0
  for f in "${CONFIG_DIR}/config.toml" "${CONFIG_DIR}/genesis.json" "${TEMPLATE}"; do
    [[ -f "${f}" ]] && chmod 644 "${f}"
  done
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R 1000:1000 "${CONFIG_DIR}"
    chown -R 1000:1000 "${ROOT_DIR}/data" 2>/dev/null || true
  fi
  echo "[setup] 权限已修复 (644, uid=1000)"
}

write_config_toml() {
  mkdir -p "${CONFIG_DIR}"
  # repair 时保留已有的 StaticNodes（enode 由 refresh-static-nodes.sh 动态维护，不应被覆盖丢失）
  local OLD_ENODES=""
  [[ -f "${CONFIG_DIR}/config.toml" ]] && \
    OLD_ENODES="$(grep -oE 'enode://[0-9a-f]{128}@[0-9.]+:[0-9]+' "${CONFIG_DIR}/config.toml" 2>/dev/null | sort -u || true)"

  cat > "${CONFIG_DIR}/config.toml" <<'EOF'
[Eth]
NetworkId = 56
TrieTimeout = 150000000000

[Eth.Miner]
GasCeil = 70000000
GasPrice = 50000000

[Eth.TxPool]
Locals = []
NoLocals = true
Journal = "transactions.rlp"
Rejournal = 3600000000000
PriceLimit = 50000000
PriceBump = 10
AccountSlots = 200
GlobalSlots = 8000
AccountQueue = 200
GlobalQueue = 4000

[Eth.GPO]
Blocks = 20
Percentile = 60
OracleThreshold = 1000

[Node]
IPCPath = "geth.ipc"
HTTPHost = "localhost"
InsecureUnlockAllowed = false
HTTPPort = 8545
HTTPVirtualHosts = ["localhost"]
HTTPModules = ["eth", "net", "web3", "txpool", "parlia"]
WSPort = 8546
WSModules = ["net", "web3", "eth"]

[Node.P2P]
MaxPeers = 200
NoDiscovery = false
# FRP/NAT 场景：inbound≈0，DialRatio=1 让全部 MaxPeers 槽位都用于主动外连
DialRatio = 1
# enode 由 scripts/refresh-static-nodes.sh 动态维护；repair 会自动保留已有的
StaticNodes = []
ListenAddr = ":30303"
EnableMsgEvents = false

[Node.LogConfig]
FilePath = "bsc.log"
MaxBytesSize = 10485760
Level = "info"
FileRoot = ""
EOF

  # template 保持干净骨架（StaticNodes 为空，不含易过期的动态 enode）
  cp -f "${CONFIG_DIR}/config.toml" "${TEMPLATE}" 2>/dev/null || true

  # 把 repair 前已有的 enode 注入回 config（template 不注入）
  if [[ -n "${OLD_ENODES}" ]] && command -v python3 >/dev/null 2>&1; then
    OLD_ENODE_FILE="$(mktemp)"
    printf '%s\n' "${OLD_ENODES}" > "${OLD_ENODE_FILE}"
    python3 - "${CONFIG_DIR}/config.toml" "${OLD_ENODE_FILE}" <<'PYEOF'
import re, sys
cfg, enode_file = sys.argv[1], sys.argv[2]
enodes = [l.strip() for l in open(enode_file) if l.strip().startswith('enode://')]
if enodes:
    s = open(cfg).read()
    arr = "StaticNodes = [\n" + ''.join('  "%s",\n' % e for e in enodes) + "]"
    s = re.sub(r'StaticNodes\s*=\s*\[[^\]]*\]', arr, s, count=1, flags=re.DOTALL)
    open(cfg, 'w').write(s)
    print("[setup] 已保留 %d 个已有 StaticNodes" % len(enodes))
PYEOF
    rm -f "${OLD_ENODE_FILE}"
  fi

  if grep -qE 'ListenAddr = ":30311"' "${CONFIG_DIR}/config.toml"; then
    echo "[setup] 修复 ListenAddr 30311 → 30303（与 P2P_PORT 一致）..."
    sed -i 's/ListenAddr = ":30311"/ListenAddr = ":30303"/' "${CONFIG_DIR}/config.toml"
  fi
  if grep -qE 'ListenAddr = ":30311",' "${CONFIG_DIR}/config.toml"; then
    echo "[setup] 错误: config.toml 含非法 TOML 语法（ListenAddr 尾逗号）" >&2
    exit 1
  fi
  echo "[setup] config.toml 已写入"
}

download_genesis() {
  echo "[setup] 下载 genesis.json (v${BSC_VERSION})..."
  mkdir -p "${CONFIG_DIR}"
  TMP_ZIP="$(mktemp /tmp/mainnet.XXXXXX.zip)"
  curl -fsSL -o "${TMP_ZIP}" \
    "https://github.com/bnb-chain/bsc/releases/download/v${BSC_VERSION}/mainnet.zip"
  unzip -p "${TMP_ZIP}" mainnet/genesis.json > "${CONFIG_DIR}/genesis.json"
  rm -f "${TMP_ZIP}"
}

flatten_mainnet_dir() {
  if [[ -f "${CONFIG_DIR}/mainnet/genesis.json" && ! -f "${CONFIG_DIR}/genesis.json" ]]; then
    mv -f "${CONFIG_DIR}/mainnet/genesis.json" "${CONFIG_DIR}/genesis.json"
  fi
  if [[ -f "${CONFIG_DIR}/mainnet/config.toml" && ! -f "${CONFIG_DIR}/config.toml" ]]; then
    mv -f "${CONFIG_DIR}/mainnet/config.toml" "${CONFIG_DIR}/config.toml"
  fi
  rm -rf "${CONFIG_DIR}/mainnet"
}

ensure_genesis() {
  flatten_mainnet_dir
  if [[ -f "${CONFIG_DIR}/genesis.json" ]]; then
    return 0
  fi
  download_genesis
}

ensure_config() {
  mkdir -p "${CONFIG_DIR}" "${DATA_DIR}" "${INCR_DIR}"
  ensure_genesis
  write_config_toml
  fix_config_perms
}

cmd_init() {
  if [[ -f "${CONFIG_DIR}/genesis.json" && -f "${CONFIG_DIR}/config.toml" ]]; then
    echo "[setup] config 已存在，跳过"
    fix_config_perms
    return 0
  fi
  ensure_config
  echo ""
  echo "[setup] 完成。下一步:"
  echo "  bash scripts/deploy.sh --bg-download"
  echo "  bash scripts/snapshot.sh start"
}

cmd_repair() {
  echo "=== 最近容器日志 ==="
  docker compose -f "${ROOT_DIR}/docker-compose.yml" logs --tail 30 bsc 2>&1 || true
  echo ""
  echo "=== 检查 config/ ==="
  ls -la "${CONFIG_DIR}/" 2>/dev/null || mkdir -p "${CONFIG_DIR}"
  echo ""
  ensure_config
  echo ""
  echo "=== 重启节点 ==="
  docker compose -f "${ROOT_DIR}/docker-compose.yml" down 2>/dev/null || true
  docker compose -f "${ROOT_DIR}/docker-compose.yml" up -d
  sleep 20
  if docker compose -f "${ROOT_DIR}/docker-compose.yml" ps bsc 2>/dev/null | grep -q 'Up'; then
    echo "=== 节点已运行 ==="
    docker exec bsc-node geth attach --datadir /bsc/node --exec "net.peerCount" 2>/dev/null \
      || echo "(geth 仍在启动，稍后再查)"
  else
    echo "=== 仍在重启，最新日志 ==="
    docker compose -f "${ROOT_DIR}/docker-compose.yml" logs --tail 20 bsc
  fi
}

CMD="${1:-init}"
case "${CMD}" in
  init|"") cmd_init ;;
  repair)  cmd_repair ;;
  -h|--help|help) usage ;;
  *)
    echo "未知命令: ${CMD}" >&2
    usage
    exit 1
    ;;
esac
