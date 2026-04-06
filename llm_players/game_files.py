"""Transcript + per-hand result files: poker_game_transcript_#.txt, poker_game_#.txt"""

from __future__ import annotations

import json
import os
import threading
from datetime import datetime, timezone
from typing import Any


def _iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class GameRecorder:
    def __init__(self, game_id: int, out_dir: str) -> None:
        self.game_id = game_id
        self.out_dir = out_dir
        os.makedirs(out_dir, exist_ok=True)
        self.transcript_path = os.path.join(out_dir, f"poker_game_transcript_{game_id}.txt")
        self.results_path = os.path.join(out_dir, f"poker_game_{game_id}.txt")
        self._lock = threading.Lock()
        self._last_winners_sig: str | None = None

    def ensure_headers(self) -> None:
        with self._lock:
            if not os.path.isfile(self.transcript_path):
                with open(self.transcript_path, "w", encoding="utf-8") as f:
                    f.write(
                        f"Poker LLM transcript — game {self.game_id} — started {_iso()}\n"
                        f"Death Note–style internal monologues before each action.\n\n"
                    )
            if not os.path.isfile(self.results_path):
                with open(self.results_path, "w", encoding="utf-8") as f:
                    f.write(
                        f"Poker LLM hand results — game {self.game_id} — started {_iso()}\n"
                        f"Each section: winners, amounts, and pot accounting.\n\n"
                    )

    def append_monologue(
        self,
        display_name: str,
        player_id: str,
        context: str,
        text: str,
    ) -> None:
        with self._lock:
            with open(self.transcript_path, "a", encoding="utf-8") as f:
                f.write("\n")
                f.write("=" * 72 + "\n")
                f.write(f"{_iso()} | {context}\n")
                f.write(f"{display_name} ({player_id})\n")
                f.write("-" * 72 + "\n")
                f.write((text or "").strip() + "\n")

    def maybe_record_hand_end(
        self,
        last_winners: list[dict[str, Any]] | None,
        pot_before_award: int | None,
    ) -> None:
        if not last_winners:
            return
        sig = json.dumps(last_winners, sort_keys=True)
        with self._lock:
            if sig == self._last_winners_sig:
                return
            self._last_winners_sig = sig
            total_won = sum(int(w.get("amount") or 0) for w in last_winners)
            lines = [
                "\n" + "=" * 72,
                f"Hand ended — {_iso()}",
                f"Pot (observed while hand was active, last sample): {pot_before_award}",
                "Winners:",
            ]
            for w in last_winners:
                pid = w.get("player_id", "?")
                amt = w.get("amount", 0)
                hname = w.get("hand_name", "")
                hn = f" — {hname}" if hname else ""
                lines.append(f"  · {pid}: +{amt} chips{hn}")
            lines.append(
                f"Collective loss by non-winners (chips into this pot): {total_won} "
                f"(zero-sum table; amounts awarded = chips others lost to the pot this hand)."
            )
            lines.append("")
            with open(self.results_path, "a", encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")


def read_game_counter(path: str) -> int:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return max(1, int(f.read().strip() or "1"))
    except (OSError, ValueError):
        return 1


def write_game_counter(path: str, n: int) -> None:
    with open(path, "w", encoding="utf-8") as f:
        f.write(str(n))


def resolve_game_id(out_dir: str, new_game: bool) -> int:
    """Persisted counter in ``out_dir/.poker_llm_game_counter``. First session is game 1."""
    path = os.path.join(out_dir, ".poker_llm_game_counter")
    if not os.path.isfile(path):
        write_game_counter(path, 1)
        return 1
    cur = read_game_counter(path)
    if new_game:
        n = cur + 1
        write_game_counter(path, n)
        return n
    return cur
