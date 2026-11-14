// supabase/functions/pointage_api/handler.js
//
// Porte d'entrée HTTP du côté 1 pour le côté 2 (Sparklog-Gestion) : `PLAN.md`, étape 3 ; base de données : migration `next/0012_sync_api`.
// Serveur à serveur : pas de CORS, pas de navigateur. Le secret du client est vérifié par `sync_authenticate` (haché en base) ; ensuite
// chaque route appelle UNE fonction SQL. Ce module ne dépend ni de Deno ni de Supabase : `deps.rpc(name, args)` est injecté (voir index.ts), donc les tests
// (src/lib/pointage-api.test.js) l'exécutent tel quel.
//
// Règles :
//  * un secret absent ou mal formé n'atteint jamais la base ; un secret faux répond 401 sans détail ; trop d'échecs répondent 429 ;
//  * on ne journalise jamais le secret, le corps ni les paramètres : seulement la route et le code de réponse ;
//  * les messages d'erreur renvoyés sont des codes courts contrôlés (jamais un texte SQL) ;
//  * aucune donnée nominative ne passe : les fonctions SQL ne renvoient que des numéros d'employé.

export const CONTRACT_VERSION = 1;
export const MAX_BODY_BYTES = 256 * 1024;
export const MAX_LIMIT = 500;
export const ACTION_TYPES = Object.freeze([
  "approve_jobs", "return_job", "set_pause", "register_account", "reissue_activation_code", "unlock_day", "upsert_group", "set_group_members",
]);

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const TS_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$/;
const SECRET_RE = /^skc_[A-Za-z0-9]{40}$/;
const SAFE_CODE_RE = /^[a-z0-9_:]{1,60}$/;

const BASE_HEADERS = Object.freeze({
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
  "x-contract-version": String(CONTRACT_VERSION),
});

function json(status, body, extra = {}) {
  return new Response(JSON.stringify(body), { status, headers: { ...BASE_HEADERS, ...extra } });
}
const fail = (status, error, extra) => json(status, { ok: false, error }, extra);

// Chemin de la route : tout ce qui suit « pointage_api » (ou le chemin entier hors Supabase).
export function routeOf(url) {
  const path = new URL(url).pathname.replace(/\/+$/, "");
  const i = path.indexOf("/pointage_api");
  const rest = i >= 0 ? path.slice(i + "/pointage_api".length) : path;
  return rest === "" ? "/" : rest;
}

// SQLSTATE de nos fonctions → réponse HTTP. Le texte renvoyé est le code court de la base s'il est sûr, jamais autre chose.
export function mapPgError(error) {
  const code = String(error?.code || "");
  const message = String(error?.message || "");
  const safe = SAFE_CODE_RE.test(message) ? message : null;
  switch (code) {
    case "28000": return [401, "invalid_client"];
    case "54000": return [429, "rate_limited"];
    case "40001": return [409, safe || "state_changed"];
    case "23505": return [409, safe || "conflict"];
    case "22023": case "23514": case "22007": case "22P02": case "22003": case "23502": return [422, safe || "invalid_request"];
    case "P0002": return [404, safe || "not_found"];
    case "42501": return [403, "forbidden"];
    default: return [500, "internal_error"];
  }
}

function errResponse(error) {
  const [status, code] = mapPgError(error);
  return fail(status, code, status === 429 ? { "retry-after": "60" } : {});
}

// ── Paramètres ──────────────────────────────────────────────────────────────
function intParam(params, name, fallback, min, max) {
  const raw = params.get(name);
  if (raw === null || raw === "") return { value: fallback };
  if (!/^\d{1,6}$/.test(raw)) return { error: `invalid_${name}` };
  const n = Number(raw);
  return n < min || n > max ? { error: `invalid_${name}` } : { value: n };
}
function cursorParams(params, tsName, idName, { idRequired = true } = {}) {
  const ts = params.get(tsName);
  const id = params.get(idName);
  if ((ts === null || ts === "") && (id === null || id === "")) return { ts: null, id: null };
  if (!ts || !TS_RE.test(ts) || Number.isNaN(Date.parse(ts))) return { error: `invalid_${tsName}` };
  if (id && !UUID_RE.test(id)) return { error: `invalid_${idName}` };
  if (idRequired && !id) return { error: `invalid_${idName}` };
  return { ts, id: id || null };
}

