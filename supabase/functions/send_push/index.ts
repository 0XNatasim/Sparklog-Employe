// supabase/functions/send_push/index.ts
//
// Notification téléphone d'une annonce. Toute la logique est dans handler.js (testée) ; ce fichier branche Supabase et web-push.
// Appelée par le côté 2 avec sa clé d'échange (la même que pointage_api) : POST { announcement_id, reread? }.
// Déploiement : `verify_jwt = false` OBLIGATOIRE (l'appelant s'authentifie avec son secret, vérifié par `sync_authenticate`).
// Secrets : VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (mailto: ou https:) — `npx web-push generate-vapid-keys`.
// Aucun en-tête CORS : appel de serveur à serveur. Journal : route et code de réponse seulement.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";
import { handle } from "./handler.js";

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const vapidPublic = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const vapidPrivate = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const vapidSubject = Deno.env.get("VAPID_SUBJECT") ?? "";
const PUSH_TIMEOUT_MS = 10_000;
const MAX_SUBSCRIPTIONS = 2000;

serve((request) => {
  if (!supabaseUrl || !serviceRole) {
    return new Response(JSON.stringify({ ok: false, error: "server_not_configured" }), { status: 500, headers: { "content-type": "application/json" } });
  }
  const admin = createClient(supabaseUrl, serviceRole, { auth: { persistSession: false, autoRefreshToken: false } });
  return handle(request, {
    // Un secret faux renvoie null (jamais une erreur) ; 54000 = trop d'essais.
    authenticate: async (secret: string) => {
      const { data, error } = await admin.rpc("sync_authenticate", { p_secret: secret });
      if (error) return error.code === "54000" ? "rate_limited" : null;
      return data ?? null;
    },
    vapidConfigured: () => Boolean(vapidPublic && vapidPrivate && vapidSubject),
    announcementExists: async (id: string) => {
      const { data } = await admin.from("announcements").select("id").eq("id", id).maybeSingle();
      return Boolean(data);
    },
    recipients: async (id: string, reread: boolean) => {
      let query = admin.from("announcement_recipients").select("employee_id").eq("announcement_id", id).is("withdrawn_at", null);
      if (reread) query = query.is("acknowledged_at", null);
      const { data } = await query;
      const employeeIds = (data ?? []).map((r: { employee_id: string }) => r.employee_id);
      const unread = new Map<string, number>();
      if (employeeIds.length) {
        const { data: rows } = await admin.from("announcement_recipients").select("employee_id")
          .in("employee_id", employeeIds).is("acknowledged_at", null).is("withdrawn_at", null);
        for (const row of rows ?? []) unread.set(row.employee_id, (unread.get(row.employee_id) ?? 0) + 1);
      }
      return { employeeIds, unread };
    },
    subscriptions: async (employeeIds: string[]) => {
      const { data, error } = await admin.from("push_subscriptions").select("id, user_id, endpoint, p256dh, auth").in("user_id", employeeIds).limit(MAX_SUBSCRIPTIONS);
      if (error) throw error;
      return data ?? [];
    },
    // generateRequestDetails construit la requête chiffrée ; on l'envoie avec fetch() pour la borner par un AbortSignal.
    deliver: async (sub: { endpoint: string; p256dh: string; auth: string }, message: string) => {
      webpush.setVapidDetails(vapidSubject, vapidPublic, vapidPrivate);
      const d = await webpush.generateRequestDetails({ endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } }, message, { TTL: 60 * 60 * 24, urgency: "high" });
      const res = await fetch(d.endpoint, { method: d.method, headers: d.headers, body: d.body, signal: AbortSignal.timeout(PUSH_TIMEOUT_MS) });
      await res.body?.cancel();
      return res.status;
    },
    removeGone: async (ids: string[]) => { await admin.from("push_subscriptions").delete().in("id", ids); },
    log: ({ route, status }: { route: string; status: number }) => console.log(JSON.stringify({ route, status })),
  });
});
