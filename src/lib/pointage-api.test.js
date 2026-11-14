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

describe("register_account : compte à adresse factice", () => {
  const body = (extra = {}) => ({ action_key: KEY, type: "register_account", payload: { employee_number: 4821, role: "employee", ...extra } });
  const withAuth = (over = {}) => {
    const created = []; const deleted = [];
    const deps = makeDeps(over.deps);
    deps.createAuthUser = async (email, password) => { created.push({ email, password }); return over.create ?? { id: "44444444-4444-4444-8444-444444444444", error: null }; };
    deps.deleteAuthUser = async (id) => { deleted.push(id); if (over.deleteFails) throw new Error("x"); };
    return { deps, created, deleted };
  };

  it("crée le compte à l'adresse factice, passe son identifiant au profil et ne montre jamais le mot de passe", async () => {
    const { deps, created, deleted } = withAuth({ deps: { responses: { apply_sync_action: { data: { employee_number: 4821, role: "employee", code: "ABCDEFGHJK" }, error: null } } } });
    const r = await read(await handle(post(body()), deps));
    expect(r.status).toBe(200);
    expect(r.body.result.code).toBe("ABCDEFGHJK");
    expect(created).toHaveLength(1);
    expect(created[0].email).toBe("4821@pointage.invalid");
    expect(created[0].password).toMatch(/^[0-9a-f]{64}$/);
    expect(JSON.stringify(r.body)).not.toContain(created[0].password);
    expect(dataCalls(deps)[0].args.p_payload).toEqual({ employee_number: 4821, role: "employee", user_id: "44444444-4444-4444-8444-444444444444" });
    expect(deleted).toEqual([]);
  });

  it("ignore un user_id envoyé par l'appelant", async () => {
    const { deps } = withAuth();
    await handle(post(body({ user_id: "99999999-9999-4999-8999-999999999999" })), deps);
    expect(dataCalls(deps)[0].args.p_payload.user_id).toBe("44444444-4444-4444-8444-444444444444");
  });

  it("refuse un numéro hors plage avant tout compte", async () => {
    for (const n of [999, 1000.5, "4821", null, 1000000, undefined]) {
      const { deps, created } = withAuth();
      const r = await read(await handle(post({ ...body(), payload: { employee_number: n, role: "employee" } }), deps));
      expect([r.status, r.body.error], String(n)).toEqual([422, "invalid_employee_number"]);
      expect(created).toHaveLength(0);
    }
    const ok = withAuth();
    expect((await handle(post({ ...body(), payload: { employee_number: 1000, role: "employee" } }), ok.deps)).status).toBe(200);
    const ok2 = withAuth();
    expect((await handle(post({ ...body(), payload: { employee_number: 999999, role: "employee" } }), ok2.deps)).status).toBe(200);
  });

  it("retire le compte créé quand l'action échoue, et répond avec l'erreur de la base", async () => {
    const { deps, deleted } = withAuth({ deps: { responses: { apply_sync_action: { data: null, error: { code: "22023", message: "invalid_role" } } } } });
    const r = await read(await handle(post(body({ role: "owner" })), deps));
    expect([r.status, r.body.error]).toEqual([422, "invalid_role"]);
    expect(deleted).toEqual(["44444444-4444-4444-8444-444444444444"]);
  });

  it("retire le compte inutile lors d'une relance, et renvoie le résultat enregistré", async () => {
    const { deps, deleted } = withAuth({ deps: { responses: { apply_sync_action: { data: { employee_number: 4821, role: "employee", replayed: true }, error: null } } } });
    const r = await read(await handle(post(body()), deps));
    expect(r.status).toBe(200);
    expect(r.body.result.replayed).toBe(true);
    expect(deleted).toHaveLength(1);
  });

  it("relance quand l'adresse existe déjà : pas de compte, et une relance reconnue répond normalement", async () => {
    const { deps, deleted } = withAuth({ create: { id: null, error: { code: "email_exists" } }, deps: { responses: { apply_sync_action: { data: { employee_number: 4821, replayed: true }, error: null } } } });
    const r = await read(await handle(post(body()), deps));
    expect(r.status).toBe(200);
    expect(dataCalls(deps)[0].args.p_payload.user_id).toBeNull();
    expect(deleted).toEqual([]);
  });

  it("répond 409 si le numéro existe déjà et que ce n'est pas une relance", async () => {
    const { deps } = withAuth({ create: { id: null, error: { code: "email_exists" } }, deps: { responses: { apply_sync_action: { data: null, error: { code: "23502", message: "null value in column id" } } } } });
    const r = await read(await handle(post(body()), deps));
    expect([r.status, r.body.error]).toEqual([409, "employee_number_taken"]);
    expect(JSON.stringify(r.body)).not.toMatch(/column/);
  });

  it("répond 500 générique si l'authentification refuse la création, sans appeler la base", async () => {
    const { deps } = withAuth({ create: { id: null, error: { code: "unexpected_failure" } } });
    const r = await read(await handle(post(body()), deps));
    expect([r.status, r.body.error]).toEqual([500, "internal_error"]);
    expect(dataCalls(deps)).toHaveLength(0);
  });

  it("une panne du retrait ne change pas la réponse d'erreur", async () => {
    const { deps } = withAuth({ deleteFails: true, deps: { responses: { apply_sync_action: { data: null, error: { code: "23505", message: "employee_number_taken" } } } } });
    const r = await read(await handle(post(body()), deps));
    expect([r.status, r.body.error]).toEqual([409, "employee_number_taken"]);
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