// ── Routes ──────────────────────────────────────────────────────────────────
// Chaque route : méthode, fonction SQL, validation des paramètres → arguments, et la clé du curseur de la page suivante.
const READ_ROUTES = {
  "/health": {
    fn: "sync_health", build: () => ({ args: {} }), single: true,
  },
  "/employees": {
    fn: "sync_employees", build: () => ({ args: {} }),
  },
  "/jobs/changed": {
    fn: "sync_jobs_changed", cursorKey: "updated_at",
    build: (p) => {
      const cur = cursorParams(p, "after_ts", "after_id"); if (cur.error) return { error: cur.error };
      const lim = intParam(p, "limit", MAX_LIMIT, 1, MAX_LIMIT); if (lim.error) return { error: lim.error };
      return { args: { p_after_ts: cur.ts, p_after_id: cur.id, p_limit: lim.value }, limit: lim.value };
    },
  },
  "/jobs/deleted": {
    fn: "sync_jobs_deleted", cursorKey: "deleted_at", cursorIdKey: "job_id",
    build: (p) => {
      const cur = cursorParams(p, "after_ts", "after_id", { idRequired: false }); if (cur.error) return { error: cur.error };
      const lim = intParam(p, "limit", MAX_LIMIT, 1, MAX_LIMIT); if (lim.error) return { error: lim.error };
      return { args: { p_after: cur.ts, p_after_id: cur.id, p_limit: lim.value }, limit: lim.value };
    },
  },
  "/jobs/ids": {
    fn: "sync_job_ids",
    build: (p) => {
      const from = p.get("from"); const to = p.get("to");
      if (!from || !DATE_RE.test(from)) return { error: "invalid_from" };
      if (!to || !DATE_RE.test(to)) return { error: "invalid_to" };
      return { args: { p_from: from, p_to: to } };
    },
  },
  "/claims/changed": {
    fn: "sync_claims_changed", cursorKey: "changed_at",
    build: (p) => {
      const cur = cursorParams(p, "after_ts", "after_id"); if (cur.error) return { error: cur.error };
      const lim = intParam(p, "limit", MAX_LIMIT, 1, MAX_LIMIT); if (lim.error) return { error: lim.error };
      return { args: { p_after_ts: cur.ts, p_after_id: cur.id, p_limit: lim.value }, limit: lim.value };
    },
  },
};

function bearerSecret(request) {
  const header = request.headers.get("authorization") || "";
  const match = /^Bearer ([^\s]+)$/i.exec(header);
  return match && SECRET_RE.test(match[1]) ? match[1] : null;
}

async function authenticate(request, deps) {
  const secret = bearerSecret(request);
  if (!secret) return { response: fail(401, "invalid_client") };
  const { data, error } = await deps.rpc("sync_authenticate", { p_secret: secret });
  if (error) return { response: errResponse(error) };
  if (!data || !UUID_RE.test(String(data))) return { response: fail(401, "invalid_client") };
  return { clientId: String(data) };
}

async function readJsonBody(request) {
  const declared = Number(request.headers.get("content-length") || 0);
  if (declared > MAX_BODY_BYTES) return { error: "payload_too_large", status: 413 };
  const text = await request.text();
  if (text.length > MAX_BODY_BYTES) return { error: "payload_too_large", status: 413 };
  try {
    const value = JSON.parse(text);
    return value && typeof value === "object" && !Array.isArray(value) ? { value } : { error: "invalid_json", status: 400 };
  } catch {
    return { error: "invalid_json", status: 400 };
  }
}

export async function handle(request, deps) {
  const route = routeOf(request.url);
  const log = (status) => { try { deps.log?.({ route, status }); } catch { /* le journal ne bloque jamais une réponse */ } };
  const done = (response) => { log(response.status); return response; };

  const read = READ_ROUTES[route];
  const isAction = route === "/actions";
  if (!read && !isAction) return done(fail(404, "not_found"));
  const allowed = isAction ? "POST" : "GET";
  if (request.method !== allowed) return done(fail(405, "method_not_allowed", { allow: allowed }));

  const auth = await authenticate(request, deps);
  if (auth.response) return done(auth.response);

  if (isAction) {
    const body = await readJsonBody(request);
    if (body.error) return done(fail(body.status, body.error));
    const { action_key: actionKey, type, payload } = body.value;
    if (!UUID_RE.test(String(actionKey || ""))) return done(fail(422, "invalid_action_key"));
    if (!ACTION_TYPES.includes(type)) return done(fail(422, "unknown_action_type"));
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) return done(fail(422, "invalid_payload"));
    const { data, error } = await deps.rpc("apply_sync_action", { p_client: auth.clientId, p_action_key: actionKey, p_type: type, p_payload: payload });
    if (error) return done(errResponse(error));
    return done(json(200, { ok: true, result: data }));
  }

  const built = read.build(new URL(request.url).searchParams);
  if (built.error) return done(fail(422, built.error));
  const { data, error } = await deps.rpc(read.fn, { p_client: auth.clientId, ...built.args });
  if (error) return done(errResponse(error));
  if (read.single) return done(json(200, { ok: true, data }));
  const rows = Array.isArray(data) ? data : [];
  const body = { ok: true, data: rows };
  if (read.cursorKey) {
    const last = rows[rows.length - 1];
    body.has_more = rows.length > 0 && rows.length === (built.limit ?? MAX_LIMIT);
    body.next = last ? { after_ts: last[read.cursorKey], after_id: last[read.cursorIdKey || "id"] } : null;
  }
  return done(json(200, body));
}
