"use strict";
// mini-deploy admin page. Talks only to its own server (/api/...). Everything that comes
// back goes in with textContent, never as HTML: deploy-log lines can hold build output.
(function () {
  var REFRESH_MS = 30000;
  var NAME_RE = /^[a-z0-9-]{1,40}$/;
  // The only two address shapes a link may have (checked again here, not trusted).
  var PC_URL_RE = /^http:\/\/[a-z0-9-]{1,40}\.localhost:8080\/$/;
  var PHONE_URL_RE = /^http:\/\/[a-z0-9-]{1,40}\.[0-9]{1,3}(-[0-9]{1,3}){3}\.nip\.io:8080\/$/;
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
    $("main").hidden = true;
    $("session-buttons").hidden = true;
    $("login").hidden = false;
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
    api("POST", "/api/action", { action: action, app: app, expect: live }).then(function (res) {
      button.disabled = false;
      if (res.status === 200) { say(app + ": " + action + " done"); }
      else if (res.status === 401) { showLogin(true); say("please sign in again", true); return; }
      else { say(app + ": " + (res.data.error || (action + " failed (" + res.status + ")")), true); }
      load();
    }, function () { button.disabled = false; say("could not reach the admin service", true); });
  }

  function copyButton(text) {
    var button = el("button", "pill", "Copy");
    button.type = "button";
    button.addEventListener("click", function () {
      navigator.clipboard.writeText(text).then(function () {
        button.textContent = "Copied";
        setTimeout(function () { button.textContent = "Copy"; }, 2000);
      }, function () { button.textContent = "Select and copy"; });
    });
    return button;
  }

  // ---------------------------------------------------------------- rendering
  function appCard(app, needsLook, atHome) {
    var card = el("article", "glass stack");
    var head = el("div", "row between");
    head.appendChild(el("h3", "app-name", app.name));
    var chip = el("span", "chip", app.held ? "on hold" : (app.live ? "live" : "nothing live"));
    chip.setAttribute("data-state", app.held ? "held" : (needsLook ? "attention" : "ok"));
    head.appendChild(chip);
    card.appendChild(head);

    if (app.preview_of) { card.appendChild(el("p", "muted", "preview of " + app.preview_of)); }
    card.appendChild(el("p", "muted mono", app.live ? "release " + app.live : "nothing live"));
    if (app.deployed) { card.appendChild(el("p", "muted", "commit " + app.deployed)); }
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

  function render(data) {
    var attention = data.attention || [];
    var needs = attention.length > 0;
    $("overall").setAttribute("data-state", needs ? "attention" : "ok");
    $("overall").textContent = needs ? "needs a look" : "all good";
    $("updated").textContent = "updated " + when(data.generated_at);
    $("home-note").textContent = data.at_home
      ? "This PC is on your home Wi-Fi: the phone addresses below work there."
      : "This PC is not on your home Wi-Fi right now, so phone addresses are hidden.";

    var apps = $("apps");
    apps.textContent = "";
    if (!data.apps.length) { apps.appendChild(el("p", "muted empty", "No apps yet.")); }
    data.apps.forEach(function (app) {
      apps.appendChild(appCard(app, attention.indexOf(app.name) >= 0, data.at_home));
    });

    var log = $("log");
    log.textContent = "";
    if (!data.events.length) { log.appendChild(el("p", "muted empty", "Nothing has happened yet.")); }
    data.events.slice().reverse().forEach(function (ev) {
      var row = el("div", "log-row");
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

  function load() {
    api("GET", "/api/state").then(function (res) {
      if (res.status === 401) { showLogin(true); return; }
      if (res.status !== 200) { say("could not load (" + res.status + ")", true); return; }
      render(res.data);
    }, function () { say("could not reach the admin service", true); });
  }

  api("GET", "/api/session").then(function (res) {
    if (res.data.logged_in && typeof res.data.csrf === "string") { csrf = res.data.csrf; showMain(); }
    else { showLogin(res.data.password_set); }
  }, function () { say("could not reach the admin service", true); });
})();
