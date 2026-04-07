from __future__ import annotations

"""
Default LLM player lineup — model IDs are env-overridable (see runner).

Player IDs use only [A-Za-z0-9_] for the poker API.
"""

# Server must define this table (see main.lua create_server_state).
DEFAULT_TABLE_ID = "llm_bots"

from dataclasses import dataclass
from typing import Literal

ProviderKind = Literal["openai", "anthropic", "openai_compat"]


@dataclass(frozen=True)
class PlayerConfig:
    player_id: str
    display_name: str
    provider: ProviderKind
    model: str
    env_api_key: str
    base_url: str | None = None
    base_url_env: str | None = None


# Desired lineup: GPT 5.4, Claude 4.6 Opus, Gemini 3.1, Meta Llama 4, DeepSeek V3.2,
# Mistral Large 3, Grok — API model strings are defaults; set *_MODEL env to override.
DEFAULT_PLAYERS: tuple[PlayerConfig, ...] = (
    PlayerConfig(
        player_id="gpt_5_4",
        display_name="GPT 5.4",
        provider="openai",
        model="gpt-5.4",
        env_api_key="OPENAI_API_KEY",
        base_url_env="OPENAI_BASE_URL",
    ),
    PlayerConfig(
        player_id="claude_4_6_opus",
        display_name="Claude 4.6 Opus",
        provider="anthropic",
        model="claude-4.6-opus",
        env_api_key="ANTHROPIC_API_KEY",
    ),
    PlayerConfig(
        player_id="gemini_3_1",
        display_name="Gemini 3.1",
        provider="openai_compat",
        model="gemini-3.1-pro",
        env_api_key="GOOGLE_API_KEY",
        base_url="https://generativelanguage.googleapis.com/v1beta/openai",
    ),
    PlayerConfig(
        player_id="llama_4",
        display_name="Meta Llama 4",
        provider="openai_compat",
        model="meta-llama/Llama-4",
        env_api_key="LLAMA_API_KEY",
        base_url_env="LLAMA_OPENAI_BASE_URL",
    ),
    PlayerConfig(
        player_id="deepseek_v3_2",
        display_name="DeepSeek V3.2",
        provider="openai_compat",
        model="deepseek-chat",
        env_api_key="DEEPSEEK_API_KEY",
        base_url="https://api.deepseek.com/v1",
    ),
    PlayerConfig(
        player_id="mistral_large_3",
        display_name="Mistral Large 3",
        provider="openai_compat",
        model="mistral-large-latest",
        env_api_key="MISTRAL_API_KEY",
        base_url="https://api.mistral.ai/v1",
    ),
    PlayerConfig(
        player_id="grok_ai",
        display_name="Grok AI",
        provider="openai_compat",
        model="grok-3",
        env_api_key="XAI_API_KEY",
        base_url="https://api.x.ai/v1",
    ),
)
