"use strict";
// Renders data.json. Everything from the data goes in with textContent, never as
// HTML: deploy-log lines contain build output, which must be treated as untrusted.
(function () {
  var REFRESH_MS = 30000;
  var NAME_RE = /^[a-z0-9-]{1,40}$/;
  // Same shapes as the Caddyfile: <app>.localhost or <app>.<ip-with-dashes>.nip.io, optional port
  var HOST_RE = /^[a-z0-9-]{1,40}\.(localhost|[0-9]{1,3}-[0-9]{1,3}-[0-9]{1,3}-[0-9]{1,3}\.nip\.io)(:[0-9]+)?$/;

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

  function copyText(text, button, codeNode) {
    var label = button.textContent;
    function say(message) {
      button.textContent = message;
      setTimeout(function () { button.textContent = label; }, 2000);
    }
    function manual() {
      // Last resort: select the command so Ctrl+C / long-press works, and say so.
      var range = document.createRange();
      range.selectNodeContents(codeNode);
      var selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      say("Selected: copy it");
    }
    function fallback() {
      // navigator.clipboard needs HTTPS; this page is plain HTTP on the home network.
      var box = document.createElement("textarea");
      var copied = false;
      box.value = text;
      box.setAttribute("readonly", "");
      box.style.cssText = "position:fixed;opacity:0;top:0;left:0";
      document.body.appendChild(box);
      box.select();
      try { copied = document.execCommand("copy"); } catch (e) { copied = false; }
      document.body.removeChild(box);
      if (copied) { say("Copied"); } else { manual(); }
    }
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(function () { say("Copied"); }, fallback);
    } else {
      fallback();
    }
  }

  function command(text) {
    var box = el("div", "cmd");
    var code = el("code", null, text);
    box.appendChild(code);
    var button = el("button", "pill", "Copy");
    button.type = "button";
    button.addEventListener("click", function () { copyText(text, button, code); });
    box.appendChild(button);
    return box;
  }

  // The build logs page only answers this PC (Caddy checks the connection comes from
  // 127.0.0.1), so only offer the link when this page itself was opened on this PC.
  var ON_THIS_PC = /^[a-z0-9-]{1,40}\.localhost$/.test(location.hostname);
  function logsLink(app, text) {
    var link = el("a", null, text);
    var url = new URL(location.href);   // same scheme and port as this page
    url.hostname = "logs.localhost";
    url.pathname = "/";
    url.search = "";
    url.hash = app || "";
    link.href = url.toString();
    return link;
  }

  function appCard(app, needsLook) {
    var card = el("article", "glass stack");
    var head = el("div", "row between");
    head.appendChild(el("h3", "app-name", app.name));
    var state = app.held ? "held" : "ok";
    var chip = el("span", "chip", app.held ? "on hold" : "live");
    chip.setAttribute("data-state", state);
    head.appendChild(chip);
    card.appendChild(head);

    if (app.preview_of && NAME_RE.test(app.name) && NAME_RE.test(app.preview_of)) {
      // A preview lives at its own address: same host as this page, other first label.
      // Only for the two address shapes Caddy serves; anything else gets no link.
      var line = el("p", "muted", "preview of " + app.preview_of);
      var host = location.host;
      if (HOST_RE.test(host)) {
        line.appendChild(document.createTextNode(" · "));
        var link = el("a", null, "open preview");
        link.href = location.protocol + "//" + app.name + host.slice(host.indexOf("."));
        line.appendChild(link);
      }
      card.appendChild(line);
    }

    card.appendChild(el("p", "muted mono", app.live ? "release " + app.live : "nothing live"));
    if (needsLook && ON_THIS_PC && NAME_RE.test(app.name)) {
      var why = el("p", "muted", "last run failed · ");
      why.appendChild(logsLink(app.name, "view build log"));
      card.appendChild(why);
    }
    if (app.deployed) {
      card.appendChild(el("p", "muted", "commit " + app.deployed));
    }

    var dots = el("ul", "dots");
    dots.setAttribute("aria-label", app.releases.length + " releases, newest last");
    app.releases.forEach(function (r) {
      var dot = el("li", r.live ? "dot live" : "dot");
      dot.title = r.id + (r.live ? " (live)" : "");
      dots.appendChild(dot);
    });
    card.appendChild(dots);
    if (app.total > app.releases.length) {
      card.appendChild(el("p", "muted", "showing the newest " + app.releases.length + " of " + app.total));
    }

    if (NAME_RE.test(app.name)) {
      card.appendChild(command("python3 scripts/deploy.py rollback " + app.name));
      if (app.held) {
        card.appendChild(command("python3 scripts/deploy.py unhold " + app.name));
      }
      if (app.preview_of) {
        card.appendChild(command("python3 scripts/deploy.py remove " + app.name));
      }
    }
    return card;
  }

  function render(data) {
    var overall = document.getElementById("overall");
    var needs = (data.attention || []).length > 0;
    overall.setAttribute("data-state", needs ? "attention" : "ok");
    overall.textContent = needs ? "needs a look" : "all good";
    document.getElementById("attention").textContent =
      needs ? "last run failed: " + data.attention.join(", ") : "";
    document.getElementById("updated").textContent = "updated " + when(data.generated_at);

    var apps = document.getElementById("apps");
    apps.textContent = "";
    if (!data.apps.length) {
      apps.appendChild(el("p", "muted empty", "No apps yet. Deploy one and it shows up here."));
    }
    var attention = data.attention || [];
    data.apps.forEach(function (app) { apps.appendChild(appCard(app, attention.indexOf(app.name) >= 0)); });
    var logsSlot = document.getElementById("logs-link");
    logsSlot.textContent = "";
    if (ON_THIS_PC) { logsSlot.appendChild(logsLink(null, "build logs (this PC only)")); }

    var log = document.getElementById("log");
    log.textContent = "";
    if (!data.events.length) {
      log.appendChild(el("p", "muted empty", "Nothing has happened yet."));
    }
    data.events.slice().reverse().forEach(function (ev) {
      var row = el("div", "log-row");
      var top = el("div", "row between");
      top.appendChild(el("span", "mono", ev.app + " · " + ev.action));
      var good = ev.result === "ok" || ev.result === "queued" || ev.result === "same" ||
        ev.result === "removed";
      top.appendChild(el("span", good ? "result-ok" : "result-bad", ev.result));
      row.appendChild(top);
      var meta = when(ev.ts) + " · " + ev.duration;
      if (ev.release && ev.release !== "-") { meta += " · " + ev.release; }
      row.appendChild(el("p", "muted", meta));
      if (ev.detail) { row.appendChild(el("p", "muted mono", ev.detail)); }
      log.appendChild(row);
    });
  }

  function load() {
    fetch("data.json", { cache: "no-store" })
      .then(function (r) { if (!r.ok) { throw new Error("HTTP " + r.status); } return r.json(); })
      .then(render)
      .catch(function (err) {
        var overall = document.getElementById("overall");
        overall.setAttribute("data-state", "attention");
        overall.textContent = "could not load data";
        document.getElementById("updated").textContent = String(err.message || err);
      });
  }

  load();
  setInterval(load, REFRESH_MS);
})();
