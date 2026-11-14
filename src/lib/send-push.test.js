import { describe, expect, it } from "vitest";
import { GENERIC_BODY, GENERIC_REREAD_BODY } from "../../supabase/functions/send_push/push_payload.js";
import { handle } from "../../supabase/functions/send_push/handler.js";

const SECRET = "skc_" + "A1b2C3d4E5".repeat(4);
const ANN = "44444444-4444-4444-8444-444444444444";
const subs = [{ id: "s1", user_id: "u1", endpoint: "https://push.invalid/1" }, { id: "s2", user_id: "u2", endpoint: "https://push.invalid/2" }, { id: "s3", user_id: "u2", endpoint: "https://push.invalid/3" }];

function setup(over = {}) {
  const calls = { delivered: [], removed: [], recipients: [], logs: [] };
  const deps = {
    authenticate: async () => "client-1",
    vapidConfigured: () => true,
    announcementExists: async () => true,
    recipients: async (id, reread) => { calls.recipients.push([id, reread]); return { employeeIds: ["u1", "u2"], unread: new Map([["u1", 2]]) }; },
    subscriptions: async () => subs,
    deliver: async (sub, message) => { calls.delivered.push({ sub, message: JSON.parse(message) }); return 201; },
    removeGone: async (ids) => { calls.removed.push(...ids); },
    log: (e) => calls.logs.push(e),
    ...over,
  };
  return { deps, calls };
}
const post = (body, headers = {}) => new Request("https://x.invalid/send_push", { method: "POST", headers: { authorization: `Bearer ${SECRET}`, "content-type": "application/json", ...headers }, body: typeof body === "string" ? body : JSON.stringify(body) });
const run = async (req, deps) => { const r = await handle(req, deps); return { status: r.status, body: await r.json(), headers: r.headers }; };

describe("send_push (annonce → notification téléphone)", () => {
  it("envoie un texte générique, jamais le contenu, avec le nombre de messages non lus sur l'icône", async () => {
    const { deps, calls } = setup();
    const r = await run(post({ announcement_id: ANN }), deps);
    expect(r).toMatchObject({ status: 200, body: { ok: true, sent: 3, failed: 0, removed: 0 } });
    expect(calls.recipients).toEqual([[ANN, false]]);
    for (const { message } of calls.delivered) {
      expect(message.body).toBe(GENERIC_BODY);
      expect(message.tag).toBe(`announcement-${ANN}`);
      expect(message.url).toBe("/");
    }
    expect(calls.delivered.map((d) => d.message.badge)).toEqual([2, 1, 1]);
  });

  it("« lire à nouveau » : seulement ceux qui n'ont pas accusé réception, texte générique de correction", async () => {
    const { deps, calls } = setup();
    await run(post({ announcement_id: ANN, reread: true }), deps);
    expect(calls.recipients).toEqual([[ANN, true]]);
    expect(calls.delivered[0].message.body).toBe(GENERIC_REREAD_BODY);
  });

  it("retire les abonnements morts (404 / 410) et compte les échecs sans les retirer", async () => {
    const { deps, calls } = setup({ deliver: async (sub) => ({ s1: 410, s2: 404, s3: 500 })[sub.id] });
    const r = await run(post({ announcement_id: ANN }), deps);
    expect(r.body).toMatchObject({ sent: 0, failed: 3, removed: 2 });
    expect(calls.removed.sort()).toEqual(["s1", "s2"]);
  });

  it("une panne d'envoi isolée n'arrête pas les autres", async () => {
    const { deps } = setup({ deliver: async (sub) => { if (sub.id === "s1") throw new Error("réseau"); return 201; } });
    expect((await run(post({ announcement_id: ANN }), deps)).body).toMatchObject({ sent: 2, failed: 1 });
  });

  it("répond sans rien envoyer quand personne n'est destinataire", async () => {
    const { deps, calls } = setup({ recipients: async () => ({ employeeIds: [], unread: new Map() }) });
    expect((await run(post({ announcement_id: ANN }), deps)).body).toEqual({ ok: true, sent: 0, failed: 0, removed: 0 });
    expect(calls.delivered).toHaveLength(0);
  });

  it("refuse sans base un secret absent ou mal formé, et une mauvaise méthode", async () => {
    for (const authorization of [undefined, "", "Basic x", "Bearer skc_court", `Bearer ${SECRET}x`]) {
      const { deps } = setup({ authenticate: async () => { throw new Error("ne doit pas être appelé"); } });
      const req = new Request("https://x.invalid/", { method: "POST", headers: authorization === undefined ? {} : { authorization }, body: "{}" });
      expect((await run(req, deps)).status, String(authorization)).toBe(401);
    }
    const { deps } = setup();
    expect((await run(new Request("https://x.invalid/", { method: "GET" }), deps)).status).toBe(405);
  });

  it("401 pour un secret inconnu, 429 quand la base limite les essais, 503 sans clés VAPID", async () => {
    expect((await run(post({ announcement_id: ANN }), setup({ authenticate: async () => null }).deps)).status).toBe(401);
    const limited = await run(post({ announcement_id: ANN }), setup({ authenticate: async () => "rate_limited" }).deps);
    expect([limited.status, limited.headers.get("retry-after")]).toEqual([429, "60"]);
    const noVapid = setup({ vapidConfigured: () => false });
    expect((await run(post({ announcement_id: ANN }), noVapid.deps)).body.error).toBe("push_not_configured");
    expect(noVapid.calls.delivered).toHaveLength(0);
  });

  it("valide le corps avant de lire la base", async () => {
    const cases = [["{pas du json", 400, "invalid_json"], ["[1]", 400, "invalid_json"], [{ announcement_id: "x" }, 422, "invalid_announcement_id"], [{}, 422, "invalid_announcement_id"],
      [{ announcement_id: ANN, reread: "oui" }, 422, "invalid_reread"], ["x".repeat(3000), 413, "payload_too_large"]];
    for (const [body, status, error] of cases) {
      const { deps, calls } = setup();
      const r = await run(post(body), deps);
      expect([r.status, r.body.error], String(error)).toEqual([status, error]);
      expect(calls.recipients).toHaveLength(0);
    }
  });

  it("404 pour une annonce inconnue ; 500 générique si la base échoue, sans texte technique", async () => {
    expect((await run(post({ announcement_id: ANN }), setup({ announcementExists: async () => false }).deps)).body.error).toBe("announcement_not_found");
    const r = await run(post({ announcement_id: ANN }), setup({ subscriptions: async () => { throw new Error("relation push_subscriptions inexistante"); } }).deps);
    expect([r.status, r.body]).toEqual([500, { ok: false, error: "internal_error" }]);
  });

  it("ne journalise que la route et le code de réponse", async () => {
    const { deps, calls } = setup();
    await run(post({ announcement_id: ANN }), deps);
    expect(calls.logs).toEqual([{ route: "/", status: 200 }]);
    expect(JSON.stringify(calls.logs)).not.toContain(SECRET);
  });
});
