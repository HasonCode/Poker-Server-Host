"""LLM backends: OpenAI-compatible chat + tools, Anthropic messages + tools."""

from __future__ import annotations

import json
import os
import ssl
import sys
import threading
import urllib.error
import urllib.request
from typing import Any, Callable

from .config import PlayerConfig
from . import poker_tools as pt
from . import prompts


def _configure_stdio() -> None:
    """Line-buffer when stderr is redirected to a file (llm-step); avoids huge silent buffers."""
    os.environ.setdefault("PYTHONUNBUFFERED", "1")
    for stream in (sys.stdout, sys.stderr):
        if not hasattr(stream, "reconfigure"):
            continue
        try:
            stream.reconfigure(line_buffering=True)
        except Exception:
            try:
                stream.reconfigure(write_through=True)
            except Exception:
                pass


_configure_stdio()


def _http_timeout() -> float:
    """Per-request socket timeout (seconds). Override: LLM_HTTP_TIMEOUT or POKER_LLM_HTTP_TIMEOUT."""
    raw = os.environ.get("LLM_HTTP_TIMEOUT") or os.environ.get("POKER_LLM_HTTP_TIMEOUT")
    if raw:
        try:
            t = float(raw)
            if t > 0:
                return t
        except ValueError:
            pass
    return 120.0


def _heartbeat_interval() -> float:
    """Seconds between 'still waiting' stderr lines during one HTTP call; 0 disables."""
    raw = os.environ.get("LLM_HTTP_HEARTBEAT_SEC", "25")
    try:
        v = float(raw)
        return v if v > 0 else 0.0
    except ValueError:
        return 25.0


def _post_json_impl(
    url: str,
    headers: dict[str, str],
    body: dict[str, Any],
    timeout: float,
) -> dict[str, Any]:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        method="POST",
        headers=headers,
    )
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            raise RuntimeError(f"HTTP {e.code}: {raw.decode('utf-8', errors='replace')[:800]}") from e
    return json.loads(raw.decode("utf-8"))


def _post_json(
    url: str,
    headers: dict[str, str],
    body: dict[str, Any],
    timeout: float | None = None,
) -> dict[str, Any]:
    """POST JSON; optional heartbeat on stderr while waiting (single long Gemini call has no other log lines)."""
    t = _http_timeout() if timeout is None else timeout
    if t <= 0:
        t = 120.0

    hb = _heartbeat_interval()
    if hb <= 0:
        return _post_json_impl(url, headers, body, t)

    box: dict[str, Any] = {}
    err: list[BaseException] = []

    def worker() -> None:
        try:
            box["data"] = _post_json_impl(url, headers, body, t)
        except BaseException as e:
            err.append(e)

    th = threading.Thread(target=worker, daemon=True)
    th.start()
    elapsed = 0.0
    while th.is_alive():
        th.join(timeout=hb)
        if th.is_alive():
            elapsed += hb
            sys.stderr.write(
                f"[llm-step] HTTP still in progress ({elapsed:.0f}s / {t:.0f}s timeout) — "
                "waiting on provider…\n"
            )
            sys.stderr.flush()
    if err:
        raise err[0]
    return box["data"]


def _normalize_base(url: str) -> str:
    return url.rstrip("/")


def _parse_tool_arguments(raw: Any) -> dict[str, Any]:
    """OpenAI spec uses a JSON string; some OpenAI-compat providers return a dict."""
    if raw is None:
        return {}
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        s = raw.strip()
        if not s:
            return {}
        try:
            out = json.loads(s)
        except json.JSONDecodeError:
            return {}
        return out if isinstance(out, dict) else {}
    return {}


def monologue_openai_compat(
    *,
    base_url: str,
    api_key: str,
    model: str,
    display_name: str,
    extra_headers: dict[str, str] | None = None,
    user_message: str | None = None,
) -> str:
    url = _normalize_base(base_url) + "/chat/completions"
    headers: dict[str, str] = {"Content-Type": "application/json"}
    if extra_headers and "x-goog-api-key" in extra_headers:
        headers.update(extra_headers)
    else:
        headers["Authorization"] = f"Bearer {api_key}"
        if extra_headers:
            headers.update(extra_headers)
    um = user_message or (
        f"You are seated as {display_name}. Write your internal monologue now."
    )
    body = {
        "model": model,
        "temperature": 0.9,
        "messages": [
            {"role": "system", "content": prompts.MONOLOGUE_SYSTEM},
            {"role": "user", "content": um},
        ],
    }
    sys.stderr.write(
        f"[llm-step] monologue → POST chat/completions (timeout {_http_timeout():.0f}s)…\n"
    )
    sys.stderr.flush()
    data = _post_json(url, headers, body)
    ch = data.get("choices") or []
    if not ch:
        raise RuntimeError(f"Unexpected response: {data!r}")
    msg = ch[0].get("message") or {}
    return str(msg.get("content") or "").strip()


