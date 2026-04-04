(function () {
  "use strict";

  /* ── DOM refs ─────────────────────────────────────── */

  const $ = (sel, el) => (el || document).querySelector(sel);
  const $$ = (sel, el) => [...(el || document).querySelectorAll(sel)];

  const tableIdInput   = $("#tableId");
  const refreshBtn     = $("#refresh");
  const connState      = $("#connState");
  const endpointEl     = $("#endpoint");

  const joinPanel      = $("#joinPanel");
  const joinForm       = $("#joinForm");
  const joinName       = $("#joinName");
  const joinChips      = $("#joinChips");
  const joinErr        = $("#joinErr");
  const joinSubmit     = $("#joinSubmit");
  const joinWaitModal  = $("#joinWaitModal");
  const joinWaitCancel = $("#joinWaitCancel");

  const gameArea       = $("#gameArea");
  const yourNameEl     = $("#yourName");
  const yourMetaEl     = $("#yourMeta");
  const yourCardsEl    = $("#yourCards");
  const leaveBtn       = $("#leaveBtn");

  const statusPill     = $("#statusPill");
  const streetVal      = $("#streetVal");
  const potVal         = $("#potVal");
  const betVal         = $("#betVal");
  const minRaiseVal    = $("#minRaiseVal");
  const communityEl    = $("#community");
  const feltWrap       = $("#feltWrap");
  const feltPotVal     = $("#feltPotVal");

  const actionPanel    = $("#actionPanel");
  const turnBadge      = $("#turnBadge");
  const actionBtns     = $("#actionBtns");
  const raiseAmtInput  = $("#raiseAmt");
  const actErr         = $("#actErr");

  const botNameInput   = $("#botName");
  const botChipsInput  = $("#botChips");
  const botFileInput   = $("#botFile");
  const botUploadStart = $("#botUploadStart");
  const botUploadStop  = $("#botUploadStop");
  const botStatusEl    = $("#botStatus");
  const botRunningList = $("#botRunningList");

  const actionLog      = $("#actionLog");

  /* ── state ────────────────────────────────────────── */

  let playerId = null;
  let playerToken = null;
  let mySeat   = null;
  let lastData = null;
  let pollTimer = null;
  let activeBotName = null;

  const urlParams = new URLSearchParams(location.search);
  if (urlParams.get("table")) tableIdInput.value = urlParams.get("table");
  if (urlParams.get("name"))  joinName.value = urlParams.get("name");

  const spectateMode = (function () {
    const v = urlParams.get("spectate");
    return v === "1" || v === "true";
  })();

  const botPanel = $(".bot-panel");

  /* ── helpers ──────────────────────────────────────── */

  function tableId() { return (tableIdInput.value || "demo").trim() || "demo"; }

  function apiBase(tid) {
    return "/v1/tables/" + encodeURIComponent(tid || tableId());
  }

  async function apiFetch(method, path, body, signal) {
    const opts = { method, headers: { "Accept": "application/json" } };
    if (spectateMode) {
      opts.credentials = "include";
    }
    if (signal) {
      opts.signal = signal;
    }
    if (playerToken) {
      opts.headers["X-Player-Token"] = playerToken;
    }
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
      data = undefined;
    }
    if (!res.ok) {
      const msg =
        (data && data.error && (data.error.message || data.error.code)) ||
        (data === undefined && text && text.length ? text.trim().slice(0, 400) : "") ||
        res.statusText ||
        "Request failed";
      const err = new Error(msg || res.statusText);
      err.apiCode = data && data.error ? data.error.code : undefined;
      err.httpStatus = res.status;
      throw err;
    }
    if (data === undefined) {
      throw new Error("Invalid JSON from server");
    }
    return data;
  }

  let joinAbortController = null;

  function showJoinWaitModal() {
    if (!joinWaitModal) return;
    joinWaitModal.classList.remove("hidden");
    document.body.classList.add("join-modal-open");
    if (joinWaitCancel) joinWaitCancel.focus();
  }

  function hideJoinWaitModal() {
    if (!joinWaitModal) return;
    joinWaitModal.classList.add("hidden");
    document.body.classList.remove("join-modal-open");
  }

  /* ── card rendering ───────────────────────────────── */

  function parseCard(str) {
    if (!str || str === "?") return null;
    const suit = str.slice(-1);
    const rank = str.slice(0, -1);
    return { rank, suit };
  }

  function isRed(suit) { return suit === "♥" || suit === "♦"; }

  function makeCardEl(str, extraCls) {
    const el = document.createElement("span");
    const parsed = parseCard(str);
    if (!parsed) {
      el.className = "card placeholder" + (extraCls ? " " + extraCls : "");
      el.textContent = "?";
      return el;
    }
    el.className = "card" + (isRed(parsed.suit) ? " red" : "") + (extraCls ? " " + extraCls : "");
    const r = document.createElement("span");
    r.className = "card-rank"; r.textContent = parsed.rank;
    const s = document.createElement("span");
    s.className = "card-suit"; s.textContent = parsed.suit;
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

  /* ── rendering ────────────────────────────────────── */

  function findMySeat(data) {
    if (!playerId) return null;
    const seats = data.seats || [];
    for (let i = 0; i < seats.length; i++) {
      if (seats[i] && seats[i].player_id === playerId) return i + 1;
    }
    return null;
  }

  function isMyTurn(data) {
    if (!playerId || !mySeat) return false;
    const hand = data.hand || {};
    return hand.status === "active" && hand.action_to_seat === mySeat;
  }

  function renderAll(data) {
    lastData = data;
    mySeat = findMySeat(data);
    const hand = data.hand || {};

    if (spectateMode) {
      joinPanel.classList.add("hidden");
      gameArea.classList.remove("hidden");
      yourNameEl.textContent = "Spectator";
      yourMetaEl.textContent = "Admin view — all hole cards visible";
      yourCardsEl.replaceChildren();
      const ph = document.createElement("p");
      ph.className = "sub spectate-ghost-note";
      ph.textContent = "Not seated. Hole cards are shown at each seat.";
      yourCardsEl.appendChild(ph);
    } else if (playerId && mySeat) {
      joinPanel.classList.add("hidden");
      gameArea.classList.remove("hidden");
    }

    /* your info */
    if (!spectateMode && playerId && mySeat) {
      const seatInfo = data.seats[mySeat - 1];
      yourNameEl.textContent = playerId;
      const tags = [];
      if (hand.button_seat === mySeat) tags.push("BTN");
      if (hand.sb_seat === mySeat)     tags.push("SB");
      if (hand.bb_seat === mySeat)     tags.push("BB");
      yourMetaEl.textContent = "Seat " + mySeat + " · " + (seatInfo ? seatInfo.stack : "?") + " chips"
        + (tags.length ? " · " + tags.join(" ") : "");

      yourCardsEl.replaceChildren();
      const hc = hand.hole_cards || {};
      const myCards = typeof hc === "object" && !Array.isArray(hc) ? hc[String(mySeat)] : null;
      if (myCards && myCards.length) {
        myCards.forEach(c => yourCardsEl.appendChild(makeCardEl(c)));
      } else if (hand.status === "active") {
        yourCardsEl.appendChild(makeFacedownEl());
        yourCardsEl.appendChild(makeFacedownEl());
      } else {
        const ph = document.createElement("span");
        ph.className = "sub"; ph.textContent = "Waiting for next hand…";
        yourCardsEl.appendChild(ph);
      }
    }

    /* hand bar */
    statusPill.textContent = hand.status || "idle";
    statusPill.className = "pill " + (hand.status === "active" ? "active" : "idle");
    streetVal.textContent = hand.street || "—";
    potVal.textContent = hand.pot != null ? hand.pot : 0;
    feltPotVal.textContent = hand.pot != null ? hand.pot : 0;
    betVal.textContent = hand.current_bet != null ? hand.current_bet : 0;
    minRaiseVal.textContent = hand.min_raise_increment != null ? hand.min_raise_increment : "—";

    /* community — show last_community when hand is idle with recent winners */
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
      /* idle with no recent hand — show empty slots */
      for (let i = 0; i < 5; i++) {
        const ph = document.createElement("span");
        ph.className = "card placeholder";
        ph.textContent = "";
        communityEl.appendChild(ph);
      }
    } else {
      comm.forEach(c => communityEl.appendChild(makeCardEl(String(c))));
      for (let i = comm.length; i < 5; i++) communityEl.appendChild(makeFacedownEl());
    }

    /* seats */
    renderSeats(data);

    /* winners */
    const winnersEl = $("#winners");
    const lw = hand.last_winners;
    if (lw && Array.isArray(lw) && lw.length > 0) {
      winnersEl.classList.remove("hidden");
      winnersEl.replaceChildren();
      lw.forEach(w => {
        const div = document.createElement("div");
        div.className = "winner-entry";
        const hname = w.hand_name && w.hand_name !== "fold" ? " (" + esc(w.hand_name) + ")" : "";
        div.innerHTML = "&#127942; <b>" + esc(w.player_id) + "</b> won <b>" + w.amount + "</b> chips" + hname;
        winnersEl.appendChild(div);
      });
    } else {
      winnersEl.classList.add("hidden");
    }

    /* action panel */
    const myTurn = !spectateMode && isMyTurn(data);
    turnBadge.classList.toggle("hidden", !myTurn);
    $$("#actionBtns .btn").forEach(b => b.disabled = !myTurn);
    if (myTurn) {
      const cb = hand.current_bet || 0;
      const mri = hand.min_raise_increment || 0;
      const myContrib = getContrib(hand, mySeat);
      const suggestRaise = Math.max(cb + mri, myContrib + mri);
      raiseAmtInput.value = suggestRaise;
    }

    /* log */
    renderLog(hand);

    /* connection */
    connState.textContent = spectateMode ? "Spectating (admin)" : "Connected";
    connState.className = "sub";
    endpointEl.textContent = spectateMode ? apiBase() + "/state?spectate=1" : apiBase() + "/state";
  }

  function getContrib(hand, seat) {
    const c = hand.contribution || {};
    if (typeof c === "object" && !Array.isArray(c)) return c[String(seat)] || 0;
    return 0;
  }

  const BET_POS = {
    1:  { x: 41, y: 72 },
    2:  { x: 27, y: 65 },
    3:  { x: 20, y: 46 },
    4:  { x: 26, y: 25 },
    5:  { x: 39, y: 20 },
    6:  { x: 52, y: 20 },
    7:  { x: 70, y: 25 },
    8:  { x: 77, y: 46 },
    9:  { x: 70, y: 65 },
    10: { x: 55, y: 72 },
  };

  function renderSeats(data) {
    const max = data.max_seats || 10;
    const seats = data.seats || [];
    const hand = data.hand || {};
    const holeCards = hand.hole_cards || {};
    const folded = hand.folded || {};

    feltWrap.querySelectorAll(".felt-bet").forEach(el => el.remove());

    for (let i = 1; i <= 10; i++) {
      const el = feltWrap.querySelector('.felt-seat[data-seat="' + i + '"]');
      if (!el) continue;

      if (i > max) { el.classList.add("hidden"); continue; }
      el.classList.remove("hidden");

      const s = seats[i - 1];
      const isFolded = typeof folded === "object" && !Array.isArray(folded) && folded[String(i)];

      const base = "felt-seat";
      el.className = base
        + (s && s.player_id ? " occupied" : "")
        + (hand.action_to_seat === i ? " acting" : "")
        + (i === mySeat ? " you" : "")
        + (spectateMode ? " spectate-ghost" : "")
        + (isFolded ? " folded" : "");
      el.dataset.seat = i;

      el.replaceChildren();

      if (s && s.player_id) {
        const name = document.createElement("div");
        name.className = "fs-name";
        name.textContent = s.player_id + (i === mySeat ? " (you)" : "");
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
        const cards = typeof holeCards === "object" && !Array.isArray(holeCards) ? holeCards[String(i)] : null;
        if (cards && cards.length) {
          cards.forEach(c => cardsDiv.appendChild(makeCardEl(c, "xs")));
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
    log.forEach(entry => {
      const li = document.createElement("li");
      const amt = entry.amount != null ? " " + entry.amount : "";
      li.innerHTML = "<b>" + esc(entry.player_id) + "</b> " +
        esc(entry.action) + amt +
        " <span style='color:var(--muted);font-size:0.75rem'>[" + esc(entry.street) + "]</span>";
      actionLog.appendChild(li);
    });
    actionLog.scrollTop = actionLog.scrollHeight;
  }

  function esc(s) {
    const d = document.createElement("div");
    d.textContent = s;
    return d.innerHTML;
  }

  /* ── polling ──────────────────────────────────────── */

  async function poll() {
    try {
      const path = spectateMode ? apiBase() + "/state?spectate=1" : apiBase() + "/state";
      const data = await apiFetch("GET", path);
      renderAll(data);
    } catch (e) {
      let msg = e.message;
      if (spectateMode && (e.apiCode === "unauthorized" || e.httpStatus === 401 || e.httpStatus === 403 || e.httpStatus === 503)) {
        msg = "Admin login required — open /admin in this browser, sign in, then reload this page.";
      }
      connState.textContent = "Error: " + msg;
      connState.className = "sub spectate-error";
    }
  }

  function startPoll() {
    stopPoll();
    poll();
    pollTimer = setInterval(poll, 1500);
  }

  function stopPoll() {
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
  }

  function showJoinPanel() {
    joinPanel.classList.remove("hidden");
    gameArea.classList.add("hidden");
    joinPanel.scrollIntoView({ behavior: "smooth", block: "start" });
    if (joinName) {
      joinName.focus();
      joinName.select();
    }
  }

  function resetClientState() {
    playerId = null;
    playerToken = null;
    mySeat = null;
    lastData = null;
    activeBotName = null;
    botUploadStart.disabled = false;
    botUploadStop.disabled = true;
    botStatusEl.textContent = "";
    actErr.textContent = "";
    if (joinErr) joinErr.textContent = "";
    connState.textContent = "Not seated";
    connState.className = "sub";
    showJoinPanel();
  }

  /** POST /leave with keepalive (no await); for tab close / refresh. */
  function sendDisconnectLeave() {
    const pid = playerId;
    const tok = playerToken;
    const tid = tableId();
    if (!pid || !tok) return;
    const path = apiBase(tid) + "/leave";
    const url = location.origin + path;
    const body = JSON.stringify({ player_id: pid });
    try {
      fetch(url, {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-Player-Token": tok,
        },
        body,
        keepalive: true,
      }).catch(function () {});
    } catch (_) { /* ignore */ }
  }

  async function leaveTable() {
    if (!playerId) return;
    try {
      await apiFetch("POST", apiBase() + "/leave", { player_id: playerId });
    } catch {
      /* still clear UI */
    }
    stopPoll();
    resetClientState();
    poll().catch(function () {});
  }

  /* ── join / leave ─────────────────────────────────── */

  joinForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    joinErr.textContent = "";
    const name = joinName.value.trim();
    const chips = parseInt(joinChips.value, 10);
    if (!name) { joinErr.textContent = "Name is required."; return; }
    if (!chips || chips < 1) { joinErr.textContent = "Chips must be at least 1."; return; }
    if (joinAbortController) {
      joinAbortController.abort();
    }
    joinAbortController = new AbortController();
    const ac = joinAbortController;
    if (joinSubmit) joinSubmit.disabled = true;
    showJoinWaitModal();
    try {
      const data = await apiFetch("POST", apiBase() + "/join", { player_id: name, chips }, ac.signal);
      playerId = name;
      playerToken = data.token || null;
      renderAll(data.table || {});
      startPoll();
    } catch (err) {
      const aborted = err.name === "AbortError" || err.code === 20;
      if (aborted) {
        joinErr.textContent = "Join cancelled.";
      } else {
        joinErr.textContent = err.message;
      }
    } finally {
      hideJoinWaitModal();
      if (joinSubmit) joinSubmit.disabled = false;
      if (joinAbortController === ac) {
        joinAbortController = null;
      }
    }
  });

  if (joinWaitCancel) {
    joinWaitCancel.addEventListener("click", () => {
      if (joinAbortController) {
        joinAbortController.abort();
      }
    });
  }

  if (joinWaitModal) {
    joinWaitModal.addEventListener("click", (ev) => {
      if (ev.target === joinWaitModal && joinAbortController) {
        joinAbortController.abort();
      }
    });
  }

  document.addEventListener("keydown", (ev) => {
    if (ev.key !== "Escape") return;
    if (!joinWaitModal || joinWaitModal.classList.contains("hidden")) return;
    if (joinAbortController) {
      joinAbortController.abort();
    }
  });

  leaveBtn.addEventListener("click", function () {
    leaveTable();
  });

  /* Tab close / navigate away: eject seat (keepalive so request may finish). */
  window.addEventListener("pagehide", function (ev) {
    if (ev.persisted) return;
    sendDisconnectLeave();
  });

  /* ── actions ──────────────────────────────────────── */

  actionBtns.addEventListener("click", async (e) => {
    const btn = e.target.closest("[data-act]");
    if (!btn || btn.disabled) return;
    await sendAction(btn.dataset.act);
  });

  async function sendAction(action, amount) {
    if (!playerId) return;
    actErr.textContent = "";
    const body = { player_id: playerId, action };
    if (action === "raise" || action === "bet") {
      body.amount = amount != null ? amount : parseInt(raiseAmtInput.value, 10);
      if (!body.amount || body.amount < 1) {
        actErr.textContent = "Enter a valid raise amount.";
        return;
      }
    }
    try {
      const data = await apiFetch("POST", apiBase() + "/actions", body);
      renderAll(data.table || {});
    } catch (err) {
      actErr.textContent = err.message;
    }
  }

  /* ── bot (file upload → server-side) ─────────────── */

  botUploadStart.addEventListener("click", async () => {
    const file = botFileInput.files[0];
    if (!file) { botStatusEl.textContent = "Select a .py or .lua file first."; return; }
    const name = (botNameInput.value || "").trim() || file.name.replace(/\.\w+$/, "");
    const chips = parseInt(botChipsInput.value, 10) || 500;
    botStatusEl.textContent = "Reading file…";

    const code = await file.text();
    try {
      const resp = await apiFetch("POST", apiBase() + "/bot/start", {
        player_id: name,
        chips,
        code,
        filename: file.name,
      });
      activeBotName = name;
      botUploadStart.disabled = true;
      botUploadStop.disabled = false;
      botStatusEl.textContent = "Bot \"" + name + "\" started (pid " + resp.pid + ", " + resp.lang + ")";
      refreshBotList();
    } catch (err) {
      botStatusEl.textContent = "Error: " + err.message;
    }
  });

  botUploadStop.addEventListener("click", async () => {
    if (!activeBotName) return;
    try {
      await apiFetch("POST", apiBase() + "/bot/stop", { player_id: activeBotName });
      botStatusEl.textContent = "Bot \"" + activeBotName + "\" stopped.";
    } catch (err) {
      botStatusEl.textContent = "Stop error: " + err.message;
    }
    activeBotName = null;
    botUploadStart.disabled = false;
    botUploadStop.disabled = true;
    refreshBotList();
  });

  async function refreshBotList() {
    try {
      const resp = await apiFetch("GET", apiBase() + "/bot/list");
      const bots = resp.bots || [];
      botRunningList.replaceChildren();
      if (bots.length === 0) return;
      bots.forEach(b => {
        const div = document.createElement("div");
        div.className = "bot-entry";
        const pill = document.createElement("span");
        pill.className = "pill active";
        pill.textContent = b.lang;
        const label = document.createElement("span");
        label.textContent = b.player_id + " (pid " + b.pid + ")";
        const stopBtn = document.createElement("button");
        stopBtn.className = "btn btn-danger btn-sm";
        stopBtn.textContent = "Stop";
        stopBtn.addEventListener("click", async () => {
          try {
            await apiFetch("POST", apiBase() + "/bot/stop", { player_id: b.player_id });
            if (activeBotName === b.player_id) {
              activeBotName = null;
              botUploadStart.disabled = false;
              botUploadStop.disabled = true;
            }
            refreshBotList();
          } catch (err) {
            botStatusEl.textContent = "Stop error: " + err.message;
          }
        });
        div.appendChild(pill);
        div.appendChild(label);
        div.appendChild(stopBtn);
        botRunningList.appendChild(div);
      });
    } catch { /* ignore */ }
  }

  /* ── table selector ───────────────────────────────── */

  let tableListTimer = null;
  const TABLE_LIST_INTERVAL = 5000;

  function ensureTableOption(tid) {
    if (!tid || !tableIdInput) return;
    const exists = [...tableIdInput.options].some(o => o.value === tid);
    if (!exists) {
      const opt = document.createElement("option");
      opt.value = tid;
      opt.textContent = tid + " (spectate)";
      tableIdInput.appendChild(opt);
    }
    tableIdInput.value = tid;
  }

  async function loadTableList() {
    try {
      const data = await apiFetch("GET", "/v1/tables");
      const tables = (data.tables || []).sort((a, b) => a.table_id.localeCompare(b.table_id));
      const prev = tableIdInput.value;
      tableIdInput.replaceChildren();
      tables.forEach(t => {
        const opt = document.createElement("option");
        opt.value = t.table_id;
        opt.textContent = t.table_id + " (" + t.seated + "/" + t.max_seats + ")";
        tableIdInput.appendChild(opt);
      });
      if (tables.find(t => t.table_id === prev)) {
        tableIdInput.value = prev;
      }
      if (spectateMode) {
        ensureTableOption(tableId());
      }
    } catch { /* keep current options */ }
  }

  function startTableListPoll() {
    if (tableListTimer) return;
    tableListTimer = setInterval(loadTableList, TABLE_LIST_INTERVAL);
  }

  /* ── init ─────────────────────────────────────────── */

  refreshBtn.addEventListener("click", () => { loadTableList(); poll(); refreshBotList(); });
  tableIdInput.addEventListener("change", () => {
    if (playerId) startPoll();
    else if (spectateMode) startPoll();
    else poll();
  });

  if (spectateMode) {
    document.body.classList.add("spectate-mode");
    joinPanel.classList.add("hidden");
    gameArea.classList.remove("hidden");
    if (leaveBtn) leaveBtn.classList.add("hidden");
    if (actionPanel) actionPanel.classList.add("hidden");
    if (botPanel) botPanel.classList.add("hidden");
    connState.textContent = "Spectate: connecting…";
    connState.className = "sub spectate-connecting";
  }

  loadTableList().then(() => {
    if (spectateMode) {
      ensureTableOption(tableId());
      startPoll();
      refreshBotList();
    } else {
      poll();
      refreshBotList();
      startTableListPoll();
    }
  });
})();
