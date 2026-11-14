// supabase/functions/send_push/handler.js
//
// Notification téléphone d'une annonce (Web Push + VAPID). Logique pure, testée par src/lib/send-push.test.js ; index.ts branche Supabase et web-push.
//
// Appelée par le CÔTÉ 2 avec sa clé d'échange (`Authorization: Bearer skc_…`, la même que pointage_api), jamais par le navigateur :
//   POST { announcement_id: uuid, reread?: true }
// Les destinataires sont lus ici, côté serveur (annonce non retirée ; avec `reread`, seulement ceux qui n'ont pas accusé réception).
// TEXTE GÉNÉRIQUE : la notification ne contient jamais le contenu de l'annonce, ni nom, heure ou montant (l'adresse d'un abonnement appartient à Google,
// Apple ou Mozilla : `docs/schema-cote1.md`, 0010).
import { buildPushPayload, GENERIC_BODY, GENERIC_REREAD_BODY, isGonePushStatus } from "./push_payload.js";

export const MAX_BODY_BYTES = 2048;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SECRET_RE = /^skc_[A-Za-z0-9]{40}$/;
const HEADERS = { "content-type": "application/json", "cache-control": "no-store", "x-content-type-options": "nosniff" };
const json = (status, body, extra = {}) => new Response(JSON.stringify(body), { status, headers: { ...HEADERS, ...extra } });
const fail = (status, error, extra) => json(status, { ok: false, error }, extra);

export async function handle(request, deps) {
  const log = (status) => { try { deps.log?.({ route: "/", status }); } catch { /* le journal ne bloque jamais */ } };
  const done = (response) => { log(response.status); return response; };

  if (request.method !== "POST") return done(fail(405, "method_not_allowed", { allow: "POST" }));
  const match = /^Bearer (\S+)$/.exec(request.headers.get("authorization") || "");
  if (!match || !SECRET_RE.test(match[1])) return done(fail(401, "invalid_client"));
  if (Number(request.headers.get("content-length") || 0) > MAX_BODY_BYTES) return done(fail(413, "payload_too_large"));
  const text = await request.text();
  if (text.length > MAX_BODY_BYTES) return done(fail(413, "payload_too_large"));

  try {
    const auth = await deps.authenticate(match[1]);
    if (auth === "rate_limited") return done(fail(429, "rate_limited", { "retry-after": "60" }));
    if (!auth) return done(fail(401, "invalid_client"));
    if (!deps.vapidConfigured()) return done(fail(503, "push_not_configured"));

    let body;
    try { body = JSON.parse(text); } catch { return done(fail(400, "invalid_json")); }
    if (!body || typeof body !== "object" || Array.isArray(body)) return done(fail(400, "invalid_json"));
    if (!UUID_RE.test(String(body.announcement_id || ""))) return done(fail(422, "invalid_announcement_id"));
    if (body.reread !== undefined && typeof body.reread !== "boolean") return done(fail(422, "invalid_reread"));
    const reread = body.reread === true;

    if (!(await deps.announcementExists(body.announcement_id))) return done(fail(404, "announcement_not_found"));
    const { employeeIds, unread } = await deps.recipients(body.announcement_id, reread);
    if (!employeeIds.length) return done(json(200, { ok: true, sent: 0, failed: 0, removed: 0 }));
    const subscriptions = await deps.subscriptions(employeeIds);

    let sent = 0, failed = 0;
    const gone = [];
    await Promise.all(subscriptions.map(async (sub) => {
      try {
        const message = buildPushPayload({
          title: "SparkLog", body: reread ? GENERIC_REREAD_BODY : GENERIC_BODY, url: "/", tag: `announcement-${body.announcement_id}`,
          badge: Math.max(1, unread.get(sub.user_id) ?? 1),
        });
        const status = await deps.deliver(sub, message);
        if (status >= 200 && status < 300) sent++;
        else { failed++; if (isGonePushStatus(status)) gone.push(sub.id); }
      } catch { failed++; }
    }));
    if (gone.length) await deps.removeGone(gone);
    return done(json(200, { ok: true, sent, failed, removed: gone.length }));
  } catch {
    return done(fail(500, "internal_error"));
  }
}
