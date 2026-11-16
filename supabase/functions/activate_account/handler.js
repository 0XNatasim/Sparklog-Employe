// supabase/functions/activate_account/handler.js
//
// Première connexion d'un employé : numéro d'employé + code d'activation (donné une fois par la gestion) + mot de passe choisi.
// Logique pure (testée par src/lib/activate-account.test.js) ; index.ts n'ajoute que le branchement Supabase.
//
// Ordre voulu : le code est vérifié et consommé par la base (`consume_activation_code` : 5 essais, 72 h, usage unique), PUIS le mot de passe est posé.
// Si la pose du mot de passe échoue, le code est déjà consommé : la gestion en réémet un (réponse 500 `activation_failed`).
// Aucune donnée personnelle : ni nom, ni courriel ne transitent ; l'adresse de connexion est `<numéro>@pointage.invalid`.

export const MAX_BODY_BYTES = 2048;
export const PASSWORD_MIN = 12;
export const PASSWORD_MAX = 72; // bcrypt ignore le reste
export const EMPLOYEE_NUMBER_MIN = 1;
export const EMPLOYEE_NUMBER_MAX = 999999;
export const CODE_RE = /^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{10}$/;

const HEADERS = { "content-type": "application/json", "cache-control": "no-store", "x-content-type-options": "nosniff" };
const json = (status, body, extra = {}) => new Response(JSON.stringify(body), { status, headers: { ...HEADERS, ...extra } });
const fail = (status, error, extra) => json(status, { ok: false, error }, extra);

// Règle de mot de passe : longueur seulement (une phrase de passe vaut mieux qu'une règle de symboles) ; refus d'un mot de passe égal au numéro ou au code.
export function passwordProblem(password, number, code) {
  if (typeof password !== "string") return "invalid_password";
  if (password.length < PASSWORD_MIN) return "password_too_short";
  if (password.length > PASSWORD_MAX) return "password_too_long";
  if (password.includes(String(number)) || password.toUpperCase().includes(code)) return "password_too_guessable";
  return null;
}

export async function handle(request, deps) {
  const log = (status) => { try { deps.log?.({ route: "/", status }); } catch { /* le journal ne bloque jamais */ } };
  const done = (response) => { log(response.status); return response; };
  if (request.method !== "POST") return done(fail(405, "method_not_allowed", { allow: "POST" }));
  if (Number(request.headers.get("content-length") || 0) > MAX_BODY_BYTES) return done(fail(413, "payload_too_large"));
  const text = await request.text();
  if (text.length > MAX_BODY_BYTES) return done(fail(413, "payload_too_large"));
  let body;
  try { body = JSON.parse(text); } catch { return done(fail(400, "invalid_json")); }
  if (!body || typeof body !== "object" || Array.isArray(body)) return done(fail(400, "invalid_json"));

  const number = body.employee_number;
  const code = typeof body.code === "string" ? body.code.replace(/[\s-]/g, "").toUpperCase() : "";
  if (!Number.isInteger(number) || number < EMPLOYEE_NUMBER_MIN || number > EMPLOYEE_NUMBER_MAX) return done(fail(422, "invalid_employee_number"));
  // Un code mal formé est refusé sans toucher à la base (il ne compte pas comme un essai).
  if (!CODE_RE.test(code)) return done(fail(422, "invalid_code_format"));
  const problem = passwordProblem(body.password, number, code);
  if (problem) return done(fail(422, problem));

  const { data, error } = await deps.rpc("consume_activation_code", { p_employee_number: number, p_code: code });
  if (error) return done(fail(500, "internal_error"));
  const row = Array.isArray(data) ? data[0] : data;
  switch (row?.status) {
    case "ok": break;
    case "expired": return done(fail(410, "code_expired"));
    case "locked": return done(fail(429, "code_locked"));
    default: return done(fail(401, "invalid_code")); // inconnu, déjà utilisé, révoqué ou faux : même réponse
  }
  try {
    const result = await deps.setPassword(row.profile_id, body.password);
    if (result?.error) return done(fail(500, "activation_failed"));
  } catch {
    return done(fail(500, "activation_failed"));
  }
  return done(json(200, { ok: true }));
}
