#!/usr/bin/env python3
"""
Smoke test: join the demo table and send a fold.

Run from the repo root with the server up::

    python testjoin.py

Override base URL::

    python testjoin.py --url http://127.0.0.1:8080
    # or
    POKER_URL=http://localhost:8080 python testjoin.py
"""

from __future__ import annotations

import argparse
import json
import os
import sys

# Repo root → clients/python on path (no PYTHONPATH needed)
_ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_ROOT, "clients", "python"))

from poker_client import PokerClient, PokerError, TransportError


def main() -> None:
    default_url = os.environ.get("POKER_URL", "http://127.0.0.1:8080")
    p = argparse.ArgumentParser(description="Join demo table and fold (smoke test)")
    p.add_argument(
        "--url",
        default=default_url,
        help="Poker server base URL (default: env POKER_URL or http://127.0.0.1:8080)",
    )
    args = p.parse_args()

    c = PokerClient(args.url)
    try:
        out = c.join_table(
            "demo",
            seat=7,
            player_id="Hason",
            chips=500,
        )
        print("join:", json.dumps(out, indent=2)[:800])
        out2 = c.send_action("demo", player_id="Hason", action="raise", amount=100)
        print("fold:", json.dumps(out2, indent=2)[:800])
    except PokerError as e:
        print("API error:", e.status_code, e.api_code, e.message, file=sys.stderr)
        raise SystemExit(1) from e
    except TransportError as e:
        print("Network / transport:", e, file=sys.stderr)
        raise SystemExit(2) from e


if __name__ == "__main__":
    main()
