// supabase/functions/activate_account/index.ts
//
// Première connexion d'un employé (numéro + code d'activation + mot de passe). Logique dans handler.js (testée).
// Déploiement : `verify_jwt = false` OBLIGATOIRE (l'employé n'a pas encore de session). Secrets : SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY (fournis).
// CORS : l'application est servie depuis son propre domaine ; la variable ALLOWED_ORIGIN (une seule origine) est la seule autorisée.
// Journal : route et code de réponse seulement (jamais le numéro, le code ni le mot de passe).

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handle } from "./handler.js";

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const allowedOrigin = Deno.env.get("ALLOWED_ORIGIN") ?? "";

serve(async (request) => {
  const cors: Record<string, string> = allowedOrigin
    ? { "access-control-allow-origin": allowedOrigin, "access-control-allow-headers": "content-type, authorization, apikey, x-client-info", "access-control-allow-methods": "POST, OPTIONS", vary: "origin" }
    : {};
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (!supabaseUrl || !serviceRole) {
    return new Response(JSON.stringify({ ok: false, error: "server_not_configured" }), { status: 500, headers: { "content-type": "application/json", ...cors } });
  }
  const admin = createClient(supabaseUrl, serviceRole, { auth: { persistSession: false, autoRefreshToken: false } });
  const response = await handle(request, {
    rpc: async (name: string, args: Record<string, unknown>) => {
      const { data, error } = await admin.rpc(name, args);
      return { data, error: error ? { code: error.code } : null };
    },
    setPassword: async (id: string, password: string) => {
      const { error } = await admin.auth.admin.updateUserById(id, { password });
      return { error: error ? { code: error.code ?? "auth_error" } : null };
    },
    log: ({ route, status }: { route: string; status: number }) => console.log(JSON.stringify({ route, status })),
  });
  for (const [k, v] of Object.entries(cors)) response.headers.set(k, v);
  return response;
});
