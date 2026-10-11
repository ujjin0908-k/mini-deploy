# The landing page, explained

Open [`index.html`](index.html) in a browser for the visual guide (a section map, the deploy
comparison, how the glass is made, the palette). This is the short text version.

## What it is

The simplest of the three sites: one HTML page and a stylesheet, deployed as it is. No build step.

```
demo-site:    source ─> Docker build ─> dist/ ─> deploy.py ─> live
landing page: web/landing/ ───────────────────> deploy.py ─> live
```

The checks, the release folder and the atomic flip are the same for both.

## The layout

| # | Block | Idea |
|---|---|---|
| 1 | Hero | what it is, and two next steps |
| 2 | Flow | five steps from `git push` to live |
| 3 | Guarantees | atomic flip, a broken build stays off, instant rollback, signed pushes only |
| 4 | Stages | the stages as a timeline, in the one dark card |

## How the look is made

Glass card = pink gradient background + a soft sphere + white at about 58% with a blur +
a thin white border and a soft pink shadow. Where a browser cannot blur, the card is more opaque.

| Token | Hex | Used for |
|---|---|---|
| blush | `#FBE4EA` | surface |
| petal | `#F7C6D4` | surface |
| rose | `#E98FA9` | decoration |
| rose strong | `#C45A7E` | big shapes only |
| deep | `#A8416A` | links, small accents |
| ink | `#2A2227` | body text |
| muted | `#6E5A65` | captions |
| cream | `#FFF8F5` | page end |

Rules: one dark card per page; pills for actions, chips for state, glass for grouping; pink is a
surface, not a small-text colour; nothing moves if the device asks to reduce motion. Body text is
checked at 4.5:1 contrast or better.

## One theme, many copies

`web/theme/pink.css` is the only source. `scripts/sync-theme.sh` copies it next to every site and
guide as `style.css`, and `scripts/test-sites.sh` fails if a copy is stale.

## Files

| File | Job |
|---|---|
| `web/landing/index.html` | the whole page |
| `web/landing/style.css` | copy of the shared theme |
| `web/theme/pink.css` | the look |
| `web/theme/explain.css` | extra pieces for the guide pages |
| `scripts/sync-theme.sh` | copies the theme |

## Try it

```bash
python3 scripts/deploy.py deploy mini-deploy web/landing
bash scripts/sync-theme.sh
bash scripts/test-sites.sh
```

Then open `http://mini-deploy.localhost:8080`.
