(function () {
  "use strict";

  const $ = (sel, el) => (el || document).querySelector(sel);

  const barStatus = $("#barStatus");
  const loginGate = $("#loginGate");
  const loginGateErr = $("#loginGateErr");
  const spectateMain = $("#spectateMain");
  const tableSelect = $("#tableSelect");
  const spectateRefreshBtn = $("#spectateRefreshBtn");
  const endpointEl = $("#endpointEl");

  const statusPill = $("#statusPill");
  const streetVal = $("#streetVal");
  const potVal = $("#potVal");
  const betVal = $("#betVal");
  const minRaiseVal = $("#minRaiseVal");
  const communityEl = $("#community");
  const feltWrap = $("#feltWrap");
  const feltPotVal = $("#feltPotVal");
  const actionLog = $("#actionLog");

  const POLL_MS = 1500;
  let pollTimer = null;

  const urlParams = new URLSearchParams(location.search);
  const initialTable = (urlParams.get("table") || "").trim();

  function esc(s) {
    const d = document.createElement("div");
    d.textContent = s;
    return d.innerHTML;
  }

  async function apiFetch(method, path, body) {
    const opts = {
      method,
      headers: { Accept: "application/json" },
      credentials: "same-origin",
    };
    if (body !== undefined) {
      opts.headers["Content-Type"] = "application/json";
      opts.body = JSON.stringify(body);
    }
    const res = await fetch(path, opts);
    const text = await res.text();
    let data;
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      data = null;
    }
    if (res.status === 401) {
      const err = new Error("Not logged in");
      err.httpStatus = 401;
      throw err;
    }
    if (!res.ok) {
      const msg =
        (data && data.error && (data.error.message || data.error.code)) ||
        res.statusText ||
        "Request failed";
      const err = new Error(msg);
      err.httpStatus = res.status;
      throw err;
    }
    return data;
  }

  function parseCard(str) {
    if (!str || str === "?") return null;
    const suit = str.slice(-1);
    const rank = str.slice(0, -1);
    return { rank, suit };
  }

  function isRed(suit) {
    return suit === "♥" || suit === "♦";
  }

  function makeCardEl(str, extraCls) {
    const el = document.createElement("span");
    const parsed = parseCard(str);
    if (!parsed) {
      el.className = "card placeholder" + (extraCls ? " " + extraCls : "");
      el.textContent = "?";
      return el;
    }
    el.className =
      "card" +
      (isRed(parsed.suit) ? " red" : "") +
      (extraCls ? " " + extraCls : "");
    const r = document.createElement("span");
    r.className = "card-rank";
    r.textContent = parsed.rank;
    const s = document.createElement("span");
    s.className = "card-suit";
    s.textContent = parsed.suit;
    el.appendChild(r);
    el.appendChild(s);
    return el;
  }

  function makeFacedownEl(extraCls) {
    const el = document.createElement("span");
    el.className = "card facedown" + (extraCls ? " " + extraCls : "");
    el.textContent = "🂠";
    return el;
  }

  function getContrib(hand, seat) {
    const c = hand.contribution || {};
    if (typeof c === "object" && !Array.isArray(c)) return c[String(seat)] || 0;
    return 0;
  }

  const BET_POS = {
    1: { x: 41, y: 72 },
    2: { x: 27, y: 65 },
    3: { x: 20, y: 46 },
    4: { x: 26, y: 25 },
    5: { x: 39, y: 20 },
    6: { x: 52, y: 20 },
    7: { x: 70, y: 25 },
    8: { x: 77, y: 46 },
    9: { x: 70, y: 65 },
    10: { x: 55, y: 72 },
  };

  function renderSeats(data) {
    const max = data.max_seats || 10;
    const seats = data.seats || [];
    const hand = data.hand || {};
    const holeCards = hand.hole_cards || {};
    const folded = hand.folded || {};

    feltWrap.querySelectorAll(".felt-bet").forEach((el) => el.remove());

    for (let i = 1; i <= 10; i++) {
      const el = feltWrap.querySelector('.felt-seat[data-seat="' + i + '"]');
      if (!el) continue;

      if (i > max) {
        el.classList.add("hidden");
        continue;
      }
      el.classList.remove("hidden");

      const s = seats[i - 1];
      const isFolded = typeof folded === "object" && !Array.isArray(folded) && folded[String(i)];

      const base = "felt-seat";
      el.className =
        base +
        (s && s.player_id ? " occupied" : "") +
        (hand.action_to_seat === i ? " acting" : "") +
        " spectate-ghost" +
        (isFolded ? " folded" : "");
      el.dataset.seat = i;
      el.replaceChildren();

      if (s && s.player_id) {
        const name = document.createElement("div");
        name.className = "fs-name";
        name.textContent = s.player_id;
        el.appendChild(name);

        const stack = document.createElement("div");
        stack.className = "fs-stack";
        stack.textContent = s.stack;
        el.appendChild(stack);

        const tags = [];
        if (hand.button_seat === i) tags.push("D");
        if (hand.sb_seat === i) tags.push("SB");
        if (hand.bb_seat === i) tags.push("BB");
        if (isFolded) tags.push("FOLD");
        if (tags.length) {
          const t = document.createElement("div");
          t.className = "fs-tags";
          t.textContent = tags.join(" · ");
          el.appendChild(t);
        }

        const cardsDiv = document.createElement("div");
        cardsDiv.className = "fs-cards";
        const cards =
          typeof holeCards === "object" && !Array.isArray(holeCards) ? holeCards[String(i)] : null;
        if (cards && cards.length) {
          cards.forEach((c) => cardsDiv.appendChild(makeCardEl(c, "xs")));
        } else if (hand.status === "active" && !isFolded) {
          cardsDiv.appendChild(makeFacedownEl("xs"));
          cardsDiv.appendChild(makeFacedownEl("xs"));
        }
        if (cardsDiv.children.length) el.appendChild(cardsDiv);

        const contrib = getContrib(hand, i);
        if (contrib > 0 && BET_POS[i]) {
          const bp = BET_POS[i];
          const bet = document.createElement("div");
          bet.className = "felt-bet";
          bet.style.left = bp.x + "%";
          bet.style.top = bp.y + "%";
          bet.textContent = contrib;
          feltWrap.appendChild(bet);
        }
      } else {
        const empty = document.createElement("div");
        empty.className = "fs-name fs-empty";
        empty.textContent = "Seat " + i;
        el.appendChild(empty);
      }
    }
  }

  function renderLog(hand) {
    actionLog.replaceChildren();
    const log = hand.action_log || [];
    if (log.length === 0) {
      const li = document.createElement("li");
      li.textContent = "No actions yet.";
      actionLog.appendChild(li);
      return;
    }
    log.forEach((entry) => {
      const li = document.createElement("li");
      const amt = entry.amount != null ? " " + entry.amount : "";
      li.innerHTML =
        "<b>" +
        esc(entry.player_id) +
        "</b> " +
        esc(entry.action) +
        amt +
        " <span style='color:var(--muted);font-size:0.75rem'>[" +
        esc(entry.street) +
        "]</span>";
      actionLog.appendChild(li);
    });
    actionLog.scrollTop = actionLog.scrollHeight;
  }

  function renderAll(data) {
    const hand = data.hand || {};

    statusPill.textContent = hand.status || "idle";
    statusPill.className = "pill " + (hand.status === "active" ? "active" : "idle");
    streetVal.textContent = hand.street || "—";
    potVal.textContent = hand.pot != null ? hand.pot : 0;
    feltPotVal.textContent = hand.pot != null ? hand.pot : 0;
    betVal.textContent = hand.current_bet != null ? hand.current_bet : 0;
    minRaiseVal.textContent = hand.min_raise_increment != null ? hand.min_raise_increment : "—";

    communityEl.replaceChildren();
    let comm = hand.community || [];
    if (comm.length === 0 && hand.status !== "active") {
      const lc = hand.last_community || [];
      if (lc.length > 0 && hand.last_winners && hand.last_winners.length > 0) {
        comm = lc;
      }
    }
    if (comm.length === 0 && hand.status === "active") {
      for (let i = 0; i < 5; i++) communityEl.appendChild(makeFacedownEl());
    } else if (comm.length === 0) {
      for (let i = 0; i < 5; i++) {
        const ph = document.createElement("span");
        ph.className = "card placeholder";
        ph.textContent = "";
        communityEl.appendChild(ph);
      }
    } else {
      comm.forEach((c) => communityEl.appendChild(makeCardEl(String(c))));
      for (let i = comm.length; i < 5; i++) communityEl.appendChild(makeFacedownEl());
    }

    renderSeats(data);

    const winnersEl = $("#winners");
    const lw = hand.last_winners;
    if (lw && Array.isArray(lw) && lw.length > 0) {
      winnersEl.classList.remove("hidden");
      winnersEl.replaceChildren();
      lw.forEach((w) => {
        const div = document.createElement("div");
        div.className = "winner-entry";
        const hname = w.hand_name && w.hand_name !== "fold" ? " (" + esc(w.hand_name) + ")" : "";
        div.innerHTML =
          "&#127942; <b>" + esc(w.player_id) + "</b> won <b>" + w.amount + "</b> chips" + hname;
        winnersEl.appendChild(div);
      });
    } else {
      winnersEl.classList.add("hidden");
    }

    renderLog(hand);

    const tid = tableSelect.value || data.table_id || "";
    barStatus.textContent = "Live — " + (tid ? "table " + tid : "select a table");
    barStatus.className = "sub";
    endpointEl.textContent = tid ? "/admin/api/tables/" + encodeURIComponent(tid) + "/snapshot" : "—";
  }

  function currentTableId() {
    return (tableSelect.value || "").trim();
  }

  function stopPoll() {
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
  }

  function startPoll() {
    stopPoll();
    const tick = () => {
      const tid = currentTableId();
      if (!tid) {
        barStatus.textContent = "Select a table to spectate.";
        endpointEl.textContent = "—";
        return;
      }
      loadSnapshot(tid);
    };
    tick();
    pollTimer = setInterval(tick, POLL_MS);
  }

  async function loadSnapshot(tid) {
    try {
      const res = await apiFetch("GET", "/admin/api/tables/" + encodeURIComponent(tid) + "/snapshot");
      if (!res || !res.table) {
        throw new Error("Invalid snapshot response");
      }
      renderAll(res.table);
    } catch (e) {
      if (e.httpStatus === 401) {
        showLoginGate(e.message);
        return;
      }
      barStatus.textContent = "Error: " + e.message;
      barStatus.className = "sub spectate-error";
    }
  }

  async function manualRefresh() {
    const btn = spectateRefreshBtn;
    if (btn) btn.disabled = true;
    barStatus.textContent = "Refreshing…";
    barStatus.className = "sub";
    try {
      await loadTables();
      updateUrlTable();
      const tid = currentTableId();
      if (tid) {
        await loadSnapshot(tid);
      } else {
        barStatus.textContent = "Table list updated. Select a table.";
        endpointEl.textContent = "—";
      }
    } catch (e) {
      if (e.httpStatus === 401) {
        showLoginGate("");
        return;
      }
      barStatus.textContent = "Error: " + e.message;
      barStatus.className = "sub spectate-error";
    } finally {
      if (btn) btn.disabled = false;
    }
  }

  async function loadTables() {
    const res = await apiFetch("GET", "/admin/api/tables");
    const list = (res && res.tables) || [];
    list.sort((a, b) => String(a.table_id).localeCompare(String(b.table_id)));

    const prev = tableSelect.value;
    tableSelect.innerHTML = "";
    const opt0 = document.createElement("option");
    opt0.value = "";
    opt0.textContent = "— Select a table —";
    tableSelect.appendChild(opt0);

    list.forEach((t) => {
      const o = document.createElement("option");
      o.value = t.table_id;
      const label =
        t.table_id +
        " · " +
        (t.seated || 0) +
        "/" +
        (t.max_seats || "?") +
        " · " +
        (t.hand_status || "?");
      o.textContent = label;
      tableSelect.appendChild(o);
    });

    if (prev && [...tableSelect.options].some((o) => o.value === prev)) {
      tableSelect.value = prev;
    } else if (initialTable && [...tableSelect.options].some((o) => o.value === initialTable)) {
      tableSelect.value = initialTable;
    } else if (list.length === 1) {
      tableSelect.value = list[0].table_id;
    }
  }

  function updateUrlTable() {
    const tid = currentTableId();
    const u = new URL(location.href);
    if (tid) u.searchParams.set("table", tid);
    else u.searchParams.delete("table");
    const qs = u.searchParams.toString();
    history.replaceState({}, "", u.pathname + (qs ? "?" + qs : "") + location.hash);
  }

  function showLoginGate(msg) {
    stopPoll();
    loginGate.classList.remove("hidden");
    spectateMain.classList.add("hidden");
    if (loginGateErr) loginGateErr.textContent = msg || "";
    barStatus.textContent = "Not signed in";
  }

  function showMain() {
    loginGate.classList.add("hidden");
    spectateMain.classList.remove("hidden");
    if (loginGateErr) loginGateErr.textContent = "";
  }

  async function init() {
    barStatus.textContent = "Checking session…";
    try {
      await apiFetch("GET", "/admin/api/session");
    } catch (e) {
      showLoginGate("");
      barStatus.textContent = "Sign in required";
      return;
    }

    showMain();
    barStatus.textContent = "Loading tables…";

    try {
      await loadTables();
    } catch (e) {
      barStatus.textContent = "Error: " + e.message;
      return;
    }

    barStatus.textContent = "Select a table or wait for live updates.";
    updateUrlTable();
    startPoll();

    tableSelect.addEventListener("change", () => {
      updateUrlTable();
      startPoll();
    });

    if (spectateRefreshBtn) {
      spectateRefreshBtn.addEventListener("click", () => {
        manualRefresh();
      });
    }
  }

  init();
})();
