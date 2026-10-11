// The "build step": turn src/ into dist/. Real apps run Vite, Astro, etc. here.
// It stamps the Node version into the page, so a visitor can see it was built
// inside the container and not just copied.
const fs = require("fs");
const path = require("path");

const src = fs.readFileSync(path.join(__dirname, "src", "index.html"), "utf8");
const out = src
  .replace("__BUILT_WITH__", "node " + process.version)
  .replace("__BUILT_AT__", new Date().toISOString());

fs.mkdirSync(path.join(__dirname, "dist"), { recursive: true });
fs.writeFileSync(path.join(__dirname, "dist", "index.html"), out);
console.log("built dist/index.html with node " + process.version);
