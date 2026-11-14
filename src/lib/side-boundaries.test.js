import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { describe, expect, it } from "vitest";

// Le côté 1 n'appelle jamais ce qui appartient au côté 2 ou à la clé de service : approbation, paie, API d'échange.
// (Un bouton qui appelait `push_approved_batch`, fonction qui n'existe plus ici, est resté après la séparation : ce test l'aurait attrapé.)
const SRC = new URL("..", import.meta.url).pathname;
const walk = (d) => readdirSync(d).flatMap((n) => { const p = join(d, n); return statSync(p).isDirectory() ? walk(p) : /\.jsx?$/.test(n) && !/\.test\./.test(n) ? [p] : []; });
const FORBIDDEN = [
  /push_approved_batch/, /classify_week/, /push_approved_to_sheet/,
  /\.rpc\(\s*["'`](?:approve_jobs|apply_sync_action|sync_[a-z_]+|issue_activation_code|consume_activation_code)["'`]/,
  /functions\.invoke\(\s*["'`](?:pointage_api|send_push|cleanup_overtime_evidence)["'`]/,
  /SERVICE_ROLE|service_role/i,
];

describe("limites du côté 1", () => {
  it("le code de l'application n'appelle ni approbation, ni paie, ni API d'échange, ni clé de service", () => {
    const hits = [];
    for (const file of walk(SRC)) {
      const text = readFileSync(file, "utf8");
      for (const re of FORBIDDEN) if (re.test(text)) hits.push(`${relative(SRC, file)} : ${re}`);
    }
    expect(hits).toEqual([]);
  });
});
