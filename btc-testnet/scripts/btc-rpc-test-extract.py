#!/usr/bin/env python3
"""Extract JSON-RPC result field from a Bitcoin Core HTTP response file."""
import json
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: btc-rpc-test-extract.py <response.json>", file=sys.stderr)
        sys.exit(2)

    data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    if data.get("error"):
        sys.exit(1)
    print(json.dumps(data["result"]))


if __name__ == "__main__":
    main()
