"""
HTTP client for the poker server JSON API.

Uses only the standard library (urllib). Typical usage::

    from poker_client import PokerClient, PokerError, TransportError

    c = PokerClient("http://127.0.0.1:8080")
    try:
        print(c.health())
        print(c.get_table_state("demo"))
    except PokerError as e:
        print(e.status_code, e.api_code, e.message)
    except TransportError as e:
        print("network/json:", e)
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Mapping, Optional


class PokerError(Exception):
    """
    The server responded with a non-success HTTP status and (usually) a JSON body::

        {"error": {"code": "...", "message": "...", "details": {...}}}
    """

    def __init__(
        self,
        status_code: int,
        *,
        api_code: Optional[str] = None,
        message: Optional[str] = None,
        details: Any = None,
        raw_body: Optional[str] = None,
    ) -> None:
        self.status_code = status_code
        self.api_code = api_code
        self.message = message
        self.details = details
        self.raw_body = raw_body
        parts = [f"HTTP {status_code}"]
        if api_code:
            parts.append(api_code)
        if message:
            parts.append(message)
        super().__init__(": ".join(parts))


class TransportError(Exception):
    """Connection failure, timeout, or response body is not valid JSON."""

    pass


def _normalize_base_url(url: str) -> str:
    """
    Accept common forms: http://127.0.0.1:8080, 127.0.0.1:8080, and fix typos
    like http:/host (single slash) which otherwise yield "no host given".
    """
    url = url.strip()
    if not url:
        raise ValueError("base_url must not be empty")
    # Fix before bare-host logic: http:/localhost is not http:// and has no ://
    if url.startswith("http:/") and not url.startswith("http://"):
        url = "http://" + url[6:].lstrip("/")
    elif url.startswith("https:/") and not url.startswith("https://"):
        url = "https://" + url[7:].lstrip("/")
    if "://" not in url:
        url = "http://" + url
    parsed = urllib.parse.urlparse(url)
    if not parsed.scheme or not parsed.netloc:
        raise ValueError(
            "Invalid base_url — need a host, e.g. http://127.0.0.1:8080 "
            f"(got {url!r})"
        )
    return url.rstrip("/")


def _decode_json_bytes(body: bytes) -> Any:
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError as e:
        raise TransportError(f"Response is not valid UTF-8: {e}") from e
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        raise TransportError(f"Response is not valid JSON: {e}") from e


class PokerClient:
    def __init__(self, base_url: str, *, timeout: float = 30.0) -> None:
        self.base_url = _normalize_base_url(base_url)
        self.timeout = timeout
        self.token: Optional[str] = None

    def _path_table(self, table_id: str, suffix: str) -> str:
        tid = urllib.parse.quote(table_id, safe="")
        return f"/v1/tables/{tid}/{suffix}"

    def _path_table_state(self, table_id: str) -> str:
        return self._path_table(table_id, "state")

    def _request_json(
        self, method: str, path: str, json_body: Optional[Any] = None
    ) -> Any:
        url = self.base_url + path
        data: Optional[bytes] = None
        headers = {"Accept": "application/json"}
        if self.token:
            headers["X-Player-Token"] = self.token
        if json_body is not None:
            data = json.dumps(json_body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(
            url,
            method=method,
            data=data,
            headers=headers,
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                body = resp.read()
        except urllib.error.HTTPError as e:
            raw = e.read()
            self._raise_http_error(e.code, raw)
        except urllib.error.URLError as e:
            raise TransportError(f"Request failed: {e.reason}") from e
        except TimeoutError as e:
            raise TransportError("Request timed out") from e

        return _decode_json_bytes(body)

    def _raise_http_error(self, status_code: int, body: bytes) -> None:
        raw_text = body.decode("utf-8", errors="replace")
        try:
            data = json.loads(raw_text)
        except json.JSONDecodeError:
            raise PokerError(
                status_code,
                message=raw_text or "(empty body)",
                raw_body=raw_text,
            ) from None

        err = data.get("error") if isinstance(data, Mapping) else None
        if isinstance(err, Mapping):
            raise PokerError(
                status_code,
                api_code=err.get("code") if isinstance(err.get("code"), str) else None,
                message=err.get("message") if isinstance(err.get("message"), str) else str(err),
                details=err.get("details"),
                raw_body=raw_text,
            ) from None

        raise PokerError(status_code, message=raw_text, raw_body=raw_text) from None

    def health(self) -> Any:
        return self._request_json("GET", "/health")

    def get_table_state(self, table_id: str) -> Any:
        return self._request_json("GET", self._path_table_state(table_id))

    def join_table(
        self,
        table_id: str,
        *,
        player_id: str,
        chips: int,
        seat: Optional[int] = None,
    ) -> Any:
        """Take a seat. Body: player_id, chips; optional seat (first free seat if omitted)."""
        body: dict[str, Any] = {"player_id": player_id, "chips": chips}
        if seat is not None:
            body["seat"] = seat
        resp = self._request_json(
            "POST",
            self._path_table(table_id, "join"),
            body,
        )
        if isinstance(resp, dict) and resp.get("token"):
            self.token = resp["token"]
        return resp

    def leave_table(self, table_id: str, *, player_id: str) -> Any:
        """Leave the table (removes the player from their seat)."""
        return self._request_json(
            "POST",
            self._path_table(table_id, "leave"),
            {"player_id": player_id},
        )

    def is_my_turn(self, table_id: str, player_id: str) -> bool:
        """Return True if it is currently *player_id*'s turn to act."""
        state = self.get_table_state(table_id)
        hand = state.get("hand") or {}
        if hand.get("status") != "active":
            return False
        ats = hand.get("action_to_seat")
        if ats is None:
            return False
        seats = state.get("seats") or []
        if not isinstance(ats, int) or ats < 1 or ats > len(seats):
            return False
        seat_info = seats[ats - 1]
        if not isinstance(seat_info, dict):
            return False
        return seat_info.get("player_id") == player_id

    def wait_for_turn(
        self,
        table_id: str,
        player_id: str,
        *,
        poll_interval: float = 0.5,
        timeout: Optional[float] = None,
    ) -> Any:
        """
        Block until it is *player_id*'s turn, then return the table state.

        Polls ``GET .../state`` every *poll_interval* seconds.
        If *timeout* is set and exceeded, raises ``TimeoutError``.
        """
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            state = self.get_table_state(table_id)
            hand = state.get("hand") or {}
            if hand.get("status") == "active":
                ats = hand.get("action_to_seat")
                seats = state.get("seats") or []
                if (
                    isinstance(ats, int)
                    and 1 <= ats <= len(seats)
                    and isinstance(seats[ats - 1], dict)
                    and seats[ats - 1].get("player_id") == player_id
                ):
                    return state
            if deadline is not None and time.monotonic() >= deadline:
                raise TimeoutError(
                    f"Timed out waiting for {player_id}'s turn after {timeout}s"
                )
            time.sleep(poll_interval)

    def send_action(
        self,
        table_id: str,
        *,
        player_id: str,
        action: str,
        amount: Optional[int] = None,
        queue: Optional[bool] = None,
    ) -> Any:
        """
        Send a table action: fold, check, call, raise, bet, all_in.
        raise/bet require amount; all_in uses full stack.

        If queue is True, only store the action for when it is legal (no-op start
        while the hand is idle). If queue is False, wrong_turn is an error instead
        of auto-queuing. If queue is omitted, not-your-turn submits are queued.
        """
        body: dict[str, Any] = {"player_id": player_id, "action": action}
        if amount is not None:
            body["amount"] = amount
        if queue is not None:
            body["queue"] = queue
        return self._request_json(
            "POST", self._path_table(table_id, "actions"), body
        )
