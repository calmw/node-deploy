#!/usr/bin/env bash
# Bitcoin Core HTTP JSON-RPC 健康检查
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSE_PY="${ROOT_DIR}/scripts/btc-rpc-test-parse.py"
EXTRACT_PY="${ROOT_DIR}/scripts/btc-rpc-test-extract.py"

RPC_URL="${BTC_RPC_URL:-http://127.0.0.1:38332/}"
RPC_USER="${BTC_RPC_USER:-}"
RPC_PASS="${BTC_RPC_PASS:-}"

PASS=0
FAIL=0
WARN=0
REQ_ID=0
TMPDIR="${TMPDIR:-/tmp}"

usage() {
  cat <<'EOF'
用法: bash scripts/btc-rpc-test.sh [选项]

对 Bitcoin Core HTTP RPC 做连通性与常用接口检查。

选项:
  --url URL       RPC 地址（默认: http://127.0.0.1:38332/）
  --user USER     rpcuser（或环境变量 BTC_RPC_USER）
  --pass PASS     rpcpassword（或环境变量 BTC_RPC_PASS）
  -h, --help      显示帮助

凭证: 命令行 > 环境变量 > btc-testnet/config/bitcoin.conf

示例:
  bash scripts/btc-rpc-test.sh --url http://127.0.0.1:38332/
  bash scripts/btc-rpc-test.sh --url http://100.x.x.x:38332/ --user ... --pass ...

注意: 远程访问需在 bitcoin.conf 配置 rpcallowip，并与云安全组来源网段一致。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) RPC_URL="$2"; shift 2 ;;
    --user) RPC_USER="$2"; shift 2 ;;
    --pass) RPC_PASS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

[[ "${RPC_URL}" == */ ]] || RPC_URL="${RPC_URL}/"

load_credentials() {
  if [[ -n "${RPC_USER}" && -n "${RPC_PASS}" ]]; then
    return 0
  fi
  local conf="${ROOT_DIR}/config/bitcoin.conf"
  if [[ -f "${conf}" ]]; then
    RPC_USER="${RPC_USER:-$("${ROOT_DIR}/scripts/conf-get.sh" rpcuser || true)}"
    RPC_PASS="${RPC_PASS:-$("${ROOT_DIR}/scripts/conf-get.sh" rpcpassword || true)}"
  fi
  if [[ -z "${RPC_USER}" || -z "${RPC_PASS}" ]]; then
    echo "错误: 未设置 RPC 凭证。" >&2
    if [[ ! -f "${conf}" ]]; then
      echo "  本机无 config/bitcoin.conf（开发机 clone 仓库时通常没有该文件）。" >&2
    fi
    echo "  远程测试请显式传入：" >&2
    echo "    bash scripts/btc-rpc-test.sh --url ${RPC_URL} --user <rpcuser> --pass '<rpcpassword>'" >&2
    echo "  或在服务器上执行（自动读 config/bitcoin.conf）：" >&2
    echo "    bash scripts/btc-rpc-test.sh --url http://127.0.0.1:38332/" >&2
    exit 1
  fi
}

rpc_call() {
  local method="$1"
  local params="${2:-[]}"
  REQ_ID=$((REQ_ID + 1))
  curl -sS -m 30 --user "${RPC_USER}:${RPC_PASS}" \
    --data-binary "{\"jsonrpc\":\"1.0\",\"id\":${REQ_ID},\"method\":\"${method}\",\"params\":${params}}" \
    -H 'content-type: text/plain;' \
    "${RPC_URL}"
}

pass_msg() { PASS=$((PASS + 1)); echo "[PASS] $*"; }
fail_msg() { FAIL=$((FAIL + 1)); echo "[FAIL] $*"; }
warn_msg() { WARN=$((WARN + 1)); echo "[WARN] $*"; }

apply_parse_lines() {
  local label="$1"
  local line status result
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    status="${line%%$'\t'*}"
    result="${line#*$'\t'}"
    case "${status}" in
      PASS) pass_msg "${label} — ${result}" ;;
      FAIL) fail_msg "${label} — ${result}" ;;
      WARN) warn_msg "${label} — ${result}" ;;
    esac
  done
}

rpc_check() {
  local label="$1"
  local method="$2"
  local params="${3:-[]}"
  local assert="${4:-}"
  local body tmp
  tmp="$(mktemp "${TMPDIR}/btc-rpc-test.XXXXXX")"

  if ! body="$(rpc_call "${method}" "${params}" 2>&1)"; then
    rm -f "${tmp}"
    fail_msg "${label} — HTTP 失败: ${body}"
    return
  fi

  printf '%s' "${body}" > "${tmp}"
  apply_parse_lines "${label}" < <(python3 "${PARSE_PY}" "${assert}" "${tmp}")
  rm -f "${tmp}"
}

