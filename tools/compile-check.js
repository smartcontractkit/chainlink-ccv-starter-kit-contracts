#!/usr/bin/env node
/* Verification-only compile of the repo's own Solidity (src/, script/, test/)
 * using solc-js, resolving imports via remappings.txt + node_modules/lib.
 * Mirrors the `dev` profile (optimizer on, via_ir off) for a fast typecheck. */
const fs = require("fs");
const path = require("path");
const solc = require("solc");

const ROOT = path.resolve(__dirname, "..");

// --- load remappings (longest-prefix-first) ---
const remappings = fs
  .readFileSync(path.join(ROOT, "remappings.txt"), "utf8")
  .split("\n")
  .map((l) => l.trim())
  .filter((l) => l && l.includes("="))
  .map((l) => {
    const i = l.indexOf("=");
    return { prefix: l.slice(0, i), target: l.slice(i + 1) };
  })
  .sort((a, b) => b.prefix.length - a.prefix.length);

function applyRemap(p) {
  for (const { prefix, target } of remappings) {
    if (p.startsWith(prefix)) return target + p.slice(prefix.length);
  }
  return p;
}

// --- collect top-level source files ---
function walk(dir, acc) {
  if (!fs.existsSync(dir)) return acc;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const fp = path.join(dir, e.name);
    if (e.isDirectory()) walk(fp, acc);
    else if (e.name.endsWith(".sol")) acc.push(path.relative(ROOT, fp));
  }
  return acc;
}
const files = [...walk(path.join(ROOT, "src"), []), ...walk(path.join(ROOT, "script"), []), ...walk(path.join(ROOT, "test"), [])];

const sources = {};
for (const f of files) sources[f] = { content: fs.readFileSync(path.join(ROOT, f), "utf8") };

// --- import resolution callback ---
function readResolved(p) {
  const candidates = [p, applyRemap(p)];
  for (const c of candidates) {
    const abs = path.isAbsolute(c) ? c : path.join(ROOT, c);
    if (fs.existsSync(abs) && fs.statSync(abs).isFile()) return fs.readFileSync(abs, "utf8");
  }
  return null;
}
function findImports(importPath) {
  const content = readResolved(importPath);
  return content ? { contents: content } : { error: "File not found: " + importPath };
}

const input = {
  language: "Solidity",
  sources,
  settings: {
    remappings: remappings.map((r) => r.prefix + "=" + r.target),
    optimizer: { enabled: true, runs: 200 },
    evmVersion: "paris",
    outputSelection: { "*": { "*": ["abi"] } },
  },
};

const out = JSON.parse(solc.compile(JSON.stringify(input), { import: findImports }));

const errors = (out.errors || []).filter((e) => e.severity === "error");
const warnings = (out.errors || []).filter((e) => e.severity === "warning");

console.log(`Compiled ${files.length} top-level files under src/ script/ test/`);
console.log(`solc ${solc.version()}`);
console.log(`errors: ${errors.length}, warnings: ${warnings.length}`);

if (warnings.length) {
  const kinds = {};
  for (const w of warnings) kinds[w.type] = (kinds[w.type] || 0) + 1;
  console.log("warning kinds:", JSON.stringify(kinds));
}
if (errors.length) {
  for (const e of errors) console.log("\n" + (e.formattedMessage || e.message));
  process.exit(1);
}
console.log("\nOK — all repo sources compile.");
