import { readFileSync, readdirSync } from "node:fs";
import { describe, expect, it } from "vitest";

// Le fichier d'aperçu (docs/apercu/schema-apercu.sql) est l'assemblage des migrations de supabase/next/ (scripts/build-preview-sql.sh) :
// ce test échoue si une migration change sans que le fichier soit régénéré.
const root = new URL("../../", import.meta.url);
const read = (path) => readFileSync(new URL(path, root), "utf8");

describe("fichier d'aperçu du schéma", () => {
  it("contient chaque migration de supabase/next/ dans l'ordre, et aucun test", () => {
    const files = readdirSync(new URL("supabase/next/", root)).filter((f) => /^\d{4}_.*\.sql$/.test(f)).sort();
    expect(files.length).toBeGreaterThanOrEqual(13);
    const header = [
      "-- Sparklog-Employés : schéma complet du côté 1 (généré par scripts/build-preview-sql.sh ; ne pas modifier à la main).",
      "-- À coller UNE SEULE FOIS dans l'éditeur SQL d'un projet Supabase VIERGE de test (docs/mode-emploi-apercu.md).",
    ].join("\n") + "\n";
    const body = files.map((f) => `\n-- ════════════════════════════════════════════════════════════════════\n-- ${f}\n-- ════════════════════════════════════════════════════════════════════\n${read(`supabase/next/${f}`)}`).join("");
    expect(read("docs/apercu/schema-apercu.sql")).toBe(header + body);
  });

  it("le mode d'emploi cite les trois fichiers SQL et ne contient aucun secret", () => {
    const guide = read("docs/mode-emploi-apercu.md");
    for (const name of ["schema-apercu.sql", "1-proprietaire.sql", "2-client-api.sql"]) expect(guide).toContain(name);
    expect(guide).not.toMatch(/skc_[A-Za-z0-9]{40}/);
    expect(guide).not.toMatch(/eyJ[A-Za-z0-9_-]{20,}/); // jeton JWT
  });
});
