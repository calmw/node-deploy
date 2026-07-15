#!/usr/bin/env bash
# BSC Chapel 测试网配置：init | repair
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${ROOT_DIR}/config"
DATA_DIR="${ROOT_DIR}/data/node"
INCR_DIR="${ROOT_DIR}/data/incr"
TEMPLATE="${CONFIG_DIR}/config.toml.template"
BSC_VERSION="${BSC_VERSION:-1.7.3}"
CONTAINER_NAME="${BSC_CONTAINER:-bsc-testnet-node}"

usage() {
  cat <<'EOF'
用法: bash scripts/setup.sh [命令]

命令:
  init     初始化 config/（默认）
  repair   重新拉取 testnet 配置并重启容器

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

is_testnet_genesis() {
  [[ -f "${CONFIG_DIR}/genesis.json" ]] || return 1
  python3 - "${CONFIG_DIR}/genesis.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
print(g.get("config", {}).get("chainId", 0))
PY
}

patch_config_toml() {
  local cfg="${CONFIG_DIR}/config.toml"
  # 以模板为准（StaticNodes 留空，peer 由 start.sh --bootnodes 与 refresh 脚本维护）
  cp -f "${TEMPLATE}" "${cfg}"
  if ! grep -q 'ListenAddr' "${cfg}"; then
    sed -i '/^\[Node\.LogConfig\]/i ListenAddr = ":30311"\nEnableMsgEvents = false\n' "${cfg}"
  fi
  if ! grep -q 'DialRatio' "${cfg}"; then
    sed -i '/^\[Node\.P2P\]/a DialRatio = 1' "${cfg}"
  fi
}

validate_config_toml() {
  local cfg="${CONFIG_DIR}/config.toml"
  python3 - "${cfg}" <<'PY' || { echo "[setup] config.toml 校验失败" >&2; return 1; }
import sys
try:
    import tomllib
    tomllib.load(open(sys.argv[1], "rb"))
except ImportError:
    import tomli as tomllib
    tomllib.load(open(sys.argv[1], "rb"))
print("[setup] config.toml 语法 OK")
PY
}

merge_static_nodes() {
  local OLD_ENODES=""
  [[ -f "${CONFIG_DIR}/config.toml" ]] && \
    OLD_ENODES="$(grep -oE 'enode://[0-9a-f]{128}@[0-9.]+:[0-9]+' "${CONFIG_DIR}/config.toml" 2>/dev/null | sort -u || true)"
  [[ -n "${OLD_ENODES}" ]] && command -v python3 >/dev/null 2>&1 || return 0
  local OLD_ENODE_FILE
  OLD_ENODE_FILE="$(mktemp)"
  printf '%s\n' "${OLD_ENODES}" > "${OLD_ENODE_FILE}"
  python3 - "${CONFIG_DIR}/config.toml" "${OLD_ENODE_FILE}" <<'PYEOF'
import re, sys
cfg, enode_file = sys.argv[1], sys.argv[2]
enodes = [l.strip() for l in open(enode_file) if l.strip().startswith('enode://')]
if not enodes:
    sys.exit(0)
# 单行数组，避免 geth TOML 对多行 StaticNodes 解析失败
line = "StaticNodes = [" + ", ".join('"%s"' % e for e in enodes) + "]"
s = open(cfg).read()
s = re.sub(r"StaticNodes\s*=\s*\[[^\]]*\]", line, s, count=1)
open(cfg, 'w').write(s)
print("[setup] 已写入 %d 个 StaticNodes（单行格式）" % len(enodes))
PYEOF
  rm -f "${OLD_ENODE_FILE}"
}

download_testnet_bundle() {
  echo "[setup] 下载 BSC Chapel testnet 配置 (v${BSC_VERSION})..."
  mkdir -p "${CONFIG_DIR}"
  TMP_ZIP="$(mktemp /tmp/testnet.XXXXXX.zip)"
  curl -fsSL -o "${TMP_ZIP}" \
    "https://github.com/bnb-chain/bsc/releases/download/v${BSC_VERSION}/testnet.zip"
  unzip -p "${TMP_ZIP}" testnet/genesis.json > "${CONFIG_DIR}/genesis.json"
  rm -f "${TMP_ZIP}"
  patch_config_toml
  validate_config_toml
  cp -f "${CONFIG_DIR}/config.toml" "${TEMPLATE}"
  echo "[setup] genesis + config.toml 已更新 (chainId=97)"
}

flatten_testnet_dir() {
  if [[ -f "${CONFIG_DIR}/testnet/genesis.json" && ! -f "${CONFIG_DIR}/genesis.json" ]]; then
    mv -f "${CONFIG_DIR}/testnet/genesis.json" "${CONFIG_DIR}/genesis.json"
  fi
  if [[ -f "${CONFIG_DIR}/testnet/config.toml" && ! -f "${CONFIG_DIR}/config.toml" ]]; then
    mv -f "${CONFIG_DIR}/testnet/config.toml" "${CONFIG_DIR}/config.toml"
  fi
  rm -rf "${CONFIG_DIR}/testnet" "${CONFIG_DIR}/mainnet"
}

ensure_testnet_config() {
  flatten_testnet_dir
  local chain_id
  chain_id="$(is_testnet_genesis 2>/dev/null || echo 0)"
  if [[ "${chain_id}" != "97" ]] || [[ ! -f "${CONFIG_DIR}/config.toml" ]]; then
    download_testnet_bundle
  else
    patch_config_toml
    merge_static_nodes
    validate_config_toml
  fi
  mkdir -p "${DATA_DIR}" "${INCR_DIR}"
  fix_config_perms
}

cmd_init() {
  if [[ -f "${CONFIG_DIR}/genesis.json" && -f "${CONFIG_DIR}/config.toml" ]] \
    && [[ "$(is_testnet_genesis 2>/dev/null || echo 0)" == "97" ]]; then
    echo "[setup] Chapel testnet config 已存在，跳过"
    fix_config_perms
    return 0
  fi
  ensure_testnet_config
  echo ""
  echo "[setup] 完成。下一步:"
  echo "  bash scripts/deploy.sh"
  echo "  或: docker compose up -d   # snap 模式无需快照"
}

cmd_repair() {
  echo "=== 最近容器日志 ==="
  docker compose -f "${ROOT_DIR}/docker-compose.yml" logs --tail 30 bsc 2>&1 || true
  echo ""
  ensure_testnet_config
  if [[ ! -f "${ROOT_DIR}/.env" ]]; then
    cp "${ROOT_DIR}/.env.example" "${ROOT_DIR}/.env"
    echo "[setup] 已创建 .env（从 .env.example）"
  fi
  if [[ -f "${DATA_DIR}/geth/chaindata/CURRENT" ]]; then
    echo "[setup] 警告: data/node 已有链数据。若曾跑过主网配置，请先 bash scripts/reset-data.sh"
  fi
  echo ""
  echo "=== 重启节点 ==="
  docker compose -f "${ROOT_DIR}/docker-compose.yml" down 2>/dev/null || true
  docker compose -f "${ROOT_DIR}/docker-compose.yml" up -d
  sleep 20
  if docker compose -f "${ROOT_DIR}/docker-compose.yml" ps bsc 2>/dev/null | grep -q 'Up'; then
    echo "=== 节点已运行 ==="
    docker exec "${CONTAINER_NAME}" geth attach --datadir /bsc/node --exec "net.peerCount" 2>/dev/null \
      || echo "(geth 仍在启动，稍后再查)"
    echo "  检查: bash scripts/status.sh"
  else
    echo "=== 仍在重启或已退出，最新日志 ==="
    docker compose -f "${ROOT_DIR}/docker-compose.yml" logs --tail 30 bsc
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
