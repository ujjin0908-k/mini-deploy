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

The background is a "pigment mist": a warm paper base, six soft clouds of colour (pink, rose,
butter yellow, sage, misty blue, lilac) that drift very slowly, and fine film grain made in the page.
Glass card = that background + white at about 46% with a blur + a thin white border and a soft
shadow, so the mist tints the card. Where a browser cannot blur, the card is more opaque.

| Token | Hex | Used for |
|---|---|---|
| paper | `#F3EEE9` | the base |
| mist pink / rose / butter / sage / blue / lilac | `#F4AEC2` `#F2B2C5` `#F1E58F` `#B2C79C` `#B9D0DE` `#D6C0E5` | background clouds only |
| deep | `#973A5F` | links, small accents |
| ink | `#2A2227` | body text |
| muted | `#5F4D57` | captions |
| cream | `#FFF8F5` | text on the dark card |

Rules: one dark card per page; pills for actions, chips for state, glass for grouping; mist colours
are background only; the mist stays still if the device asks to reduce motion. Text is checked at
4.5:1 contrast or better over the strongest patch of every mist colour.

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
