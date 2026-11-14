// Compare ce que l'application lit / écrit (src/) à la structure de supabase/next/ (relevée par DUMP_SCHEMA=… scripts/test-next-schema.sh).
// Usage : node scripts/check-app-against-schema.mjs schema.json [--json]
// Analyse statique approximative : .from("table") + select("a, b, rel(c)") / eq / order / in / is / gte… / insert|update|upsert({…}) sur la même chaîne, et .rpc("f").
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const schema = JSON.parse(readFileSync(process.argv[2], "utf8"));
const root = new URL("..", import.meta.url).pathname;
// Code de l'application (src/) ET des fonctions Edge (supabase/functions/) : les deux parlent à la même base.
const files = (dir) => readdirSync(dir).flatMap((n) => {
  const p = join(dir, n);
  if (statSync(p).isDirectory()) return files(p);
  return /\.(jsx?|ts)$/.test(n) && !/\.test\./.test(n) ? [p] : [];
});
const sources = [...files(join(root, "src")), ...files(join(root, "supabase/functions"))];

const issues = new Map(); // clé → Set(fichiers)
const add = (key, file) => { if (!issues.has(key)) issues.set(key, new Set()); issues.get(key).add(file); };

function splitTop(list) { // coupe sur les virgules hors parenthèses
  const out = []; let depth = 0, cur = "";
  for (const ch of list) {
    if (ch === "(") depth++; if (ch === ")") depth--;
    if (ch === "," && depth === 0) { out.push(cur.trim()); cur = ""; } else cur += ch;
  }
  if (cur.trim()) out.push(cur.trim());
  return out;
}

for (const file of sources) {
  const rel = relative(root, file);
  const text = readFileSync(file, "utf8");
  for (const m of text.matchAll(/\.rpc\(\s*["'`](\w+)["'`]/g)) if (!schema.functions.includes(m[1])) add(`rpc manquante : ${m[1]}`, rel);
  for (const m of text.matchAll(/\.from\(\s*["'`](\w+)["'`]\s*\)/g)) {
    const table = m[1];
    if (/^(sparklog|storage)/.test(table)) continue;
    if (/storage\s*$/.test(text.slice(Math.max(0, m.index - 12), m.index))) continue; // storage.from("compartiment")
    const cols = schema.columns[table];
    if (!cols) { add(`table manquante : ${table}`, rel); continue; }
    // la chaîne : jusqu'à la fin de l'instruction (; ou ligne vide), bornée à 900 caractères
    let chain = text.slice(m.index + m[0].length, m.index + m[0].length + 900);
    // … et coupée au début de la requête suivante (Promise.all, plusieurs requêtes dans une fonction)
    const end = chain.search(/;\s*\n|\n\s*\n|\.from\(|\.rpc\(|\b(?:supabase|client|admin)\s*\.(?:from|rpc|storage|functions)|\bawait\b|\bconst\b|\blet\b|\breturn\b|\bfunction\b/);
    if (end > 0) chain = chain.slice(0, end);
    const wanted = new Set();
    for (const s of chain.matchAll(/\.select\(\s*["'`]([^"'`]*)["'`]/g)) {
      for (const part of splitTop(s[1])) {
        if (part === "*" || /^\w+!?\w*\(/.test(part) || part.includes(":")) continue; // jointures et alias : non vérifiés
        wanted.add(part);
      }
    }
    for (const s of chain.matchAll(/\.(?:eq|neq|gt|gte|lt|lte|is|in|order|like|ilike|not|contains)\(\s*["'`](\w+)["'`]/g)) wanted.add(s[1]);
    // Clés de premier niveau de l'objet écrit (les objets imbriqués, ex. `details: { … }` d'une colonne jsonb, sont ignorés).
    for (const s of chain.matchAll(/\.(?:insert|update|upsert)\(\s*\{/g)) {
      let depth = 1, i = s.index + s[0].length, top = "";
      for (; i < chain.length && depth > 0; i++) {
        const ch = chain[i];
        if (ch === "{" || ch === "[" || ch === "(") depth++;
        else if (ch === "}" || ch === "]" || ch === ")") depth--;
        if (depth === 1) top += ch;
      }
      for (const k of top.matchAll(/(?:^|,)\s*(\w+)\s*(?::|,|$)/g)) wanted.add(k[1]);
    }
    for (const c of wanted) if (!cols.includes(c)) add(`colonne manquante : ${table}.${c}`, rel);
  }
}

const rows = [...issues.entries()].sort(([a], [b]) => a.localeCompare(b));
if (process.argv.includes("--json")) console.log(JSON.stringify(Object.fromEntries(rows.map(([k, v]) => [k, [...v].sort()])), null, 1));
else {
  for (const [key, set] of rows) console.log(`${key}   ← ${[...set].sort().join(", ")}`);
  console.log(`\n${rows.length} écart(s)`);
}
process.exit(rows.length ? 1 : 0);
