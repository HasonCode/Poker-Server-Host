"""LLM backends: OpenAI-compatible chat + tools, Anthropic messages + tools."""

from __future__ import annotations

import json
import ssl
import sys
import urllib.error
import urllib.request
from typing import Any, Callable

from .config import PlayerConfig
from . import poker_tools as pt
from . import prompts


def _post_json(
    url: str,
    headers: dict[str, str],
    body: dict[str, Any],
    timeout: float = 120.0,
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


def _normalize_base(url: str) -> str:
    return url.rstrip("/")


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

    for rnd in range(max_rounds):
        sys.stderr.write(
            f"[llm-step] decide round {rnd + 1}/{max_rounds} → POST chat/completions "
            f"(each call can take up to 120s on slow providers)…\n"
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
                raw_args = fn.get("arguments") or "{}"
                try:
                    args = json.loads(raw_args) if isinstance(raw_args, str) else {}
                except json.JSONDecodeError:
                    args = {}
                if not isinstance(args, dict):
                    args = {}
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
                raw_args = fn.get("arguments") or "{}"
                try:
                    args = json.loads(raw_args) if isinstance(raw_args, str) else {}
                except json.JSONDecodeError:
                    args = {}
                if not isinstance(args, dict):
                    args = {}
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

    for _ in range(max_rounds):
        body = {
            "model": model,
            "max_tokens": 4096,
            "system": prompts.ACTION_SYSTEM,
            "tools": tools,
            "messages": messages,
        }
        data = _post_json(url, headers, body)
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
