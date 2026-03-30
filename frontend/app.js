(function () {
  "use strict";

  const qs = (sel, el) => (el || document).querySelector(sel);

  const tableIdInput = qs("#tableId");
  const pollToggle = qs("#poll");
  const refreshBtn = qs("#refresh");
  const connState = qs("#connState");
  const lastFetch = qs("#lastFetch");
  const seatsEl = qs("#seats");
  const handStatus = qs("#handStatus");
  const handStreet = qs("#handStreet");
  const handPot = qs("#handPot");
  const communityEl = qs("#community");
  const actionLog = qs("#actionLog");
  const endpointEl = qs("#endpoint");
  const handBtn = qs("#handBtn");
  const handBlinds = qs("#handBlinds");
  const handAct = qs("#handAct");
  const handMinRaise = qs("#handMinRaise");

  let pollTimer = null;

  const urlParams = new URLSearchParams(location.search);
  const tableFromUrl = urlParams.get("table");
  if (tableFromUrl) {
    tableIdInput.value = tableFromUrl;
  }

  function currentTableId() {
    const v = (tableIdInput.value || "demo").trim();
    return v || "demo";
  }

  function stateUrl() {
    const id = encodeURIComponent(currentTableId());
    return `/v1/tables/${id}/state`;
  }

  function setConn(ok, msg) {
    connState.textContent = msg;
    connState.className = "pill " + (ok ? "pill-ok" : "pill-err");
  }

  function renderSeats(data) {
    const max = data.max_seats || 10;
    const seats = data.seats || [];
    const frag = document.createDocumentFragment();
    for (let i = 1; i <= max; i++) {
      const s = seats[i];
      const div = document.createElement("div");
      div.className = "seat" + (s && s.player_id ? " occupied" : "");
      const num = document.createElement("div");
      num.className = "seat-num";
      num.textContent = "Seat " + i;
      div.appendChild(num);
      if (s && s.player_id) {
        const name = document.createElement("div");
        name.className = "seat-name";
        name.textContent = s.player_id;
        div.appendChild(name);
        const stack = document.createElement("div");
        stack.className = "seat-stack";
        stack.textContent = String(s.stack) + " chips";
        div.appendChild(stack);
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

  function renderHand(hand) {
    if (!hand) {
      handStatus.textContent = "—";
      handStreet.textContent = "—";
      handPot.textContent = "0";
      handBtn.textContent = "—";
      handBlinds.textContent = "—";
      handAct.textContent = "—";
      handMinRaise.textContent = "—";
      communityEl.replaceChildren();
      const li = document.createElement("li");
      li.textContent = "No hand data.";
      actionLog.replaceChildren(li);
      return;
    }
    handStatus.textContent = hand.status || "—";
    handStreet.textContent = hand.street || "—";
    handPot.textContent = String(hand.pot != null ? hand.pot : 0);
    handBtn.textContent =
      hand.button_seat != null ? "seat " + hand.button_seat : "—";
    var sb = hand.sb_seat != null ? hand.sb_seat : "—";
    var bb = hand.bb_seat != null ? hand.bb_seat : "—";
    var sba = hand.sb_amount != null ? hand.sb_amount : 2;
    var bba = hand.bb_amount != null ? hand.bb_amount : 5;
    handBlinds.textContent = sb + " (" + sba + ") / " + bb + " (" + bba + ")";
    handAct.textContent =
      hand.action_to_seat != null ? "seat " + hand.action_to_seat : "—";
    handMinRaise.textContent =
      hand.min_raise_increment != null ? String(hand.min_raise_increment) : "—";

    communityEl.replaceChildren();
    const comm = hand.community || [];
    if (comm.length === 0) {
      const ph = document.createElement("span");
      ph.className = "card placeholder";
      ph.textContent = "—";
      communityEl.appendChild(ph);
    } else {
      comm.forEach(function (c) {
        const el = document.createElement("span");
        el.className = "card";
        el.textContent = String(c);
        communityEl.appendChild(el);
      });
    }

    actionLog.replaceChildren();
    const log = hand.action_log || [];
    if (log.length === 0) {
      const li = document.createElement("li");
      li.textContent = "No actions yet.";
      actionLog.appendChild(li);
    } else {
      log.forEach(function (entry) {
        const li = document.createElement("li");
        li.textContent = typeof entry === "string" ? entry : JSON.stringify(entry);
        actionLog.appendChild(li);
      });
    }
  }

  async function fetchState() {
    endpointEl.textContent = stateUrl();
    try {
      const res = await fetch(stateUrl(), { cache: "no-store" });
      const text = await res.text();
      let data;
      try {
        data = JSON.parse(text);
      } catch (e) {
        throw new Error("Invalid JSON");
      }
      if (!res.ok) {
        const err = (data && data.error && data.error.message) || res.statusText;
        throw new Error(err);
      }
      setConn(true, "Live");
      lastFetch.textContent = "Updated " + new Date().toLocaleTimeString();
      renderSeats(data);
      renderHand(data.hand);
    } catch (e) {
      setConn(false, "Error");
      lastFetch.textContent = String(e.message || e);
      connState.className = "pill pill-err";
    }
  }

  function restartPoll() {
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
    if (pollToggle.checked) {
      pollTimer = setInterval(fetchState, 2000);
    }
  }

  tableIdInput.addEventListener("change", function () {
    fetchState();
    restartPoll();
  });

  refreshBtn.addEventListener("click", fetchState);

  pollToggle.addEventListener("change", restartPoll);

  fetchState();
  restartPoll();
})();
