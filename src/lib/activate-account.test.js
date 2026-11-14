import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { CODE_RE, MAX_BODY_BYTES, PASSWORD_MAX, PASSWORD_MIN, handle, passwordProblem } from "../../supabase/functions/activate_account/handler.js";

const URL_ = "https://example.invalid/functions/v1/activate_account";
const PROFILE = "55555555-5555-4555-8555-555555555555";
const GOOD = { employee_number: 4821, code: "ABCDEFGHJK", password: "une phrase de passe solide" };

function setup({ status = "ok", rpcError = null, setError = null, setThrows = false } = {}) {
  const calls = []; const sets = []; const logs = [];
  return {
    calls, sets, logs,
    rpc: async (name, args) => { calls.push({ name, args }); return rpcError ? { data: null, error: rpcError } : { data: [{ status, profile_id: status === "ok" ? PROFILE : null }], error: null }; },
    setPassword: async (id, password) => { sets.push({ id, password }); if (setThrows) throw new Error("x"); return { error: setError }; },
    log: (e) => logs.push(e),
  };
}
const post = (body, opts = {}) => new Request(URL_, { method: "POST", headers: { "content-type": "application/json", ...(opts.headers || {}) }, body: opts.raw ?? JSON.stringify(body) });
const run = async (req, deps) => { const r = await handle(req, deps); return { status: r.status, body: await r.json(), headers: r.headers }; };

describe("activate_account", () => {
  it("consomme le code puis pose le mot de passe", async () => {
    const deps = setup();
    const r = await run(post(GOOD), deps);
    expect(r).toMatchObject({ status: 200, body: { ok: true } });
    expect(deps.calls).toEqual([{ name: "consume_activation_code", args: { p_employee_number: 4821, p_code: "ABCDEFGHJK" } }]);
    expect(deps.sets).toEqual([{ id: PROFILE, password: GOOD.password }]);
    expect(r.headers.get("cache-control")).toBe("no-store");
  });

  it("accepte un code saisi avec espaces, tirets ou minuscules", async () => {
    const deps = setup();
    expect((await run(post({ ...GOOD, code: "abcde-fghjk " }), deps)).status).toBe(200);
    expect(deps.calls[0].args.p_code).toBe("ABCDEFGHJK");
  });

  it("refuse sans toucher à la base un numéro, un code ou un mot de passe invalide", async () => {
    const cases = [
      [{ ...GOOD, employee_number: 999 }, "invalid_employee_number"], [{ ...GOOD, employee_number: "4821" }, "invalid_employee_number"], [{ ...GOOD, employee_number: 1000000 }, "invalid_employee_number"],
      [{ ...GOOD, code: "ABCDEFGHJ" }, "invalid_code_format"], [{ ...GOOD, code: "ABCDEFGHJ0" }, "invalid_code_format"], [{ ...GOOD, code: "OOOOOOOOOO" }, "invalid_code_format"], [{ ...GOOD, code: 12345 }, "invalid_code_format"],
      [{ ...GOOD, password: "court" }, "password_too_short"], [{ ...GOOD, password: "x".repeat(PASSWORD_MAX + 1) }, "password_too_long"], [{ ...GOOD, password: undefined }, "invalid_password"],
      [{ ...GOOD, password: "mon numero 4821 perso" }, "password_too_guessable"], [{ ...GOOD, password: "le code abcdefghjk ici" }, "password_too_guessable"],
    ];
    for (const [body, error] of cases) {
      const deps = setup();
      const r = await run(post(body), deps);
      expect([r.status, r.body.error], error).toEqual([422, error]);
      expect(deps.calls).toHaveLength(0);
      expect(deps.sets).toHaveLength(0);
    }
  });

  it("ne pose aucun mot de passe quand la base refuse le code, avec une réponse précise seulement pour expiré / bloqué", async () => {
    for (const [status, http, error] of [["invalid", 401, "invalid_code"], ["expired", 410, "code_expired"], ["locked", 429, "code_locked"], ["autre", 401, "invalid_code"]]) {
      const deps = setup({ status });
      const r = await run(post(GOOD), deps);
      expect([r.status, r.body.error], status).toEqual([http, error]);
      expect(deps.sets).toHaveLength(0);
    }
  });

  it("répond 500 générique si la base échoue, sans texte technique", async () => {
    const deps = setup({ rpcError: { code: "XX000" } });
    const r = await run(post(GOOD), deps);
    expect([r.status, r.body]).toEqual([500, { ok: false, error: "internal_error" }]);
    expect(deps.sets).toHaveLength(0);
  });

  it("signale activation_failed quand le mot de passe ne peut pas être posé (erreur ou exception)", async () => {
    for (const opts of [{ setError: { code: "x" } }, { setThrows: true }]) {
      const r = await run(post(GOOD), setup(opts));
      expect([r.status, r.body.error]).toEqual([500, "activation_failed"]);
    }
  });

  it("valide la méthode et le corps", async () => {
    expect((await run(new Request(URL_, { method: "GET" }), setup())).status).toBe(405);
    expect((await run(post(null, { raw: "{pas du json" }), setup())).body.error).toBe("invalid_json");
    expect((await run(post(null, { raw: "[1]" }), setup())).body.error).toBe("invalid_json");
    expect((await run(post(null, { raw: "x".repeat(MAX_BODY_BYTES + 1) }), setup())).status).toBe(413);
    expect((await run(post(GOOD, { headers: { "content-length": String(MAX_BODY_BYTES + 1) } }), setup())).status).toBe(413);
  });

  it("ne journalise ni le numéro, ni le code, ni le mot de passe", async () => {
    const deps = setup();
    await run(post(GOOD), deps);
    expect(deps.logs).toEqual([{ route: "/", status: 200 }]);
    expect(JSON.stringify(deps.logs)).not.toMatch(/4821|ABCDEFGHJK|phrase/);
  });

  it("garde l'alphabet du code identique à celui de la base (0001) et la longueur de mot de passe cohérente", () => {
    const sql = readFileSync(new URL("../../supabase/next/0001_identity.sql", import.meta.url), "utf8");
    const alphabet = sql.match(/alphabet constant text := '([A-Z2-9]+)'/)[1];
    expect(CODE_RE.source).toBe(`^[${alphabet}]{10}$`);
    expect(passwordProblem("a".repeat(PASSWORD_MIN), 1234, "ABCDEFGHJK")).toBeNull();
  });

  it("index.ts : un seul domaine autorisé, journal minimal, aucun * en CORS", () => {
    const src = readFileSync(new URL("../../supabase/functions/activate_account/index.ts", import.meta.url), "utf8");
    expect(src).toContain("ALLOWED_ORIGIN");
    expect(src).not.toMatch(/allow-origin["']?\s*:\s*["']\*/i);
    expect(src).toContain("verify_jwt = false");
    expect(src).not.toMatch(/console\.\w+\([^)]*(password|code|employee_number|body)/);
  });
});
