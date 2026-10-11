// The "build step": turn src/ into dist/. Real apps run Vite, Astro, etc. here.
// It stamps the Node version into the page, so a visitor can see it was built
// inside the container and not just copied.
const fs = require("fs");
const path = require("path");

const srcDir = path.join(__dirname, "src");
const outDir = path.join(__dirname, "dist");
// Only web files are published. Editor leftovers (*.bak, *~, Thumbs.db) and dotfiles stay out.
const WEB_FILES = new Set([".html", ".css", ".js", ".svg", ".png", ".jpg", ".jpeg", ".webp", ".gif", ".ico", ".txt"]);
fs.mkdirSync(outDir, { recursive: true });

for (const name of fs.readdirSync(srcDir)) {
  const from = path.join(srcDir, name);
  const info = fs.lstatSync(from);  // lstat: a symlink is seen as a link, not followed
  if (!info.isFile() || name.startsWith(".") || !WEB_FILES.has(path.extname(name).toLowerCase())) {
    console.log("skipped " + name);
    continue;
  }
  if (name === "index.html") {
    // the only file that gets the stamps; everything else (style.css) is copied as it is
    const html = fs.readFileSync(from, "utf8")
      .replace("__BUILT_WITH__", "node " + process.version)
      .replace("__BUILT_AT__", new Date().toISOString());
    fs.writeFileSync(path.join(outDir, name), html);
  } else {
    fs.copyFileSync(from, path.join(outDir, name));
  }
}
console.log("built dist/ with node " + process.version);