rpc_result() {
  local method="$1"
  local params="${2:-[]}"
  local body tmp
  tmp="$(mktemp "${TMPDIR}/btc-rpc-extract.XXXXXX")"

  if ! body="$(rpc_call "${method}" "${params}" 2>&1)"; then
    rm -f "${tmp}"
    return 1
  fi

  printf '%s' "${body}" > "${tmp}"
  if ! python3 "${EXTRACT_PY}" "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  rm -f "${tmp}"
}

main() {
  command -v curl >/dev/null 2>&1 || { echo "错误: 需要 curl" >&2; exit 1; }
  command -v python3 >/dev/null 2>&1 || { echo "错误: 需要 python3" >&2; exit 1; }
  [[ -f "${PARSE_PY}" && -f "${EXTRACT_PY}" ]] || {
    echo "错误: 缺少 ${PARSE_PY} 或 ${EXTRACT_PY}" >&2
    exit 1
  }

  load_credentials

  echo "============================================"
  echo " Bitcoin Core RPC 测试"
  echo " URL:  ${RPC_URL}"
  echo " User: ${RPC_USER}"
  echo "============================================"
  echo

  local start end elapsed body tmp
  tmp="$(mktemp "${TMPDIR}/btc-rpc-test.XXXXXX")"
  start="$(python3 -c 'import time; print(int(time.time()*1000))')"
  if body="$(rpc_call getblockchaininfo 2>&1)"; then
    end="$(python3 -c 'import time; print(int(time.time()*1000))')"
    elapsed=$((end - start))
    printf '%s' "${body}" > "${tmp}"
    if python3 "${EXTRACT_PY}" "${tmp}" >/dev/null 2>&1; then
      pass_msg "HTTP 连通性 — ${elapsed}ms"
    else
      rm -f "${tmp}"
      fail_msg "HTTP 可达但认证/RPC 失败 — 检查 rpcuser/rpcpassword 与 rpcallowip"
      echo; echo "汇总: PASS=${PASS} WARN=${WARN} FAIL=${FAIL}"; exit 1
    fi
  else
    rm -f "${tmp}"
    fail_msg "HTTP 连通性 — ${body}"
    echo; echo "汇总: PASS=${PASS} WARN=${WARN} FAIL=${FAIL}"; exit 1
  fi
  rm -f "${tmp}"

  rpc_check "getblockchaininfo" getblockchaininfo '[]' chain_signet
  rpc_check "getnetworkinfo" getnetworkinfo '[]' network_active
  rpc_check "getblockcount" getblockcount '[]' blockcount_height
  rpc_check "getbestblockhash" getbestblockhash '[]' block_hash
  rpc_check "getmempoolinfo" getmempoolinfo '[]' mempool_loaded
  rpc_check "getpeerinfo" getpeerinfo '[]' peer_list
  rpc_check "estimatesmartfee(6)" estimatesmartfee '[6,"economical"]' smart_fee
  rpc_check "getrawmempool" getrawmempool '[]' tx_list

  local height best prev chaintx_window
  if height="$(rpc_result getblockcount 2>/dev/null)"; then
    height="$(python3 -c 'import json,sys; print(int(json.loads(sys.argv[1])))' "${height}")"
    if [[ "${height}" -gt 0 ]]; then
      chaintx_window="${height}"
      [[ "${chaintx_window}" -gt 2016 ]] && chaintx_window=2016
      rpc_check "getchaintxstats(${chaintx_window})" getchaintxstats "[${chaintx_window}]" chaintxstats
    else
      warn_msg "getchaintxstats — 跳过（height=0，同步未完成）"
    fi
    rpc_check "getblockhash(${height})" getblockhash "[${height}]" block_hash
    if best="$(rpc_result getbestblockhash 2>/dev/null)"; then
      best="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]))' "${best}")"
      rpc_check "getblock(best, verbose=1)" getblock "[\"${best}\",1]" block_verbose
    fi
    if [[ "${height}" -gt 1 ]]; then
      if prev="$(rpc_result getblockhash "$((height - 1))" 2>/dev/null)"; then
        prev="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]))' "${prev}")"
        rpc_check "getblock(prev, verbose=0)" getblock "[\"${prev}\",0]" block_hex
      fi
    fi
  else
    fail_msg "链式查询 — 无法读取 blockcount"
  fi

  echo
  echo "============================================"
  echo " 汇总: PASS=${PASS}  WARN=${WARN}  FAIL=${FAIL}"
  echo "============================================"

  [[ "${FAIL}" -eq 0 ]]
}

main
