"""Optional text-to-speech for monologues — one voice profile per configured player_id."""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import threading
from typing import Final

_lock = threading.Lock()

# espeak-ng / espeak extra argv (voice / speed / pitch). Unknown ids use _DEFAULT_ESPEAK.
_ESPEAK_BY_PLAYER: Final[dict[str, list[str]]] = {
    "gpt_5_4": ["-v", "en+m3", "-s", "158", "-p", "52"],
    "claude_4_6_opus": ["-v", "en+f4", "-s", "148", "-p", "42"],
    "gemini_3_1": ["-v", "en-gb", "-s", "150", "-p", "48"],
    "llama_4": ["-v", "en-us", "-s", "162", "-p", "50"],
    "deepseek_v3_2": ["-v", "en+m5", "-s", "150", "-p", "46"],
    "mistral_large_3": ["-v", "en+f2", "-s", "155", "-p", "55"],
    "grok_ai": ["-v", "en+m2", "-s", "168", "-p", "58"],
}
_DEFAULT_ESPEAK: Final[list[str]] = ["-v", "en", "-s", "150", "-p", "50"]

# macOS `say -v Name` — one voice per player (install English voices in System Settings if missing).
_SAY_BY_PLAYER: Final[dict[str, str]] = {
    "gpt_5_4": "Alex",
    "claude_4_6_opus": "Samantha",
    "gemini_3_1": "Daniel",
    "llama_4": "Tom",
    "deepseek_v3_2": "Fred",
    "mistral_large_3": "Victoria",
    "grok_ai": "Moira",
}
_DEFAULT_SAY_VOICE = "Alex"


def _strip_for_speech(text: str, max_chars: int) -> str:
    max_chars = max(1, int(max_chars))
    t = text.strip()
    if not t:
        return ""
    t = re.sub(r"```[\s\S]*?```", " ", t)
    t = re.sub(r"`([^`]*)`", r"\1", t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"\1", t)
    t = re.sub(r"\*([^*]+)\*", r"\1", t)
    t = re.sub(r"[_#]+", " ", t)
    t = re.sub(r"\s+", " ", t).strip()
    if len(t) > max_chars:
        t = t[: max_chars - 1].rsplit(" ", 1)[0] + " …"
    return t


def _espeak_bin() -> str | None:
    for name in ("espeak-ng", "espeak"):
        p = shutil.which(name)
        if p:
            return p
    return None


def _say_bin() -> str | None:
    return shutil.which("say") if sys.platform == "darwin" else None


def tts_available(engine: str) -> bool:
    eng = (engine or "espeak").strip().lower()
    if eng == "say":
        return _say_bin() is not None
    return _espeak_bin() is not None


def speak_monologue(
    player_id: str,
    text: str,
    *,
    engine: str = "espeak",
    max_chars: int = 6000,
) -> None:
    """
    Speak monologue text with a player-specific voice. Serialized with a lock so
    concurrent --auto threads do not overlap audio.
    """
    prepared = _strip_for_speech(text, max_chars)
    if not prepared:
        return

    eng = (engine or "espeak").strip().lower()
    if eng == "say":
        if not _say_bin():
            sys.stderr.write(
                "[tts] `say` not found (macOS only). Install espeak-ng or use --tts-engine espeak.\n"
            )
            sys.stderr.flush()
            return
        voice = _SAY_BY_PLAYER.get(player_id, _DEFAULT_SAY_VOICE)
        cmd = ["say", "-v", voice, prepared]
    else:
        exe = _espeak_bin()
        if not exe:
            sys.stderr.write(
                "[tts] espeak-ng/espeak not found in PATH. "
                "On Fedora: sudo dnf install espeak-ng  ·  macOS: use --tts-engine say\n"
            )
            sys.stderr.flush()
            return
        extra = list(_ESPEAK_BY_PLAYER.get(player_id, _DEFAULT_ESPEAK))
        cmd = [exe] + extra + ["--stdin"]

    with _lock:
        try:
            if eng == "say":
                subprocess.run(
                    cmd,
                    check=False,
                    timeout=max(120, len(prepared) // 8),
                    capture_output=True,
                )
            else:
                subprocess.run(
                    cmd,
                    input=prepared.encode("utf-8"),
                    check=False,
                    timeout=max(120, len(prepared) // 8),
                    capture_output=True,
                )
        except subprocess.TimeoutExpired:
            sys.stderr.write("[tts] speech subprocess timed out\n")
            sys.stderr.flush()
        except OSError as e:
            sys.stderr.write(f"[tts] {e}\n")
            sys.stderr.flush()