def monologue_anthropic(
    *,
    api_key: str,
    model: str,
    display_name: str,
    user_message: str | None = None,
) -> str:
    url = "https://api.anthropic.com/v1/messages"
    headers = {
        "Content-Type": "application/json",
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
    }
    um = user_message or (
        f"You are seated as {display_name}. Write your internal monologue now."
    )
    body = {
        "model": model,
        "max_tokens": 1024,
        "system": prompts.MONOLOGUE_SYSTEM,
        "messages": [{"role": "user", "content": um}],
    }
    sys.stderr.write(
        f"[llm-step] monologue → POST messages (timeout {_http_timeout():.0f}s)…\n"
    )
    sys.stderr.flush()
    data = _post_json(url, headers, body)
    blocks = data.get("content") or []
    parts: list[str] = []
    for b in blocks:
        if isinstance(b, dict) and b.get("type") == "text":
            parts.append(str(b.get("text") or ""))
    return "\n".join(parts).strip()


def _openai_tools_to_anthropic(tools: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for t in tools:
        fn = t.get("function") or {}
        out.append(
            {
                "name": fn["name"],
                "description": fn.get("description", ""),
                "input_schema": fn.get("parameters") or {"type": "object", "properties": {}},
            }
        )
    return out


def decide_openai_compat(
    *,
    base_url: str,
    api_key: str,
    model: str,
    state: dict,
    player_id: str,
    display_name: str,
    max_rounds: int = 24,
    extra_headers: dict[str, str] | None = None,
) -> tuple[str, int | None]:
    url = _normalize_base(base_url) + "/chat/completions"
    headers = {"Content-Type": "application/json"}
    if extra_headers and "x-goog-api-key" in extra_headers:
        headers.update(extra_headers)
    else:
        headers["Authorization"] = f"Bearer {api_key}"
        if extra_headers:
            headers.update(extra_headers)

    messages: list[dict[str, Any]] = [
        {"role": "system", "content": prompts.ACTION_SYSTEM},
        {
            "role": "user",
            "content": (
                f"You are {display_name} ({player_id}). It is your turn. "
                f"Use tools to inspect the table, then submit_poker_action."
            ),
        },
    ]

    tool_exec: Callable[[str, dict[str, Any]], dict[str, Any]] = (
        lambda name, args: pt.execute_tool(name, state, player_id, args)
    )

    to = _http_timeout()
    hb = _heartbeat_interval()
    hb_note = f"{hb:.0f}s between lines" if hb > 0 else "off"
    for rnd in range(max_rounds):
        sys.stderr.write(
            f"[llm-step] decide round {rnd + 1}/{max_rounds} → POST chat/completions "
            f"(timeout {to:.0f}s/call; in-call progress {hb_note})…\n"
        )
        sys.stderr.flush()
        body: dict[str, Any] = {
            "model": model,
            "temperature": 0.3,
            "messages": messages,
            "tools": pt.OPENAI_STYLE_TOOLS,
            "tool_choice": "auto",
        }
        data = _post_json(url, headers, body)
        if isinstance(data, dict) and data.get("error") is not None:
            err = data.get("error")
            msg = err.get("message") if isinstance(err, dict) else str(err)
            typ = err.get("type") if isinstance(err, dict) else ""
            raise RuntimeError(
                f"Provider rejected request (often invalid tool schema or model): {msg}"
                + (f" type={typ}" if typ else "")
            )
        ch = (data.get("choices") or [None])[0]
        if not ch:
            raise RuntimeError(f"No choices: {data!r}")
        msg = ch.get("message") or {}
        tool_calls = msg.get("tool_calls")
        if tool_calls:
            messages.append(msg)
            submit_tc = None
            for tc in tool_calls:
                fn = tc.get("function") or {}
                if (fn.get("name") or "") == "submit_poker_action":
                    submit_tc = tc
                    break
            for tc in tool_calls:
                fn = tc.get("function") or {}
                name = fn.get("name") or ""
                if name == "submit_poker_action":
                    continue
                args = _parse_tool_arguments(fn.get("arguments"))
                tid = tc.get("id") or "call"
                result = tool_exec(name, args)
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": tid,
                        "content": json.dumps(result),
                    }
                )
            if submit_tc is not None:
                fn = submit_tc.get("function") or {}
                args = _parse_tool_arguments(fn.get("arguments"))
                act = str(args.get("action") or "fold").lower()
                amt = args.get("amount")
                ai = None if amt is None else int(amt)
                return act, ai
            continue

        # No tool calls — nudge
        messages.append(
            {
                "role": "user",
                "content": "You must call submit_poker_action with your move.",
            }
        )

    return "fold", None


