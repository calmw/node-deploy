#!/usr/bin/env python3
"""Parse Bitcoin Core JSON-RPC response and run health-check assertions."""
from __future__ import annotations

import json
import sys
from pathlib import Path


def out(kind: str, msg: str) -> None:
    print(f"{kind}\t{msg}")


def load_rpc_json(path: str) -> dict:
    raw = Path(path).read_text(encoding="utf-8")
    if not raw.strip():
        raise json.JSONDecodeError("empty response", raw, 0)
    return json.loads(raw)


def extract_result(data: dict) -> object:
    if data.get("error"):
        err = data["error"]
        msg = err.get("message", err) if isinstance(err, dict) else err
        out("FAIL", f"RPC 错误: {msg}")
        sys.exit(0)
    return data.get("result")


def run_assert(assert_name: str, result: object) -> None:
    if assert_name == "chain_main":
        if result.get("chain") != "main":
            out("FAIL", f"chain={result.get('chain')}，期望 main")
        elif result.get("blocks", 0) <= 0:
            out("FAIL", f"blocks={result.get('blocks')}")
        else:
            p = result.get("verificationprogress", 0)
            ibd = result.get("initialblockdownload", True)
            out(
                "PASS",
                f"main blocks={result['blocks']} headers={result['headers']} "
                f"progress={p:.6f} ibd={ibd}",
            )
            if ibd or p < 0.999:
                out("WARN", f"未完全同步 progress={p}")

    elif assert_name == "chain_signet":
        if result.get("chain") != "signet":
            out("FAIL", f"chain={result.get('chain')}，期望 signet")
        elif result.get("blocks", 0) <= 0:
            out("FAIL", f"blocks={result.get('blocks')}")
        else:
            p = result.get("verificationprogress", 0)
            ibd = result.get("initialblockdownload", True)
            out(
                "PASS",
                f"signet blocks={result['blocks']} headers={result['headers']} "
                f"progress={p:.6f} ibd={ibd}",
            )
            if ibd or p < 0.999:
                out("WARN", f"未完全同步 progress={p}")
        return

    if assert_name == "network_active":
        if not result.get("networkactive"):
            out("FAIL", "networkactive=false")
        else:
            c = result.get("connections", 0)
            out("PASS", f"connections={c} {result.get('subversion', '')}")
            if c < 3:
                out("WARN", f"peer 偏少: {c}")
        return

    if assert_name == "positive_int":
        n = int(result)
        if n <= 0:
            out("FAIL", f"值无效: {n}")
        else:
            out("PASS", f"height={n}")
        return

    if assert_name == "block_hash":
        if not (isinstance(result, str) and len(result) == 64):
            out("FAIL", f"hash 无效: {result!r}")
        else:
            out("PASS", f"{result[:16]}...")
        return

    if assert_name == "mempool_loaded":
        if not result.get("loaded"):
            out("FAIL", "mempool 未 loaded")
        else:
            out("PASS", f"size={result.get('size', 0)} optimal={result.get('optimal', '?')}")
        return

    if assert_name == "peer_list":
        if not isinstance(result, list):
            out("FAIL", "期望 peer 数组")
        else:
            out("PASS", f"peers={len(result)}")
            if len(result) < 3:
                out("WARN", f"peer 偏少: {len(result)}")
        return

    if assert_name == "smart_fee":
        if isinstance(result, dict) and result.get("feerate") is not None:
            out("PASS", f"feerate={result['feerate']} BTC/kvB")
        else:
            out("PASS", "响应正常")
            out("WARN", "无 feerate（内存池可能较空）")
        return

    if assert_name == "tx_list":
        if not isinstance(result, list):
            out("FAIL", "期望 txid 列表")
        else:
            out("PASS", f"pending={len(result)}")
        return

    if assert_name == "block_verbose":
        if not isinstance(result, dict) or "hash" not in result:
            out("FAIL", "区块对象无效")
        else:
            out("PASS", f"height={result.get('height')} nTx={len(result.get('tx', []))}")
        return

    if assert_name == "block_hex":
        if not isinstance(result, str) or len(result) < 10:
            out("FAIL", "区块 hex 无效")
        else:
            out("PASS", f"raw_len={len(result)}")
        return

    if assert_name == "chaintxstats":
        if not isinstance(result, dict) or "time" not in result:
            out("FAIL", "chaintxstats 无效")
        else:
            out(
                "PASS",
                f"window={result.get('window_block_count')} "
                f"txrate={result.get('txrate', 0):.4f}",
            )
        return

    out("PASS", "ok")


def main() -> None:
    if len(sys.argv) < 3:
        print("usage: btc-rpc-test-parse.py <assert> <response.json>", file=sys.stderr)
        sys.exit(2)

    assert_name = sys.argv[1]
    response_path = sys.argv[2]

    try:
        data = load_rpc_json(response_path)
    except json.JSONDecodeError as exc:
        out("FAIL", f"非 JSON 响应: {exc}")
        return

    result = extract_result(data)
    run_assert(assert_name, result)


if __name__ == "__main__":
    main()
