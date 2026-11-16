import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";

vi.mock("@/supabaseClient", () => ({ supabase: {} }));
import {
  CODE_ALPHABET, PASSWORD_MAX, PASSWORD_MIN, activateAccount, activationErrorKey, isValidCodeFormat, loginEmail, formatEmployeeNumber, normalizeCode, parseEmployeeNumber, passwordProblem,
} from "./employee-login";
import { dictionaries } from "./i18n";

describe("numéro d'employé", () => {
  it("accepte 1 à 999999 (affiché sur 4 chiffres), refuse le reste", () => {
    expect(parseEmployeeNumber("4821")).toBe(4821);
    expect(parseEmployeeNumber(" 48 21 ")).toBe(4821);
    expect(parseEmployeeNumber("1000")).toBe(1000);
    expect(parseEmployeeNumber("999999")).toBe(999999);
    expect(parseEmployeeNumber("0001")).toBe(1);
    expect(parseEmployeeNumber("73")).toBe(73);
    expect(formatEmployeeNumber(1)).toBe("0001");
    expect(formatEmployeeNumber(4821)).toBe("4821");
    expect(formatEmployeeNumber(123456)).toBe("123456");
    for (const bad of ["0", "000", "1000000", "12a4", "", null, undefined, "4821@pointage.invalid", "-4821", "48.21"]) expect(parseEmployeeNumber(bad), String(bad)).toBeNull();
  });
  it("fabrique l'adresse factice", () => expect(loginEmail(4821)).toBe("4821@pointage.invalid"));
});

describe("code d'activation", () => {
  it("normalise comme le serveur", () => {
    expect(normalizeCode(" abcde-fghjk ")).toBe("ABCDEFGHJK");
    expect(isValidCodeFormat("abcde fghjk")).toBe(true);
    for (const bad of ["ABCDEFGHJ", "ABCDEFGHJ0", "OOOOOOOOOO", "ABCDEFGHJKM", ""]) expect(isValidCodeFormat(bad), bad).toBe(false);
  });
  it("garde l'alphabet identique à celui de la base (0001)", () => {
    const sql = readFileSync(new URL("../../supabase/next/0001_identity.sql", import.meta.url), "utf8");
    expect(sql.match(/alphabet constant text := '([A-Z2-9]+)'/)[1]).toBe(CODE_ALPHABET);
  });
});

describe("mot de passe", () => {
  it("applique les mêmes limites que le serveur", () => {
    expect(passwordProblem("", 4821, "")).toBeNull();
    expect(passwordProblem("a".repeat(PASSWORD_MIN - 1), 4821, "")).toBe("password_too_short");
    expect(passwordProblem("a".repeat(PASSWORD_MAX + 1), 4821, "")).toBe("password_too_long");
    expect(passwordProblem("ma phrase 4821 solide", 4821, "")).toBe("password_too_guessable");
    expect(passwordProblem("avec abcdefghjk dedans", 4821, "ABCDE FGHJK")).toBe("password_too_guessable");
    expect(passwordProblem("une phrase de passe solide", 4821, "ABCDEFGHJK")).toBeNull();
  });
  it("les constantes suivent la fonction serveur", () => {
    const src = readFileSync(new URL("../../supabase/functions/activate_account/handler.js", import.meta.url), "utf8");
    expect(src).toContain(`PASSWORD_MIN = ${PASSWORD_MIN}`);
    expect(src).toContain(`PASSWORD_MAX = ${PASSWORD_MAX}`);
  });
});

describe("activateAccount", () => {
  const cfg = (fetchImpl) => ({ url: "https://x.invalid", anonKey: "anon", fetchImpl });
  const args = { number: 4821, code: "abcde-fghjk", password: "une phrase de passe solide" };
  const reply = (status, body) => async () => new Response(JSON.stringify(body), { status });

  it("envoie le numéro, le code normalisé et le mot de passe à la fonction", async () => {
    let seen;
    const r = await activateAccount(cfg(async (url, init) => { seen = { url, init }; return new Response(JSON.stringify({ ok: true }), { status: 200 }); }), args);
    expect(r).toEqual({ ok: true });
    expect(seen.url).toBe("https://x.invalid/functions/v1/activate_account");
    expect(seen.init.method).toBe("POST");
    expect(JSON.parse(seen.init.body)).toEqual({ employee_number: 4821, code: "ABCDEFGHJK", password: args.password });
  });
  it("renvoie le code d'erreur du serveur, ou générique si le corps est illisible", async () => {
    expect(await activateAccount(cfg(reply(401, { ok: false, error: "invalid_code" })), args)).toMatchObject({ ok: false, error: "invalid_code", status: 401 });
    expect(await activateAccount(cfg(async () => new Response("<html>", { status: 502 })), args)).toMatchObject({ ok: false, error: "internal_error" });
    expect(await activateAccount(cfg(reply(200, { nope: 1 })), args)).toMatchObject({ ok: false });
  });
  it("traite une panne réseau ou un délai dépassé comme « network »", async () => {
    expect(await activateAccount(cfg(async () => { throw new TypeError("Failed to fetch"); }), args)).toEqual({ ok: false, error: "network" });
    expect(await activateAccount({ ...cfg(() => new Promise(() => {})), timeoutMs: 20 }, args)).toEqual({ ok: false, error: "network" });
  });
});

describe("textes", () => {
  it("chaque code d'erreur connu a un texte en français et en anglais", () => {
    for (const code of ["invalid_code", "code_expired", "code_locked", "activation_failed", "password_too_short", "password_too_guessable", "invalid_code_format", "invalid_employee_number", "internal_error", "network", "bad"]) {
      const key = activationErrorKey(code);
      for (const lang of ["fr", "en"]) expect(dictionaries[lang][key], `${lang} ${key}`).toBeTruthy();
    }
  });
});
