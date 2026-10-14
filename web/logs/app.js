"use strict";
// Renders data/index.json and, on click, one log file. Log text is build output, which
// is untrusted: everything goes in with textContent, never as HTML.
(function () {
  var NAME_RE = /^[a-z0-9-]{1,40}$/;
  var FILE_RE = /^[0-9]{8}-[0-9]{6}(-[0-9]{1,3})?-(ok|fail)\.log$/;

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) { node.className = cls; }
    if (text !== undefined && text !== null) { node.textContent = String(text); }
    return node;
  }

  function when(iso) {
    var d = new Date(iso);
    return isNaN(d.getTime()) ? String(iso || "?") : d.toLocaleString([], {
      month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit"
    });
  }

  function show(app, build, button) {
    if (!NAME_RE.test(app) || !FILE_RE.test(build.file)) { return; }
    var current = document.querySelector('.build[aria-current="true"]');
    if (current) { current.removeAttribute("aria-current"); }
    button.setAttribute("aria-current", "true");
    var viewer = document.getElementById("viewer");
    var text = document.getElementById("view-text");
    document.getElementById("view-title").textContent = app + " · " + build.result;
    document.getElementById("view-meta").textContent = when(build.started) + " · " + build.duration +
      (build.commit ? " · commit " + build.commit : "") + (build.release ? " · release " + build.release : "");
    text.textContent = "loading…";
    viewer.hidden = false;
    fetch("data/" + app + "/" + build.file, { cache: "no-store" })
      .then(function (r) { if (!r.ok) { throw new Error("HTTP " + r.status); } return r.text(); })
      .then(function (body) {
        text.textContent = body;
        text.scrollTop = text.scrollHeight;  // the end is where a build says how it went
        viewer.scrollIntoView({ behavior: "smooth", block: "start" });
      })
      .catch(function (err) { text.textContent = "could not load the log: " + (err.message || err); });
  }

  function card(app) {
    var box = el("article", "glass stack");
    box.id = "app-" + app.name;
    box.appendChild(el("h3", null, app.name));
    var list = el("ul", "builds");
    app.builds.forEach(function (b) {
      var item = el("li");
      var button = el("button", "build");
      button.type = "button";
      button.appendChild(el("span", "when", when(b.started)));
      button.appendChild(el("span", b.result === "ok" ? "muted" : "bad", b.result === "ok" ? "ok" : "failed"));
      button.appendChild(el("span", "muted mono", b.duration));
      if (b.commit) { button.appendChild(el("span", "muted mono", b.commit)); }
      button.addEventListener("click", function () { show(app.name, b, button); });
      item.appendChild(button);
      list.appendChild(item);
    });
    box.appendChild(list);
    return box;
  }

  function render(data) {
    document.getElementById("updated").textContent = "updated " + when(data.generated_at);
    var apps = document.getElementById("apps");
    apps.textContent = "";
    var shown = (data.apps || []).filter(function (a) { return NAME_RE.test(a.name); });
    if (!shown.length) {
      apps.appendChild(el("p", "muted empty", "No builds yet. Build an app and its log shows up here."));
      return;
    }
    shown.forEach(function (app) { apps.appendChild(card(app)); });
    // logs.localhost/#demo-site (the admin page links like that): open that app's newest build.
    var wanted = decodeURIComponent(location.hash.slice(1));
    if (NAME_RE.test(wanted)) {
      var app = shown.filter(function (a) { return a.name === wanted; })[0];
      var first = document.querySelector("#app-" + wanted + " .build");
      if (app && first) { show(app.name, app.builds[0], first); }
    }
  }

  fetch("data/index.json", { cache: "no-store" })
    .then(function (r) { if (!r.ok) { throw new Error("HTTP " + r.status); } return r.json(); })
    .then(render)
    .catch(function (err) {
      document.getElementById("updated").textContent = "could not load the list: " + (err.message || err);
    });
})();
