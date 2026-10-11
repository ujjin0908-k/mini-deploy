# The demo site, explained

Open [`index.html`](index.html) in a browser for the visual guide (a journey diagram, a
before/after of the page, the build box rules). This is the short text version.

## What it is

A tiny site whose job is to prove the whole pipeline: its source is built inside a locked-down
Docker box and only the finished folder goes live. The server has no Node installed.

```
examples/static-site ─copy─> /var/tmp ─> [ Docker box: npm ci ─> npm run build ] ─> dist/
dist/ ─> deploy.py checks ─> releases/<id> ─> current flips ─> Caddy serves it
```

A failure anywhere before the last step leaves the live site untouched.

## The stamp: before and after

Source (`examples/static-site/src/index.html`):

```html
<h1>static-site, built with __BUILT_WITH__</h1>
<p class="muted">built at __BUILT_AT__</p>
```

After the build (`dist/index.html`):

```html
<h1>static-site, built with node v22.23.3</h1>
<p class="muted">built at 2026-10-11T15:37:34.896Z</p>
```

Only the build step can fill the placeholders, so a Node version on the live page proves it was
built in the container. A visible `__BUILT_WITH__` means the source was deployed by mistake.

## Releases: keep a few, move one arrow

Each deploy adds a folder under `releases/` and removes the oldest beyond five. `current` is a
symbolic link that Caddy serves; replacing it is one filesystem step. A rollback only moves that
link one step back, so nothing is rebuilt or deleted and you can roll forward again.

## Files

| File | Job |
|---|---|
| `examples/static-site/package.json` | build command and wanted Node version |
| `examples/static-site/package-lock.json` | exact dependencies for `npm ci` |
| `examples/static-site/build.js` | stamps `index.html`, copies the rest into `dist/` |
| `examples/static-site/src/index.html` | the page with two placeholders |
| `examples/static-site/src/style.css` | copy of the shared theme |
| `scripts/build.py` | runs the Docker box and hands `dist/` to the deploy |

## What the build box is not allowed to do

Run as root, write to its own disk, use special powers, run away (1 GB, 2 CPUs, 512 processes,
10 minutes), see `.env` files, or run npm install scripts.

## Try it

```bash
python3 scripts/build.py build demo-site examples/static-site
python3 scripts/deploy.py list demo-site
python3 scripts/deploy.py rollback demo-site
```

Then open `http://demo-site.localhost:8080` and look for the Node version in the heading.
