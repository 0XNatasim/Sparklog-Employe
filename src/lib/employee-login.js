// Connexion par numéro d'employé (côté 1). Le numéro identifie ; il n'authentifie qu'avec un mot de passe (ou, la première fois, un code d'activation).
// L'adresse de connexion de Supabase Auth est factice : `<numéro>@pointage.invalid` (créée par la fonction pointage_api, jamais affichée à l'employé).
import { withTimeout } from "@/lib/utils";

export const FAKE_EMAIL_DOMAIN = "pointage.invalid";
export const EMPLOYEE_NUMBER_MIN = 1;
export const EMPLOYEE_NUMBER_MAX = 999999;
export const PASSWORD_MIN = 12;
export const PASSWORD_MAX = 72;
export const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const CODE_RE = new RegExp(`^[${CODE_ALPHABET}]{10}$`);

// Texte saisi → entier valide, sinon null. Seuls les chiffres comptent (espaces tolérés) ; jamais d'adresse courriel ici.
export function parseEmployeeNumber(text) {
  const digits = String(text ?? "").replace(/\s/g, "");
  if (!/^\d{1,6}$/.test(digits)) return null;
  const n = Number(digits);
  return n >= EMPLOYEE_NUMBER_MIN && n <= EMPLOYEE_NUMBER_MAX ? n : null;
}

// Affichage : toujours 4 chiffres au moins (« 0001 »). Le numéro stocké reste un entier.
export const formatEmployeeNumber = (n) => (Number.isInteger(n) ? String(n).padStart(4, "0") : "");

export const loginEmail = (number) => `${number}@${FAKE_EMAIL_DOMAIN}`;

// Même normalisation que la fonction serveur : espaces et tirets retirés, majuscules.
export const normalizeCode = (text) => String(text ?? "").replace(/[\s-]/g, "").toUpperCase();
export const isValidCodeFormat = (text) => CODE_RE.test(normalizeCode(text));

// Mot de passe : longueur seulement ; ni le numéro ni le code (même règle que le serveur, pour afficher le problème avant l'envoi).
export function passwordProblem(password, number, code) {
  if (typeof password !== "string" || password.length === 0) return null; // champ vide : pas encore une erreur à afficher
  if (password.length < PASSWORD_MIN) return "password_too_short";
  if (password.length > PASSWORD_MAX) return "password_too_long";
  if ((number && password.includes(String(number))) || (code && password.toUpperCase().includes(normalizeCode(code)))) return "password_too_guessable";
  return null;
}

const KNOWN_ERRORS = new Set([
  "invalid_employee_number", "invalid_code_format", "invalid_code", "code_expired", "code_locked", "activation_failed",
  "password_too_short", "password_too_long", "password_too_guessable", "invalid_password", "internal_error", "network",
]);
// Clé de texte pour une erreur de la fonction `activate_account` ; tout le reste = message générique.
export const activationErrorKey = (code) => (KNOWN_ERRORS.has(code) ? `login.errors.${code}` : "login.errors.generic");

// Appel de la fonction Edge `activate_account` (pas de session : l'employé n'en a pas encore). Renvoie { ok: true } ou { ok: false, error }.
export async function activateAccount({ url, anonKey, fetchImpl = globalThis.fetch, timeoutMs = 15000 }, { number, code, password }) {
  try {
    const response = await withTimeout(fetchImpl(`${url}/functions/v1/activate_account`, {
      method: "POST",
      headers: { "content-type": "application/json", apikey: anonKey, authorization: `Bearer ${anonKey}` },
      body: JSON.stringify({ employee_number: number, code: normalizeCode(code), password }),
    }), timeoutMs);
    let body = null;
    try { body = await response.json(); } catch { /* corps absent ou illisible */ }
    if (response.ok && body?.ok === true) return { ok: true };
    return { ok: false, error: typeof body?.error === "string" ? body.error : "internal_error", status: response.status };
  } catch {
    return { ok: false, error: "network" };
  }
}
