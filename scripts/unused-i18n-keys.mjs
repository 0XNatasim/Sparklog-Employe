// Liste les clés de src/lib/i18n.js qu'aucun fichier de src/ ne cite (ni telle quelle, ni par un préfixe construit comme `status.${x}`).
// Usage : node scripts/unused-i18n-keys.mjs [--json]   (lecture seule ; la suppression se fait avec scripts/prune-i18n.mjs)
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
const root = new URL("..", import.meta.url).pathname;
const walk = (d) => readdirSync(d).flatMap((n) => { const p = join(d, n); return statSync(p).isDirectory() ? walk(p) : /\.(jsx?|ts)$/.test(n) ? [p] : []; });
const files = walk(join(root, "src")).filter((f) => !/\/i18n\.js$/.test(f) && !/\.test\./.test(f));
const code = files.map((f) => readFileSync(f, "utf8")).join("\n");
const i18n = readFileSync(join(root, "src/lib/i18n.js"), "utf8");
const keys = [...new Set([...i18n.matchAll(/^\s+"([\w.\-]+)":/gm)].map((m) => m[1]))];
// préfixes dynamiques : `...\`prefix.${` ou "prefix." + x
const dynamic = new Set();
for (const m of code.matchAll(/[`"']([\w.\-]*\.)\$\{/g)) dynamic.add(m[1]);
for (const m of code.matchAll(/["']([\w.\-]+\.)["']\s*\+/g)) dynamic.add(m[1]);
// `word(key)` ajoute le suffixe `.plain` (UnlockDayManager) : une clé `x.plain` suit l'usage de `x`.
const used = (k) => (k.endsWith(".plain") && used(k.slice(0, -6))) || code.includes(`"${k}"`) || code.includes(`'${k}'`) || code.includes(`\`${k}\``) || [...dynamic].some((p) => k.startsWith(p));
const unusedKeys = keys.filter((k) => !used(k));
const unused = unusedKeys;
if (process.argv.includes("--json")) console.log(JSON.stringify({ total: keys.length, dynamic: [...dynamic].sort(), unused }, null, 1));
else { console.log(`${unused.length} clé(s) inutilisée(s) sur ${keys.length} (préfixes dynamiques : ${dynamic.size})`); for (const k of unused) console.log(k); }
