"use strict";
// mini-deploy admin page. Talks only to its own server (/api/...). Everything that comes
// back goes in with textContent, never as HTML: deploy-log lines can hold build output.
(function () {
  var REFRESH_MS = 30000;
  var NAME_RE = /^[a-z0-9-]{1,40}$/;
  // The only two address shapes a link may have (checked again here, not trusted).
  var PC_URL_RE = /^http:\/\/[a-z0-9-]{1,40}\.localhost:8080\/$/;
  var PHONE_URL_RE = /^http:\/\/[a-z0-9-]{1,40}\.[0-9]{1,3}(-[0-9]{1,3}){3}\.nip\.io:8080\/$/;
  var TAILNET_URL_RE = /^https:\/\/[a-z0-9-]+(\.[a-z0-9-]+)*\.ts\.net:[0-9]{4,5}\/$/;   // P5
  var csrf = null;
  var timer = null;

  function $(id) { return document.getElementById(id); }
  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) { node.className = cls; }
    if (text !== undefined && text !== null) { node.textContent = String(text); }
    return node;
  }
  function when(iso) {
    var d = new Date(iso);
    return isNaN(d.getTime()) ? String(iso) : d.toLocaleString([], {
      month: "short", day: "numeric", hour: "2-digit", minute: "2-digit"
    });
  }
  function say(text, bad) {
    var box = $("message");
    box.textContent = text || "";
    box.hidden = !text;
    box.setAttribute("data-state", bad ? "bad" : "ok");
  }

  // ---------------------------------------------------------------- Bean, toasts (café look, 2026-10-23)
  var MOUTHS = {
    idle: "M96 140 Q 101 144 106 140", happy: "M95 139 Q 101 146 107 139",
    brewing: "M97 140 Q 101 145 105 140 Q 101 138 97 140", worried: "M96 143 Q 101 138 106 143"
  };
  var moodHold = null;   // a short mood after something the user did (rollback done, upload failed)
  function mood(state, line) {
    var bean = $("bean");
    bean.setAttribute("class", "bean " + state);
    $("mouth").setAttribute("d", MOUTHS[state] || MOUTHS.idle);
    if (line) { $("bubble").textContent = line; }
  }
  function holdMood(state, line, ms) {
    moodHold = { state: state, line: line, until: Date.now() + ms };
    mood(state, line);
  }
  function toast(text, bad) {
    var t = el("div", "toast" + (bad ? " bad" : ""), text);
    $("toasts").appendChild(t);
    setTimeout(function () { if (t.parentNode) { t.parentNode.removeChild(t); } }, 4500);
  }
  function clock(iso) {
    var d = new Date(iso);
    return isNaN(d.getTime()) ? "" : d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }
  function ageSeconds(iso, nowIso) {
    var a = new Date(iso).getTime(), b = new Date(nowIso).getTime();
    return isNaN(a) || isNaN(b) ? Infinity : (b - a) / 1000;
  }

  // Every request: same origin, no cache. Changes carry the CSRF token and are JSON.
  function api(method, path, body) {
    var opts = { method: method, credentials: "same-origin", cache: "no-store", headers: {} };
    if (body !== undefined) {
      opts.headers["Content-Type"] = "application/json";
      opts.body = JSON.stringify(body);
    }
    if (method === "POST" && csrf) { opts.headers["X-CSRF-Token"] = csrf; }
    return fetch(path, opts).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (data) {
        return { status: r.status, data: data || {} };
      });
    });
  }

  // ---------------------------------------------------------------- signing in and out
  function showLogin(passwordSet) {
    csrf = null;
    if (timer) { clearInterval(timer); timer = null; }
    // Nothing from the signed-in view may stay in the page: the one-time secret, the form, the token.
    clearSecret();
    $("connect-form").reset();
    $("upload-form").reset();
    $("token").value = "";
    addOpen = false;
    tokenDecided = false;
    $("main").hidden = true;
    $("session-buttons").hidden = true;
    $("login").hidden = false;
    ["home-note", "backup-note", "ai-note"].forEach(function (id) { $(id).textContent = ""; });
    moodHold = null;
    mood("idle", "Sign in, and I'll tell you how your apps are doing.");
    $("overall").textContent = "signed out";
    $("overall").setAttribute("data-state", "held");
    $("login-help").textContent = passwordSet === false
      ? "No password yet. In a WSL window run: python3 /mnt/c/Users/indra/Code/mini-deploy/scripts/admin.py set-password"
      : "Sign in to manage your apps.";
    $("password").focus();
  }

  function showMain() {
    $("login").hidden = true;
    $("main").hidden = false;
    $("session-buttons").hidden = false;
    load();
    if (!timer) { timer = setInterval(load, REFRESH_MS); }
  }

  $("login-form").addEventListener("submit", function (event) {
    event.preventDefault();   // never a real form post: JSON only
    var field = $("password");
    var password = field.value;
    field.value = "";
    api("POST", "/api/login", { password: password }).then(function (res) {
      if (res.status === 200 && typeof res.data.csrf === "string") {
        csrf = res.data.csrf;
        say("");
        showMain();
      } else {
        say(res.data.error || ("sign-in failed (" + res.status + ")"), true);
        field.focus();
      }
    }, function () { say("could not reach the admin service", true); });
  });

  $("logout").addEventListener("click", function () {
    api("POST", "/api/logout", {}).then(function () { say("signed out"); showLogin(true); });
  });
  $("logout-all").addEventListener("click", function () {
    if (!window.confirm("Sign out every browser that is signed in, including this one?")) { return; }
    api("POST", "/api/logout-all", {}).then(function () { say("every session is signed out"); showLogin(true); });
  });

  // ---------------------------------------------------------------- actions
  var CONFIRM = {
    rollback: "Roll back {app} to its previous release? Pushes from GitHub are then held until you press Unhold.",
    rollforward: "Move {app} forward to its next newer release? Pushes are held until you press Unhold.",
    unhold: "Let pushes from GitHub deploy {app} again?"
  };
  // `live` is the release this page showed: the server refuses a rollback if live has
  // changed since (a double click or a retry must never go back two steps).
  function act(action, app, live, button) {
    if (!NAME_RE.test(app)) { return; }
    if (!window.confirm(CONFIRM[action].replace("{app}", app))) { return; }
    button.disabled = true;
    var DONE = { rollback: "rolled back", rollforward: "rolled forward", unhold: "taking pushes again" };
    api("POST", "/api/action", { action: action, app: app, expect: live }).then(function (res) {
      button.disabled = false;
      if (res.status === 200) {
        say("");
        toast(app + ": " + DONE[action] + (action === "unhold" ? "" : ". Pushes wait until you press Unhold."));
        holdMood("happy", action === "unhold"
          ? app + " takes pushes from GitHub again."
          : app + " is on another release now. I'm holding it, so a push can't undo that.", 8000);
      }
      else if (res.status === 401) { showLogin(true); say("please sign in again", true); return; }
      else {
        var why = app + ": " + (res.data.error || (action + " failed (" + res.status + ")"));
        say(why, true);
        toast(why, true);
        holdMood("worried", "That didn't work: " + (res.data.error || "the server said no") + ".", 8000);
      }
      load();
    }, function () { button.disabled = false; say("could not reach the admin service", true); });
  }

  function copyButton(text) {
    var button = el("button", "pill", "Copy");
    button.type = "button";
    button.addEventListener("click", function () {
      if (!navigator.clipboard) { say("copy is not available in this browser: select the text and copy it by hand", true); return; }
      navigator.clipboard.writeText(text).then(function () {
        button.textContent = "Copied";
        setTimeout(function () { button.textContent = "Copy"; }, 2000);
      }, function () { button.textContent = "Select and copy"; });
    });
    return button;
  }

  // ---------------------------------------------------------------- rendering
  // The last live release shown per app: when it changes, the cup slides from the old bean to the new one.
  var lastLive = {};
  var BEAN_STEP = 28;   // px from one bean to the next (18 px bean + 10 px gap)

  function beansRow(app) {
    var releases = Array.isArray(app.releases) ? app.releases : [];
    var row = el("div", "beans");
    var liveAt = -1;
    releases.forEach(function (r, i) {
      if (r && r.live) { liveAt = i; }
      row.appendChild(el("span", "b" + (r && r.live ? " live" : "")));
    });
    row.setAttribute("role", "img");
    row.setAttribute("aria-label", releases.length + " release" + (releases.length === 1 ? "" : "s") + " kept" +
      (liveAt >= 0 ? ", number " + (liveAt + 1) + " is live"
        : app.live ? ", the live one is older than these" : ", none live"));
    if (liveAt >= 0) {
      var marker = el("span", "marker");
      marker.appendChild(document.importNode($("cup-tpl").content, true));
      var before = lastLive[app.name];
      var from = typeof before === "number" ? before : liveAt;
      marker.style.left = (from * BEAN_STEP) + "px";
      row.appendChild(marker);
      if (from !== liveAt) {   // let the browser draw the old place first, then slide
        requestAnimationFrame(function () { requestAnimationFrame(function () { marker.style.left = (liveAt * BEAN_STEP) + "px"; }); });
      }
    }
    return { row: row, liveAt: liveAt };
  }

  function aiMeter(usage) {
    if (!usage || typeof usage.per_day !== "number") { return null; }
    var box = el("div", "meter");
    var line = el("div", "meter-line");
    line.appendChild(el("span", null, "AI today"));
    line.appendChild(el("span", "mono", usage.requests + " / " + usage.per_day));
    var mug = el("div", "mug" + (usage.requests >= usage.per_day ? " full" : ""));
    var fill = el("i");
    mug.appendChild(fill);
    box.appendChild(line);
    box.appendChild(mug);
    var pct = Math.min(100, Math.max(usage.requests > 0 ? 2 : 0, usage.requests / usage.per_day * 100));
    requestAnimationFrame(function () { fill.style.width = pct + "%"; });
    return box;
  }

  function appCard(app, needsLook, atHome, usage) {
    var card = el("article", "glass app-card");
    var head = el("div", "app-head");
    var title = el("div", "app-title");
    title.appendChild(el("span", "tile", app.name.charAt(0).toUpperCase()));
    title.appendChild(el("h3", "app-name", app.name));
    head.appendChild(title);
    var chip = el("span", "chip", app.held ? "on hold" : (app.live ? "live" : "nothing live"));
    chip.setAttribute("data-state", app.held ? "held" : (needsLook ? "attention" : "ok"));
    head.appendChild(chip);
    card.appendChild(head);

    if (app.preview_of) { card.appendChild(el("p", "muted", "preview of " + app.preview_of)); }
    var beans = beansRow(app);
    card.appendChild(beans.row);
    if (typeof lastLive[app.name] === "number" && lastLive[app.name] !== beans.liveAt) { card.classList.add("flash"); }
    if (beans.liveAt >= 0) { lastLive[app.name] = beans.liveAt; }
    card.appendChild(el("p", "muted mono", (app.live ? "release " + app.live : "nothing live") +
      (app.deployed ? " · commit " + app.deployed : "")));
    var meter = aiMeter(usage);
    if (meter) { card.appendChild(meter); }
    if (needsLook) {
      var why = el("p", "muted", "last run failed · ");
      var logs = el("a", null, "view build log");
      var url = new URL(location.href);   // same scheme and port as this page, other name
      url.hostname = "logs.localhost";
      url.pathname = "/";
      url.search = "";
      url.hash = NAME_RE.test(app.name) ? app.name : "";
      logs.href = url.toString();
      why.appendChild(logs);
      card.appendChild(why);
    }

    var links = el("div", "links");
    if (typeof app.pc_url === "string" && PC_URL_RE.test(app.pc_url)) {
      var pc = el("p", null);
      var open = el("a", null, "open on this PC");
      open.href = app.pc_url;
      open.rel = "noopener";
      open.target = "_blank";
      pc.appendChild(open);
      links.appendChild(pc);
    }
    if (typeof app.phone_url === "string" && PHONE_URL_RE.test(app.phone_url)) {
      links.appendChild(el("p", "muted small", "phone (home Wi-Fi):"));
      var box = el("div", "address");
      box.appendChild(el("code", "mono", app.phone_url));
      box.appendChild(copyButton(app.phone_url));
      links.appendChild(box);
    } else {
      links.appendChild(el("p", "muted small",
        atHome ? "phone address: not available" : "phone address: shown when this PC is on your home Wi-Fi"));
    }
    if (typeof app.tailnet_url === "string" && TAILNET_URL_RE.test(app.tailnet_url)) {
      links.appendChild(el("p", "muted small", "phone, anywhere (Tailscale on, on the phone):"));
      var anywhere = el("div", "address");
      anywhere.appendChild(el("code", "mono", app.tailnet_url));
      anywhere.appendChild(copyButton(app.tailnet_url));
      links.appendChild(anywhere);
    }
    card.appendChild(links);

    if (NAME_RE.test(app.name)) {
      var actions = el("div", "actions");
      [["rollback", "Roll back"], ["rollforward", "Roll forward"]].forEach(function (pair) {
        var b = el("button", "pill", pair[1]);
        b.type = "button";
        b.addEventListener("click", function () { act(pair[0], app.name, app.live, b); });
        actions.appendChild(b);
      });
      if (app.held) {
        var u = el("button", "pill pill-dark", "Unhold");
        u.type = "button";
        u.addEventListener("click", function () { act("unhold", app.name, app.live, u); });
        actions.appendChild(u);
      }
      card.appendChild(actions);
    }
    return card;
  }

  // ---------------------------------------------------------------- the latest push, from the deploy log
  var lastEventTs = "";
  var fastTimer = null;
  var FAST_MS = 3000;          // while a push is building, look again every 3 s instead of 30 s
  var SKIPPED = { held: "on hold: not deployed", same: "already live", superseded: "a newer push replaced it",
    disconnected: "repo disconnected", stale: "not the newest commit" };

  // The push to show: one still building (any app, newest first, under 15 min old) wins, so two
  // pushes at once never hide each other; otherwise the newest push of any app.
  function latestPush(events, nowIso) {
    var seen = {}, newest = null, building = null;
    for (var i = events.length - 1; i >= 0; i--) {
      var ev = events[i];
      if (!(ev && ev.action === "webhook" && ev.app !== "webhook" && NAME_RE.test(String(ev.app)) &&
            ev.result !== "ignored" && ev.result !== "rejected")) { continue; }
      if (!newest) { newest = ev; }
      if (seen[ev.app]) { continue; }          // only each app's own newest push counts
      seen[ev.app] = true;
      if (!building && (ev.result === "queued" || ev.result === "requeued") && ageSeconds(ev.ts, nowIso) < 900) {
        building = ev;
      }
    }
    return building || newest;
  }
  // "feature-x--horizon" is a preview of horizon: say so, so it never reads like the live app.
  function appLabel(name) {
    var at = String(name).lastIndexOf("--");
    return at > 0 ? name.slice(at + 2) + " (preview " + name.slice(0, at) + ")" : name;
  }

  function station(id, state) { $(id).className = "station" + (state ? " " + state : ""); }

  function renderTrack(data) {
    var push = latestPush(data.events || [], data.generated_at);
    var who = push ? appLabel(push.app) : "";
    var track = $("track");
    var commit = push && typeof push.detail === "string" && /^commit [0-9a-f]{7}/.test(push.detail) ? push.detail.slice(7, 14) : "";
    $("st-live-label").textContent = "Live";
    $("st-live-note").textContent = "switched in one move";
    track.classList.remove("brewing");
    var stage = !push ? "none" : (push.result === "queued" || push.result === "requeued") ? "brewing" : push.result === "ok" ? "live"
      : (push.result === "fail" || push.result === "crash") ? "failed" : "skipped";
    if (stage === "none") {
      ["st-in", "st-build", "st-live"].forEach(function (id) { station(id, ""); });
      $("pipe").style.width = "0%";
      $("track-status").textContent = "Nothing has been pushed yet.";
    } else if (stage === "brewing") {
      station("st-in", "done"); station("st-build", "now"); station("st-live", "");
      $("pipe").style.width = "50%";
      track.classList.add("brewing");
      $("track-status").textContent = "Brewing " + who + (commit ? " " + commit : "") + " since " + clock(push.ts) + "...";
    } else if (stage === "live") {
      station("st-in", "done"); station("st-build", "done"); station("st-live", "done");
      $("pipe").style.width = "100%";
      $("track-status").textContent = who + (commit ? " " + commit : "") + " went live at " + clock(push.ts) +
        " (took " + push.duration + ")";
    } else if (stage === "failed") {
      station("st-in", "done"); station("st-build", "failed"); station("st-live", "failed");
      $("pipe").style.width = "50%";
      $("st-live-label").textContent = "Not deployed";
      $("st-live-note").textContent = "the live site stayed as it was";
      $("track-status").textContent = who + " failed at " + clock(push.ts) + ": see the build log";
    } else {
      station("st-in", "done"); station("st-build", ""); station("st-live", "");
      $("pipe").style.width = "33%";
      $("st-live-label").textContent = "Skipped";
      $("st-live-note").textContent = SKIPPED[push.result] || push.result;
      $("track-status").textContent = who + " at " + clock(push.ts) + ": " + (SKIPPED[push.result] || push.result);
    }
    // A build takes about 20 s: look again soon so the track moves with it. A "queued" line older than
    // 15 minutes means nothing closed it (the webhook stopped): back to the normal 30 s, never 3 s forever.
    var age = push ? ageSeconds(push.ts, data.generated_at) : Infinity;
    if (stage === "brewing" && age < 900 && !fastTimer) {
      fastTimer = setTimeout(function () { fastTimer = null; if (!$("main").hidden) { load(); } }, FAST_MS);
    }
    return { ev: push, stage: stage, age: age };
  }

  // Bean's mood and words come from the same data the page shows: never a guess.
  function renderBean(data, push, attention, backup, aiFull, aiWarn) {
    if (moodHold && Date.now() < moodHold.until) { mood(moodHold.state, moodHold.line); return; }
    moodHold = null;
    var apps = data.apps || [];
    var held = apps.filter(function (a) { return a.held; }).map(function (a) { return a.name; });
    if (push.stage === "brewing") {
      mood("brewing", "A push to " + appLabel(push.ev.app) + " came in. Brewing it now...");
    } else if (push.stage === "failed" && push.age < 1800) {
      mood("worried", appLabel(push.ev.app) + "'s build failed, so I kept serving the old one. Nobody saw a broken page.");
    } else if (attention.length) {
      mood("worried", attention.join(", ") + (attention.length === 1 ? " needs" : " need") + " a look: the last run failed.");
    } else if (backup.stale) {
      mood("worried", "The weekly backup needs a look. The details are just below.");
    } else if (aiFull || aiWarn) {
      mood("worried", aiWarn ? "Something is off with the AI counters. The details are just below." : "An app reached today's AI limit. It resets at midnight.");
    } else if (push.stage === "live" && push.age < 180 && held.indexOf(push.ev.app) < 0) {
      // (never right after a rollback: then the app is held, and "fresh is live" would be untrue)
      mood("happy", "Fresh " + appLabel(push.ev.app) + " is live! The old release is still on the shelf if you need it.");
    } else if (held.length) {
      mood("idle", held.join(", ") + (held.length === 1 ? " is" : " are") + " on hold after a rollback. Press Unhold when you're ready.");
    } else if (!apps.length) {
      mood("idle", "No apps yet. Connect a repo or upload a zip below, and I'll brew it.");
    } else {
      mood("idle", "All " + apps.length + " apps are live. Nothing brewing" +
        (backup.last_ok ? "; the last backup was " + when(backup.last_ok) + "." : "."));
    }
  }

  function render(data) {
    var attention = data.attention || [];
    var backup = data.backup || { stale: true };
    var needs = attention.length > 0 || backup.stale === true;
    $("overall").setAttribute("data-state", needs ? "attention" : "ok");
    $("overall").textContent = needs ? "needs a look" : "all good";
    $("updated").textContent = "updated " + when(data.generated_at);
    $("home-note").textContent = data.at_home
      ? "This PC is on your home Wi-Fi: the phone addresses below work there."
      : "This PC is not on your home Wi-Fi right now, so phone addresses are hidden.";
    // The weekly backup (OneDrive). A failed run or none for 8 days asks for a look.
    var note = $("backup-note");
    if (backup.stale) {
      note.className = "small result-bad";
      note.textContent = (backup.last_result === "fail" ? "The last backup failed" : "No backup for over a week")
        + (backup.last_ok ? " (last good one " + when(backup.last_ok) + ")" : " (none yet)")
        + ": in WSL, journalctl -u mini-deploy-backup";
    } else {
      note.className = "muted small";
      note.textContent = "Last backup " + when(backup.last_ok) + " (OneDrive, no secrets inside).";
    }
    // AI use today per app, against its daily limit (counts only). Red once an app hit its limit.
    var ai = data.ai || {};
    var parts = [], full = false;
    Object.keys(ai).sort().forEach(function (name) {
      var u = ai[name];
      if (typeof u.per_day === "number") {
        parts.push(name + " " + u.requests + "/" + u.per_day);
        if (u.requests >= u.per_day) { full = true; }
      } else {
        parts.push(name + " " + u.requests + " (no limits: refused)");
      }
    });
    var aiWarn = typeof data.ai_warning === "string" ? data.ai_warning : "";
    $("ai-note").className = full || aiWarn ? "small result-bad" : "muted small";
    $("ai-note").textContent = (parts.length
      ? "AI use today (resets 00:00 JST): " + parts.join(" · ") + (full ? ". A daily limit was reached." : "")
      : "AI use today: no limits set yet, so every AI request is refused.")
      + (aiWarn ? " Warning: " + aiWarn + "." : "");

    knownApps = data.apps.map(function (a) { return a.name; });
    var apps = $("apps");
    apps.textContent = "";
    if (!data.apps.length) { apps.appendChild(el("p", "muted empty", "No apps yet.")); }
    data.apps.forEach(function (app) {
      apps.appendChild(appCard(app, attention.indexOf(app.name) >= 0, data.at_home, ai[app.name]));
    });

    var push = renderTrack(data);
    renderBean(data, push, attention, backup, full, aiWarn);

    var log = $("log");
    log.textContent = "";
    if (!data.events.length) { log.appendChild(el("p", "muted empty", "Nothing has happened yet.")); }
    var newest = lastEventTs;
    data.events.slice().reverse().forEach(function (ev) {
      var row = el("div", "log-row" + (lastEventTs && ev.ts > lastEventTs ? " new" : ""));
      if (!newest || ev.ts > newest) { newest = ev.ts; }
      var top = el("div", "row between");
      top.appendChild(el("span", "mono", ev.app + " · " + ev.action));
      var good = ev.result === "ok" || ev.result === "queued" || ev.result === "same" || ev.result === "removed";
      top.appendChild(el("span", good ? "result-ok" : "result-bad", ev.result));
      row.appendChild(top);
      var meta = when(ev.ts) + " · " + ev.duration;
      if (ev.release && ev.release !== "-") { meta += " · " + ev.release; }
      row.appendChild(el("p", "muted", meta));
      if (ev.detail) { row.appendChild(el("p", "muted mono", ev.detail)); }
      log.appendChild(row);
    });
    lastEventTs = newest;

    var audit = $("audit");
    audit.textContent = "";
    if (!data.audit.length) { audit.appendChild(el("p", "muted empty", "No changes yet.")); }
    data.audit.forEach(function (a) {
      var row = el("div", "audit-row row between");
      row.appendChild(el("span", "mono", when(a.ts) + " · " + a.action + (a.app !== "-" ? " · " + a.app : "")));
      row.appendChild(el("span", a.result === "ok" ? "result-ok" : "result-bad", a.result));
      audit.appendChild(row);
    });
  }

  // ---------------------------------------------------------------- GitHub repos (P3b)
  // The secret is shown once, in its own box, and is never kept by a refresh. The list
  // redraws every 30 s, so the box lives outside it.
  var HOOK_ID_RE = /^[0-9a-f]{32}$/;
  var REPO_RE = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9_-][A-Za-z0-9_.-]{0,99}$/;   // the server checks again
  var hookBase = null;
  var addOpen = false;        // the connect form is open because the user asked for it
  var tokenDecided = false;   // the token section opens itself once, on the first load

  function showSecret(hookId, secret, base, repoName) {
    if (!HOOK_ID_RE.test(hookId) || typeof secret !== "string") { return; }
    hookBase = typeof base === "string" && /^https:\/\//.test(base) ? base : hookBase;
    $("sb-url").textContent = (hookBase || "") + "/webhook/" + hookId;
    $("sb-secret").textContent = secret;
    $("sb-repo").textContent = typeof repoName === "string" ? "For " + repoName : "";
    $("sb-body").hidden = false;
    $("sb-collapsed").hidden = true;
    $("secret-box").hidden = false;
    $("secret-box").scrollIntoView({ behavior: "smooth", block: "center" });
  }
  // Removes the one-time secret from the page (the clipboard keeps its own copy until overwritten).
  function clearSecret() {
    $("sb-secret").textContent = "";
    $("sb-url").textContent = "";
    $("sb-repo").textContent = "";
    $("sb-body").hidden = false;
    $("sb-collapsed").hidden = true;
    $("secret-box").hidden = true;
  }
  // True while a secret is on screen and has not been copied yet.
  function secretPending() {
    return !$("secret-box").hidden && !$("sb-body").hidden;
  }
  // The big button copies the address and the secret together, then the box collapses and the secret leaves the page.
  $("sb-copy").addEventListener("click", function () {
    if (!navigator.clipboard) {
      say("copy is not available in this browser: select the address and secret and copy them by hand", true);
      return;
    }
    var text = $("sb-url").textContent + "\n" + $("sb-secret").textContent;
    navigator.clipboard.writeText(text).then(function () {
      $("sb-secret").textContent = "";
      $("sb-url").textContent = "";
      $("sb-body").hidden = true;
      $("sb-collapsed").hidden = false;
    }, function () { say("copy failed: select the address and secret and copy them by hand", true); });
  });
  $("sb-done").addEventListener("click", clearSecret);

  // The connect form is shown only when the user asks for it, or when no repo is connected yet.
  function showConnect(open) {
    $("connect-panel").hidden = !open;
    $("add-repo").hidden = open;
  }
  $("add-repo").addEventListener("click", function () { addOpen = true; showConnect(true); });
  $("cancel-repo").addEventListener("click", function () { addOpen = false; showConnect(false); });

  // While one of these requests runs, its buttons are off, so a double click cannot send it twice.
  var busy = false;
  function setBusy(on) {
    busy = on;
    var buttons = document.querySelectorAll("#repos button, #connect-form button, #token-form button");
    for (var i = 0; i < buttons.length; i++) { buttons[i].disabled = on; }
  }

  // One request that may answer with a new secret (connect, rotate) or nothing (token, disconnect).
  function gitAction(path, body, okText, onOk, repoName) {
    if (busy) { return; }
    setBusy(true);
    api("POST", path, body).then(function (res) {
      setBusy(false);
      if (res.status === 401) { showLogin(true); say("please sign in again", true); return; }
      if (res.status !== 200) { say(res.data.error || ("failed (" + res.status + ")"), true); return; }
      say(res.data.replaces_existing === true
        ? okText + ". Note: an app with this name already exists; the first push replaces what is live (Roll back still works)."
        : okText);
      if (res.data.secret) { showSecret(res.data.hook_id, res.data.secret, res.data.hook_base, repoName); }
      if (onOk) { onOk(); }
      load();
    }, function () { setBusy(false); say("could not reach the admin service", true); });
  }

  function rotateRepo(repo) {
    if (!window.confirm("Make a new secret for " + repo + "? The old one stops working at once; update GitHub's webhook.")) { return; }
    if (secretPending() && !window.confirm("A secret that was not copied yet is still on screen. Replace it?")) { return; }
    gitAction("/api/repos/rotate", { repo: repo }, "new secret for " + repo + " (shown below, once)", null, repo);
  }
  function disconnectRepo(repo) {
    if (!window.confirm("Disconnect " + repo + "? Its pushes are refused from now on, and pushes still waiting are dropped. " +
        "The app and its previews stay on this PC (remove previews with deploy.py remove).")) { return; }
    gitAction("/api/repos/disconnect", { repo: repo }, "disconnected " + repo);
  }

  $("token-form").addEventListener("submit", function (event) {
    event.preventDefault();   // JSON only, never a form post
    // The field is cleared only after the server has saved the token, so a failed save keeps it.
    gitAction("/api/token", { token: $("token").value }, "token saved", function () { $("token").value = ""; });
  });

  $("connect-form").addEventListener("submit", function (event) {
    event.preventDefault();
    var body = {
      repo: $("c-repo").value.trim(),
      app: $("c-app").value.trim(),
      branch: $("c-branch").value.trim() || "main",
      subdir: $("c-subdir").value.trim(),
      kind: $("c-kind").value,
      previews: $("c-previews").checked
    };
    if (!REPO_RE.test(body.repo)) { say("the repo must look like owner/name", true); return; }
    if (!NAME_RE.test(body.app)) { say("the app name may use only a-z, 0-9 and '-' (1 to 40 characters)", true); return; }
    if (secretPending() && !window.confirm("A secret that was not copied yet is still on screen. Replace it?")) { return; }
    gitAction("/api/repos/connect", body, "connected " + body.repo + ": its address and secret are shown below, once",
      function () {
        // Done: clear the form and fold it away, and point at the new box.
        $("connect-form").reset();
        $("c-branch").value = "main";
        addOpen = false;
        showConnect(false);
        $("secret-box").scrollIntoView({ behavior: "smooth", block: "center" });
      }, body.repo);
  });

  function renderGithub(data) {
    hookBase = typeof data.hook_base === "string" ? data.hook_base : null;
    $("token-status").textContent = data.token || "unknown";
    if (!tokenDecided) {
      // Open the token section only while no token is saved (a refresh never reopens it).
      $("token-section").open = data.token !== "set";
      tokenDecided = true;
    }
    var list = $("repos");
    list.textContent = "";
    var repos = data.repos || [];
    if (!repos.length) { list.appendChild(el("p", "muted empty", "No repos connected yet.")); }
    // With no repo yet, the connect form is the first thing to fill in; otherwise it stays folded.
    $("cancel-repo").hidden = repos.length === 0;
    showConnect(addOpen || repos.length === 0);
    repos.forEach(function (r) {
      var row = el("div", "audit-row stack");
      row.appendChild(el("span", "mono", r.repo + " → " + r.app));
      row.appendChild(el("p", "muted small", r.branch + " · " + (r.subdir || "root") + " · " + r.kind +
        (r.previews ? " · previews on" : "")));
      var actions = el("div", "actions");
      var rot = el("button", "pill", "New secret");
      rot.type = "button";
      rot.addEventListener("click", function () { rotateRepo(r.repo); });
      var dis = el("button", "pill", "Disconnect");
      dis.type = "button";
      dis.addEventListener("click", function () { disconnectRepo(r.repo); });
      actions.appendChild(rot);
      actions.appendChild(dis);
      row.appendChild(actions);
      list.appendChild(row);
    });
  }

  // ---------------------------------------------------------------- uploads (P4)
  // The zip goes as the request body itself (no form encoding). The server checks everything
  // again; these checks only save a pointless 50 MB send.
  var MAX_UPLOAD = 50 * 1024 * 1024;
  var knownApps = [];
  var uploading = false;

  $("upload-form").addEventListener("submit", function (event) {
    event.preventDefault();
    if (uploading) { return; }
    var app = $("u-app").value.trim();
    var file = $("u-file").files[0];
    if (!NAME_RE.test(app) || app.indexOf("--") >= 0) {
      say("the app name may use only a-z, 0-9 and '-' (1 to 40 characters, no '--')", true);
      return;
    }
    if (!file) { say("pick a .zip file", true); return; }
    if (file.size === 0) { say("that file is empty", true); return; }
    if (file.size > MAX_UPLOAD) { say("the zip is larger than 50 MB", true); return; }
    if (knownApps.indexOf(app) >= 0 &&
        !window.confirm("Replace what is live on " + app + " with this zip? Roll back still works.")) { return; }
    uploading = true;
    var button = $("u-send");
    button.disabled = true;
    button.textContent = "Uploading...";
    say("uploading " + app + "...");
    fetch("/api/upload/" + encodeURIComponent(app), {
      method: "POST", credentials: "same-origin", cache: "no-store",
      headers: { "Content-Type": "application/zip", "X-CSRF-Token": csrf || "" },
      body: file
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (data) {
        return { status: r.status, data: data || {} };
      });
    }).then(function (res) {
      if (res.status === 401) { showLogin(true); say("please sign in again", true); return; }
      if (res.status !== 200) {
        var why = app + ": " + (res.data.error || ("upload failed (" + res.status + ")"));
        say(why, true);
        toast(why, true);
        holdMood("worried", "I couldn't serve that zip: " + (res.data.error || "the server refused it") + ".", 8000);
        return;
      }
      say(app + ": uploaded and live (release " + res.data.release + ")" +
        (res.data.warning ? ". " + res.data.warning : ""));
      toast(app + " is live from your zip");
      holdMood("happy", "Fresh " + app + " is live from your zip! Roll back still works.", 8000);
      $("upload-form").reset();
      load();
    }, function () {
      // The connection broke before the answer came. The server may still have finished,
      // so the page re-reads what is live instead of guessing.
      say("the connection broke before the answer came: the upload may still have gone live; check Recent deploys", true);
      load();
    }).then(function () {
      uploading = false;
      button.disabled = false;
      button.textContent = "Upload";
    });
  });

  // Refreshes can overlap. Only the newest answer is shown, so an old one that arrives late cannot undo a change.
  var loadSent = 0;
  var loadShown = 0;
  function load() {
    var mine = ++loadSent;
    api("GET", "/api/state").then(function (res) {
      if (mine < loadShown) { return; }
      loadShown = mine;
      if (csrf === null) { return; }   // signed out while this answer was on its way: show nothing
      if (res.status === 401) { showLogin(true); return; }
      if (res.status !== 200) { say("could not load (" + res.status + ")", true); return; }
      render(res.data);
      renderGithub(res.data);
    }, function () { say("could not reach the admin service", true); });
  }

  api("GET", "/api/session").then(function (res) {
    if (res.data.logged_in && typeof res.data.csrf === "string") { csrf = res.data.csrf; showMain(); }
    else { showLogin(res.data.password_set); }
  }, function () { say("could not reach the admin service", true); });
})();
