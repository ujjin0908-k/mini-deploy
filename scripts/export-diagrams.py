#!/usr/bin/env python3
"""Export the drawings from the *-explained pages as standalone .svg files.

    export-diagrams.py                 write them into the Obsidian vault (Explained/images)
    export-diagrams.py --out DIR       write them somewhere else (tests)

The drawings in the HTML pages take their colours from the page's stylesheet. An image
on its own (in Obsidian, or in an <img>) has no stylesheet, so each exported file gets
its own <style> block with every colour written out, and a cream background so it reads
in a dark Obsidian theme too. Run it again whenever a drawing changes. Standard library only.
"""

import argparse
import html
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
VAULT_IMAGES = Path("/mnt/c/Users/indra/OneDrive/Desktop/obsidian/skeloton/ai_workspace_skeleton"
                    "/Obsidian/Projects/Mini Deploy/Explained/images")

# page -> names for its drawings, in the order they appear on the page
PAGES = {
    "dashboard-explained/index.html": ["dashboard-anatomy", "dashboard-data-flow", "dashboard-refresh-loop"],
    "demo-site-explained/index.html": ["demo-site-journey", "demo-site-releases"],
    "landing-explained/index.html": ["landing-layout", "landing-deploy-compare", "landing-glass-recipe",
                                     "landing-theme-sync"],
}
XML_ENTITIES = {"lt", "gt", "amp", "quot", "apos"}


def css_variables():
    """--name: value pairs from the theme's :root block."""
    css = (REPO / "web/theme/pink.css").read_text(encoding="utf-8")
    return dict(re.findall(r"--([a-z-]+):\s*([^;]+);", css))


def resolve(text, variables):
    """Replace var(--x) with its value, repeatedly (a value may use another variable)."""
    for _ in range(5):
        text = re.sub(r"var\(--([a-z-]+)\)", lambda m: variables.get(m.group(1), m.group(0)).strip(), text)
    return text


def svg_rules(variables):
    """The `svg .something { ... }` rules from explain.css, with colours written out."""
    css = (REPO / "web/theme/explain.css").read_text(encoding="utf-8")
    rules = [line.strip() for line in css.splitlines() if line.strip().startswith("svg .")]
    return resolve("\n".join(rules), variables)


def xml_safe(svg):
    """HTML allows names like &ldquo; that XML does not; turn them into numbers."""
    def fix(m):
        name = m.group(1)
        if name in XML_ENTITIES:
            return m.group(0)
        char = html.unescape(m.group(0))
        return m.group(0) if char == m.group(0) else f"&#{ord(char)};"
    return re.sub(r"&([A-Za-z][A-Za-z0-9]*);", fix, svg)


UNSAFE_SVG = re.compile(r"<script|<foreignObject|<!DOCTYPE|<!ENTITY|\son[a-z]+\s*=|javascript:", re.I)


def standalone(svg, style):
    # These files land in the Obsidian vault. A drawing has no business running code.
    bad = UNSAFE_SVG.search(svg)
    if bad:
        raise SystemExit(f"error: a drawing contains {bad.group(0)!r}; refusing to export it")
    view = re.search(r'viewBox="0 0 (\d+) (\d+)"', svg)
    width, height = view.group(1), view.group(2)
    svg = xml_safe(svg)
    svg = svg.replace("<svg ", f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" ', 1)
    background = f'<rect x="0" y="0" width="{width}" height="{height}" rx="24" fill="#FFF8F5"/>'
    # the style and the background go right after the opening tag, under everything else
    svg = re.sub(r"(<svg\b[^>]*>)", lambda m: f"{m.group(1)}\n<style>\n{style}\n</style>\n{background}", svg, count=1)
    ET.fromstring(svg)  # raises if the result is not well-formed XML
    return svg


def export(out_dir):
    variables = css_variables()
    style = svg_rules(variables)
    out_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for page, names in PAGES.items():
        text = (REPO / page).read_text(encoding="utf-8")
        svgs = re.findall(r"<svg\b.*?</svg>", text, flags=re.S)
        if len(svgs) != len(names):
            raise SystemExit(f"error: {page} has {len(svgs)} drawings but {len(names)} names; update PAGES")
        for name, svg in zip(names, svgs):
            path = out_dir / f"{name}.svg"
            path.write_text(standalone(svg, style), encoding="utf-8")
            written.append(path.name)
    return written


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default=str(VAULT_IMAGES))
    args = parser.parse_args()
    written = export(Path(args.out))
    print(f"wrote {len(written)} drawings to {args.out}")
    for name in written:
        print(f"  {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
