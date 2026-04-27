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

import atexit
import json
import signal
import sys
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
        self._joined_table_id: Optional[str] = None
        self._joined_player_id: Optional[str] = None
        self._disconnect_hooks_registered = False

    def _leave_if_joined(self) -> None:
        """Best-effort leave when the process exits (Ctrl+C, SIGTERM, atexit)."""
        tid = self._joined_table_id
        pid = self._joined_player_id
        if not tid or not pid:
            return
        try:
            self.leave_table(tid, player_id=pid)
        except Exception:
            self._joined_table_id = None
            self._joined_player_id = None
            self.token = None

    def _register_disconnect_hooks(self) -> None:
        if self._disconnect_hooks_registered:
            return
        self._disconnect_hooks_registered = True
        atexit.register(self._leave_if_joined)

        def _sig_handler(signum: int, frame: Any) -> None:
            self._leave_if_joined()
            sys.exit(128 + signum)

        try:
            signal.signal(signal.SIGINT, _sig_handler)
            signal.signal(signal.SIGTERM, _sig_handler)
        except (ValueError, OSError):
            pass

    def _path_table(self, table_id: str, suffix: str) -> str:
        tid = urllib.parse.quote(table_id, safe="")
        return f"/v1/tables/{tid}/{suffix}"

    def _path_table_state(self, table_id: str) -> str:
        return self._path_table(table_id, "state")

    def _request_json(
        self,
        method: str,
        path: str,
        json_body: Optional[Any] = None,
        *,
        timeout: Optional[float] = None,
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
        t = timeout if timeout is not None else self.timeout
        try:
            with urllib.request.urlopen(req, timeout=t) as resp:
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
        chips: Optional[int] = None,
        seat: Optional[int] = None,
    ) -> Any:
        """Take a seat. Body: player_id; optional seat. Stack is the table buy_in_chips."""
        body: dict[str, Any] = {"player_id": player_id}
        if chips is not None:
            body["chips"] = chips
        if seat is not None:
            body["seat"] = seat
        join_timeout = max(self.timeout, 150.0)
        resp = self._request_json(
            "POST",
            self._path_table(table_id, "join"),
            body,
            timeout=join_timeout,
        )
        if isinstance(resp, dict) and resp.get("token"):
            self.token = resp["token"]
        self._joined_table_id = table_id
        self._joined_player_id = player_id
        self._register_disconnect_hooks()
        return resp

    def leave_table(self, table_id: str, *, player_id: str) -> Any:
        """Leave the table (removes the player from their seat)."""
        resp = self._request_json(
            "POST",
            self._path_table(table_id, "leave"),
            {"player_id": player_id},
        )
        if self._joined_table_id == table_id and self._joined_player_id == player_id:
            self._joined_table_id = None
            self._joined_player_id = None
            self.token = None
        return resp

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
        client_action_id: Optional[str] = None,
        expected_action_seq: Optional[int] = None,
    ) -> Any:
        """
        Send a table action: fold, check, call, raise, bet, all_in.
        raise/bet require amount; all_in uses full stack.

        If *queue* is True, only store the action for when it is legal (no-op start
        while the hand is idle). If *queue* is False, wrong_turn is an error instead
        of auto-queuing. If *queue* is omitted, not-your-turn submits are queued.

        *client_action_id* is an optional string the server uses for **idempotency**:
        replaying the same id for this player returns the original response instead
        of applying (or queuing) the action again. Use it on retries after a network
        error so that a "fold" intended for hand N is never silently re-applied as
        a queued move on hand N+1. Cached entries expire after 60 s.

        *expected_action_seq* asserts that you are acting on a specific
        ``hand.action_seq`` you saw in a recent snapshot. If the server's current
        seq differs and the action would otherwise apply now, it is rejected with
        ``stale_action`` (HTTP 409); the error ``details`` include
        ``current_seq`` so you can refresh and retry. Ignored when the action
        would be queued.
        """
        body: dict[str, Any] = {"player_id": player_id, "action": action}
        if amount is not None:
            body["amount"] = amount
        if queue is not None:
            body["queue"] = queue
        if client_action_id is not None:
            body["client_action_id"] = client_action_id
        if expected_action_seq is not None:
            body["expected_action_seq"] = expected_action_seq
        return self._request_json(
            "POST", self._path_table(table_id, "actions"), body
        )

    def set_ready(
        self,
        table_id: str,
        *,
        player_id: str,
        ready: bool = True,
    ) -> Any:
        """
        Signal readiness/start confirmation for the first hand of the current
        table cohort on a table configured with ``wait_for_ready``. A cohort
        begins when players sit at a table that was previously empty. Pass
        ``ready=False`` to withdraw a previous signal.

        On tables that were created without ``wait_for_ready`` this call is
        accepted (the server tracks the flag) but the table deals normally
        regardless. After the cohort's first hand has been dealt, subsequent
        calls are accepted for consistency but do not affect dealing until
        the table becomes empty and the next cohort begins.

        Requires the ``X-Player-Token`` obtained from :meth:`join_table` and
        must match ``player_id``.
        """
        body = {"player_id": player_id, "ready": bool(ready)}
        return self._request_json(
            "POST", self._path_table(table_id, "ready"), body
        )

    def start_table(
        self,
        table_id: str,
        *,
        player_id: str,
        ready: bool = True,
    ) -> Any:
        """Alias for :meth:`set_ready` using the server's ``/start`` route."""
        body = {"player_id": player_id, "ready": bool(ready)}
        return self._request_json(
            "POST", self._path_table(table_id, "start"), body
        )

    def wait_for_hand(
        self,
        table_id: str,
        *,
        poll_interval: float = 0.5,
        timeout: Optional[float] = None,
    ) -> Any:
        """
        Block until the current table cohort's first hand has been dealt
        (``hand.status == "active"``). Useful for bots on ``wait_for_ready``
        tables that want to ``set_ready`` and then sit idle until cards are out.

        Returns the most recent table state snapshot. Raises
        :class:`TimeoutError` if *timeout* seconds elapse first.
        """
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            state = self.get_table_state(table_id)
            hand = state.get("hand") or {}
            if hand.get("status") == "active":
                return state
            if deadline is not None and time.monotonic() >= deadline:
                raise TimeoutError(
                    f"Timed out waiting for first hand of table {table_id!r}"
                )
            time.sleep(poll_interval)
