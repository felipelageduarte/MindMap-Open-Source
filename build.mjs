#!/usr/bin/env node
// build.mjs — gera mindmap.html (auto-contido) a partir de index.html + vendor/.
// Uso: node build.mjs
import fs from "fs";

let html = fs.readFileSync("index.html", "utf8");
const css = fs.readFileSync("vendor/MindElixir.css", "utf8");
const js  = fs.readFileSync("vendor/MindElixir.iife.js", "utf8");

html = html.replace(
  /<link rel="stylesheet" href="vendor\/MindElixir\.css">/,
  `<style id="mindelixir-css">\n${css}\n</style>`
);
html = html.replace(
  /<script src="vendor\/MindElixir\.iife\.js"><\/script>/,
  `<script>\n${js}\n</script>`
);

if (/vendor\//.test(html)) {
  console.error("ERRO: mindmap.html ainda referencia vendor/ — inline falhou.");
  process.exit(1);
}

fs.writeFileSync("mindmap.html", html);
console.log(`mindmap.html gerado (${(fs.statSync("mindmap.html").size / 1024 | 0)}KB).`);
