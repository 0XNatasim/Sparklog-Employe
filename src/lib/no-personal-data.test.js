import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { describe, expect, it } from "vitest";
import { employeeLabel } from "./employee-label";

// Invariant I1 (PLAN.md) : le côté 1 ne recueille, ne lit ni n'affiche aucun nom, courriel, téléphone, NAS, région, syndicat ni carte CCQ.
// Ce test lit le code source : une colonne nominative qui revient dans `src/` fait échouer la CI.
const SRC = new URL("..", import.meta.url).pathname;
const FORBIDDEN = [
  /\bfull_name\b/, /\bwork_region\b/, /\bunion_association\b/, /\bbirth_date\b/, /\bccq_card\w*/, /\bccq_number\b/, /\bemployee_sensitive\b/,
  /\bemployee\??\.(phone|email)\b/, /\bprofile\??\.(phone|email)\b/, /from\("profiles"\)[^;]*select\("[^"]*\b(phone|email)\b/,
];
const IGNORED = [/\.test\.jsx?$/, /\/i18n\.js$/, /\/payroll\/ccq-benefits\.js$/];

function sources(dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return sources(path);
    return /\.jsx?$/.test(name) && !IGNORED.some((re) => re.test(path)) ? [path] : [];
  });
}

describe("aucune donnée personnelle côté 1", () => {
  it("le code ne touche à aucune colonne nominative", () => {
    const hits = [];
    for (const file of sources(SRC)) {
      const text = readFileSync(file, "utf8");
      for (const re of FORBIDDEN) if (re.test(text)) hits.push(`${relative(SRC, file)} : ${re}`);
    }
    expect(hits).toEqual([]);
  });

  it("le libellé d'un employé est son numéro, jamais un nom", () => {
    expect(employeeLabel({ employee_number: 4821, full_name: "Ne doit pas apparaître", email: "x@y.z" })).toBe("#4821");
    expect(employeeLabel({})).toBe("");
    expect(employeeLabel(null)).toBe("");
    expect(employeeLabel({ employee_number: "4821" })).toBe("");
  });
});
