import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { ACTION_TYPES, CONTRACT_VERSION, MAX_BODY_BYTES, handle, mapPgError, routeOf } from "../../supabase/functions/pointage_api/handler.js";

// Porte d'entrée du côté 1 pour le côté 2 : le module HTTP est exécuté tel quel, avec une base simulée (`deps.rpc`).
const BASE = "https://example.invalid/functions/v1/pointage_api";
const SECRET = "skc_" + "A1b2C3d4E5".repeat(4);
const CLIENT = "11111111-1111-4111-8111-111111111111";
const JOB = "22222222-2222-4222-8222-222222222222";
const KEY = "33333333-3333-4333-8333-333333333333";

function makeDeps({ clientId = CLIENT, authError = null, responses = {}, onCall } = {}) {
  const calls = [];
  const logs = [];
  return {
    calls, logs,
    rpc: async (name, args) => {
      calls.push({ name, args });
      onCall?.(name, args);
      if (name === "sync_authenticate") return { data: clientId, error: authError };
      const r = responses[name];
      return typeof r === "function" ? r(args) : r ?? { data: [], error: null };
    },
    log: (entry) => logs.push(entry),
  };
}
const get = (path, headers = {}) => new Request(BASE + path, { method: "GET", headers: { authorization: `Bearer ${SECRET}`, ...headers } });
const post = (body, { headers = {}, raw } = {}) => new Request(BASE + "/actions", {
  method: "POST", headers: { authorization: `Bearer ${SECRET}`, "content-type": "application/json", ...headers }, body: raw ?? JSON.stringify(body),
});
const read = async (response) => ({ status: response.status, body: await response.json(), headers: response.headers });
const dataCalls = (deps) => deps.calls.filter((c) => c.name !== "sync_authenticate");

describe("routes et méthodes", () => {
  it("extrait la route après « pointage_api »", () => {
    expect(routeOf(BASE + "/jobs/changed?limit=5")).toBe("/jobs/changed");
    expect(routeOf(BASE + "/")).toBe("/");
    expect(routeOf("https://x.invalid/health")).toBe("/health");
  });

  it("répond 404 sur une route inconnue, sans toucher à la base", async () => {
    const deps = makeDeps();
    const r = await read(await handle(get("/inconnue"), deps));
    expect(r.status).toBe(404);
    expect(deps.calls).toHaveLength(0);
  });

  it("répond 405 (avec Allow) sur une mauvaise méthode, sans toucher à la base", async () => {
    const deps = makeDeps();
    const res = await handle(new Request(BASE + "/jobs/changed", { method: "POST", headers: { authorization: `Bearer ${SECRET}` } }), deps);
    expect(res.status).toBe(405);
    expect(res.headers.get("allow")).toBe("GET");
    const res2 = await handle(new Request(BASE + "/actions", { method: "GET", headers: { authorization: `Bearer ${SECRET}` } }), deps);
    expect(res2.status).toBe(405);
    expect(res2.headers.get("allow")).toBe("POST");
    const res3 = await handle(new Request(BASE + "/health", { method: "OPTIONS" }), deps);
    expect(res3.status).toBe(405);
    expect(deps.calls).toHaveLength(0);
  });

  it("n'ajoute aucun en-tête CORS (serveur à serveur) et interdit la mise en cache", async () => {
    const deps = makeDeps({ responses: { sync_health: { data: { contract_version: 1 }, error: null } } });
    const res = await handle(get("/health"), deps);
    expect([...res.headers.keys()].some((k) => k.startsWith("access-control-"))).toBe(false);
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("x-contract-version")).toBe(String(CONTRACT_VERSION));
  });
});

