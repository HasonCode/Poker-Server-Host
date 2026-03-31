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
  const seatsEl        = $("#seats");

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
  let mySeat   = null;
  let lastData = null;
  let pollTimer = null;
  let activeBotName = null;

  const urlParams = new URLSearchParams(location.search);
  if (urlParams.get("table")) tableIdInput.value = urlParams.get("table");
  if (urlParams.get("name"))  joinName.value = urlParams.get("name");

  /* ── helpers ──────────────────────────────────────── */

  function tableId() { return (tableIdInput.value || "demo").trim() || "demo"; }

  function apiBase(tid) {
    return "/v1/tables/" + encodeURIComponent(tid || tableId());
  }

  async function apiFetch(method, path, body) {
    const opts = { method, headers: { "Accept": "application/json" } };
    if (body !== undefined) {
      opts.headers["Content-Type"] = "application/json";
      opts.body = JSON.stringify(body);
    }
    const res = await fetch(path, opts);
    const text = await res.text();
    let data;
    try { data = JSON.parse(text); } catch { throw new Error("Invalid JSON from server"); }
    if (!res.ok) {
      const msg = data?.error?.message || res.statusText;
      const err = new Error(msg);
      err.apiCode = data?.error?.code;
      throw err;
    }
    return data;
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

    if (playerId && mySeat) {
      joinPanel.classList.add("hidden");
      gameArea.classList.remove("hidden");
    }

    /* your info */
    if (playerId && mySeat) {
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
    betVal.textContent = hand.current_bet != null ? hand.current_bet : 0;
    minRaiseVal.textContent = hand.min_raise_increment != null ? hand.min_raise_increment : "—";

    /* community */
    communityEl.replaceChildren();
    const comm = hand.community || [];
    if (comm.length === 0) {
      for (let i = 0; i < 5; i++) communityEl.appendChild(makeFacedownEl());
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
    const myTurn = isMyTurn(data);
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
    connState.textContent = "Connected";
    connState.className = "sub";
    endpointEl.textContent = apiBase() + "/state";
  }

  function getContrib(hand, seat) {
    const c = hand.contribution || {};
    if (typeof c === "object" && !Array.isArray(c)) return c[String(seat)] || 0;
    return 0;
  }

  function renderSeats(data) {
    const max = data.max_seats || 10;
    const seats = data.seats || [];
    const hand = data.hand || {};
    const holeCards = hand.hole_cards || {};
    const folded = hand.folded || {};
    const frag = document.createDocumentFragment();

    for (let i = 1; i <= max; i++) {
      const s = seats[i - 1];
      const div = document.createElement("div");
      const isFolded = typeof folded === "object" && !Array.isArray(folded) && folded[String(i)];

      let cls = "seat";
      if (s && s.player_id) cls += " occupied";
      if (hand.action_to_seat === i) cls += " acting";
      if (i === mySeat) cls += " you";
      if (isFolded) cls += " folded";
      div.className = cls;

      const num = document.createElement("div");
      num.className = "seat-num";
      const tags = [];
      if (hand.button_seat === i) tags.push("BTN");
      if (hand.sb_seat === i) tags.push("SB");
      if (hand.bb_seat === i) tags.push("BB");
      if (hand.action_to_seat === i) tags.push("▸ACT");
      num.textContent = "Seat " + i + (tags.length ? " · " + tags.join(" ") : "");
      div.appendChild(num);

      if (s && s.player_id) {
        const name = document.createElement("div");
        name.className = "seat-name";
        name.textContent = s.player_id + (i === mySeat ? " (you)" : "");
        div.appendChild(name);

        const stack = document.createElement("div");
        stack.className = "seat-stack";
        stack.textContent = s.stack + " chips";
        div.appendChild(stack);

        const contrib = getContrib(hand, i);
        if (contrib > 0) {
          const betEl = document.createElement("div");
          betEl.className = "seat-bet";
          betEl.textContent = "bet " + contrib;
          div.appendChild(betEl);
        }

        if (isFolded) {
          const f = document.createElement("div");
          f.className = "seat-tags";
          f.textContent = "FOLDED";
          div.appendChild(f);
        }

        const cardsDiv = document.createElement("div");
        cardsDiv.className = "seat-cards";
        const cards = typeof holeCards === "object" && !Array.isArray(holeCards) ? holeCards[String(i)] : null;
        if (cards && cards.length) {
          cards.forEach(c => cardsDiv.appendChild(makeCardEl(c, "sm")));
        } else if (hand.status === "active" && !isFolded) {
          cardsDiv.appendChild(makeFacedownEl("sm"));
          cardsDiv.appendChild(makeFacedownEl("sm"));
        }
        div.appendChild(cardsDiv);
      } else {
        const empty = document.createElement("div");
        empty.className = "seat-name";
        empty.style.color = "var(--muted)";
        empty.textContent = "Empty";
        div.appendChild(empty);
      }
      frag.appendChild(div);
    }
    seatsEl.replaceChildren(frag);
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
      const data = await apiFetch("GET", apiBase() + "/state");
      renderAll(data);
    } catch (e) {
      connState.textContent = "Error: " + e.message;
      connState.className = "sub";
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

  /* ── join / leave ─────────────────────────────────── */

  joinForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    joinErr.textContent = "";
    const name = joinName.value.trim();
    const chips = parseInt(joinChips.value, 10);
    if (!name) { joinErr.textContent = "Name is required."; return; }
    if (!chips || chips < 1) { joinErr.textContent = "Chips must be at least 1."; return; }
    try {
      const data = await apiFetch("POST", apiBase() + "/join", { player_id: name, chips });
      playerId = name;
      renderAll(data.table || {});
      startPoll();
    } catch (err) {
      joinErr.textContent = err.message;
    }
  });

  leaveBtn.addEventListener("click", async () => {
    if (!playerId) return;
    try {
      await apiFetch("POST", apiBase() + "/leave", { player_id: playerId });
    } catch { /* ignore */ }
    playerId = null;
    mySeat = null;
    activeBotName = null;
    botUploadStart.disabled = false;
    botUploadStop.disabled = true;
    botStatusEl.textContent = "";
    gameArea.classList.add("hidden");
    joinPanel.classList.remove("hidden");
    stopPoll();
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

  /* ── init ─────────────────────────────────────────── */

  refreshBtn.addEventListener("click", () => { poll(); refreshBotList(); });
  tableIdInput.addEventListener("change", () => { if (playerId) startPoll(); else poll(); });

  poll();
  refreshBotList();
})();
