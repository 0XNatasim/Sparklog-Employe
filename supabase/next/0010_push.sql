-- Sparklog-Employés — schéma neuf du côté 1. Migration 0010 : abonnements aux notifications sur le téléphone (Web Push).
-- Relevé dans une base reconstruite à partir des 150 migrations de Sparklog V2.4.258 (0074, 0113, 0172, 0173 et voisines).
--
-- Écarts voulus par rapport à Sparklog :
--  * **pas de `user_agent`** : l'appareil de l'employé (modèle, navigateur) n'est pas conservé (`PLAN.md` 3.6 et 12.2). Le paramètre reste accepté par
--    `register_push_subscription` pour ne pas casser le client, mais il est ignoré ;
--  * `push_enabled_users` renvoie aussi le numéro d'employé ;
--  * `purge_stale_push_subscriptions` (service seulement) : un abonnement qui n'a pas été revu depuis un délai donné est supprimé (minimisation).
--
-- À SAVOIR (conformité, `OFFICIEL.md`) : l'adresse (`endpoint`) d'un abonnement appartient au service de notification du navigateur (Google, Apple ou Mozilla,
-- hors Québec). Elle identifie un appareil. Le contenu d'une notification doit donc être **générique** (jamais un nom, une heure précise ni un montant) :
-- p. ex. « Une de vos fiches a été retournée ». La fonction Edge `send_push` est à adapter dans ce sens (étape 12.2 du plan).

create table public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  endpoint text not null unique check (char_length(endpoint) between 20 and 2048),
  p256dh text not null check (char_length(p256dh) between 20 and 256),
  auth text not null check (char_length(auth) between 8 and 128),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index push_subscriptions_user_idx on public.push_subscriptions (user_id);
create index push_subscriptions_last_seen_idx on public.push_subscriptions (last_seen_at);

-- Enregistrer (ou reprendre) l'abonnement de l'appareil. Un même appareil qui change de compte reprend son abonnement.
create function public.register_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'not_authenticated';
  end if;
  if not public.is_active_employee() then
    raise exception using errcode = '42501', message = 'account_paused';
  end if;
  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, last_seen_at = now();
end;
$$;

-- Qui a des notifications activées (gestionnaires avec double authentification) : identifiants et numéros seulement.
create function public.push_enabled_users()
returns table (user_id uuid, employee_number integer)
language sql stable security definer set search_path = '' as $$
  select distinct s.user_id, p.employee_number
    from public.push_subscriptions s join public.profiles p on p.id = s.user_id
   where public.get_my_role() = 'manager';
$$;

-- Ménage : supprime les abonnements non revus depuis `p_days` jours (service seulement ; à planifier). Renvoie le nombre supprimé.
create function public.purge_stale_push_subscriptions(p_days integer default 180)
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if p_days is null or p_days < 7 then
    raise exception using errcode = '22023', message = 'invalid_retention_days';
  end if;
  delete from public.push_subscriptions where last_seen_at < now() - make_interval(days => p_days);
  get diagnostics n = row_count;
  return n;
end;
$$;

-- ── Droits et règles d'accès ────────────────────────────────────────────────
revoke all on table public.push_subscriptions from anon, public, authenticated;
alter table public.push_subscriptions enable row level security;
grant select, delete on public.push_subscriptions to authenticated;
grant select, delete on public.push_subscriptions to service_role;   -- la fonction Edge lit les abonnements et retire ceux qui n'existent plus
create policy push_subscriptions_read_own on public.push_subscriptions for select to authenticated using (user_id = (select auth.uid()));
create policy push_subscriptions_delete_own on public.push_subscriptions for delete to authenticated using (user_id = (select auth.uid()));

revoke all on function public.register_push_subscription(text, text, text, text), public.push_enabled_users(), public.purge_stale_push_subscriptions(integer)
  from public, anon, authenticated;
grant execute on function public.register_push_subscription(text, text, text, text), public.push_enabled_users() to authenticated;
grant execute on function public.purge_stale_push_subscriptions(integer) to service_role;
