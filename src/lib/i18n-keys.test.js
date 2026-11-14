import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { dictionaries } from "./i18n";

// Chaque clé de texte citée dans le code (t("clé"), labelKey: "clé"…) existe en français ET en anglais ; les deux langues ont les mêmes clés.
// Évite qu'un nettoyage (scripts/prune-i18n.mjs) ou un oubli laisse afficher une clé brute à l'écran.
const SRC = new URL("..", import.meta.url).pathname;
const walk = (d) => readdirSync(d).flatMap((n) => { const p = join(d, n); return statSync(p).isDirectory() ? walk(p) : /\.jsx?$/.test(n) && !/\.test\./.test(n) && !/\/i18n\.js$/.test(p) ? [p] : []; });
const KEY = /(?:\bt\(|\blabelKey:\s*|\bt\(\s*)["'`]([a-zA-Z][\w-]*(?:\.[\w-]+)+)["'`]/g;

describe("textes (i18n)", () => {
  it("les deux langues ont exactement les mêmes clés", () => {
    const fr = new Set(Object.keys(dictionaries.fr)), en = new Set(Object.keys(dictionaries.en));
    expect([...fr].filter((k) => !en.has(k))).toEqual([]);
    expect([...en].filter((k) => !fr.has(k))).toEqual([]);
  });

  it("toute clé citée dans le code existe", () => {
    const missing = [];
    for (const file of walk(SRC)) {
      const text = readFileSync(file, "utf8");
      for (const m of text.matchAll(KEY)) if (!(m[1] in dictionaries.fr)) missing.push(`${file.replace(SRC, "")} : ${m[1]}`);
    }
    expect([...new Set(missing)]).toEqual([]);
  });
});