describe("authentification", () => {
  it("refuse sans appeler la base un secret absent ou mal formé", async () => {
    for (const header of [undefined, "", "Basic abc", "Bearer", `Bearer skc_court`, `Bearer ${SECRET}x`, `Bearer ${SECRET.replace("skc_", "xyz_")}`, `Bearer ${SECRET} autre`]) {
      const deps = makeDeps();
      const res = await handle(new Request(BASE + "/health", { headers: header === undefined ? {} : { authorization: header } }), deps);
      expect(res.status, String(header)).toBe(401);
      expect(deps.calls, String(header)).toHaveLength(0);
    }
  });

  it("répond 401 sans détail quand la base ne reconnaît pas le secret", async () => {
    const deps = makeDeps({ clientId: null });
    const r = await read(await handle(get("/health"), deps));
    expect(r.status).toBe(401);
    expect(r.body).toEqual({ ok: false, error: "invalid_client" });
    expect(deps.calls.map((c) => c.name)).toEqual(["sync_authenticate"]);
  });

  it("répond 401 si la base renvoie autre chose qu'un identifiant de client", async () => {
    const deps = makeDeps({ clientId: "pas-un-uuid" });
    expect((await handle(get("/health"), deps)).status).toBe(401);
  });

  it("répond 429 avec Retry-After quand la base limite les tentatives", async () => {
    const deps = makeDeps({ clientId: null, authError: { code: "54000", message: "rate_limited" } });
    const res = await handle(get("/employees"), deps);
    expect(res.status).toBe(429);
    expect(res.headers.get("retry-after")).toBe("60");
    expect(dataCalls(deps)).toHaveLength(0);
  });

  it("répond 500 générique si l'authentification échoue pour une autre raison, sans renvoyer le texte de la base", async () => {
    const deps = makeDeps({ clientId: null, authError: { code: "XX000", message: "relation \"sync_clients\" does not exist" } });
    const r = await read(await handle(get("/health"), deps));
    expect(r.status).toBe(500);
    expect(JSON.stringify(r.body)).not.toMatch(/sync_clients|relation/);
  });

  it("envoie le secret à la base une seule fois et ne le renvoie jamais", async () => {
    const deps = makeDeps({ responses: { sync_health: { data: { contract_version: 1 }, error: null } } });
    const res = await handle(get("/health"), deps);
    const text = await res.text();
    expect(text).not.toContain(SECRET);
    expect(deps.calls.filter((c) => JSON.stringify(c.args).includes(SECRET))).toHaveLength(1);
    expect(JSON.stringify(deps.logs)).not.toContain(SECRET);
  });
});

