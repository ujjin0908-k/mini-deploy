# The dashboard, explained

Open [`index.html`](index.html) in a browser for the visual guide (diagrams, an annotated drawing,
a real `data.json`). This is the short text version.

## What it is

A page that shows every deployed app, its releases and what just happened. It has no server of
its own: `scripts/dashboard.py` writes one small file, `data.json`, and the page draws it.

```
/sites/<app>/releases + current link ─┐
                                      ├─> scripts/dashboard.py ─> data.json ─> deploy.py (app "dashboard") ─> Caddy ─> browser
/var/log/mini-deploy.log ─────────────┘
```

It runs after every deploy, build and webhook job, and does nothing if only the timestamp changed.

## The six parts of the page

| # | Part | Comes from |
|---|---|---|
| 1 | Overall status chip | `attention[]` |
| 2 | App name and live / on hold chip | `apps[].name`, `apps[].held` |
| 3 | Live release and commit | `apps[].live`, `apps[].deployed` |
| 4 | Release dots (live one ringed) | `apps[].releases[]` |
| 5 | A rollback / unhold command to copy | built from the app name |
| 6 | Recent activity | `events[]` |

## Why it is safe

- Read-only: no endpoint changes anything. You run the copied command yourself.
- Log text is shown with `textContent` only, never as HTML.
- Log lines that do not match the exact format are dropped.
- A failure shows only a short reason ("build failed", "timed out", "refused: unsafe file") and the commit id. The full error stays in `/var/log/mini-deploy.log` on the PC.
- A Content-Security-Policy tells the browser to run only the page's own script.
- No outside requests: no fonts, scripts or images from elsewhere.
- Limit: Caddy is bound to your Wi-Fi address, so everyone on that network can see it.

## A bug worth knowing

The first version listed every app, itself included. Each refresh changed the dashboard's own
"live release", so the next refresh always looked different and deployed again, forever. It now
leaves itself out.

## Files

| File | Job |
|---|---|
| `scripts/dashboard.py` | collects data, writes `data.json`, deploys it |
| `web/dashboard/index.html` | structure |
| `web/dashboard/app.js` | fetches `data.json`, draws the cards |
| `web/dashboard/style.css` | copy of the shared theme |

## Try it

```bash
python3 scripts/dashboard.py --force         # rebuild and redeploy
python3 scripts/dashboard.py                 # "dashboard is up to date (nothing changed)"
python3 scripts/dashboard.py --out /tmp/dash # write the site to a folder, no deploy
```

Then open `http://dashboard.localhost:8080`.
