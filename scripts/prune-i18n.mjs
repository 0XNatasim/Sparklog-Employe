// Retire de src/lib/i18n.js (français ET anglais) les clés qu'aucun fichier de src/ ne cite (voir scripts/unused-i18n-keys.mjs).
// Ne touche que les lignes d'une seule ligne `    "clé": "texte",` ; une entrée sur plusieurs lignes est signalée, pas supprimée.
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
const root = new URL("..", import.meta.url).pathname;
const report = JSON.parse(execFileSync("node", [`${root}scripts/unused-i18n-keys.mjs`, "--json"], { encoding: "utf8" }));
const unused = new Set(report.unused);
const path = `${root}src/lib/i18n.js`;
const lines = readFileSync(path, "utf8").split("\n");
let removed = 0; const skipped = [];
const out = lines.filter((line) => {
  const m = /^\s+"([\w.\-]+)":/.exec(line);
  if (!m || !unused.has(m[1])) return true;
  if (/^\s+"[\w.\-]+": (".*"|`.*`),\s*$/.test(line)) { removed++; return false; }
  skipped.push(m[1]); return true;
});
writeFileSync(path, out.join("\n"));
console.log(`${removed} ligne(s) retirée(s) (français + anglais) ; ${skipped.length} entrée(s) à plusieurs lignes laissée(s)`);
for (const k of new Set(skipped)) console.log("  à la main :", k);
