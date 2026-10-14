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
      if (!navigator.clipboard) { say("copy is not available in this browser: select the text and copy it by hand", true); return; }
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

    knownApps = data.apps.map(function (a) { return a.name; });
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
      if (res.status !== 200) { say(app + ": " + (res.data.error || ("upload failed (" + res.status + ")")), true); return; }
      say(app + ": uploaded and live (release " + res.data.release + ")" +
        (res.data.warning ? ". " + res.data.warning : ""));
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