describe("lecture", () => {
  it("transmet le client authentifié et les valeurs par défaut", async () => {
    const deps = makeDeps();
    await handle(get("/jobs/changed"), deps);
    expect(dataCalls(deps)).toEqual([{ name: "sync_jobs_changed", args: { p_client: CLIENT, p_after_ts: null, p_after_id: null, p_limit: 500 } }]);
  });

  it("valide les paramètres avant tout appel de lecture", async () => {
    const cases = [
      ["/jobs/changed?limit=0", "invalid_limit"], ["/jobs/changed?limit=501", "invalid_limit"], ["/jobs/changed?limit=abc", "invalid_limit"], ["/jobs/changed?limit=-5", "invalid_limit"],
      ["/jobs/changed?after_ts=hier&after_id=" + JOB, "invalid_after_ts"], ["/jobs/changed?after_ts=2026-11-14T10:00:00Z", "invalid_after_id"],
      ["/jobs/changed?after_ts=2026-11-14T10:00:00Z&after_id=xyz", "invalid_after_id"], ["/jobs/changed?after_id=" + JOB, "invalid_after_ts"],
      ["/jobs/ids?from=2026-11-01", "invalid_to"], ["/jobs/ids?to=2026-11-01", "invalid_from"], ["/jobs/ids?from=1er&to=2026-11-01", "invalid_from"],
      ["/claims/changed?limit=999", "invalid_limit"], ["/jobs/deleted?after_ts=2026-13-45T25:00:00Z", "invalid_after_ts"],
    ];
    for (const [path, error] of cases) {
      const deps = makeDeps();
      const r = await read(await handle(get(path), deps));
      expect(r.status, path).toBe(422);
      expect(r.body.error, path).toBe(error);
      expect(dataCalls(deps), path).toHaveLength(0);
    }
  });

  it("accepte un curseur complet et le transmet tel quel", async () => {
    const deps = makeDeps();
    await handle(get(`/jobs/changed?after_ts=2026-11-14T10:00:00.123456Z&after_id=${JOB}&limit=2`), deps);
    expect(dataCalls(deps)[0].args).toEqual({ p_client: CLIENT, p_after_ts: "2026-11-14T10:00:00.123456Z", p_after_id: JOB, p_limit: 2 });
  });

  it("annonce la page suivante quand la page est pleine, avec le curseur de la dernière ligne", async () => {
    const rows = [{ id: "a", updated_at: "2026-11-14T10:00:00Z" }, { id: "b", updated_at: "2026-11-14T10:00:01Z" }];
    const deps = makeDeps({ responses: { sync_jobs_changed: { data: rows, error: null } } });
    const r = await read(await handle(get("/jobs/changed?limit=2"), deps));
    expect(r.body).toEqual({ ok: true, data: rows, has_more: true, next: { after_ts: "2026-11-14T10:00:01Z", after_id: "b" } });
    const deps2 = makeDeps({ responses: { sync_jobs_changed: { data: [rows[0]], error: null } } });
    const r2 = await read(await handle(get("/jobs/changed?limit=2"), deps2));
    expect(r2.body.has_more).toBe(false);
    const deps3 = makeDeps({ responses: { sync_jobs_changed: { data: [], error: null } } });
    expect((await read(await handle(get("/jobs/changed"), deps3))).body).toEqual({ ok: true, data: [], has_more: false, next: null });
  });

  it("utilise le bon curseur pour les suppressions et les demandes de repas / stationnement", async () => {
    const del = makeDeps({ responses: { sync_jobs_deleted: { data: [{ job_id: JOB, deleted_at: "2026-11-14T10:00:00Z" }], error: null } } });
    const r = await read(await handle(get("/jobs/deleted?limit=1"), del));
    expect(r.body.next).toEqual({ after_ts: "2026-11-14T10:00:00Z", after_id: JOB });
    expect(dataCalls(del)[0].args).toEqual({ p_client: CLIENT, p_after: null, p_after_id: null, p_limit: 1 });
    const claims = makeDeps({ responses: { sync_claims_changed: { data: [{ id: KEY, changed_at: "2026-11-14T11:00:00Z" }], error: null } } });
    const c = await read(await handle(get("/claims/changed?limit=1"), claims));
    expect(c.body.next).toEqual({ after_ts: "2026-11-14T11:00:00Z", after_id: KEY });
  });

  it("transmet les dates de /jobs/ids et la liste des employés", async () => {
    const deps = makeDeps();
    await handle(get("/jobs/ids?from=2026-11-01&to=2026-11-14"), deps);
    await handle(get("/employees"), deps);
    expect(dataCalls(deps)).toEqual([
      { name: "sync_job_ids", args: { p_client: CLIENT, p_from: "2026-11-01", p_to: "2026-11-14" } },
      { name: "sync_employees", args: { p_client: CLIENT } },
    ]);
  });

  it("traduit les erreurs de la base sans jamais renvoyer un texte SQL", async () => {
    const deps = makeDeps({ responses: { sync_job_ids: { data: null, error: { code: "22023", message: "invalid_range" } } } });
    const r = await read(await handle(get("/jobs/ids?from=2026-01-01&to=2026-12-31"), deps));
    expect(r.status).toBe(422);
    expect(r.body).toEqual({ ok: false, error: "invalid_range" });
    const leak = makeDeps({ responses: { sync_employees: { data: null, error: { code: "XX000", message: "FATAL: password authentication failed for user postgres" } } } });
    const l = await read(await handle(get("/employees"), leak));
    expect(l.status).toBe(500);
    expect(JSON.stringify(l.body)).not.toMatch(/password|postgres|FATAL/);
  });
});

