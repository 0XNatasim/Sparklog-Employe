// supabase/functions/pointage_api/index.ts
//
// Porte d'entrée du côté 1 pour le côté 2 (Sparklog-Gestion). Toute la logique est dans handler.js (testée) ; ce fichier ne fait que brancher Supabase.
//
// Déploiement : `verify_jwt = false` OBLIGATOIRE (l'appelant n'est pas un utilisateur Supabase : il s'authentifie avec son propre secret, vérifié par
// `sync_authenticate`). Secrets de la fonction : SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY (fournis par la plateforme). Aucune autre variable.
// Routes (GET sauf /actions) : /health, /employees, /jobs/changed, /jobs/deleted, /jobs/ids, /claims/changed, POST /actions.
// Documentation du contrat : docs/api-cote2.md.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handle } from "./handler.js";

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

serve(async (request) => {
  if (!supabaseUrl || !serviceRole) {
    return new Response(JSON.stringify({ ok: false, error: "server_not_configured" }), { status: 500, headers: { "content-type": "application/json" } });
  }
  const admin = createClient(supabaseUrl, serviceRole, { auth: { persistSession: false, autoRefreshToken: false } });
  return handle(request, {
    // PostgREST renvoie le SQLSTATE dans `error.code` et notre code court dans `error.message`.
    rpc: async (name: string, args: Record<string, unknown>) => {
      const { data, error } = await admin.rpc(name, args);
      return { data, error: error ? { code: error.code, message: error.message } : null };
    },
    // Compte de connexion à adresse factice (clé de service seulement) ; `email_exists` est reconnu par le gestionnaire.
    createAuthUser: async (email: string, password: string) => {
      const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
      return error ? { id: null, error: { code: error.code ?? "auth_error" } } : { id: data.user.id, error: null };
    },
    deleteAuthUser: async (id: string) => { await admin.auth.admin.deleteUser(id); },
    // Journal minimal : route et code de réponse. Jamais le secret, le corps ni les paramètres.
    log: ({ route, status }: { route: string; status: number }) => console.log(JSON.stringify({ route, status })),
  });
});
