// Banc d'essai de lecture des captures Field Service avec Tesseract (en ligne de commande) + le VRAI analyseur de l'application.
// Usage : node scripts/ocr-bench.mjs <vérité.json> [--variants a,b,…] [--lang eng+fra] [--details]
//   vérité.json : { "<chemin de l'image>": { ot, job_date, depart, arrivee, fin, km_aller, miles_traveled } | null }  (null = image sans rapport : rien ne doit être lu)
//   Ne jamais commiter les images ni la vérité (numéros d'OT réels) : le dépôt est public.
// Prérequis : tesseract (+ fra, eng) et ImageMagick (`convert`). Résultat : exactitude par champ et par variante, et captures « complètes » (tous les champs justes).
import { execFileSync } from "node:child_process";
import { readFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseExtractedText } from "../src/lib/work-order-parse.js";

const args = process.argv.slice(2);
const truthPath = args.find((a) => !a.startsWith("--"));
const opt = (name, fallback) => { const i = args.indexOf(`--${name}`); return i >= 0 ? args[i + 1] : fallback; };
const lang = opt("lang", "eng+fra");
const details = args.includes("--details");
const truth = JSON.parse(readFileSync(truthPath, "utf8"));
const tmp = mkdtempSync(join(tmpdir(), "ocrbench-"));

// Prétraitements (ImageMagick) × mode de segmentation de page (psm) de Tesseract.
const PREP = {
  raw: [],
  gray: ["-colorspace", "Gray", "-normalize"],
  up2: ["-resize", "200%", "-colorspace", "Gray", "-normalize"],
  up2sharp: ["-resize", "200%", "-colorspace", "Gray", "-normalize", "-sharpen", "0x1"],
  up3: ["-resize", "300%", "-colorspace", "Gray", "-normalize"],
  // ce que fait l'application aujourd'hui avant OCR.space : côté long réduit à 1600 px, JPEG qualité 70
  app: ["-resize", "1600x1600>", "-quality", "70"],
};
const VARIANTS = {
  "raw-psm6": ["raw", 6], "raw-psm4": ["raw", 4], "raw-psm11": ["raw", 11], "raw-psm3": ["raw", 3],
  "gray-psm6": ["gray", 6], "up2-psm6": ["up2", 6], "up2-psm4": ["up2", 4], "up2-psm11": ["up2", 11], "up2-psm3": ["up2", 3],
  "up2sharp-psm6": ["up2sharp", 6], "up3-psm6": ["up3", 6], "up3-psm4": ["up3", 4], "app-psm6": ["app", 6], "app-psm4": ["app", 4],
};
const wanted = (opt("variants", Object.keys(VARIANTS).join(",")) || "").split(",").filter(Boolean);
const FIELDS = ["ot", "job_date", "depart", "arrivee", "fin", "km_aller", "miles_traveled"];

function ocr(image, [prep, psm], n) {
  const prepared = join(tmp, `p${n}-${prep}.png`);
  execFileSync("convert", [image, ...PREP[prep], prepared]);
  return execFileSync("tesseract", [prepared, "stdout", "-l", lang, "--psm", String(psm)], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
}

const images = Object.keys(truth);
const results = {};
for (const variant of wanted) {
  const stats = Object.fromEntries(FIELDS.map((f) => [f, { ok: 0, total: 0 }]));
  let complete = 0, scored = 0, falsePositive = 0, unrelated = 0; const misses = [];
  images.forEach((image, n) => {
    const expected = truth[image];
    let parsed = {};
    try { parsed = parseExtractedText(ocr(image, VARIANTS[variant], n)); } catch (e) { parsed = {}; }
    if (expected === null) { unrelated++; if (Object.keys(parsed).length) falsePositive++; return; }
    scored++; let all = true;
    for (const f of FIELDS) {
      stats[f].total++;
      const good = parsed[f] === expected[f];
      if (good) stats[f].ok++; else { all = false; misses.push(`${image.split("/").pop()} ${f}: lu ${JSON.stringify(parsed[f] ?? null)} attendu ${JSON.stringify(expected[f])}`); }
    }
    if (all) complete++;
  });
  results[variant] = { stats, complete, scored, falsePositive, unrelated, misses };
}

const pct = (s) => `${s.ok}/${s.total}`;
console.log(`variante           complètes  ${FIELDS.map((f) => f.padEnd(9)).join(" ")} sans-rapport(faux positifs)`);
for (const [variant, r] of Object.entries(results)) {
  console.log(`${variant.padEnd(18)} ${`${r.complete}/${r.scored}`.padEnd(10)} ${FIELDS.map((f) => pct(r.stats[f]).padEnd(9)).join(" ")} ${r.falsePositive}/${r.unrelated}`);
}
if (details) for (const [variant, r] of Object.entries(results)) { console.log(`\n== ${variant}`); for (const m of r.misses) console.log("  " + m); }