describe("actions", () => {
  const good = { action_key: KEY, type: "set_pause", payload: { employee_number: 3701, paused: true } };

  it("transmet l'action et renvoie le résultat de la base (y compris une relance)", async () => {
    const deps = makeDeps({ responses: { apply_sync_action: { data: { employee_number: 3701, is_paused: true, replayed: true }, error: null } } });
    const r = await read(await handle(post(good), deps));
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ ok: true, result: { employee_number: 3701, is_paused: true, replayed: true } });
    expect(dataCalls(deps)).toEqual([{ name: "apply_sync_action", args: { p_client: CLIENT, p_action_key: KEY, p_type: "set_pause", p_payload: good.payload } }]);
  });

  it("n'accepte que les types prévus", async () => {
    expect(ACTION_TYPES).toEqual(["approve_jobs", "return_job", "set_pause", "register_account", "reissue_activation_code", "unlock_day", "upsert_group", "set_group_members"]);
    for (const type of [undefined, "", "delete_everything", "SET_PAUSE", 12]) {
      const deps = makeDeps();
      const r = await read(await handle(post({ ...good, type }), deps));
      expect(r.status, String(type)).toBe(422);
      expect(r.body.error).toBe("unknown_action_type");
      expect(dataCalls(deps)).toHaveLength(0);
    }
  });

  it("refuse une clé, une charge ou un corps invalide avant la base", async () => {
    const cases = [
      [post({ ...good, action_key: "pas-un-uuid" }), 422, "invalid_action_key"], [post({ ...good, action_key: undefined }), 422, "invalid_action_key"],
      [post({ ...good, payload: undefined }), 422, "invalid_payload"], [post({ ...good, payload: [] }), 422, "invalid_payload"], [post({ ...good, payload: "x" }), 422, "invalid_payload"],
      [post(null, { raw: "{pas du json" }), 400, "invalid_json"], [post(null, { raw: "[1, 2]" }), 400, "invalid_json"], [post(null, { raw: "" }), 400, "invalid_json"],
      [post(null, { raw: "x".repeat(MAX_BODY_BYTES + 1) }), 413, "payload_too_large"], [post(good, { headers: { "content-length": String(MAX_BODY_BYTES + 1) } }), 413, "payload_too_large"],
    ];
    for (const [request, status, error] of cases) {
      const deps = makeDeps();
      const r = await read(await handle(request, deps));
      expect([r.status, r.body.error]).toEqual([status, error]);
      expect(dataCalls(deps)).toHaveLength(0);
    }
  });

  it("traduit les conflits et les refus de la base en codes HTTP stables", async () => {
    const table = [
      [{ code: "40001", message: "job_state_changed" }, 409, "job_state_changed"], [{ code: "23505", message: "action_key_reused" }, 409, "action_key_reused"],
      [{ code: "23505", message: "employee_number_taken" }, 409, "employee_number_taken"], [{ code: "22023", message: "invalid_role" }, 422, "invalid_role"],
      [{ code: "P0002", message: "employee_not_found" }, 404, "employee_not_found"], [{ code: "28000", message: "invalid_client" }, 401, "invalid_client"],
      [{ code: "42501", message: "permission denied for table jobs" }, 403, "forbidden"], [{ code: "22P02", message: "invalid input syntax for type uuid: \"x\"" }, 422, "invalid_request"],
    ];
    for (const [error, status, code] of table) {
      const deps = makeDeps({ responses: { apply_sync_action: { data: null, error } } });
      const r = await read(await handle(post(good), deps));
      expect([r.status, r.body.error], JSON.stringify(error)).toEqual([status, code]);
    }
  });
});

describe("correspondance des erreurs", () => {
  it("garde un texte seulement s'il est un code court sûr", () => {
    expect(mapPgError({ code: "40001", message: "job_state_changed" })).toEqual([409, "job_state_changed"]);
    expect(mapPgError({ code: "40001", message: "Could not serialize access due to concurrent update" })).toEqual([409, "state_changed"]);
    expect(mapPgError({ code: "23505", message: "duplicate key value violates unique constraint \"x\"" })).toEqual([409, "conflict"]);
    expect(mapPgError({ code: "22023", message: "x".repeat(200) })).toEqual([422, "invalid_request"]);
    expect(mapPgError({ code: "P0002", message: "" })).toEqual([404, "not_found"]);
    expect(mapPgError({ code: "54000", message: "rate_limited" })).toEqual([429, "rate_limited"]);
    expect(mapPgError({ code: "08006", message: "connection failure" })).toEqual([500, "internal_error"]);
    expect(mapPgError(null)).toEqual([500, "internal_error"]);
  });
});

describe("journal", () => {
  it("note la route et le code de réponse, jamais le contenu, et ne bloque jamais une réponse", async () => {
    const deps = makeDeps({ responses: { apply_sync_action: { data: { ok: 1 }, error: null } } });
    await handle(post({ action_key: KEY, type: "set_pause", payload: { employee_number: 3701, paused: true } }), deps);
    await handle(get("/inconnue"), deps);
    expect(deps.logs).toEqual([{ route: "/actions", status: 200 }, { route: "/inconnue", status: 404 }]);
    const broken = { ...makeDeps(), log: () => { throw new Error("journal en panne"); } };
    expect((await handle(get("/inconnue"), broken)).status).toBe(404);
  });
});

describe("branchement Deno (index.ts)", () => {
  const source = readFileSync(new URL("../../supabase/functions/pointage_api/index.ts", import.meta.url), "utf8");
  it("n'utilise que la clé de service de la plateforme, ne journalise ni le secret ni le corps, et délègue tout à handler.js", () => {
    expect(source).toContain('import { handle } from "./handler.js"');
    expect(source).toContain("SUPABASE_SERVICE_ROLE_KEY");
    expect(source).not.toMatch(/console\.(log|info|warn|error)\([^)]*(request|authorization|secret|body|headers)/i);
    expect(source).toContain("verify_jwt = false");
    expect(source).not.toMatch(/Access-Control/i);
  });
});