def decide_anthropic(
    *,
    api_key: str,
    model: str,
    state: dict,
    player_id: str,
    display_name: str,
    max_rounds: int = 24,
) -> tuple[str, int | None]:
    url = "https://api.anthropic.com/v1/messages"
    headers = {
        "Content-Type": "application/json",
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
    }
    tools = _openai_tools_to_anthropic(pt.OPENAI_STYLE_TOOLS)
    messages: list[dict[str, Any]] = [
        {
            "role": "user",
            "content": (
                f"You are {display_name} ({player_id}). It is your turn. "
                f"Use tools to inspect the table, then submit_poker_action."
            ),
        }
    ]
    tool_exec: Callable[[str, dict[str, Any]], dict[str, Any]] = (
        lambda name, args: pt.execute_tool(name, state, player_id, args)
    )

    to = _http_timeout()
    hb = _heartbeat_interval()
    hb_note = f"{hb:.0f}s between lines" if hb > 0 else "off"
    for rnd in range(max_rounds):
        sys.stderr.write(
            f"[llm-step] decide round {rnd + 1}/{max_rounds} → POST messages "
            f"(timeout {to:.0f}s/call; in-call progress {hb_note})…\n"
        )
        sys.stderr.flush()
        body = {
            "model": model,
            "max_tokens": 4096,
            "system": prompts.ACTION_SYSTEM,
            "tools": tools,
            "messages": messages,
        }
        data = _post_json(url, headers, body)
        if isinstance(data, dict) and data.get("type") == "error":
            err = data.get("error") or {}
            msg = err.get("message") if isinstance(err, dict) else str(data)
            raise RuntimeError(f"Anthropic API error: {msg}")
        content = data.get("content") or []
        stop_reason = data.get("stop_reason")
        tool_uses = [c for c in content if isinstance(c, dict) and c.get("type") == "tool_use"]
        if tool_uses:
            messages.append({"role": "assistant", "content": content})
            submit_tu = next(
                (tu for tu in tool_uses if tu.get("name") == "submit_poker_action"),
                None,
            )
            tool_results: list[dict[str, Any]] = []
            for tu in tool_uses:
                name = tu.get("name") or ""
                if name == "submit_poker_action":
                    continue
                tid = tu.get("id") or ""
                inp = tu.get("input") if isinstance(tu.get("input"), dict) else {}
                result = tool_exec(name, inp)
                tool_results.append(
                    {
                        "type": "tool_result",
                        "tool_use_id": tid,
                        "content": json.dumps(result),
                    }
                )
            if tool_results:
                messages.append({"role": "user", "content": tool_results})
            if submit_tu is not None:
                inp = submit_tu.get("input") if isinstance(submit_tu.get("input"), dict) else {}
                act = str(inp.get("action") or "fold").lower()
                amt = inp.get("amount")
                ai = None if amt is None else int(amt)
                return act, ai
            continue
        if stop_reason == "end_turn" and not tool_uses:
            messages.append(
                {
                    "role": "user",
                    "content": "You must use tools and end with submit_poker_action.",
                }
            )
            continue
        messages.append(
            {
                "role": "user",
                "content": "You must call submit_poker_action with your move.",
            }
        )

    return "fold", None


def resolve_model_env(pc: PlayerConfig, env: dict[str, str]) -> str:
    """Optional per-player model override: GPT_5_4_MODEL, etc."""
    key = f"{pc.player_id.upper()}_MODEL"
    return env.get(key) or pc.model
