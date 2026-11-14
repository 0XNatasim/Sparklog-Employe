-- Sparklog-Employés : schéma complet du côté 1 (généré par scripts/build-preview-sql.sh ; ne pas modifier à la main).
-- À coller UNE SEULE FOIS dans l'éditeur SQL d'un projet Supabase VIERGE de test (docs/mode-emploi-apercu.md).

-- ════════════════════════════════════════════════════════════════════
-- 0001_identity.sql
-- ════════════════════════════════════════════════════════════════════
-- Sparklog-Employés — schéma neuf du côté 1 (pointage). Migration 0001 : identité par numéro d'employé + codes d'activation.
-- NE PAS appliquer à la base de Sparklog. Cible : la NOUVELLE base du côté 1 (PLAN.md, étapes 2, 5 et 9.4).
--
-- Principes :
--  * aucun nom, courriel, téléphone, NAS ni montant de paie ici (invariant I1) ;
--  * `auth.users.email` portera une adresse factice `<numéro>@pointage.invalid` (créée par une fonction Edge, pas par ce fichier) ;
--  * le numéro d'employé identifie, il n'authentifie pas : il ne sert qu'avec un code d'activation, puis un mot de passe choisi (idée 1) ;
--  * le code d'activation n'est jamais stocké en clair (condensat bcrypt), à usage unique, 72 h, 5 essais, et n'est lisible que par `service_role`.
-- Supabase place pgcrypto dans le schéma `extensions`.

create extension if not exists pgcrypto with schema extensions;

-- ── Profil minimal ──────────────────────────────────────────────────────────
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  employee_number integer not null unique check (employee_number between 1000 and 999999),
  role text not null default 'employee'
    check (role in ('employee', 'foreman', 'subcontractor_1', 'manager', 'admin', 'owner')),
  is_paused boolean not null default false,
  first_activated_at timestamptz,
  created_at timestamptz not null default now()
);
comment on column public.profiles.employee_number is
  'Numéro attribué par le côté 2 (aléatoire, non séquentiel, jamais réutilisé). Pseudonyme : seul le côté 2 sait à qui il appartient.';

revoke all on table public.profiles from anon, public, authenticated;
grant select on table public.profiles to authenticated;
alter table public.profiles enable row level security;
create policy profiles_select_own on public.profiles for select to authenticated using (id = auth.uid());

-- ── Codes d'activation ──────────────────────────────────────────────────────
create table public.activation_codes (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  code_hash text not null,
  expires_at timestamptz not null,
  attempts integer not null default 0 check (attempts >= 0),
  used_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);
create index activation_codes_profile_idx on public.activation_codes (profile_id, created_at desc);

-- Aucun droit pour le navigateur : uniquement les deux fonctions ci-dessous, appelées par une fonction Edge (service_role).
revoke all on table public.activation_codes from anon, public, authenticated;
alter table public.activation_codes enable row level security;

-- Code lisible : 10 caractères sans O, 0, I, 1, L (31 symboles, environ 49 bits). Tirage par rejet (octets >= 248 écartés) : aucun biais.
create function public.issue_activation_code(p_profile_id uuid, p_ttl interval default interval '72 hours')
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  bytes bytea;
  code text := '';
  i integer;
begin
  if not exists (select 1 from public.profiles where id = p_profile_id) then
    raise exception 'unknown_profile' using errcode = 'P0002';
  end if;
  while length(code) < 10 loop
    bytes := extensions.gen_random_bytes(32);
    for i in 0..31 loop
      exit when length(code) >= 10;
      if get_byte(bytes, i) < 248 then
        code := code || substr(alphabet, (get_byte(bytes, i) % 31) + 1, 1);
      end if;
    end loop;
  end loop;
  -- un seul code valide à la fois : l'ancien est révoqué
  update public.activation_codes set revoked_at = now()
   where profile_id = p_profile_id and used_at is null and revoked_at is null;
  insert into public.activation_codes (profile_id, code_hash, expires_at)
  values (p_profile_id, extensions.crypt(code, extensions.gen_salt('bf', 10)), now() + p_ttl);
  return code;
end;
$$;

-- Résultat : ok | invalid | expired | locked. Les essais ratés sont enregistrés (pas de `raise` : il annulerait le compte d'essais).
-- Un numéro inconnu répond `invalid`, comme un mauvais code (pas d'énumération des numéros).
create function public.consume_activation_code(p_employee_number integer, p_code text)
returns table (status text, profile_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  prof uuid;
  rec public.activation_codes%rowtype;
  max_attempts constant integer := 5;
begin
  select p.id into prof from public.profiles p where p.employee_number = p_employee_number and not p.is_paused;
  if prof is null then
    perform extensions.crypt(coalesce(p_code, ''), extensions.gen_salt('bf', 10)); -- temps de réponse comparable
    return query select 'invalid'::text, null::uuid;
    return;
  end if;
  select * into rec from public.activation_codes c
   where c.profile_id = prof and c.used_at is null and c.revoked_at is null
   order by c.created_at desc limit 1 for update;
  if not found then
    return query select 'invalid'::text, null::uuid;
    return;
  end if;
  if rec.attempts >= max_attempts then
    return query select 'locked'::text, null::uuid;
    return;
  end if;
  if rec.expires_at <= now() then
    return query select 'expired'::text, null::uuid;
    return;
  end if;
  if rec.code_hash = extensions.crypt(coalesce(p_code, ''), rec.code_hash) then
    update public.activation_codes set used_at = now() where id = rec.id;
    update public.profiles set first_activated_at = coalesce(first_activated_at, now()) where id = prof;
    return query select 'ok'::text, prof;
  else
    update public.activation_codes set attempts = attempts + 1 where id = rec.id;
    return query select 'invalid'::text, null::uuid;
  end if;
end;
$$;

revoke all on function public.issue_activation_code(uuid, interval) from public, anon, authenticated;
revoke all on function public.consume_activation_code(integer, text) from public, anon, authenticated;
grant execute on function public.issue_activation_code(uuid, interval) to service_role;
grant execute on function public.consume_activation_code(integer, text) to service_role;

-- ════════════════════════════════════════════════════════════════════
-- 0002_roles.sql
-- ════════════════════════════════════════════════════════════════════
-- Sparklog-Employés — schéma neuf du côté 1. Migration 0002 : rôles, double authentification des gestionnaires, lecture des profils.
-- Mêmes noms et même logique que Sparklog (0103, 0133) : `get_my_role()` ne renvoie `manager` qu'avec une session `aal2` ;
-- `is_privileged()` = propriétaire + `aal2`. Aucune donnée nominative : le profil ne contient que le numéro, le rôle et la pause.

alter table public.profiles
  add column admin_sections text[] not null default '{}';

-- Vrai quand la session a passé le deuxième facteur (jeton `aal` = aal2).
create function public.session_is_aal2()
returns boolean language sql stable set search_path = '' as $$
  select coalesce((select auth.jwt() ->> 'aal'), '') = 'aal2';
$$;

-- owner / manager (et admin avec sections accordées) → 'manager' seulement avec aal2, sinon 'employee' ;
-- admin sans section, sous-traitant et contremaître → 'employee' ; employé → 'employee'.
create function public.get_my_role()
returns text language sql stable security definer set search_path = '' as $$
  select case
           when p.role in ('owner', 'manager')
             or (p.role = 'admin' and coalesce(array_length(p.admin_sections, 1), 0) > 0)
             then case when public.session_is_aal2() then 'manager' else 'employee' end
           when p.role in ('admin', 'subcontractor_1', 'foreman') then 'employee'
           else p.role
         end
    from public.profiles p where p.id = auth.uid();
$$;

create function public.is_privileged()
returns boolean language sql stable security definer set search_path = '' as $$
  select public.session_is_aal2() and exists (
    select 1 from public.profiles where id = auth.uid() and role = 'owner'
  );
$$;

create function public.is_active_employee()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles
     where id = auth.uid() and role in ('employee', 'foreman', 'subcontractor_1') and is_paused = false
  );
$$;

revoke all on function public.session_is_aal2(), public.get_my_role(), public.is_privileged(), public.is_active_employee() from public, anon;
grant execute on function public.session_is_aal2(), public.get_my_role(), public.is_privileged(), public.is_active_employee() to authenticated;

-- Un gestionnaire (aal2) lit tous les profils (numéros et rôles seulement) ; chacun lit le sien (0001).
create policy profiles_select_managers on public.profiles for select to authenticated
  using (public.get_my_role() = 'manager');

-- Aucune écriture par le navigateur : créer, mettre en pause ou changer un rôle passe par une fonction serveur (côté 2, `PLAN.md` 9.4).

-- ════════════════════════════════════════════════════════════════════
-- 0003_company_settings.sql
-- ════════════════════════════════════════════════════════════════════
-- Sparklog-Employés — schéma neuf du côté 1. Migration 0003 : réglages du temps, jours fériés, OT prédéfinis, durée de conservation des preuves.
-- Structure relevée dans une base reconstruite à partir des 150 migrations de Sparklog V2.4.258 ; mêmes contraintes et mêmes règles d'accès.
--
-- Écarts voulus par rapport à Sparklog :
--  * `company_capture_settings` (lecture de la carte CCQ, de la date de naissance, du syndicat) n'existe pas : le côté 1 ne recueille aucun de ces renseignements ;
--  * les OT prédéfinis ne contiennent aucun prénom ni nom (l'ancienne liste avait un libellé nominatif : il n'est pas repris) ;
--  * chaque table a ses droits écrits en toutes lettres (`revoke all` avant `grant`).

-- ── Réglages du temps (une seule ligne) ─────────────────────────────────────
create table public.company_time_settings (
  id boolean primary key default true check (id = true),
  timezone text not null default 'America/Toronto' check (timezone = 'America/Toronto'),
  daily_deadline time not null default '23:59:00',
  anomaly_long_day_minutes integer not null default 720 check (anomaly_long_day_minutes between 60 and 1440),
  anomaly_high_km integer not null default 300 check (anomaly_high_km between 1 and 5000),
  updated_at timestamptz not null default now()
);
insert into public.company_time_settings (id) values (true);

-- ── Conservation des preuves de temps supplémentaire (une seule ligne) ──────
create table public.overtime_settings (
  id boolean primary key default true check (id = true),
  evidence_retention_days integer not null default 30 check (evidence_retention_days between 1 and 365),
  updated_at timestamptz not null default now()
);
insert into public.overtime_settings (id) values (true);

-- ── Jours fériés de l'entreprise ────────────────────────────────────────────
create table public.company_holidays (
  holiday_date date primary key,
  label text not null,
  created_at timestamptz not null default now()
);
insert into public.company_holidays (holiday_date, label) values
  ('2026-01-01', 'Jour de l''An'),
  ('2026-01-02', 'Vacances de la construction — hiver'),
  ('2026-01-03', 'Vacances de la construction — hiver'),
  ('2026-04-03', 'Vendredi saint'),
  ('2026-04-06', 'Lundi de Pâques'),
  ('2026-05-18', 'Journée nationale des patriotes'),
  ('2026-06-24', 'Fête nationale du Québec'),
  ('2026-07-03', 'Fête du Canada'),
  ('2026-09-07', 'Fête du Travail'),
  ('2026-10-12', 'Action de grâces'),
  ('2026-11-13', 'Jour du Souvenir'),
  ('2026-12-25', 'Noël'),
  ('2027-01-01', 'Jour de l''An'),
  ('2027-03-26', 'Vendredi saint'),
  ('2027-03-29', 'Lundi de Pâques'),
  ('2027-05-24', 'Journée nationale des patriotes'),
  ('2027-06-24', 'Fête nationale du Québec'),
  ('2027-07-02', 'Fête du Canada'),
  ('2027-09-06', 'Fête du Travail'),
  ('2027-10-11', 'Action de grâces'),
  ('2027-11-12', 'Jour du Souvenir'),
  ('2027-12-25', 'Noël'),
  ('2028-01-01', 'Jour de l''An'),
  ('2028-04-14', 'Vendredi saint'),
  ('2028-04-17', 'Lundi de Pâques'),
  ('2028-05-22', 'Journée nationale des patriotes'),
  ('2028-06-23', 'Fête nationale du Québec'),
  ('2028-06-30', 'Fête du Canada'),
  ('2028-09-04', 'Fête du Travail'),
  ('2028-10-09', 'Action de grâces'),
  ('2028-11-10', 'Jour du Souvenir'),
  ('2028-12-25', 'Noël');

-- ── OT prédéfinis (la liste déroulante de la saisie) ────────────────────────
-- Jamais un numéro de 4 chiffres ou plus : les numéros d'OT sont repérés ailleurs (réutilisation d'un OT), un libellé ne doit pas les imiter.
create table public.preset_work_orders (
  id uuid primary key default gen_random_uuid(),
  label text not null check (char_length(btrim(label)) between 2 and 60 and btrim(label) !~ '^[0-9]{4,}$'),
  sort_order integer not null default 100 check (sort_order between 0 and 10000),
  active boolean not null default true,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create unique index preset_work_orders_label_uniq on public.preset_work_orders (lower(btrim(label)));
insert into public.preset_work_orders (label, sort_order) values
  ('PAUSE SÉCURITÉ', 10), ('FORMATION HILO EMBAUCHE', 20), ('FORMATION BRITTON', 30), ('FORMATION HQ', 40), ('CONTREMAÎTRE', 51);

-- ── Droits et règles d'accès ────────────────────────────────────────────────
revoke all on table public.company_time_settings, public.overtime_settings, public.company_holidays, public.preset_work_orders from anon, public, authenticated;
alter table public.company_time_settings enable row level security;
alter table public.overtime_settings enable row level security;
alter table public.company_holidays enable row level security;
alter table public.preset_work_orders enable row level security;

-- Tout compte connecté lit ; seuls les gestionnaires (aal2) modifient les réglages. Les jours fériés ne s'écrivent que par migration.
grant select on public.company_time_settings, public.overtime_settings, public.company_holidays, public.preset_work_orders to authenticated;
grant update (timezone, daily_deadline, anomaly_long_day_minutes, anomaly_high_km, updated_at) on public.company_time_settings to authenticated;
grant update (evidence_retention_days, updated_at) on public.overtime_settings to authenticated;
grant insert, update, delete on public.preset_work_orders to authenticated;

create policy time_settings_read on public.company_time_settings for select to authenticated using (true);
create policy time_settings_manager_update on public.company_time_settings for update to authenticated
  using ((select public.get_my_role()) = 'manager') with check ((select public.get_my_role()) = 'manager');
create policy overtime_settings_read on public.overtime_settings for select to authenticated using (true);
create policy overtime_settings_manager_update on public.overtime_settings for update to authenticated
  using ((select public.get_my_role()) = 'manager') with check ((select public.get_my_role()) = 'manager');
create policy holidays_read on public.company_holidays for select to authenticated using (true);
create policy preset_work_orders_read on public.preset_work_orders for select to authenticated using (true);
create policy preset_work_orders_manager_insert on public.preset_work_orders for insert to authenticated with check (public.get_my_role() = 'manager');
create policy preset_work_orders_manager_update on public.preset_work_orders for update to authenticated
  using (public.get_my_role() = 'manager') with check (public.get_my_role() = 'manager');
create policy preset_work_orders_manager_delete on public.preset_work_orders for delete to authenticated using (public.get_my_role() = 'manager');

-- ════════════════════════════════════════════════════════════════════
-- 0004_jobs.sql
-- ════════════════════════════════════════════════════════════════════
-- Sparklog-Employés — schéma neuf du côté 1. Migration 0004 : la fiche de temps (`jobs`) et ses règles de validation.
-- Structure et règles relevées dans une base reconstruite à partir des 150 migrations de Sparklog V2.4.258 (0062 à 0064, 0116, 0135 et voisines).
--
-- Écarts voulus par rapport à Sparklog :
--  * pas de taux ni de montant sur la fiche (`hourly_rate_snapshot`, `team_leader_premium_snapshot`, `km_rate_snapshot` : la paie est au côté 2) ;
--  * pas de `manager_entry_by_name` (un nom) : l'auteur d'une saisie de gestionnaire est `manager_entry_by` (identifiant, donc numéro) ;
--  * les fonctions ont un `search_path` vide et des noms qualifiés ;
--  * la preuve de temps supplémentaire et les captures d'inventaire de `validate_job_submission_contract` arrivent avec leurs tables (0005 et 0007), qui remplacent la fonction.
-- Écriture : un employé n'écrit une fiche qu'en `saved` / `updated` ; passer à `submitted` se fait par une fonction serveur (0005), jamais par une mise à jour directe.

-- ── Options du profil qui changent le TEMPS (pas la paie) ───────────────────
alter table public.profiles
  add column first_trip_unpaid boolean not null default false,
  add column ten_hour_days boolean not null default false,
  add column km_apart_from_capture boolean not null default false,
  add column return_with_benefits_to_8h boolean not null default false,
  add column overtime_first_hour_double boolean not null default false,
  add column inventory_screenshots_enabled boolean not null default false,
  add column parking_receipts_enabled boolean not null default false;

-- ── Petites fonctions communes ──────────────────────────────────────────────
create function public.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create function public.is_not_paused()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and is_paused = false);
$$;

-- Numéro d'OT « de 4 chiffres ou plus » (les libellés prédéfinis n'en sont jamais).
create function public.normalized_ot(p_ot text)
returns text language sql immutable set search_path = '' as $$
  select case when btrim(coalesce(p_ot, '')) ~ '^[0-9]{4,}$' then btrim(p_ot) end;
$$;

-- ── Heure locale de Montréal → instant (gestion des changements d'heure) ────
-- Une heure qui n'existe pas (printemps) est refusée ; une heure répétée (automne) exige un choix `fold` 1 (première) ou 2 (deuxième).
create function public.montreal_local_instant(p_local timestamp, p_fold smallint, out instant timestamptz, out repeated boolean)
returns record language plpgsql stable set search_path = '' as $$
declare
  tz constant text := 'America/Toronto';
  first_time timestamptz := (p_local + interval '4 hours') at time zone 'UTC';
  second_time timestamptz := (p_local + interval '5 hours') at time zone 'UTC';
  first_ok boolean := timezone(tz, first_time) = p_local;
  second_ok boolean := timezone(tz, second_time) = p_local;
begin
  repeated := first_ok and second_ok;
  if not first_ok and not second_ok then
    raise exception using errcode = '22007', message = 'nonexistent_montreal_local_time';
  end if;
  if repeated then
    if p_fold is null then
      raise exception using errcode = '22007', message = 'ambiguous_montreal_local_time';
    end if;
    instant := case when p_fold = 1 then first_time else second_time end;
  else
    instant := case when first_ok then first_time else second_time end;
  end if;
end;
$$;

-- ── La fiche ────────────────────────────────────────────────────────────────
create table public.jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  job_date date not null,
  ot text,
  depart time,
  arrivee time,
  fin time,
  km_aller numeric default 0,
  km_retour numeric not null default 0 check (km_retour >= 0),
  km_total numeric not null default 0 check (km_total >= 0),
  return_time_minutes integer not null default 0
    check (return_time_minutes between 0 and 240 and return_time_minutes % 5 = 0),
  status text not null default 'saved' check (status in ('saved', 'updated', 'submitted', 'approved')),
  locked boolean not null default false,
  overtime_evidence_captured boolean not null default false,
  parking_receipt_captured boolean not null default false,
  meal_claim_captured boolean not null default false,
  exported_to_sheet boolean not null default false,
  exported_at timestamptz,
  exported_by uuid references public.profiles(id),
  submission_key uuid,
  started_at timestamptz,
  ended_at timestamptz,
  depart_fold smallint,
  fin_fold smallint,
  manager_entry_at timestamptz,
  manager_entry_by uuid,
  manager_entry_note text,
  manager_entry_reminded_at timestamptz,
  employee_confirmed_at timestamptz,
  updated_at timestamptz default now(),
  constraint jobs_dst_fold_chk check ((depart_fold is null or depart_fold in (1, 2)) and (fin_fold is null or fin_fold in (1, 2))),
  constraint jobs_user_submission_key_uniq unique (user_id, submission_key)
);
comment on column public.jobs.submission_key is 'Clé d''idempotence du client : unique par (user_id, submission_key). NULL pour une fiche sans clé (les NULL sont distincts).';

create index jobs_user_date_idx on public.jobs (user_id, job_date desc);
create index jobs_status_date_idx on public.jobs (status, job_date desc);
create index jobs_manager_keyset_idx on public.jobs (job_date desc, id desc);
create index jobs_manager_entry_idx on public.jobs (manager_entry_at desc) where manager_entry_at is not null;
create index jobs_normalized_ot_idx on public.jobs (public.normalized_ot(ot)) where public.normalized_ot(ot) is not null;
create index jobs_exported_by_idx on public.jobs (exported_by);

-- Les dates de début et de fin réelles (instants) viennent toujours de la date et des heures affichées.
create function public.resolve_montreal_job_instants()
returns trigger language plpgsql set search_path = '' as $$
declare
  start_local timestamp;
  end_local timestamp;
  start_result record;
  end_result record;
begin
  -- Le choix de l'heure répétée est une décision de gestionnaire (fonction serveur `security definer`).
  if current_user in ('authenticated', 'anon') and (
       (tg_op = 'INSERT' and (new.depart_fold is not null or new.fin_fold is not null))
    or (tg_op = 'UPDATE' and (new.depart_fold is distinct from old.depart_fold or new.fin_fold is distinct from old.fin_fold))
  ) then
    raise exception using errcode = '42501', message = 'dst_choice_manager_only';
  end if;

  if new.depart is null or new.fin is null then
    new.started_at := null;
    new.ended_at := null;
    return new;
  end if;

  start_local := new.job_date + new.depart;
  end_local := new.job_date + new.fin;
  if new.fin <= new.depart then end_local := end_local + interval '1 day'; end if;

  select * into start_result from public.montreal_local_instant(start_local, new.depart_fold);
  select * into end_result from public.montreal_local_instant(end_local, new.fin_fold);
  -- Un choix n'a de sens que dans l'heure répétée.
  if not start_result.repeated then new.depart_fold := null; end if;
  if not end_result.repeated then new.fin_fold := null; end if;

  new.started_at := start_result.instant;
  new.ended_at := end_result.instant;
  return new;
end;
$$;

-- Contrat de soumission : tout passage à `submitted` (application ou insertion directe falsifiée) est validé ici.
-- Version de base : intervalle, chevauchement, retour, kilomètres. 0005 y ajoute la preuve de temps supplémentaire ; 0007, l'inventaire de fin de quart.
create function public.validate_job_submission_contract()
returns trigger language plpgsql set search_path = '' as $$
declare
  duration_minutes integer;
begin
  if new.status <> 'submitted' then return new; end if;
  if tg_op = 'UPDATE' and old.status not in ('saved', 'updated') then return new; end if;
  if new.started_at is null or new.ended_at is null then
    raise exception using errcode = '23514', message = 'invalid_job_interval';
  end if;
  duration_minutes := extract(epoch from (new.ended_at - new.started_at))::integer / 60;
  if duration_minutes <= 0 or duration_minutes > 960 then
    raise exception using errcode = '23514', message = 'invalid_job_interval';
  end if;

  -- Un verrou par employé : deux soumissions simultanées ne peuvent pas se chevaucher sans le savoir.
  perform pg_advisory_xact_lock(hashtextextended(new.user_id::text, 0));

  if exists (
    select 1 from public.jobs j
     where j.user_id = new.user_id and j.id <> new.id
       and j.status in ('submitted', 'approved')
       and j.started_at is not null and j.ended_at is not null
       and tstzrange(j.started_at, j.ended_at, '[)') && tstzrange(new.started_at, new.ended_at, '[)')
  ) then
    raise exception using errcode = '23P01', message = 'overlapping_job_interval';
  end if;
  if new.return_time_minutes > duration_minutes then
    raise exception using errcode = '23514', message = 'return_time_exceeds_job_interval';
  end if;
  if new.km_total is null or new.km_aller is null or new.km_retour is null
     or new.km_total < 0 or new.km_aller < 0 or new.km_retour < 0
     or new.km_retour > new.km_total
     or abs((new.km_aller + new.km_retour) - new.km_total) > 0.001 then
    raise exception using errcode = '23514', message = 'invalid_job_kilometres';
  end if;
  return new;
end;
$$;

-- ── Déverrouillage d'une journée (saisie après l'échéance) ──────────────────
create table public.job_entry_unlocks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  job_date date not null,
  unlocked_until timestamptz,
  reason text,
  created_by uuid not null default auth.uid() references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (user_id, job_date)
);
create index job_entry_unlocks_created_by_idx on public.job_entry_unlocks (created_by);

-- Fenêtre de saisie : refus un jour férié et après l'échéance du jour, sauf journée déverrouillée ; sans effet pour les gestionnaires et les fonctions serveur.
create function public.enforce_job_entry_window()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  local_now timestamp;
  deadline time;
  company_tz text;
  has_unlock boolean;
  unchanged public.jobs;
begin
  if public.get_my_role() = 'manager' or auth.uid() is null then return new; end if;
  if tg_op = 'UPDATE' then
    -- Les indicateurs de capture (preuve, stationnement, repas) peuvent changer après l'échéance.
    unchanged := new;
    unchanged.parking_receipt_captured := old.parking_receipt_captured;
    unchanged.meal_claim_captured := old.meal_claim_captured;
    unchanged.overtime_evidence_captured := old.overtime_evidence_captured;
    if unchanged is not distinct from old then return new; end if;
  end if;
  select timezone, daily_deadline into company_tz, deadline from public.company_time_settings where id = true;
  company_tz := coalesce(company_tz, 'America/Toronto');
  deadline := coalesce(deadline, '23:59'::time);
  local_now := timezone(company_tz, now());
  select exists (
    select 1 from public.job_entry_unlocks
     where user_id = new.user_id and job_date = new.job_date and (unlocked_until is null or unlocked_until > now())
  ) into has_unlock;
  if has_unlock then return new; end if;
  if exists (select 1 from public.company_holidays where holiday_date = new.job_date) then
    raise exception 'Jobs cannot be entered for a company holiday';
  end if;
  if local_now >= (new.job_date + deadline + interval '1 minute') then
    raise exception 'The entry deadline for this work date has passed';
  end if;
  return new;
end;
$$;

-- Un employé ne pose ni l'approbation ni l'export.
create function public.protect_job_manager_fields()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null and public.get_my_role() is distinct from 'manager' then
    if tg_op = 'INSERT' then
      if coalesce(new.exported_to_sheet, false) or new.exported_at is not null or new.exported_by is not null or new.status = 'approved' then
        raise exception 'Employees cannot set export or approval fields on jobs';
      end if;
    elsif new.exported_to_sheet is distinct from old.exported_to_sheet
       or new.exported_at is distinct from old.exported_at
       or new.exported_by is distinct from old.exported_by
       or (new.status = 'approved' and old.status is distinct from 'approved') then
      raise exception 'Employees cannot set export or approval fields on jobs';
    end if;
  end if;
  return new;
end;
$$;

-- Les champs de saisie par un gestionnaire (urgence) ne s'écrivent que par fonction serveur.
create function public.protect_job_manager_entry_fields()
returns trigger language plpgsql set search_path = '' as $$
begin
  if current_user in ('authenticated', 'anon') then
    if tg_op = 'INSERT' then
      if new.manager_entry_at is not null or new.manager_entry_by is not null or new.manager_entry_note is not null
         or new.manager_entry_reminded_at is not null or new.employee_confirmed_at is not null then
        raise exception using errcode = '42501', message = 'manager_entry_fields_protected';
      end if;
    elsif new.manager_entry_at is distinct from old.manager_entry_at
       or new.manager_entry_by is distinct from old.manager_entry_by
       or new.manager_entry_note is distinct from old.manager_entry_note
       or new.manager_entry_reminded_at is distinct from old.manager_entry_reminded_at
       or new.employee_confirmed_at is distinct from old.employee_confirmed_at then
      raise exception using errcode = '42501', message = 'manager_entry_fields_protected';
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_00_resolve_montreal_job_instants before insert or update of job_date, depart, fin, depart_fold, fin_fold
  on public.jobs for each row execute function public.resolve_montreal_job_instants();
create trigger trg_validate_job_submission before insert or update on public.jobs
  for each row execute function public.validate_job_submission_contract();
create trigger jobs_enforce_entry_window before insert or update on public.jobs
  for each row execute function public.enforce_job_entry_window();
create trigger jobs_protect_manager_entry_fields before insert or update on public.jobs
  for each row execute function public.protect_job_manager_entry_fields();
create trigger jobs_protect_manager_fields before insert or update on public.jobs
  for each row execute function public.protect_job_manager_fields();
create trigger jobs_set_updated_at before update on public.jobs
  for each row execute function public.set_updated_at();

-- ── Droits et règles d'accès ────────────────────────────────────────────────
revoke all on table public.jobs, public.job_entry_unlocks from anon, public, authenticated;
revoke all on function public.set_updated_at(), public.is_not_paused(), public.normalized_ot(text),
  public.montreal_local_instant(timestamp, smallint), public.resolve_montreal_job_instants(),
  public.validate_job_submission_contract(), public.enforce_job_entry_window(),
  public.protect_job_manager_fields(), public.protect_job_manager_entry_fields() from public, anon;
-- `montreal_local_instant` est appelée par le trigger des instants, qui s'exécute avec les droits de l'appelant (il lit `current_user`) : fonction pure, sans accès aux données.
grant execute on function public.is_not_paused(), public.normalized_ot(text), public.montreal_local_instant(timestamp, smallint) to authenticated;
grant select, insert, update, delete on public.jobs to authenticated;
grant select, insert, update, delete on public.job_entry_unlocks to authenticated;
alter table public.jobs enable row level security;
alter table public.job_entry_unlocks enable row level security;

create policy jobs_employee_read_own on public.jobs for select to authenticated using (user_id = (select auth.uid()));
create policy jobs_manager_read_all on public.jobs for select to authenticated using ((select public.get_my_role()) = 'manager');
create policy jobs_employee_insert_own on public.jobs for insert to authenticated
  with check (public.is_not_paused() and user_id = auth.uid() and status = 'saved' and locked = false);
create policy jobs_employee_update_own_editable on public.jobs for update to authenticated
  using (public.is_not_paused() and user_id = auth.uid() and locked = false and status in ('saved', 'updated'))
  with check (public.is_not_paused() and user_id = auth.uid() and locked = false and status in ('saved', 'updated'));
create policy jobs_employee_delete_own_editable on public.jobs for delete to authenticated
  using (user_id = (select auth.uid()) and locked = false and status in ('saved', 'updated') and (select public.is_not_paused()));

create policy unlocks_read on public.job_entry_unlocks for select to authenticated
  using (user_id = (select auth.uid()) or (select public.get_my_role()) = 'manager');
create policy unlocks_manager_manage on public.job_entry_unlocks for all to authenticated
  using ((select public.get_my_role()) = 'manager') with check ((select public.get_my_role()) = 'manager');

-- ════════════════════════════════════════════════════════════════════
-- 0005_job_writes.sql
-- ════════════════════════════════════════════════════════════════════
-- Sparklog-Employés — schéma neuf du côté 1. Migration 0005 : fonctions serveur d'écriture des fiches, journal d'audit sans nom, avis à l'employé.
-- Relevé dans une base reconstruite à partir des 150 migrations de Sparklog V2.4.258 : `save_own_job`, `return_job_for_correction`,
-- `create_job_for_employee`, `submit_manager_entry_for_employee` (versions finales), plus `approve_jobs` (nouveau : l'approbation vient du côté 2, `PLAN.md` 3.4 et 9.2).
--
-- Écarts voulus par rapport à Sparklog :
--  * le journal d'audit ne contient AUCUN nom : acteur et cible sont des identifiants et des numéros d'employé ; les métadonnées n'acceptent qu'une liste de clés permises (`PLAN.md` 3.6, 10.8) ;
--  * le journal est **non modifiable** (ni mise à jour ni suppression, pas même par une fonction) : les corrections ne l'écrasent jamais (`PLAN.md` 10.9) ;
--  * `employee_notices` : l'employé est **avisé** de toute fiche créée, soumise ou retournée par un gestionnaire (exigence de la convention). Sparklog n'avisait pas quand le propriétaire **soumettait** pour l'employé ;
--  * une fiche **soumise** est toujours **verrouillée**, y compris quand le propriétaire la soumet pour l'employé (dans Sparklog elle restait déverrouillée : elle ne pouvait alors ni être retournée ni approuvée) ;
--  * les annonces (broadcasts) n'existent pas ici : l'avis passe par `employee_notices` ;
--  * `save_own_job` ne retient pas encore l'indicateur de preuve de temps supplémentaire (la table des preuves arrive avec 0006, qui remplace la fonction).

-- ── Journal d'audit (sans nom, non modifiable) ──────────────────────────────
create table public.audit_log (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  actor_id uuid,
  actor_number integer,
  action text not null check (char_length(action) between 3 and 60),
  target_user_id uuid,
  target_number integer,
  job_id uuid,
  details jsonb not null default '{}'::jsonb
);
create index audit_log_created_idx on public.audit_log (created_at desc);
create index audit_log_job_idx on public.audit_log (job_id) where job_id is not null;

-- Seules ces clés peuvent figurer dans `details` : aucun texte libre (un OT ou une note peut contenir un nom).
create function public.audit_log_guard()
returns trigger language plpgsql set search_path = '' as $$
declare k text;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    raise exception using errcode = '42501', message = 'audit_log_immutable';
  end if;
  if jsonb_typeof(new.details) <> 'object' then
    raise exception using errcode = '23514', message = 'audit_details_must_be_object';
  end if;
  for k in select jsonb_object_keys(new.details) loop
    if k not in ('job_date', 'from', 'to', 'count', 'reason_code', 'submitted', 'km') then
      raise exception using errcode = '23514', message = 'audit_details_key_not_allowed: ' || k;
    end if;
  end loop;
  return new;
end;
$$;
create trigger audit_log_guard_write before insert or update or delete on public.audit_log
  for each row execute function public.audit_log_guard();

-- Écriture interne : numéros résolus ici, jamais passés par l'appelant.
create function public.write_audit(p_actor uuid, p_action text, p_target uuid, p_job uuid, p_details jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = '' as $$
  insert into public.audit_log (actor_id, actor_number, action, target_user_id, target_number, job_id, details)
  select p_actor, (select employee_number from public.profiles where id = p_actor),
         p_action, p_target, (select employee_number from public.profiles where id = p_target), p_job, coalesce(p_details, '{}'::jsonb);
$$;

-- ── Avis à l'employé ────────────────────────────────────────────────────────
create table public.employee_notices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  job_id uuid references public.jobs(id) on delete cascade,
  kind text not null check (kind in ('job_created_by_manager', 'job_submitted_by_owner', 'job_returned')),
  job_date date,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index employee_notices_user_idx on public.employee_notices (user_id, created_at desc);

create function public.notify_employee(p_user uuid, p_job uuid, p_kind text, p_job_date date)
returns void language sql security definer set search_path = '' as $$
  insert into public.employee_notices (user_id, job_id, kind, job_date) values (p_user, p_job, p_kind, p_job_date);
$$;

-- ── Enregistrer / soumettre sa propre fiche ─────────────────────────────────
-- Création idempotente par clé de soumission (une relance renvoie la fiche déjà validée), sous le même verrou par employé que le validateur.
-- Une fiche soumise ne se modifie plus par cette fonction ; la relance d'une soumission réussie est sans effet.
create function public.save_own_job(
  p_job_id uuid, p_new_job_id uuid, p_submission_key uuid, p_submit boolean, p_job_date date, p_ot text,
  p_depart time, p_arrivee time, p_fin time, p_km_total numeric, p_km_aller numeric, p_return_time_minutes integer,
  p_km_retour numeric, p_overtime_evidence_captured boolean, p_parking_receipt_captured boolean,
  p_confirm_manager_entry boolean default false)
returns table (id uuid, status text, locked boolean)
language plpgsql security definer set search_path = '' as $$
declare
  caller_id uuid := auth.uid();
  current_job public.jobs%rowtype;
  result_job public.jobs%rowtype;
  confirming boolean := false;
begin
  if caller_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if not public.is_not_paused() then
    raise exception using errcode = '42501', message = 'job_write_not_allowed';
  end if;
  if p_job_date is null then
    raise exception using errcode = '23514', message = 'job_date_required';
  end if;

  if p_job_id is null then
    if p_submission_key is null then
      raise exception using errcode = '23514', message = 'submission_key_required';
    end if;
    -- On cherche la clé d'abord : les triggers BEFORE INSERT passent avant ON CONFLICT et signaleraient la relance comme un chevauchement.
    perform pg_advisory_xact_lock(hashtextextended(caller_id::text, 0));
    select * into result_job from public.jobs j where j.user_id = caller_id and j.submission_key = p_submission_key;
    if result_job.id is null then
      insert into public.jobs (
        id, user_id, submission_key, job_date, ot, depart, arrivee, fin, km_total, km_aller, return_time_minutes, km_retour,
        overtime_evidence_captured, parking_receipt_captured, status, locked
      ) values (
        coalesce(p_new_job_id, gen_random_uuid()), caller_id, p_submission_key, p_job_date, p_ot, p_depart, p_arrivee, p_fin,
        coalesce(p_km_total, 0), coalesce(p_km_aller, 0), coalesce(p_return_time_minutes, 0), coalesce(p_km_retour, 0),
        false, coalesce(p_parking_receipt_captured, false),
        case when p_submit then 'submitted' else 'saved' end, p_submit
      )
      on conflict (user_id, submission_key) do nothing
      returning * into result_job;
      if result_job.id is null then
        select * into result_job from public.jobs j where j.user_id = caller_id and j.submission_key = p_submission_key;
      end if;
    end if;
  else
    select * into current_job from public.jobs j where j.id = p_job_id and j.user_id = caller_id for update;
    if current_job.id is null then
      raise exception using errcode = 'P0002', message = 'job_not_found';
    end if;
    if current_job.status = 'submitted' and current_job.locked and p_submit then
      result_job := current_job;   -- relance après une soumission réussie : sans effet
    else
      if current_job.locked or current_job.status not in ('saved', 'updated') then
        raise exception using errcode = '55000', message = 'job_not_editable';
      end if;
      -- Une fiche créée par un gestionnaire doit d'abord être confirmée par l'employé.
      if p_submit and current_job.manager_entry_at is not null and current_job.employee_confirmed_at is null then
        if not coalesce(p_confirm_manager_entry, false) then
          raise exception using errcode = '55000', message = 'manager_entry_confirmation_required';
        end if;
        confirming := true;
      end if;
      update public.jobs j
         set job_date = p_job_date, ot = p_ot, depart = p_depart, arrivee = p_arrivee, fin = p_fin,
             km_total = coalesce(p_km_total, 0), km_aller = coalesce(p_km_aller, 0),
             return_time_minutes = coalesce(p_return_time_minutes, 0), km_retour = coalesce(p_km_retour, 0),
             overtime_evidence_captured = false,
             parking_receipt_captured = coalesce(p_parking_receipt_captured, false),
             status = case when p_submit then 'submitted' else 'updated' end,
             locked = p_submit,
             employee_confirmed_at = case when confirming then now() else j.employee_confirmed_at end
       where j.id = current_job.id
       returning * into result_job;
      if confirming then
        perform public.write_audit(caller_id, 'manager_entry_confirmed', caller_id, result_job.id,
                                   jsonb_build_object('job_date', result_job.job_date));
      end if;
    end if;
  end if;
  return query select result_job.id, result_job.status, result_job.locked;
end;
$$;

-- ── Retourner une fiche pour correction (gestionnaire, version attendue) ────
create function public.return_job_for_correction(p_job_id uuid, p_expected_updated_at timestamptz)
returns table (id uuid, status text, locked boolean, updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid := auth.uid();
  current_job public.jobs%rowtype;
  changed_job public.jobs%rowtype;
begin
  if actor_id is null or public.get_my_role() <> 'manager' then
    raise exception using errcode = '42501', message = 'manager_role_required';
  end if;
  select * into current_job from public.jobs j where j.id = p_job_id for update;
  if current_job.id is null then
    raise exception using errcode = 'P0002', message = 'job_not_found';
  end if;
  if p_expected_updated_at is null or current_job.status <> 'submitted' or not current_job.locked
     or current_job.updated_at is distinct from p_expected_updated_at then
    raise exception using errcode = '40001', message = 'job_state_changed';
  end if;
  update public.jobs j set status = 'updated', locked = false where j.id = current_job.id returning * into changed_job;
  perform public.write_audit(actor_id, 'job_returned_for_correction', changed_job.user_id, changed_job.id,
                             jsonb_build_object('from', current_job.status, 'to', changed_job.status, 'job_date', changed_job.job_date));
  perform public.notify_employee(changed_job.user_id, changed_job.id, 'job_returned', changed_job.job_date);
  return query select changed_job.id, changed_job.status, changed_job.locked, changed_job.updated_at;
end;
$$;

-- ── Approuver (appelée par le côté 2 avec sa clé de service) ────────────────
-- Entrée : [{"id": "...", "expected_updated_at": "..."}]. Résultat typé par fiche ; jamais d'approbation forcée.
create function public.approve_jobs(p_jobs jsonb)
returns table (job_id uuid, result text)
language plpgsql security definer set search_path = '' as $$
declare
  item jsonb;
  jid uuid;
  expected timestamptz;
  cur public.jobs%rowtype;
begin
  if jsonb_typeof(p_jobs) <> 'array' or jsonb_array_length(p_jobs) > 500 then
    raise exception using errcode = '22023', message = 'invalid_approval_batch';
  end if;
  for item in select * from jsonb_array_elements(p_jobs) loop
    jid := (item ->> 'id')::uuid;
    expected := (item ->> 'expected_updated_at')::timestamptz;
    select * into cur from public.jobs j where j.id = jid for update;
    if cur.id is null then
      return query select jid, 'not_found'::text;
    elsif cur.status = 'approved' then
      return query select jid, 'already_approved'::text;
    elsif cur.status <> 'submitted' or not cur.locked then
      return query select jid, 'not_submitted'::text;
    elsif expected is null or cur.updated_at is distinct from expected then
      return query select jid, 'conflict'::text;
    else
      update public.jobs j set status = 'approved' where j.id = jid;
      perform public.write_audit(null, 'job_approved', cur.user_id, cur.id, jsonb_build_object('job_date', cur.job_date));
      return query select jid, 'approved'::text;
    end if;
  end loop;
end;
$$;

-- ── Feuille d'urgence : le propriétaire crée ou soumet pour un employé ──────
create function public.create_job_for_employee(
  p_employee_id uuid, p_submission_key uuid, p_job_date date, p_ot text, p_depart time, p_arrivee time, p_fin time,
  p_km_aller numeric, p_note text, p_depart_fold smallint default null, p_fin_fold smallint default null, p_submit boolean default false)
returns table (id uuid, broadcast_id uuid)
language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid := auth.uid();
  target public.profiles%rowtype;
  existing public.jobs%rowtype;
  new_job public.jobs%rowtype;
  today_local date := (timezone('America/Toronto', now()))::date;
  clean_ot text := btrim(coalesce(p_ot, ''));
  clean_note text := btrim(coalesce(p_note, ''));
  duration_minutes integer;
begin
  if actor_id is null or not public.is_privileged() then
    raise exception using errcode = '42501', message = 'owner_role_required';
  end if;
  if p_employee_id is null or p_submission_key is null or p_job_date is null then
    raise exception using errcode = '23514', message = 'manager_entry_missing_field';
  end if;
  if clean_ot = '' then raise exception using errcode = '23514', message = 'manager_entry_ot_required'; end if;
  if char_length(clean_note) < 3 or char_length(clean_note) > 500 then
    raise exception using errcode = '23514', message = 'manager_entry_note_required';
  end if;
  if p_job_date > today_local or p_job_date < today_local - 31 then
    raise exception using errcode = '23514', message = 'manager_entry_date_out_of_window';
  end if;
  if p_depart is null or p_fin is null then raise exception using errcode = '23514', message = 'invalid_job_interval'; end if;
  duration_minutes := (extract(epoch from (p_fin - p_depart))::integer / 60);
  if duration_minutes <= 0 then duration_minutes := duration_minutes + 1440; end if;
  if duration_minutes <= 0 or duration_minutes > 960 then raise exception using errcode = '23514', message = 'invalid_job_interval'; end if;
  if (p_depart_fold is not null and p_depart_fold not in (1, 2)) or (p_fin_fold is not null and p_fin_fold not in (1, 2)) then
    raise exception using errcode = '23514', message = 'invalid_dst_choice';
  end if;
  if p_km_aller is not null and p_km_aller < 0 then raise exception using errcode = '23514', message = 'invalid_job_kilometres'; end if;

  select * into target from public.profiles p where p.id = p_employee_id;
  if target.id is null or target.role not in ('employee', 'foreman', 'admin', 'subcontractor_1')
     or (target.is_paused and not coalesce(p_submit, false)) then
    raise exception using errcode = 'P0002', message = 'manager_entry_employee_not_eligible';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_employee_id::text, 0));
  -- Une relance (réponse perdue, double clic) renvoie la fiche déjà validée : une fiche, un audit, un avis.
  select * into existing from public.jobs j where j.user_id = p_employee_id and j.submission_key = p_submission_key;
  if existing.id is not null then
    if existing.manager_entry_at is null then
      raise exception using errcode = '23505', message = 'submission_key_conflict';
    end if;
    return query select existing.id, null::uuid;
    return;
  end if;

  if coalesce(p_submit, false) then perform set_config('sparklog.owner_submit', 'on', true); end if;
  insert into public.jobs (
    user_id, submission_key, job_date, ot, depart, arrivee, fin, depart_fold, fin_fold, km_total, km_aller, return_time_minutes, km_retour,
    status, locked, manager_entry_at, manager_entry_by, manager_entry_note
  ) values (
    p_employee_id, p_submission_key, p_job_date, clean_ot, p_depart, p_arrivee, p_fin, p_depart_fold, p_fin_fold,
    coalesce(p_km_aller, 0), coalesce(p_km_aller, 0), 0, 0,
    case when coalesce(p_submit, false) then 'submitted' else 'saved' end, coalesce(p_submit, false), now(), actor_id, clean_note
  ) returning * into new_job;
  perform set_config('sparklog.owner_submit', 'off', true);

  if not coalesce(p_submit, false) then
    -- L'employé doit pouvoir soumettre une journée passée après l'échéance : on la rouvre 14 jours (une réouverture sans fin n'est jamais raccourcie).
    insert into public.job_entry_unlocks (user_id, job_date, unlocked_until, reason, created_by)
    values (p_employee_id, p_job_date, now() + interval '14 days', 'manager_entry', actor_id)
    on conflict (user_id, job_date) do update set unlocked_until = case
      when public.job_entry_unlocks.unlocked_until is null then null
      else greatest(public.job_entry_unlocks.unlocked_until, excluded.unlocked_until) end;
  end if;
  -- Avis à l'employé dans les deux cas (changement de ses heures par un tiers).
  perform public.notify_employee(p_employee_id, new_job.id,
    case when coalesce(p_submit, false) then 'job_submitted_by_owner' else 'job_created_by_manager' end, p_job_date);
  perform public.write_audit(actor_id,
    case when coalesce(p_submit, false) then 'job_created_submitted_by_owner' else 'job_created_by_owner' end,
    p_employee_id, new_job.id,
    jsonb_build_object('job_date', p_job_date, 'km', coalesce(p_km_aller, 0), 'submitted', coalesce(p_submit, false)));
  return query select new_job.id, null::uuid;
end;
$$;

create function public.submit_manager_entry_for_employee(p_job_id uuid)
returns table (id uuid)
language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid := auth.uid();
  current_job public.jobs%rowtype;
begin
  if actor_id is null or not public.is_privileged() then
    raise exception using errcode = '42501', message = 'owner_role_required';
  end if;
  select * into current_job from public.jobs j where j.id = p_job_id for update;
  if current_job.id is null or current_job.manager_entry_at is null then
    raise exception using errcode = 'P0002', message = 'manager_entry_not_found';
  end if;
  if current_job.status = 'submitted' then
    return query select current_job.id;
    return;
  end if;
  if current_job.status not in ('saved', 'updated') or current_job.locked then
    raise exception using errcode = '23514', message = 'manager_entry_not_submittable';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(current_job.user_id::text, 0));
  perform set_config('sparklog.owner_submit', 'on', true);
  update public.jobs j set status = 'submitted', locked = true where j.id = current_job.id;
  perform set_config('sparklog.owner_submit', 'off', true);
  perform public.notify_employee(current_job.user_id, current_job.id, 'job_submitted_by_owner', current_job.job_date);
  perform public.write_audit(actor_id, 'job_submitted_by_owner', current_job.user_id, current_job.id,
                             jsonb_build_object('job_date', current_job.job_date));
  return query select current_job.id;
end;
$$;

-- ── Droits et règles d'accès ────────────────────────────────────────────────
revoke all on table public.audit_log, public.employee_notices from anon, public, authenticated;
alter table public.audit_log enable row level security;
alter table public.employee_notices enable row level security;
grant select on public.audit_log to authenticated, service_role;
grant select on public.employee_notices to authenticated;
grant update (read_at) on public.employee_notices to authenticated;
create policy audit_log_manager_read on public.audit_log for select to authenticated using ((select public.get_my_role()) = 'manager');
create policy employee_notices_read_own on public.employee_notices for select to authenticated using (user_id = (select auth.uid()));
create policy employee_notices_mark_read on public.employee_notices for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

revoke all on function public.audit_log_guard(), public.write_audit(uuid, text, uuid, uuid, jsonb), public.notify_employee(uuid, uuid, text, date),
  public.save_own_job(uuid, uuid, uuid, boolean, date, text, time, time, time, numeric, numeric, integer, numeric, boolean, boolean, boolean),
  public.return_job_for_correction(uuid, timestamptz), public.approve_jobs(jsonb),
  public.create_job_for_employee(uuid, uuid, date, text, time, time, time, numeric, text, smallint, smallint, boolean),
  public.submit_manager_entry_for_employee(uuid) from public, anon, authenticated;
grant execute on function
  public.save_own_job(uuid, uuid, uuid, boolean, date, text, time, time, time, numeric, numeric, integer, numeric, boolean, boolean, boolean),
  public.return_job_for_correction(uuid, timestamptz),
  public.create_job_for_employee(uuid, uuid, date, text, time, time, time, numeric, text, smallint, smallint, boolean),
  public.submit_manager_entry_for_employee(uuid) to authenticated;
grant execute on function public.approve_jobs(jsonb) to service_role;

-- ════════════════════════════════════════════════════════════════════
-- 0006_overtime_evidence.sql
-- ════════════════════════════════════════════════════════════════════
-- Sparklog-Employés — schéma neuf du côté 1. Migration 0006 : preuve de temps supplémentaire.
-- Relevé dans une base reconstruite à partir des 150 migrations de Sparklog V2.4.258 (0005, 0065, 0075, 0076, 0084, 0125, 0135 et voisines).
--
-- Contenu : table des preuves, avis aux gestionnaires, compartiment de stockage `overtime-evidence` et ses règles d'accès, rattachement de la preuve
-- à la dernière fiche du jour, nettoyage quand la journée redescend à 8 h, version COMPLÈTE de `validate_job_submission_contract`
-- (preuve exigée au-delà de 8 h payées, 10 h pour « 4 jours de 10 h », premier trajet non payé, 65 km), `save_own_job` qui ne retient l'indicateur que si une preuve existe,
-- et `save_own_job_with_overtime_evidence` (fiche + preuve + avis en une seule transaction).
--
-- Écarts voulus par rapport à Sparklog :
--  * `overtime_day_minutes` n'est plus appelable par le navigateur (elle renvoyait les minutes de n'importe quel employé) ;
--  * pas de table de repas ni de stationnement ici (0007) : les colonnes `meal_claim_id` / `parking_receipt_id` de `manager_notifications` viennent avec elles ;
--  * `manager_notifications` ne contient aucun nom (identifiant de l'employé seulement) ;
--  * la vérification de l'inventaire de fin de quart n'y est pas encore : la migration d'inventaire remplace la fonction.
-- Reste identique à Sparklog, volontairement : le nettoyage d'une preuve utilise le seuil fixe de 480 min, même pour « 4 jours de 10 h ».

-- ── Avis aux gestionnaires ──────────────────────────────────────────────────
create table public.overtime_evidence (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null unique references public.jobs(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  job_date date not null,
  storage_path text not null,
  ocr_text text,
  ocr_status text not null default 'needs_review' check (ocr_status in ('pending', 'processed', 'needs_review', 'failed')),
  daily_minutes integer not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index overtime_evidence_user_idx on public.overtime_evidence (user_id);
create index overtime_evidence_created_idx on public.overtime_evidence (created_at desc, job_id);
create index overtime_evidence_day_idx on public.overtime_evidence (user_id, job_date);

create table public.manager_notifications (
  id uuid primary key default gen_random_uuid(),
  type text not null default 'overtime_evidence',
  employee_id uuid not null references public.profiles(id) on delete cascade,
  job_id uuid references public.jobs(id) on delete cascade,
  evidence_id uuid references public.overtime_evidence(id) on delete cascade,
  daily_minutes integer not null,
  created_at timestamptz not null default now(),
  changes jsonb
);
create index manager_notifications_employee_idx on public.manager_notifications (employee_id);
create index manager_notifications_evidence_idx on public.manager_notifications (evidence_id);
create index manager_notifications_job_idx on public.manager_notifications (job_id);

create table public.manager_notification_reads (
  notification_id uuid not null references public.manager_notifications(id) on delete cascade,
  manager_id uuid not null references public.profiles(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (notification_id, manager_id)
);
create index manager_notification_reads_manager_idx on public.manager_notification_reads (manager_id);

-- ── Minutes de la journée (interne) ─────────────────────────────────────────
create function public.overtime_day_minutes(p_user uuid, p_date date)
returns integer language sql stable security definer set search_path = '' as $$
  select coalesce(sum(
    extract(epoch from (case when j.fin >= j.depart then j.fin - j.depart else j.fin - j.depart + interval '24 hours' end)) / 60
  ), 0)::int
  from public.jobs j
  where j.user_id = p_user and j.job_date = p_date and j.depart is not null and j.fin is not null;
$$;

-- ── La preuve suit la dernière fiche du jour ────────────────────────────────
create function public.attach_overtime_evidence_to_last_job(p_user uuid, p_date date)
returns void language plpgsql security definer set search_path = '' as $$
declare last_job uuid;
begin
  if p_user is null or p_date is null then return; end if;
  if not exists (select 1 from public.overtime_evidence e where e.user_id = p_user and e.job_date = p_date) then return; end if;
  select j.id into last_job from public.jobs j
   where j.user_id = p_user and j.job_date = p_date
   order by j.ended_at desc nulls last, j.fin desc nulls last, j.id desc limit 1;
  if last_job is null then return; end if;
  update public.overtime_evidence e set job_id = last_job where e.user_id = p_user and e.job_date = p_date and e.job_id <> last_job;
  update public.manager_notifications n set job_id = last_job
   where n.type = 'overtime_evidence' and n.job_id <> last_job
     and n.job_id in (select j.id from public.jobs j where j.user_id = p_user and j.job_date = p_date);
  -- Mises à jour d'indicateur seulement : permises par la fenêtre de saisie et la protection des champs, sans relancer les triggers de durée.
  update public.jobs j set overtime_evidence_captured = (j.id = last_job)
   where j.user_id = p_user and j.job_date = p_date and j.overtime_evidence_captured is distinct from (j.id = last_job);
end;
$$;

create function public.attach_overtime_evidence_after_evidence_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.attach_overtime_evidence_to_last_job(new.user_id, new.job_date);
  return null;
end;
$$;

create function public.attach_overtime_evidence_after_job_write()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    perform public.attach_overtime_evidence_to_last_job(old.user_id, old.job_date);
    return null;
  end if;
  perform public.attach_overtime_evidence_to_last_job(new.user_id, new.job_date);
  if tg_op = 'UPDATE' and new.job_date is distinct from old.job_date then
    perform public.attach_overtime_evidence_to_last_job(old.user_id, old.job_date);
  end if;
  return null;
end;
$$;

-- Quand la journée redescend à 8 h ou moins, la preuve n'a plus d'objet : elle est retirée et l'indicateur effacé.
create function public.reconcile_overtime_evidence()
returns trigger language plpgsql security definer set search_path = '' as $$
declare p_user uuid; p_date date;
begin
  if tg_op = 'DELETE' then p_user := old.user_id; p_date := old.job_date; else p_user := new.user_id; p_date := new.job_date; end if;
  if public.overtime_day_minutes(p_user, p_date) <= 480 then
    delete from public.overtime_evidence where user_id = p_user and job_date = p_date;
    update public.jobs set overtime_evidence_captured = false where user_id = p_user and job_date = p_date and overtime_evidence_captured = true;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

-- Supprimer la fiche qui porte la preuve : la preuve passe à une autre fiche du jour.
create function public.rehome_overtime_evidence_before_job_delete()
returns trigger language plpgsql security definer set search_path = '' as $$
declare target uuid;
begin
  if not exists (select 1 from public.overtime_evidence e where e.job_id = old.id)
     and not exists (select 1 from public.manager_notifications n where n.job_id = old.id and n.type = 'overtime_evidence') then
    return old;
  end if;
  select j.id into target from public.jobs j
   where j.user_id = old.user_id and j.job_date = old.job_date and j.id <> old.id
   order by j.ended_at desc nulls last, j.fin desc nulls last, j.id desc limit 1;
  if target is not null then
    update public.overtime_evidence set job_id = target where job_id = old.id;
    update public.manager_notifications set job_id = target where job_id = old.id and type = 'overtime_evidence';
  end if;
  return old;
end;
$$;

create function public.sync_overtime_evidence_flag_after_job_delete()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.attach_overtime_evidence_to_last_job(old.user_id, old.job_date);
  return old;
end;
$$;

-- Une notification pointe toujours la fiche qui porte la preuve.
create function public.point_overtime_notification_at_evidence_job()
returns trigger language plpgsql security definer set search_path = '' as $$
declare holder uuid;
begin
  if new.type = 'overtime_evidence' and new.evidence_id is not null then
    select e.job_id into holder from public.overtime_evidence e where e.id = new.evidence_id;
    if holder is not null then new.job_id := holder; end if;
  end if;
  return new;
end;
$$;

create trigger overtime_evidence_attach_to_last_job after insert on public.overtime_evidence
  for each row execute function public.attach_overtime_evidence_after_evidence_insert();
create trigger manager_notifications_point_at_evidence_job before insert on public.manager_notifications
  for each row execute function public.point_overtime_notification_at_evidence_job();
create trigger jobs_attach_overtime_evidence after insert or update of job_date, depart, fin, overtime_evidence_captured on public.jobs
  for each row execute function public.attach_overtime_evidence_after_job_write();
create trigger jobs_reconcile_overtime_evidence after insert or delete or update of job_date, depart, fin, status on public.jobs
  for each row execute function public.reconcile_overtime_evidence();
create trigger jobs_rehome_overtime_evidence before delete on public.jobs
  for each row execute function public.rehome_overtime_evidence_before_job_delete();
create trigger jobs_sync_overtime_evidence_flag after delete on public.jobs
  for each row execute function public.sync_overtime_evidence_flag_after_job_delete();

-- ── Contrat de soumission COMPLET (remplace la version de base de 0004) ─────
create or replace function public.validate_job_submission_contract()
returns trigger language plpgsql set search_path = '' as $$
declare
  duration_minutes integer;
  other_minutes integer;
  day_has_evidence boolean;
  is_office_employee boolean;
  daily_regular_minutes integer := 480;
  first_trip_unpaid boolean;
  unpaid_trip_minutes integer := 0;
  -- Le propriétaire soumet pour l'employé (create_job_for_employee / submit_manager_entry_for_employee) : la preuve ne peut venir que
  -- de l'employé, donc seul ce contrôle est sauté ; intervalle, chevauchement et kilomètres restent contrôlés. L'indicateur n'est posé
  -- que dans ces fonctions `security definer`, pour leur transaction.
  owner_submit boolean := coalesce(current_setting('sparklog.owner_submit', true), '') = 'on';
begin
  if new.status <> 'submitted' then return new; end if;
  if tg_op = 'UPDATE' and old.status not in ('saved', 'updated') then return new; end if;
  if new.started_at is null or new.ended_at is null then
    raise exception using errcode = '23514', message = 'invalid_job_interval';
  end if;
  duration_minutes := extract(epoch from (new.ended_at - new.started_at))::integer / 60;
  if duration_minutes <= 0 or duration_minutes > 960 then
    raise exception using errcode = '23514', message = 'invalid_job_interval';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(new.user_id::text, 0));
  select coalesce(p.role = 'admin', false), coalesce(p.first_trip_unpaid, false)
    into is_office_employee, first_trip_unpaid
    from public.profiles p where p.id = new.user_id;
  -- « 4 jours de 10 h » : le temps supplémentaire, donc sa preuve, commence après 10 h (jamais pour contremaître ni sous-traitant).
  if exists (select 1 from public.profiles p where p.id = new.user_id and p.ten_hour_days and p.role not in ('foreman', 'subcontractor_1')) then
    daily_regular_minutes := 600;
  end if;
  select
    coalesce(sum(case
      when j.started_at is not null and j.ended_at is not null then extract(epoch from (j.ended_at - j.started_at))::integer / 60
      when j.depart is not null and j.fin is not null then (extract(epoch from (j.fin - j.depart))::integer / 60 + 1440) % 1440
      else 0 end), 0)::integer,
    coalesce(bool_or(j.overtime_evidence_captured), false)
  into other_minutes, day_has_evidence
  from public.jobs j
  where j.user_id = new.user_id and j.job_date = new.job_date and j.id <> new.id
    and j.status in ('saved', 'updated', 'submitted', 'approved');

  -- Employé « premier trajet non payé » : le seuil se compte sur le temps PAYÉ. Premier trajet de la journée (Départ le plus tôt, puis id),
  -- limité à la durée de cette fiche, nul sans Arrivée, et nul quand cette première fiche fait 65 km ou plus (depuis le 2026-10-11).
  -- Jumeau de dayFirstTripUnpaidMinutes dans supabase/functions/_shared/payroll_engine.js.
  if coalesce(first_trip_unpaid, false) then
    select case
             when d.depart is null or d.arrivee is null or d.fin is null then 0
             when new.job_date >= date '2026-10-11' and d.km >= 65 then 0
             else least(((extract(epoch from (d.arrivee - d.depart))::integer / 60) + 1440) % 1440,
                        ((extract(epoch from (d.fin - d.depart))::integer / 60) + 1440) % 1440)
           end
      into unpaid_trip_minutes
      from (
        select x.id, x.depart, x.arrivee, x.fin, x.km from (
          select j.id, j.depart, j.arrivee, j.fin, greatest(coalesce(j.km_total, 0), coalesce(j.km_aller, 0) + coalesce(j.km_retour, 0)) as km
            from public.jobs j
           where j.user_id = new.user_id and j.job_date = new.job_date and j.id <> new.id and j.status in ('saved', 'updated', 'submitted', 'approved')
          union all
          select new.id, new.depart, new.arrivee, new.fin, greatest(coalesce(new.km_total, 0), coalesce(new.km_aller, 0) + coalesce(new.km_retour, 0))
        ) x
        order by coalesce(left(x.depart::text, 5), '') collate "C", x.id::text collate "C"
        limit 1
      ) d;
  end if;

  if not owner_submit and not coalesce(is_office_employee, false)
     and duration_minutes + other_minutes - coalesce(unpaid_trip_minutes, 0) > daily_regular_minutes
     and not (coalesce(new.overtime_evidence_captured, false) or day_has_evidence) then
    raise exception using errcode = '23514', message = 'overtime_evidence_required';
  end if;
  -- (L'inventaire de fin de quart est ajouté par la migration d'inventaire.)

  if exists (
    select 1 from public.jobs j
     where j.user_id = new.user_id and j.id <> new.id and j.status in ('submitted', 'approved')
       and j.started_at is not null and j.ended_at is not null
       and tstzrange(j.started_at, j.ended_at, '[)') && tstzrange(new.started_at, new.ended_at, '[)')
  ) then
    raise exception using errcode = '23P01', message = 'overlapping_job_interval';
  end if;
  if new.return_time_minutes > duration_minutes then
    raise exception using errcode = '23514', message = 'return_time_exceeds_job_interval';
  end if;
  if new.km_total is null or new.km_aller is null or new.km_retour is null
     or new.km_total < 0 or new.km_aller < 0 or new.km_retour < 0
     or new.km_retour > new.km_total
     or abs((new.km_aller + new.km_retour) - new.km_total) > 0.001 then
    raise exception using errcode = '23514', message = 'invalid_job_kilometres';
  end if;
  return new;
end;
$$;

-- ── save_own_job : l'indicateur de preuve n'est retenu que si une preuve existe ce jour-là ──
create or replace function public.save_own_job(
  p_job_id uuid, p_new_job_id uuid, p_submission_key uuid, p_submit boolean, p_job_date date, p_ot text,
  p_depart time, p_arrivee time, p_fin time, p_km_total numeric, p_km_aller numeric, p_return_time_minutes integer,
  p_km_retour numeric, p_overtime_evidence_captured boolean, p_parking_receipt_captured boolean,
  p_confirm_manager_entry boolean default false)
returns table (id uuid, status text, locked boolean)
language plpgsql security definer set search_path = '' as $$
declare
  caller_id uuid := auth.uid();
  current_job public.jobs%rowtype;
  result_job public.jobs%rowtype;
  confirming boolean := false;
  day_has_evidence boolean;
begin
  if caller_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if not public.is_not_paused() then
    raise exception using errcode = '42501', message = 'job_write_not_allowed';
  end if;
  if p_job_date is null then
    raise exception using errcode = '23514', message = 'job_date_required';
  end if;
  day_has_evidence := exists (select 1 from public.overtime_evidence e where e.user_id = caller_id and e.job_date = p_job_date);

  if p_job_id is null then
    if p_submission_key is null then
      raise exception using errcode = '23514', message = 'submission_key_required';
    end if;
    perform pg_advisory_xact_lock(hashtextextended(caller_id::text, 0));
    select * into result_job from public.jobs j where j.user_id = caller_id and j.submission_key = p_submission_key;
    if result_job.id is null then
      insert into public.jobs (
        id, user_id, submission_key, job_date, ot, depart, arrivee, fin, km_total, km_aller, return_time_minutes, km_retour,
        overtime_evidence_captured, parking_receipt_captured, status, locked
      ) values (
        coalesce(p_new_job_id, gen_random_uuid()), caller_id, p_submission_key, p_job_date, p_ot, p_depart, p_arrivee, p_fin,
        coalesce(p_km_total, 0), coalesce(p_km_aller, 0), coalesce(p_return_time_minutes, 0), coalesce(p_km_retour, 0),
        coalesce(p_overtime_evidence_captured, false) and day_has_evidence, coalesce(p_parking_receipt_captured, false),
        case when p_submit then 'submitted' else 'saved' end, p_submit
      )
      on conflict (user_id, submission_key) do nothing
      returning * into result_job;
      if result_job.id is null then
        select * into result_job from public.jobs j where j.user_id = caller_id and j.submission_key = p_submission_key;
      end if;
    end if;
  else
    select * into current_job from public.jobs j where j.id = p_job_id and j.user_id = caller_id for update;
    if current_job.id is null then
      raise exception using errcode = 'P0002', message = 'job_not_found';
    end if;
    if current_job.status = 'submitted' and current_job.locked and p_submit then
      result_job := current_job;
    else
      if current_job.locked or current_job.status not in ('saved', 'updated') then
        raise exception using errcode = '55000', message = 'job_not_editable';
      end if;
      if p_submit and current_job.manager_entry_at is not null and current_job.employee_confirmed_at is null then
        if not coalesce(p_confirm_manager_entry, false) then
          raise exception using errcode = '55000', message = 'manager_entry_confirmation_required';
        end if;
        confirming := true;
      end if;
      update public.jobs j
         set job_date = p_job_date, ot = p_ot, depart = p_depart, arrivee = p_arrivee, fin = p_fin,
             km_total = coalesce(p_km_total, 0), km_aller = coalesce(p_km_aller, 0),
             return_time_minutes = coalesce(p_return_time_minutes, 0), km_retour = coalesce(p_km_retour, 0),
             overtime_evidence_captured = coalesce(p_overtime_evidence_captured, false)
               and (day_has_evidence or (current_job.overtime_evidence_captured and current_job.job_date = p_job_date)),
             parking_receipt_captured = coalesce(p_parking_receipt_captured, false),
             status = case when p_submit then 'submitted' else 'updated' end,
             locked = p_submit,
             employee_confirmed_at = case when confirming then now() else j.employee_confirmed_at end
       where j.id = current_job.id
       returning * into result_job;
      if confirming then
        perform public.write_audit(caller_id, 'manager_entry_confirmed', caller_id, result_job.id, jsonb_build_object('job_date', result_job.job_date));
      end if;
    end if;
  end if;
  return query select result_job.id, result_job.status, result_job.locked;
end;
$$;

-- ── Fiche + preuve + avis aux gestionnaires, en une seule transaction ───────
create function public.save_own_job_with_overtime_evidence(
  p_job_id uuid, p_new_job_id uuid, p_submission_key uuid, p_submit boolean, p_job_date date, p_ot text,
  p_depart time, p_arrivee time, p_fin time, p_km_total numeric, p_km_aller numeric, p_return_time_minutes integer,
  p_km_retour numeric, p_parking_receipt_captured boolean, p_evidence_id uuid, p_storage_path text, p_daily_minutes integer,
  p_confirm_manager_entry boolean default false)
returns table (id uuid, status text, locked boolean, evidence_id uuid)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
  existing public.overtime_evidence%rowtype;
  saved_id uuid;
  saved_status text;
  saved_locked boolean;
  retention integer;
  minutes integer := least(greatest(coalesce(p_daily_minutes, 0), 0), 1440);
begin
  if caller_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_evidence_id is null or p_storage_path is null or p_job_date is null then
    raise exception using errcode = '23514', message = 'overtime_evidence_required';
  end if;
  -- Relance après une validation dont la réponse s'est perdue : la preuve existe déjà, donc la fiche, la preuve et l'avis aussi.
  select * into existing from public.overtime_evidence e where e.id = p_evidence_id;
  if existing.id is not null then
    if existing.user_id <> caller_id then
      raise exception using errcode = '42501', message = 'evidence_not_owned';
    end if;
    return query select j.id, j.status, j.locked, existing.id from public.jobs j where j.id = existing.job_id;
    return;
  end if;
  -- Le fichier doit déjà être téléversé, dans le dossier de l'appelant pour ce jour-là.
  if p_storage_path not like caller_id::text || '/' || p_job_date::text || '/%' then
    raise exception using errcode = '23514', message = 'invalid_evidence_path';
  end if;
  if not exists (
    select 1 from storage.objects o
     where o.bucket_id = 'overtime-evidence' and o.name = p_storage_path and (o.owner_id = caller_id::text or o.owner = caller_id)
  ) then
    raise exception using errcode = 'P0002', message = 'evidence_file_missing';
  end if;
  -- 1. La fiche, en brouillon (aucune preuve revendiquée encore).
  select s.id, s.status, s.locked into saved_id, saved_status, saved_locked
    from public.save_own_job(p_job_id, p_new_job_id, p_submission_key, false, p_job_date, p_ot, p_depart, p_arrivee, p_fin,
                             p_km_total, p_km_aller, p_return_time_minutes, p_km_retour, false, p_parking_receipt_captured, false) s;
  -- 2. La preuve (son trigger marque la dernière fiche du jour).
  select coalesce(o.evidence_retention_days, 30) into retention from public.overtime_settings o where o.id = true;
  retention := least(365, greatest(1, coalesce(retention, 30)));
  insert into public.overtime_evidence (id, job_id, user_id, job_date, storage_path, daily_minutes, expires_at, ocr_status)
  values (p_evidence_id, saved_id, caller_id, p_job_date, p_storage_path, minutes, now() + make_interval(days => retention), 'pending');
  -- 3. Avis aux gestionnaires (une fois par preuve).
  insert into public.manager_notifications (type, employee_id, job_id, evidence_id, daily_minutes)
  select 'overtime_evidence', caller_id, saved_id, p_evidence_id, minutes
   where not exists (select 1 from public.manager_notifications n where n.evidence_id = p_evidence_id);
  -- 4. Soumission, maintenant que la preuve existe. Un refus annule aussi les étapes 1 à 3.
  if p_submit then
    select s.id, s.status, s.locked into saved_id, saved_status, saved_locked
      from public.save_own_job(saved_id, null, null, true, p_job_date, p_ot, p_depart, p_arrivee, p_fin, p_km_total, p_km_aller,
                               p_return_time_minutes, p_km_retour, true, p_parking_receipt_captured, p_confirm_manager_entry) s;
  end if;
  return query select saved_id, saved_status, saved_locked, p_evidence_id;
end;
$$;

-- ── Stockage des preuves : compartiment privé, dossier = identifiant de l'employé ──
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('overtime-evidence', 'overtime-evidence', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create policy "overtime storage: owner upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'overtime-evidence' and public.is_not_paused() and (storage.foldername(name))[1] = (auth.uid())::text);
create policy "overtime storage: manager read" on storage.objects for select to authenticated
  using (bucket_id = 'overtime-evidence' and public.get_my_role() = 'manager');

-- ── Droits et règles d'accès ────────────────────────────────────────────────
revoke all on table public.overtime_evidence, public.manager_notifications, public.manager_notification_reads from anon, public, authenticated;
alter table public.overtime_evidence enable row level security;
alter table public.manager_notifications enable row level security;
alter table public.manager_notification_reads enable row level security;
grant select on public.overtime_evidence, public.manager_notifications to authenticated;
grant select, insert, update, delete on public.manager_notification_reads to authenticated;
create policy overtime_evidence_manager_read on public.overtime_evidence for select to authenticated using ((select public.get_my_role()) = 'manager');
create policy manager_notifications_manager_read on public.manager_notifications for select to authenticated using ((select public.get_my_role()) = 'manager');
create policy notification_reads_manage_own on public.manager_notification_reads for all to authenticated
  using (manager_id = (select auth.uid()) and (select public.get_my_role()) = 'manager')
  with check (manager_id = (select auth.uid()) and (select public.get_my_role()) = 'manager');

revoke all on function public.overtime_day_minutes(uuid, date), public.attach_overtime_evidence_to_last_job(uuid, date),
  public.attach_overtime_evidence_after_evidence_insert(), public.attach_overtime_evidence_after_job_write(),
  public.reconcile_overtime_evidence(), public.rehome_overtime_evidence_before_job_delete(),
  public.sync_overtime_evidence_flag_after_job_delete(), public.point_overtime_notification_at_evidence_job(),
  public.save_own_job_with_overtime_evidence(uuid, uuid, uuid, boolean, date, text, time, time, time, numeric, numeric, integer, numeric, boolean, uuid, text, integer, boolean)
  from public, anon, authenticated;
grant execute on function
  public.save_own_job_with_overtime_evidence(uuid, uuid, uuid, boolean, date, text, time, time, time, numeric, numeric, integer, numeric, boolean, uuid, text, integer, boolean)
  to authenticated;

-- ════════════════════════════════════════════════════════════════════
-- 0007_meals_parking.sql
-- ════════════════════════════════════════════════════════════════════
-- Sparklog-Employés — schéma neuf du côté 1. Migration 0007 : repas, stationnement, avis de modification d'une fiche à preuve, téléchargements de preuves.
-- Relevé dans une base reconstruite à partir des 150 migrations de Sparklog V2.4.258 (0012, 0016, 0086, 0125, 0126, 0139 et voisines).
--
-- Écarts voulus par rapport à Sparklog :
--  * le **souper est refusé à l'insertion** si la journée n'y donne pas droit, et le nombre de minutes enregistré est **calculé par le serveur** : dans Sparklog,
--    seul un `check (>= 615)` sur une valeur fournie par le navigateur protégeait l'insertion (le ménage ne passait qu'à la modification d'une fiche) ;
--  * un employé ne peut insérer des avis que de type `meal_claim` ou `parking_receipt` (il pouvait en fabriquer de tout type) ;
--  * le journal d'audit est celui de 0005 (numéros, aucune clé libre) : pas de `actor_name`, et `ot` n'y figure plus ;
--  * pas de trigger d'audit d'approbation d'une fiche : toute approbation passe par `approve_jobs` (0005), qui écrit son audit.
-- À décider (non modifié ici) : `payroll_treatment` (remboursement ou avantage imposable) est une décision de PAIE prise à l'approbation dans Sparklog ; si vous voulez
-- l'invariant « aucun montant de paie » au sens strict, elle passe au côté 2. Même question pour les montants de repas (30 $) et de stationnement saisis par l'employé.

-- ── Tables ──────────────────────────────────────────────────────────────────
create table public.meal_claims (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  job_date date not null,
  amount numeric not null default 30 check (amount = 30),
  storage_path text,
  daily_work_minutes integer not null check (daily_work_minutes >= 615),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  payroll_treatment text check (payroll_treatment in ('expense_reimbursement', 'taxable_benefit')),
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, job_date)
);
create index meal_claims_job_idx on public.meal_claims (job_id);
create index meal_claims_reviewed_by_idx on public.meal_claims (reviewed_by);
create index meal_claims_pending_created_idx on public.meal_claims (created_at desc, job_id) where status = 'pending';

create table public.parking_receipts (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null unique references public.jobs(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  job_date date not null,
  storage_path text,
  amount numeric not null default 0 check (amount >= 0),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  extra_storage_paths text[] not null default '{}' check (cardinality(extra_storage_paths) <= 9),
  expires_at timestamptz,
  pictures_purged_at timestamptz,
  created_at timestamptz not null default now()
);
comment on column public.parking_receipts.extra_storage_paths is 'Photos du parcomètre après la première (storage_path), dans l''ordre pris. Même compartiment, même dossier de l''employé.';
create index parking_receipts_user_idx on public.parking_receipts (user_id);
create index parking_receipts_reviewed_by_idx on public.parking_receipts (reviewed_by);
create index parking_receipts_pending_created_idx on public.parking_receipts (created_at desc, job_id) where status = 'pending';
create index parking_receipts_expiry_idx on public.parking_receipts (expires_at) where storage_path is not null;

create table public.evidence_downloads (
  bucket text not null check (bucket in ('overtime-evidence', 'parking-receipts')),
  storage_path text not null,
  downloaded_by uuid not null default auth.uid(),
  downloaded_at timestamptz not null default now(),
  primary key (bucket, storage_path)
);

-- Les avis de repas et de stationnement s'ajoutent à ceux de 0006.
alter table public.manager_notifications
  add column meal_claim_id uuid references public.meal_claims(id) on delete cascade,
  add column parking_receipt_id uuid references public.parking_receipts(id) on delete cascade,
  add constraint manager_notifications_type_chk check (type in ('overtime_evidence', 'overtime_job_edited', 'meal_claim', 'parking_receipt'));
create index manager_notifications_meal_idx on public.manager_notifications (meal_claim_id);
create index manager_notifications_parking_idx on public.manager_notifications (parking_receipt_id);

-- ── Souper : droit selon la journée ─────────────────────────────────────────
-- Minutes payées du jour pour le souper : durée de chaque fiche moins son retour (le retour n'est jamais du temps supplémentaire), moins le premier trajet non payé
-- (premier Départ du jour, jamais si cette fiche fait 65 km ou plus depuis le 2026-10-11). Jumeau de dayFirstTripUnpaidMinutes dans payroll_engine.js.
create function public.meal_day_paid_minutes(p_user uuid, p_date date)
returns integer language plpgsql stable security definer set search_path = '' as $$
declare
  daily_work_minutes integer := 0;
  unpaid_trip_minutes integer := 0;
begin
  select coalesce(sum(greatest(0, s.span - least(greatest(coalesce(s.return_time_minutes, 0), 0), s.span))), 0)
    into daily_work_minutes
    from (
      select j.return_time_minutes,
             case when j.depart is not null and j.fin is not null
                  then (extract(epoch from (j.fin - j.depart)) / 60)::int + case when j.fin < j.depart then 1440 else 0 end
                  else 0 end as span
        from public.jobs j where j.user_id = p_user and j.job_date = p_date
    ) s;
  if exists (select 1 from public.profiles p where p.id = p_user and p.first_trip_unpaid) then
    select case
             when d.depart is null or d.arrivee is null or d.fin is null then 0
             when p_date >= date '2026-10-11' and d.km >= 65 then 0
             else least(((extract(epoch from (d.arrivee - d.depart))::integer / 60) + 1440) % 1440,
                        ((extract(epoch from (d.fin - d.depart))::integer / 60) + 1440) % 1440)
           end
      into unpaid_trip_minutes
      from (
        select j.depart, j.arrivee, j.fin, greatest(coalesce(j.km_total, 0), coalesce(j.km_aller, 0) + coalesce(j.km_retour, 0)) as km
          from public.jobs j where j.user_id = p_user and j.job_date = p_date
         order by coalesce(left(j.depart::text, 5), '') collate "C", j.id::text collate "C"
         limit 1
      ) d;
  end if;
  return daily_work_minutes - coalesce(unpaid_trip_minutes, 0);
end;
$$;

-- Souper dû : jour de semaine, 615 minutes payées (journée de 8 h + 2 h 15), hors retour. « 4 jours de 10 h » : aucun souper (décision du 2026-11-13) sauf contremaître et sous-traitant.
create function public.is_meal_eligible(p_user uuid, p_date date)
returns boolean language sql stable security definer set search_path = '' as $$
  select extract(dow from p_date) not in (0, 6)
     and not exists (select 1 from public.profiles p where p.id = p_user and p.ten_hour_days and p.role not in ('foreman', 'subcontractor_1'))
     and public.meal_day_paid_minutes(p_user, p_date) >= 615;
$$;

create function public.reconcile_overtime_meal(p_user uuid, p_date date)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_user is null or p_date is null then return; end if;
  if not public.is_meal_eligible(p_user, p_date) then
    delete from public.manager_notifications n
     where n.type = 'meal_claim' and n.job_id in (select id from public.jobs where user_id = p_user and job_date = p_date);
    delete from public.meal_claims m where m.user_id = p_user and m.job_date = p_date and m.reviewed_by is null;
    update public.jobs set meal_claim_captured = false where user_id = p_user and job_date = p_date and meal_claim_captured is true;
  end if;
end;
$$;

create function public.trg_reconcile_overtime_meal()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    perform public.reconcile_overtime_meal(old.user_id, old.job_date);
    return old;
  end if;
  perform public.reconcile_overtime_meal(new.user_id, new.job_date);
  return new;
end;
$$;
create trigger reconcile_overtime_meal_after_delete after delete on public.jobs
  for each row execute function public.trg_reconcile_overtime_meal();
create trigger reconcile_overtime_meal_after_update after update of depart, arrivee, fin, return_time_minutes on public.jobs
  for each row execute function public.trg_reconcile_overtime_meal();

-- À l'insertion (employé) : seulement un souper dû, et les minutes sont celles du serveur.
create function public.meal_claims_validate()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null and public.get_my_role() is distinct from 'manager' then
    if not public.is_meal_eligible(new.user_id, new.job_date) then
      raise exception using errcode = '23514', message = 'meal_not_eligible';
    end if;
    new.daily_work_minutes := public.meal_day_paid_minutes(new.user_id, new.job_date);
  end if;
  return new;
end;
$$;
create trigger meal_claims_validate_insert before insert on public.meal_claims
  for each row execute function public.meal_claims_validate();

-- Un employé ne touche pas aux champs de révision.
create function public.protect_meal_review_fields()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null and public.get_my_role() is distinct from 'manager' then
    if tg_op = 'INSERT' then
      new.status := 'pending'; new.payroll_treatment := null; new.reviewed_by := null; new.reviewed_at := null;
    elsif new.status is distinct from old.status or new.payroll_treatment is distinct from old.payroll_treatment
       or new.reviewed_by is distinct from old.reviewed_by or new.reviewed_at is distinct from old.reviewed_at then
      raise exception 'Employees cannot change meal claim review fields';
    end if;
  end if;
  return new;
end;
$$;
create trigger meal_protect_review_fields before insert or update on public.meal_claims
  for each row execute function public.protect_meal_review_fields();

create function public.protect_parking_review_fields()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null and public.get_my_role() is distinct from 'manager' then
    if tg_op = 'INSERT' then
      if coalesce(new.status, 'pending') <> 'pending' or new.reviewed_by is not null or new.reviewed_at is not null then
        raise exception 'Employees cannot set parking review fields';
      end if;
    elsif new.status is distinct from old.status or new.reviewed_by is distinct from old.reviewed_by or new.reviewed_at is distinct from old.reviewed_at then
      raise exception 'Employees cannot set parking review fields';
    end if;
  end if;
  return new;
end;
$$;
create trigger parking_protect_review_fields before insert or update on public.parking_receipts
  for each row execute function public.protect_parking_review_fields();

-- ── Stationnement : plafond du jour, échéance des photos, chemins ───────────
create function public.enforce_daily_parking_cap()
returns trigger language plpgsql security definer set search_path = '' as $$
declare daily_total numeric;
begin
  select coalesce(sum(amount), 0) into daily_total from public.parking_receipts where user_id = new.user_id and job_date = new.job_date and id <> new.id;
  if daily_total + new.amount > 20 then
    raise exception 'The daily parking maximum is $20';
  end if;
  return new;
end;
$$;
create trigger parking_receipts_daily_cap before insert or update of amount, user_id, job_date on public.parking_receipts
  for each row execute function public.enforce_daily_parking_cap();

create function public.parking_receipts_set_expiry()
returns trigger language plpgsql security definer set search_path = '' as $$
declare retention integer;
begin
  select coalesce(o.evidence_retention_days, 30) into retention from public.overtime_settings o where o.id = true;
  retention := least(365, greatest(1, coalesce(retention, 30)));
  if tg_op = 'INSERT' then
    new.pictures_purged_at := null;
    new.expires_at := now() + make_interval(days => retention);
  elsif auth.uid() is not null then
    new.expires_at := old.expires_at;
    new.pictures_purged_at := old.pictures_purged_at;
    -- Des photos ajoutées après un nettoyage ouvrent une nouvelle fenêtre.
    if old.storage_path is null and new.storage_path is not null then
      new.pictures_purged_at := null;
      new.expires_at := now() + make_interval(days => retention);
    end if;
  end if;
  return new;
end;
$$;
create trigger parking_receipts_set_expiry before insert or update on public.parking_receipts
  for each row execute function public.parking_receipts_set_expiry();

create function public.validate_parking_receipt_paths()
returns trigger language plpgsql set search_path = '' as $$
declare p text;
begin
  if new.storage_path is null then
    if new.pictures_purged_at is null or cardinality(coalesce(new.extra_storage_paths, '{}')) > 0 then
      raise exception 'Parking receipt picture must be in the employee''s own folder' using errcode = 'check_violation';
    end if;
    return new;
  end if;
  if new.storage_path not like new.user_id::text || '/%' then
    raise exception 'Parking receipt picture must be in the employee''s own folder' using errcode = 'check_violation';
  end if;
  foreach p in array coalesce(new.extra_storage_paths, '{}') loop
    if p is null or p not like new.user_id::text || '/%' or p = new.storage_path then
      raise exception 'Parking receipt picture must be in the employee''s own folder' using errcode = 'check_violation';
    end if;
  end loop;
  if cardinality(new.extra_storage_paths) <> (select count(distinct x) from unnest(new.extra_storage_paths) x) then
    raise exception 'Duplicate parking receipt picture' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger parking_receipts_validate_paths before insert or update of storage_path, extra_storage_paths, user_id, pictures_purged_at on public.parking_receipts
  for each row execute function public.validate_parking_receipt_paths();

-- Téléchargement de preuves : l'auteur et l'heure viennent du serveur.
create function public.evidence_downloads_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.downloaded_by := auth.uid();
  new.downloaded_at := now();
  return new;
end;
$$;
create trigger evidence_downloads_guard before insert on public.evidence_downloads
  for each row execute function public.evidence_downloads_guard();

-- ── Révision par un gestionnaire (double authentification) ──────────────────
create function public.review_meal_claim(p_claim_id uuid, p_decision text, p_payroll_treatment text default null)
returns table (id uuid, status text, payroll_treatment text, reviewed_by uuid, reviewed_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid := auth.uid();
  current_claim public.meal_claims%rowtype;
  changed_claim public.meal_claims%rowtype;
begin
  if actor_id is null or public.get_my_role() <> 'manager' then
    raise exception using errcode = '42501', message = 'manager_role_required';
  end if;
  if p_decision is null or p_decision not in ('approved', 'rejected') then
    raise exception using errcode = '22023', message = 'invalid_review_decision';
  end if;
  if p_decision = 'approved' and coalesce(p_payroll_treatment, '') not in ('expense_reimbursement', 'taxable_benefit') then
    raise exception using errcode = '22023', message = 'invalid_payroll_treatment';
  end if;
  select * into current_claim from public.meal_claims c where c.id = p_claim_id for update;
  if current_claim.id is null then
    raise exception using errcode = 'P0002', message = 'meal_claim_not_found';
  end if;
  if current_claim.status <> 'pending' then
    raise exception using errcode = '40001', message = 'meal_claim_already_reviewed';
  end if;
  update public.meal_claims c
     set status = p_decision, payroll_treatment = case when p_decision = 'approved' then p_payroll_treatment else null end,
         reviewed_by = actor_id, reviewed_at = now()
   where c.id = current_claim.id returning * into changed_claim;
  return query select changed_claim.id, changed_claim.status, changed_claim.payroll_treatment, changed_claim.reviewed_by, changed_claim.reviewed_at;
end;
$$;

create function public.review_parking_claim(p_job_id uuid, p_decision text)
returns table (id uuid, job_id uuid, status text, reviewed_by uuid, reviewed_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid := auth.uid();
  current_claim public.parking_receipts%rowtype;
  changed_claim public.parking_receipts%rowtype;
begin
  if actor_id is null or public.get_my_role() <> 'manager' then
    raise exception using errcode = '42501', message = 'manager_role_required';
  end if;
  if p_decision is null or p_decision not in ('approved', 'rejected') then
    raise exception using errcode = '22023', message = 'invalid_review_decision';
  end if;
  select * into current_claim from public.parking_receipts p where p.job_id = p_job_id for update;
  if current_claim.id is null then
    raise exception using errcode = 'P0002', message = 'parking_claim_not_found';
  end if;
  if current_claim.status <> 'pending' then
    raise exception using errcode = '40001', message = 'parking_claim_already_reviewed';
  end if;
  update public.parking_receipts p set status = p_decision, reviewed_by = actor_id, reviewed_at = now()
   where p.id = current_claim.id returning * into changed_claim;
  return query select changed_claim.id, changed_claim.job_id, changed_claim.status, changed_claim.reviewed_by, changed_claim.reviewed_at;
end;
$$;

-- Audit des révisions (numéros seulement ; le statut est dans la clé permise `to`).
create function public.audit_meal_review()
returns trigger language plpgsql security definer set search_path = '' as $$
declare actor uuid := coalesce(new.reviewed_by, auth.uid());
begin
  if new.status is distinct from old.status and new.status in ('approved', 'rejected') then
    perform public.write_audit(actor, 'meal_reviewed', new.user_id, new.job_id, jsonb_build_object('to', new.status, 'job_date', new.job_date));
  end if;
  return new;
end;
$$;
create trigger audit_meal_review after update on public.meal_claims for each row execute function public.audit_meal_review();

create function public.audit_parking_review()
returns trigger language plpgsql security definer set search_path = '' as $$
declare actor uuid := coalesce(new.reviewed_by, auth.uid());
begin
  if new.status is distinct from old.status and new.status in ('approved', 'rejected') then
    perform public.write_audit(actor, 'parking_reviewed', new.user_id, new.job_id, jsonb_build_object('to', new.status, 'job_date', new.job_date));
  end if;
  return new;
end;
$$;
create trigger audit_parking_review after update on public.parking_receipts for each row execute function public.audit_parking_review();

-- ── Avis aux gestionnaires quand l'employé modifie une fiche qui porte une preuve ──
-- Une seule notification non lue par fiche : les modifications successives s'y fusionnent ; si tout revient à l'état d'origine, elle disparaît.
create function public.notify_overtime_job_edit()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  proof public.overtime_evidence%rowtype;
  diff jsonb := '{}'::jsonb;
  existing_id uuid;
  existing_changes jsonb;
  merged jsonb;
  k text;
  v jsonb;
begin
  -- Les changements d'un gestionnaire ou du service (approbation, réouverture, maintenance) ne créent pas d'avis.
  if auth.uid() is null or auth.uid() <> new.user_id then return new; end if;
  select * into proof from public.overtime_evidence where job_id = new.id order by created_at desc limit 1;
  if proof.id is null then return new; end if;
  if new.job_date is distinct from old.job_date then diff := diff || jsonb_build_object('job_date', jsonb_build_object('from', to_jsonb(old.job_date), 'to', to_jsonb(new.job_date))); end if;
  if new.ot is distinct from old.ot then diff := diff || jsonb_build_object('ot', jsonb_build_object('from', to_jsonb(old.ot), 'to', to_jsonb(new.ot))); end if;
  if new.depart is distinct from old.depart then diff := diff || jsonb_build_object('depart', jsonb_build_object('from', to_jsonb(old.depart::text), 'to', to_jsonb(new.depart::text))); end if;
  if new.arrivee is distinct from old.arrivee then diff := diff || jsonb_build_object('arrivee', jsonb_build_object('from', to_jsonb(old.arrivee::text), 'to', to_jsonb(new.arrivee::text))); end if;
  if new.fin is distinct from old.fin then diff := diff || jsonb_build_object('fin', jsonb_build_object('from', to_jsonb(old.fin::text), 'to', to_jsonb(new.fin::text))); end if;
  if new.return_time_minutes is distinct from old.return_time_minutes then diff := diff || jsonb_build_object('return_time_minutes', jsonb_build_object('from', to_jsonb(old.return_time_minutes), 'to', to_jsonb(new.return_time_minutes))); end if;
  if new.km_total is distinct from old.km_total then diff := diff || jsonb_build_object('km_total', jsonb_build_object('from', to_jsonb(old.km_total), 'to', to_jsonb(new.km_total))); end if;
  if new.km_retour is distinct from old.km_retour then diff := diff || jsonb_build_object('km_retour', jsonb_build_object('from', to_jsonb(old.km_retour), 'to', to_jsonb(new.km_retour))); end if;
  if diff = '{}'::jsonb then return new; end if;

  select id, coalesce(changes, '{}'::jsonb) into existing_id, existing_changes
    from public.manager_notifications mn
   where mn.job_id = new.id and mn.type = 'overtime_job_edited'
     and not exists (select 1 from public.manager_notification_reads r where r.notification_id = mn.id)
   order by mn.created_at desc limit 1;

  if existing_id is not null then
    merged := existing_changes;
    for k, v in select key, value from jsonb_each(diff) loop
      if merged ? k then merged := jsonb_set(merged, array[k, 'to'], v -> 'to');
      else merged := merged || jsonb_build_object(k, v); end if;
    end loop;
    for k, v in select key, value from jsonb_each(merged) loop
      if (v -> 'from') is not distinct from (v -> 'to') then merged := merged - k; end if;
    end loop;
    if merged = '{}'::jsonb then
      delete from public.manager_notifications where id = existing_id;
    else
      update public.manager_notifications set changes = merged, evidence_id = proof.id, daily_minutes = proof.daily_minutes, created_at = now() where id = existing_id;
    end if;
  else
    insert into public.manager_notifications (type, employee_id, job_id, evidence_id, daily_minutes, changes)
    values ('overtime_job_edited', new.user_id, new.id, proof.id, proof.daily_minutes, diff);
  end if;
  return new;
end;
$$;
create trigger jobs_notify_overtime_edit after update of job_date, ot, depart, arrivee, fin, km_total, km_aller, km_retour, return_time_minutes, status on public.jobs
  for each row execute function public.notify_overtime_job_edit();

-- ── Stockage : un compartiment privé par type de pièce ──────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('parking-receipts', 'parking-receipts', false, 10485760, array['image/jpeg', 'image/png', 'image/webp']),
  ('meal-receipts', 'meal-receipts', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
create policy "parking storage: owner upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'parking-receipts' and public.is_not_paused() and (storage.foldername(name))[1] = (auth.uid())::text);
create policy "parking storage: manager read" on storage.objects for select to authenticated
  using (bucket_id = 'parking-receipts' and public.get_my_role() = 'manager');
create policy "meal storage: owner upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'meal-receipts' and public.is_not_paused() and (storage.foldername(name))[1] = (auth.uid())::text);
create policy "meal storage: manager read" on storage.objects for select to authenticated
  using (bucket_id = 'meal-receipts' and public.get_my_role() = 'manager');

-- ── Droits et règles d'accès ────────────────────────────────────────────────
revoke all on table public.meal_claims, public.parking_receipts, public.evidence_downloads from anon, public, authenticated;
alter table public.meal_claims enable row level security;
alter table public.parking_receipts enable row level security;
alter table public.evidence_downloads enable row level security;
grant select, insert on public.meal_claims to authenticated;
grant select, insert, update on public.parking_receipts to authenticated;
grant select, insert on public.evidence_downloads to authenticated;
grant insert on public.manager_notifications to authenticated;

create policy meal_claims_read_own on public.meal_claims for select to authenticated using (user_id = (select auth.uid()));
create policy meal_claims_manager_read on public.meal_claims for select to authenticated using ((select public.get_my_role()) = 'manager');
create policy meal_claims_owner_insert on public.meal_claims for insert to authenticated
  with check ((select public.is_not_paused()) and user_id = (select auth.uid())
              and exists (select 1 from public.jobs j where j.id = meal_claims.job_id and j.user_id = (select auth.uid())));

create policy parking_receipts_read_own on public.parking_receipts for select to authenticated using (user_id = (select auth.uid()));
create policy parking_receipts_manager_read on public.parking_receipts for select to authenticated using ((select public.get_my_role()) = 'manager');
create policy parking_receipts_owner_insert on public.parking_receipts for insert to authenticated
  with check ((select public.is_not_paused()) and user_id = (select auth.uid())
              and exists (select 1 from public.jobs j where j.id = parking_receipts.job_id and j.user_id = (select auth.uid())));
create policy parking_receipts_owner_update_pending on public.parking_receipts for update to authenticated
  using (public.is_not_paused() and user_id = auth.uid() and status = 'pending')
  with check (public.is_not_paused() and user_id = auth.uid() and status = 'pending' and reviewed_by is null and reviewed_at is null);

-- Un employé n'ajoute que des avis de repas ou de stationnement, pour sa propre fiche.
create policy manager_notifications_owner_insert on public.manager_notifications for insert to authenticated
  with check ((select public.is_not_paused()) and employee_id = (select auth.uid()) and type in ('meal_claim', 'parking_receipt')
              and exists (select 1 from public.jobs j where j.id = manager_notifications.job_id and j.user_id = (select auth.uid())));

create policy evidence_downloads_manager_read on public.evidence_downloads for select to authenticated using (public.get_my_role() = 'manager');
create policy evidence_downloads_manager_insert on public.evidence_downloads for insert to authenticated with check (public.get_my_role() = 'manager');

revoke all on function public.meal_day_paid_minutes(uuid, date), public.is_meal_eligible(uuid, date), public.reconcile_overtime_meal(uuid, date),
  public.trg_reconcile_overtime_meal(), public.meal_claims_validate(), public.protect_meal_review_fields(), public.protect_parking_review_fields(),
  public.enforce_daily_parking_cap(), public.parking_receipts_set_expiry(), public.validate_parking_receipt_paths(), public.evidence_downloads_guard(),
  public.review_meal_claim(uuid, text, text), public.review_parking_claim(uuid, text), public.audit_meal_review(), public.audit_parking_review(),
  public.notify_overtime_job_edit() from public, anon, authenticated;
grant execute on function public.review_meal_claim(uuid, text, text), public.review_parking_claim(uuid, text) to authenticated;

-- ════════════════════════════════════════════════════════════════════
-- 0008_notes_activity.sql
-- ════════════════════════════════════════════════════════════════════
-- Sparklog-Employés — schéma neuf du côté 1. Migration 0008 : notes du contremaître (jointes à la fiche) et journal d'activité de l'employé.
-- Relevé dans une base reconstruite à partir des 150 migrations de Sparklog V2.4.258 (0067, 0134, 0136, 0138, 0140 et voisines).
-- (Les notes entre gestionnaires et le temps libre sont au côté 2 : décision du 2026-11-14.)
--
-- Écarts voulus par rapport à Sparklog :
--  * `foreman_reports.audited_name` (texte libre : un NOM) devient `audited_employee_number` (le numéro de l'employé audité) ;
--  * pas de `returned_by_name` (un nom) : `returned_by` suffit ;
--  * **faille fermée** (notée dans Sparklog, jamais corrigée) : un contremaître pouvait écrire `returned_at`, `returned_by` et `return_reason` à l'insertion de sa propre note,
--    donc afficher une fausse étiquette « Retournée par … » ; un déclencheur les remet à zéro à l'insertion ;
--  * journal d'activité : pas de `user_name`, pas d'appareil (`device` : empreinte), pas de `ot` (texte libre), et une liste fermée de clés de détail ;
--  * l'avis à l'employé (`employee_notices`, 0005) est aussi posé quand une fiche de contremaître est retournée.
-- Reste identique : la raison d'un retour (≤ 500 caractères) et le texte de la note sont du texte libre ; le côté 2 filtre les noms avant envoi (`PLAN.md` 3.5).

-- ── Notes du contremaître ───────────────────────────────────────────────────
create table public.foreman_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  submission_key uuid not null,
  report_date date not null,
  audited_employee_number integer check (audited_employee_number is null or audited_employee_number between 1000 and 999999),
  body text not null check (char_length(btrim(body)) between 1 and 5000),
  created_at timestamptz not null default now(),
  job_id uuid references public.jobs(id) on delete cascade,
  updated_at timestamptz not null default now(),
  returned_at timestamptz,
  returned_by uuid references public.profiles(id) on delete set null,
  return_reason text check (return_reason is null or char_length(btrim(return_reason)) between 1 and 500),
  constraint foreman_reports_user_key_uniq unique (user_id, submission_key)
);
create unique index foreman_reports_job_uniq on public.foreman_reports (job_id) where job_id is not null;
create index foreman_reports_created_idx on public.foreman_reports (created_at desc);
create index foreman_reports_user_created_idx on public.foreman_reports (user_id, created_at desc);

create table public.foreman_report_reads (
  report_id uuid not null references public.foreman_reports(id) on delete cascade,
  manager_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (report_id, manager_id)
);

-- À l'insertion : l'heure vient du serveur, le texte est nettoyé, et rien ne laisse croire que la note a déjà été retournée.
create function public.foreman_reports_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.created_at := now();
  new.updated_at := now();
  new.body := btrim(new.body);
  new.returned_at := null;
  new.returned_by := null;
  new.return_reason := null;
  return new;
end;
$$;
create trigger foreman_reports_guard before insert on public.foreman_reports for each row execute function public.foreman_reports_guard();

-- À la mise à jour : auteur, fiche, date, clé et heure de création figés ; `updated_at` ne bouge que si le texte ou le numéro change
-- (un retour de la fiche ne remet donc pas la note « non lue »).
create function public.foreman_reports_guard_update()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.id := old.id;
  new.user_id := old.user_id;
  new.job_id := old.job_id;
  new.submission_key := old.submission_key;
  new.report_date := old.report_date;
  new.created_at := old.created_at;
  new.body := btrim(new.body);
  if new.body is distinct from old.body or new.audited_employee_number is distinct from old.audited_employee_number then
    new.updated_at := now();
  else
    new.updated_at := old.updated_at;
  end if;
  return new;
end;
$$;
create trigger foreman_reports_guard_update before update on public.foreman_reports for each row execute function public.foreman_reports_guard_update();

create function public.foreman_report_reads_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.manager_id := coalesce(auth.uid(), new.manager_id);
  new.read_at := now();
  return new;
end;
$$;
create trigger foreman_report_reads_guard before insert or update on public.foreman_report_reads for each row execute function public.foreman_report_reads_guard();

-- Retourner la fiche d'un contremaître avec une raison (gestionnaire avec double authentification, version attendue).
-- Seule cette fonction écrit les colonnes `returned_*`.
create function public.return_foreman_note_sheet(p_report_id uuid, p_expected_updated_at timestamptz, p_reason text default null)
returns table (id uuid, status text)
language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid := auth.uid();
  note public.foreman_reports%rowtype;
  current_job public.jobs%rowtype;
  changed_job public.jobs%rowtype;
  clean_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if actor_id is null or public.get_my_role() <> 'manager' then
    raise exception using errcode = '42501', message = 'manager_role_required';
  end if;
  if clean_reason is not null and char_length(clean_reason) > 500 then
    raise exception using errcode = '23514', message = 'return_reason_too_long';
  end if;
  select * into note from public.foreman_reports r where r.id = p_report_id;
  if note.id is null or note.job_id is null then
    raise exception using errcode = 'P0002', message = 'note_has_no_sheet';
  end if;
  select * into current_job from public.jobs j where j.id = note.job_id for update;
  if current_job.id is null then
    raise exception using errcode = 'P0002', message = 'job_not_found';
  end if;
  if p_expected_updated_at is null or current_job.status <> 'submitted' or not current_job.locked
     or current_job.updated_at is distinct from p_expected_updated_at then
    raise exception using errcode = '40001', message = 'job_state_changed';
  end if;
  update public.jobs j set status = 'updated', locked = false where j.id = current_job.id returning * into changed_job;
  update public.foreman_reports r set returned_at = now(), returned_by = actor_id, return_reason = clean_reason where r.id = note.id;
  perform public.write_audit(actor_id, 'job_returned_for_correction', changed_job.user_id, changed_job.id,
                             jsonb_build_object('from', current_job.status, 'to', changed_job.status, 'job_date', changed_job.job_date));
  perform public.notify_employee(changed_job.user_id, changed_job.id, 'job_returned', changed_job.job_date);
  return query select changed_job.id, changed_job.status;
end;
$$;

-- ── Journal d'activité de l'employé ─────────────────────────────────────────
create table public.employee_activity_log (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  event text not null check (event in ('login', 'app_open', 'job_saved', 'job_submitted', 'job_deleted')),
  job_id uuid,
  details jsonb not null default '{}'::jsonb
);
create index employee_activity_log_created_idx on public.employee_activity_log (created_at desc);
create index employee_activity_log_user_created_idx on public.employee_activity_log (user_id, created_at desc);

create function public.employee_activity_log_guard()
returns trigger language plpgsql set search_path = '' as $$
declare k text;
begin
  if jsonb_typeof(new.details) <> 'object' then
    raise exception using errcode = '23514', message = 'activity_details_must_be_object';
  end if;
  for k in select jsonb_object_keys(new.details) loop
    if k not in ('job_date', 'depart', 'fin', 'status', 'edit') then
      raise exception using errcode = '23514', message = 'activity_details_key_not_allowed: ' || k;
    end if;
  end loop;
  return new;
end;
$$;
create trigger employee_activity_log_guard before insert on public.employee_activity_log for each row execute function public.employee_activity_log_guard();

-- Présence : une connexion à moins d'une minute de la précédente, ou une visite à moins de 30 minutes d'une connexion ou visite, est la même présence.
-- Le paramètre d'appareil est accepté (compatibilité du client) mais NON conservé.
create function public.log_employee_activity(p_event text, p_device text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  window_size interval;
begin
  if uid is null or p_event not in ('login', 'app_open') then return; end if;
  window_size := case when p_event = 'login' then interval '1 minute' else interval '30 minutes' end;
  if exists (
    select 1 from public.employee_activity_log
     where user_id = uid and event = any (case when p_event = 'login' then array['login'] else array['login', 'app_open'] end)
       and created_at > now() - window_size
  ) then return; end if;
  insert into public.employee_activity_log (user_id, event) values (uid, p_event);
end;
$$;

-- Activité sur les fiches : seulement quand l'employé agit sur SES fiches. Informatif : ne bloque jamais une écriture.
create function public.log_employee_job_activity()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  ev text;
  j public.jobs;
begin
  begin
    if uid is null then return null; end if;
    if tg_op = 'DELETE' then
      j := old;
      if j.user_id is distinct from uid then return null; end if;
      ev := 'job_deleted';
    elsif tg_op = 'INSERT' then
      j := new;
      if j.user_id is distinct from uid then return null; end if;
      ev := case when j.status = 'submitted' then 'job_submitted' else 'job_saved' end;
    else
      j := new;
      if j.user_id is distinct from uid then return null; end if;
      if new.status is distinct from old.status and new.status = 'submitted' then
        ev := 'job_submitted';
      elsif (new.job_date, new.ot, new.depart, new.arrivee, new.fin, new.km_aller, new.km_retour, new.return_time_minutes)
            is distinct from (old.job_date, old.ot, old.depart, old.arrivee, old.fin, old.km_aller, old.km_retour, old.return_time_minutes) then
        ev := 'job_saved';
      else
        return null;
      end if;
    end if;
    insert into public.employee_activity_log (user_id, event, job_id, details)
    values (uid, ev, j.id, jsonb_build_object('job_date', j.job_date, 'depart', left(j.depart::text, 5), 'fin', left(j.fin::text, 5), 'status', j.status, 'edit', tg_op = 'UPDATE'));
  exception when others then
    null;
  end;
  return null;
end;
$$;
create trigger jobs_log_employee_activity after insert or delete or update on public.jobs
  for each row execute function public.log_employee_job_activity();

-- ── Droits et règles d'accès ────────────────────────────────────────────────
revoke all on table public.foreman_reports, public.foreman_report_reads, public.employee_activity_log from anon, public, authenticated;
alter table public.foreman_reports enable row level security;
alter table public.foreman_report_reads enable row level security;
alter table public.employee_activity_log enable row level security;
grant select, insert, delete on public.foreman_reports to authenticated;
grant update (body, audited_employee_number) on public.foreman_reports to authenticated;
grant select, insert on public.foreman_report_reads to authenticated;
grant update (read_at) on public.foreman_report_reads to authenticated;
grant select on public.employee_activity_log to authenticated;

create policy foreman_reports_read on public.foreman_reports for select to authenticated
  using (user_id = (select auth.uid()) or (select public.get_my_role()) = 'manager');
create policy foreman_reports_foreman_insert on public.foreman_reports for insert to authenticated
  with check (user_id = (select auth.uid())
              and exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'foreman' and not p.is_paused)
              and (job_id is null or exists (select 1 from public.jobs j where j.id = foreman_reports.job_id and j.user_id = (select auth.uid()))));
create policy foreman_reports_foreman_update_while_editable on public.foreman_reports for update to authenticated
  using (user_id = (select auth.uid()) and job_id is not null
         and exists (select 1 from public.jobs j where j.id = foreman_reports.job_id and j.user_id = (select auth.uid()) and j.status in ('saved', 'updated')))
  with check (user_id = (select auth.uid()));
create policy foreman_reports_manager_delete on public.foreman_reports for delete to authenticated using ((select public.get_my_role()) = 'manager');

create policy foreman_report_reads_own_select on public.foreman_report_reads for select to authenticated
  using (manager_id = (select auth.uid()) and (select public.get_my_role()) = 'manager');
create policy foreman_report_reads_own_insert on public.foreman_report_reads for insert to authenticated
  with check (manager_id = (select auth.uid()) and (select public.get_my_role()) = 'manager');
create policy foreman_report_reads_own_update on public.foreman_report_reads for update to authenticated
  using (manager_id = (select auth.uid()) and (select public.get_my_role()) = 'manager')
  with check (manager_id = (select auth.uid()) and (select public.get_my_role()) = 'manager');

create policy employee_activity_log_manager_read on public.employee_activity_log for select to authenticated using ((select public.get_my_role()) = 'manager');

revoke all on function public.foreman_reports_guard(), public.foreman_reports_guard_update(), public.foreman_report_reads_guard(),
  public.return_foreman_note_sheet(uuid, timestamptz, text), public.employee_activity_log_guard(), public.log_employee_activity(text, text),
  public.log_employee_job_activity() from public, anon, authenticated;
grant execute on function public.return_foreman_note_sheet(uuid, timestamptz, text), public.log_employee_activity(text, text) to authenticated;

-- ════════════════════════════════════════════════════════════════════
-- 0009_inventory.sql
-- ════════════════════════════════════════════════════════════════════
-- Sparklog-Employés — schéma neuf du côté 1. Migration 0009 : inventaire de fin de quart, groupes d'employés, stock minimum par groupe.
-- Relevé dans une base reconstruite à partir des 150 migrations de Sparklog V2.4.258 (0071, 0097, 0105, 0114, 0121, 0122, 0127, 0128 et voisines).
--
-- Écarts voulus par rapport à Sparklog :
--  * un groupe est un entrepôt ou une équipe (nom du groupe) ; ses membres sont des **numéros** : `inventory_negative_alerts` renvoie `employee_number` et non un nom ;
--  * `dismiss_inventory_negative_alert` écrit dans le journal d'audit sans nom (0005), clés permises seulement ;
--  * `inventory_stock_levels` et `inventory_negative_alerts` comptent les 7 derniers jours en heure de Montréal (Sparklog : date du serveur) ;
--  * chaque table a ses droits écrits en toutes lettres (`revoke all` avant `grant`) ;
--  * `validate_job_submission_contract` (0006) est remplacée : elle ajoute l'inventaire de fin de quart.
-- Les lectures de captures (OCR) sont faites par la fonction Edge `process_inventory_screenshot` avec la clé de service : elle écrit `inventory_items`.
-- Le domaine d'OCR (aujourd'hui un service externe) est à revoir (`PLAN.md`, étape 12.3) : les captures ne doivent jamais contenir de nom.

-- ── Groupes d'employés (entrepôts, équipes) ─────────────────────────────────
create table public.employee_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 60),
  note text check (note is null or char_length(note) <= 300),
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  low_stock_alert boolean not null default false
);
create unique index employee_groups_name_uniq on public.employee_groups (lower(btrim(name)));
create trigger employee_groups_updated_at before update on public.employee_groups for each row execute function public.set_updated_at();

create table public.employee_group_members (
  group_id uuid not null references public.employee_groups(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  added_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index employee_group_members_user_idx on public.employee_group_members (user_id);

-- ── Captures d'inventaire et lignes lues ────────────────────────────────────
create table public.inventory_screenshots (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  job_date date not null,
  slot smallint not null check (slot between 1 and 5),
  storage_path text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  ocr_status text not null default 'pending' check (ocr_status in ('pending', 'processed', 'needs_review', 'failed')),
  list_total integer check (list_total is null or list_total between 0 and 1000),
  defective_total integer check (defective_total is null or defective_total between 0 and 1000),
  unique (user_id, job_date, slot)
);
comment on column public.inventory_screenshots.slot is '1 à 3 : captures de la liste d''équipement ; 4 : photo « Produits défectueux ».';
create index inventory_screenshots_date_idx on public.inventory_screenshots (job_date, user_id);
create index inventory_screenshots_expires_at_idx on public.inventory_screenshots (expires_at);

create table public.inventory_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  job_date date not null,
  slot smallint not null check (slot between 1 and 5),
  code text not null check (code ~ '^EQ[0-9]{6}$'),
  name text not null,
  quantity numeric(10, 2) check (quantity between -99999 and 99999),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  section text not null default 'inventory' check (section in ('inventory', 'defective')),
  unique (user_id, job_date, slot, section, code)
);
comment on column public.inventory_items.section is 'inventory : liste d''équipement ; defective : lignes lues sous « Produits défectueux ».';
create index inventory_items_date_user_idx on public.inventory_items (job_date, user_id);
create index inventory_items_expires_at_idx on public.inventory_items (expires_at);
create index inventory_items_neg_alert_idx on public.inventory_items (user_id, job_date, section) where quantity < 0 and section = 'inventory';

create table public.inventory_alert_dismissals (
  user_id uuid not null references public.profiles(id) on delete cascade,
  job_date date not null,
  dismissed_by uuid not null,
  dismissed_at timestamptz not null default now(),
  primary key (user_id, job_date)
);

-- Minimum par employé et par appareil, pour chaque groupe.
create table public.inventory_min_ratios (
  group_id uuid not null references public.employee_groups(id) on delete cascade,
  code text not null check (code ~ '^EQ[0-9]{6}$'),
  name text not null check (char_length(btrim(name)) between 1 and 200),
  per_employee numeric(8, 3) not null check (per_employee > 0 and per_employee <= 1000),
  updated_by uuid default auth.uid() references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (group_id, code)
);

-- Journal (compteurs seulement) de la lecture d'une liste : sert à comprendre pourquoi un employé a été bloqué à l'étape Inventaire.
create table public.inventory_reading_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  job_date date not null,
  reading_state text,
  lines_read integer check (lines_read is null or lines_read between 0 and 1000),
  lines_expected integer check (lines_expected is null or lines_expected between 0 and 1000),
  lines_missing integer check (lines_missing is null or lines_missing between 0 and 1000),
  lines_unreadable integer check (lines_unreadable is null or lines_unreadable between 0 and 1000),
  step_block text check (step_block is null or step_block in ('wait', 'retake', 'override')),
  reading_known boolean not null default true,
  complement_tried boolean not null default false,
  created_at timestamptz not null default now()
);
create index inventory_reading_log_day_idx on public.inventory_reading_log (job_date desc, user_id);

create function public.inventory_min_ratios_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_by := auth.uid();
  new.updated_at := now();
  return new;
end;
$$;
create trigger inventory_min_ratios_guard before insert or update on public.inventory_min_ratios for each row execute function public.inventory_min_ratios_guard();

create function public.inventory_reading_log_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.user_id := auth.uid();
  new.created_at := now();
  return new;
end;
$$;
create trigger inventory_reading_log_guard before insert on public.inventory_reading_log for each row execute function public.inventory_reading_log_guard();

-- ── Alertes de quantité négative (dernière liste de chacun, 7 derniers jours) ──
create function public.inventory_negative_alerts()
returns table (user_id uuid, employee_number integer, job_date date, code text, item_name text, quantity numeric)
language sql stable security definer set search_path = '' as $$
  with latest as (
    select i.user_id, max(i.job_date) as job_date
      from public.inventory_items i
     where public.get_my_role() = 'manager' and i.section = 'inventory'
       and i.job_date >= (timezone('America/Toronto', now()))::date - 7
     group by i.user_id
  )
  select distinct on (l.user_id, l.job_date, i.code) l.user_id, p.employee_number, l.job_date, i.code, i.name as item_name, i.quantity
    from latest l
    join public.inventory_items i on i.user_id = l.user_id and i.job_date = l.job_date
    join public.profiles p on p.id = l.user_id
   where i.section = 'inventory' and i.quantity < 0
     and not exists (select 1 from public.inventory_alert_dismissals d where d.user_id = l.user_id and d.job_date = l.job_date)
   order by l.user_id, l.job_date, i.code, i.slot desc;
$$;

create function public.dismiss_inventory_negative_alert(p_user_id uuid, p_job_date date)
returns void language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  inserted uuid;
begin
  if actor is null or not public.session_is_aal2() or not exists (
    select 1 from public.profiles where id = actor and role in ('manager', 'owner') and not coalesce(is_paused, false)
  ) then
    raise exception 'inventory_alert_not_allowed' using errcode = '42501';
  end if;
  if p_user_id is null or p_job_date is null then
    raise exception 'inventory_alert_missing' using errcode = '22023';
  end if;
  if not exists (select 1 from public.inventory_items where user_id = p_user_id and job_date = p_job_date and section = 'inventory' and quantity < 0) then
    raise exception 'inventory_alert_none' using errcode = 'P0002';
  end if;
  insert into public.inventory_alert_dismissals (user_id, job_date, dismissed_by) values (p_user_id, p_job_date, actor)
  on conflict (user_id, job_date) do nothing returning user_id into inserted;
  if inserted is null then return; end if;
  perform public.write_audit(actor, 'inventory_negative_dismissed', p_user_id, null, jsonb_build_object('job_date', p_job_date));
end;
$$;

-- ── Stock par groupe : minimum = ratio × effectif (membres non en pause), contre la dernière liste de chacun ──
create function public.inventory_stock_levels()
returns table (group_id uuid, group_name text, code text, item_name text, per_employee numeric, headcount integer, minimum numeric,
               on_hand numeric, lists_counted integer, is_low boolean, alert_enabled boolean)
language sql stable security definer set search_path = '' as $$
  with members as (
    select m.group_id, p.id as user_id
      from public.employee_group_members m join public.profiles p on p.id = m.user_id
     where public.get_my_role() = 'manager' and not p.is_paused
  ),
  latest as (
    select i.user_id, max(i.job_date) as job_date
      from public.inventory_items i
     where i.section = 'inventory' and i.job_date >= (timezone('America/Toronto', now()))::date - 7
       and i.user_id in (select user_id from members)
     group by i.user_id
  ),
  -- Une ligne par employé et par code : une quantité lue l'emporte sur une quantité coupée au bord d'une capture, puis la dernière case.
  merged as (
    select distinct on (i.user_id, i.code) i.user_id, i.code, i.quantity
      from public.inventory_items i join latest l on l.user_id = i.user_id and l.job_date = i.job_date
     where i.section = 'inventory'
     order by i.user_id, i.code, (i.quantity is not null) desc, i.slot desc
  ),
  heads as (select m.group_id, count(*)::integer as headcount from members m group by m.group_id),
  lists as (select m.group_id, count(*)::integer as n from members m join latest l on l.user_id = m.user_id group by m.group_id),
  held as (select m.group_id, x.code, sum(coalesce(x.quantity, 0)) as on_hand from members m join merged x on x.user_id = m.user_id group by m.group_id, x.code)
  select r.group_id, g.name, r.code, r.name, r.per_employee, coalesce(h.headcount, 0), round(r.per_employee * coalesce(h.headcount, 0), 2),
         coalesce(d.on_hand, 0), coalesce(l.n, 0),
         coalesce(l.n, 0) > 0 and coalesce(d.on_hand, 0) < r.per_employee * coalesce(h.headcount, 0), g.low_stock_alert
    from public.inventory_min_ratios r
    join public.employee_groups g on g.id = r.group_id
    left join heads h on h.group_id = r.group_id
    left join lists l on l.group_id = r.group_id
    left join held d on d.group_id = r.group_id and d.code = r.code
   where public.get_my_role() = 'manager'
   order by g.name, r.name, r.code;
$$;

-- ── Contrat de soumission COMPLET avec l'inventaire (remplace celui de 0006) ──
create or replace function public.validate_job_submission_contract()
returns trigger language plpgsql set search_path = '' as $$
declare
  duration_minutes integer;
  other_minutes integer;
  day_has_evidence boolean;
  is_office_employee boolean;
  daily_regular_minutes integer := 480;
  first_trip_unpaid boolean;
  inventory_enabled boolean;
  unpaid_trip_minutes integer := 0;
  -- Le propriétaire soumet pour l'employé (create_job_for_employee / submit_manager_entry_for_employee) : la preuve ne peut venir que
  -- de l'employé, donc seul ce contrôle est sauté ; intervalle, chevauchement et kilomètres restent contrôlés. L'indicateur n'est posé
  -- que dans ces fonctions `security definer`, pour leur transaction.
  owner_submit boolean := coalesce(current_setting('sparklog.owner_submit', true), '') = 'on';
begin
  if new.status <> 'submitted' then return new; end if;
  if tg_op = 'UPDATE' and old.status not in ('saved', 'updated') then return new; end if;
  if new.started_at is null or new.ended_at is null then
    raise exception using errcode = '23514', message = 'invalid_job_interval';
  end if;
  duration_minutes := extract(epoch from (new.ended_at - new.started_at))::integer / 60;
  if duration_minutes <= 0 or duration_minutes > 960 then
    raise exception using errcode = '23514', message = 'invalid_job_interval';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(new.user_id::text, 0));
  select coalesce(p.role = 'admin', false), coalesce(p.first_trip_unpaid, false), coalesce(p.inventory_screenshots_enabled, false)
    into is_office_employee, first_trip_unpaid, inventory_enabled
    from public.profiles p where p.id = new.user_id;
  -- « 4 jours de 10 h » : le temps supplémentaire, donc sa preuve, commence après 10 h (jamais pour contremaître ni sous-traitant).
  if exists (select 1 from public.profiles p where p.id = new.user_id and p.ten_hour_days and p.role not in ('foreman', 'subcontractor_1')) then
    daily_regular_minutes := 600;
  end if;
  select
    coalesce(sum(case
      when j.started_at is not null and j.ended_at is not null then extract(epoch from (j.ended_at - j.started_at))::integer / 60
      when j.depart is not null and j.fin is not null then (extract(epoch from (j.fin - j.depart))::integer / 60 + 1440) % 1440
      else 0 end), 0)::integer,
    coalesce(bool_or(j.overtime_evidence_captured), false)
  into other_minutes, day_has_evidence
  from public.jobs j
  where j.user_id = new.user_id and j.job_date = new.job_date and j.id <> new.id
    and j.status in ('saved', 'updated', 'submitted', 'approved');

  -- Employé « premier trajet non payé » : le seuil se compte sur le temps PAYÉ. Premier trajet de la journée (Départ le plus tôt, puis id),
  -- limité à la durée de cette fiche, nul sans Arrivée, et nul quand cette première fiche fait 65 km ou plus (depuis le 2026-10-11).
  -- Jumeau de dayFirstTripUnpaidMinutes dans supabase/functions/_shared/payroll_engine.js.
  if coalesce(first_trip_unpaid, false) then
    select case
             when d.depart is null or d.arrivee is null or d.fin is null then 0
             when new.job_date >= date '2026-10-11' and d.km >= 65 then 0
             else least(((extract(epoch from (d.arrivee - d.depart))::integer / 60) + 1440) % 1440,
                        ((extract(epoch from (d.fin - d.depart))::integer / 60) + 1440) % 1440)
           end
      into unpaid_trip_minutes
      from (
        select x.id, x.depart, x.arrivee, x.fin, x.km from (
          select j.id, j.depart, j.arrivee, j.fin, greatest(coalesce(j.km_total, 0), coalesce(j.km_aller, 0) + coalesce(j.km_retour, 0)) as km
            from public.jobs j
           where j.user_id = new.user_id and j.job_date = new.job_date and j.id <> new.id and j.status in ('saved', 'updated', 'submitted', 'approved')
          union all
          select new.id, new.depart, new.arrivee, new.fin, greatest(coalesce(new.km_total, 0), coalesce(new.km_aller, 0) + coalesce(new.km_retour, 0))
        ) x
        order by coalesce(left(x.depart::text, 5), '') collate "C", x.id::text collate "C"
        limit 1
      ) d;
  end if;

  if not owner_submit and not coalesce(is_office_employee, false)
     and duration_minutes + other_minutes - coalesce(unpaid_trip_minutes, 0) > daily_regular_minutes
     and not (coalesce(new.overtime_evidence_captured, false) or day_has_evidence) then
    raise exception using errcode = '23514', message = 'overtime_evidence_required';
  end if;
  -- Inventaire de fin de quart : la journée doit porter au moins une capture d'inventaire Field Service (le personnel de bureau en est exempté,
  -- et les jours avant la date de déploiement sont tolérés). La complétude se juge par le nombre de lignes de la liste, pas par le nombre de photos.
  -- La photo « produits défectueux » (case 4) ne compte pas comme capture d'inventaire.
  if not owner_submit and not coalesce(is_office_employee, false) and coalesce(inventory_enabled, false)
     and new.job_date >= date '2026-10-08'
     and not exists (select 1 from public.inventory_screenshots s where s.user_id = new.user_id and s.job_date = new.job_date and s.slot between 1 and 3) then
    raise exception using errcode = '23514', message = 'inventory_screenshots_required';
  end if;

  if exists (
    select 1 from public.jobs j
     where j.user_id = new.user_id and j.id <> new.id and j.status in ('submitted', 'approved')
       and j.started_at is not null and j.ended_at is not null
       and tstzrange(j.started_at, j.ended_at, '[)') && tstzrange(new.started_at, new.ended_at, '[)')
  ) then
    raise exception using errcode = '23P01', message = 'overlapping_job_interval';
  end if;
  if new.return_time_minutes > duration_minutes then
    raise exception using errcode = '23514', message = 'return_time_exceeds_job_interval';
  end if;
  if new.km_total is null or new.km_aller is null or new.km_retour is null
     or new.km_total < 0 or new.km_aller < 0 or new.km_retour < 0
     or new.km_retour > new.km_total
     or abs((new.km_aller + new.km_retour) - new.km_total) > 0.001 then
    raise exception using errcode = '23514', message = 'invalid_job_kilometres';
  end if;
  return new;
end;
$$;

-- ── Stockage des captures : compartiment privé, dossier = identifiant de l'employé ──
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('inventory-screenshots', 'inventory-screenshots', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
create policy "inventory storage: owner upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'inventory-screenshots' and public.is_not_paused() and (storage.foldername(name))[1] = (auth.uid())::text);
create policy "inventory storage: owner read" on storage.objects for select to authenticated
  using (bucket_id = 'inventory-screenshots' and (storage.foldername(name))[1] = (auth.uid())::text);
create policy "inventory storage: owner delete" on storage.objects for delete to authenticated
  using (bucket_id = 'inventory-screenshots' and public.is_not_paused() and (storage.foldername(name))[1] = (auth.uid())::text);
create policy "inventory storage: manager read" on storage.objects for select to authenticated
  using (bucket_id = 'inventory-screenshots' and (select public.get_my_role()) = 'manager');

-- ── Droits et règles d'accès ────────────────────────────────────────────────
revoke all on table public.employee_groups, public.employee_group_members, public.inventory_screenshots, public.inventory_items,
  public.inventory_alert_dismissals, public.inventory_min_ratios, public.inventory_reading_log from anon, public, authenticated;
alter table public.employee_groups enable row level security;
alter table public.employee_group_members enable row level security;
alter table public.inventory_screenshots enable row level security;
alter table public.inventory_items enable row level security;
alter table public.inventory_alert_dismissals enable row level security;
alter table public.inventory_min_ratios enable row level security;
alter table public.inventory_reading_log enable row level security;
grant select, insert, update, delete on public.employee_groups, public.employee_group_members, public.inventory_min_ratios to authenticated;
grant select, insert, update on public.inventory_screenshots to authenticated;
grant select on public.inventory_items to authenticated;
grant select, insert on public.inventory_reading_log to authenticated;

create policy employee_groups_managers on public.employee_groups for all to authenticated
  using (public.get_my_role() = 'manager') with check (public.get_my_role() = 'manager');
create policy employee_group_members_managers on public.employee_group_members for all to authenticated
  using (public.get_my_role() = 'manager') with check (public.get_my_role() = 'manager');
create policy inventory_min_ratios_managers on public.inventory_min_ratios for all to authenticated
  using (public.get_my_role() = 'manager') with check (public.get_my_role() = 'manager');
create policy inventory_items_owner_read on public.inventory_items for select to authenticated using (user_id = (select auth.uid()));
create policy inventory_items_manager_read on public.inventory_items for select to authenticated using ((select public.get_my_role()) = 'manager');
create policy inventory_screenshots_owner_read on public.inventory_screenshots for select to authenticated using (user_id = (select auth.uid()));
create policy inventory_screenshots_manager_read on public.inventory_screenshots for select to authenticated using ((select public.get_my_role()) = 'manager');
create policy inventory_screenshots_owner_insert on public.inventory_screenshots for insert to authenticated
  with check (public.is_not_paused() and user_id = (select auth.uid()));
create policy inventory_screenshots_owner_update on public.inventory_screenshots for update to authenticated
  using (public.is_not_paused() and user_id = (select auth.uid())) with check (public.is_not_paused() and user_id = (select auth.uid()));
create policy inventory_reading_log_manager_read on public.inventory_reading_log for select to authenticated using (public.get_my_role() = 'manager');
create policy inventory_reading_log_own_insert on public.inventory_reading_log for insert to authenticated with check (user_id = auth.uid());

revoke all on function public.inventory_min_ratios_guard(), public.inventory_reading_log_guard(), public.inventory_negative_alerts(),
  public.dismiss_inventory_negative_alert(uuid, date), public.inventory_stock_levels() from public, anon, authenticated;
grant execute on function public.inventory_negative_alerts(), public.dismiss_inventory_negative_alert(uuid, date), public.inventory_stock_levels() to authenticated;

-- ════════════════════════════════════════════════════════════════════
-- 0010_push.sql
-- ════════════════════════════════════════════════════════════════════
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

-- ════════════════════════════════════════════════════════════════════
-- 0011_announcements.sql
-- ════════════════════════════════════════════════════════════════════
-- Sparklog-Employés — schéma neuf du côté 1. Migration 0011 : annonces aux employés, publiées par le côté 2.
-- Relevé dans une base reconstruite à partir des 150 migrations de Sparklog V2.4.258 (0002, 0010, 0096, 0107 et voisines : `manager_broadcasts`,
-- `broadcast_recipients`, `broadcast_revisions`, `edit_broadcast`, `withdraw_broadcast_unread`).
--
-- Modèle : le côté 2 (qui connaît les noms) écrit l'annonce ; le côté 1 la **diffuse** aux numéros visés et enregistre qui l'a lue. Les gestionnaires du côté 1 n'écrivent pas
-- d'annonce (décision du 2026-11-14). Toute écriture passe par une fonction réservée à la clé de service (`PLAN.md` 3.4, 9.2 et 12.1).
--
-- Écarts voulus par rapport à Sparklog :
--  * `announcements` / `announcement_recipients` / `announcement_revisions` remplacent `manager_broadcasts` / `broadcast_recipients` / `broadcast_revisions` (l'écran de l'employé est à adapter) ;
--  * pas d'expéditeur : aucune colonne `sender_id`, `edited_by` ni nom ; l'audit est écrit sans acteur (le service) et sans texte libre ;
--  * le destinataire est un **numéro d'employé** ; l'audience est `all`, `groups` (membres d'un groupe, 0009) ou `selected` (liste de numéros) ;
--  * publication **idempotente** par clé d'action : une relance ne crée ni annonce ni destinataire en double ;
--  * modification avec **version attendue** (conflit si l'annonce a changé depuis la lecture) ;
--  * un employé ne peut **que** accuser réception (une fois) : il ne peut pas se désabonner, ni modifier une autre colonne ;
--  * pièces jointes dans un compartiment privé, lisibles seulement par les destinataires non retirés **de cette annonce** (Sparklog : tout compte connecté lisait tout le compartiment).
-- Le texte d'une annonce est du texte libre : le côté 2 vérifie qu'il ne contient pas de nom (`PLAN.md` 3.5).

create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  action_key uuid not null unique,
  body text not null default '' check (char_length(body) <= 5000),
  audience text not null check (audience in ('all', 'groups', 'selected')),
  attachments jsonb not null default '[]'::jsonb check (jsonb_typeof(attachments) = 'array' and jsonb_array_length(attachments) <= 10),
  created_at timestamptz not null default now(),
  edited_at timestamptz
);
comment on column public.announcements.attachments is 'Images et PDF du message, dans l''ordre : [{path, kind: image|pdf, name}] dans le compartiment announcement-files.';

create table public.announcement_recipients (
  announcement_id uuid not null references public.announcements(id) on delete cascade,
  employee_id uuid not null references public.profiles(id) on delete cascade,
  acknowledged_at timestamptz,
  withdrawn_at timestamptz,
  primary key (announcement_id, employee_id)
);
create index announcement_recipients_unacked_idx on public.announcement_recipients (employee_id) where acknowledged_at is null;

create table public.announcement_revisions (
  id uuid primary key default gen_random_uuid(),
  announcement_id uuid not null references public.announcements(id) on delete cascade,
  body text not null,
  attachments jsonb not null default '[]'::jsonb,
  edited_at timestamptz not null default now(),
  reread boolean not null default false,
  reread_count integer not null default 0
);
create index announcement_revisions_announcement_idx on public.announcement_revisions (announcement_id, edited_at);

-- Pièces jointes valides : au plus 10, chacune {path: <identifiant>.<jpg|jpeg|png|webp|pdf>, kind: image|pdf}.
create function public.announcement_attachments_valid(p_attachments jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select jsonb_typeof(p_attachments) = 'array'
     and jsonb_array_length(p_attachments) <= 10
     and not exists (
       select 1 from jsonb_array_elements(p_attachments) a
        where jsonb_typeof(a) <> 'object'
           or coalesce(a ->> 'path', '') !~ '^[A-Za-z0-9-]+\.(jpg|jpeg|png|webp|pdf)$'
           or coalesce(a ->> 'kind', '') not in ('image', 'pdf')
     );
$$;

-- L'employé n'accuse réception qu'une fois : la date ne se remet pas à zéro ni ne se change.
create function public.announcement_recipients_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if auth.uid() is not null then
    if old.acknowledged_at is not null then
      new.acknowledged_at := old.acknowledged_at;
    elsif new.acknowledged_at is not null then
      new.acknowledged_at := now();
    end if;
  end if;
  return new;
end;
$$;
create trigger announcement_recipients_guard before update on public.announcement_recipients
  for each row execute function public.announcement_recipients_guard();

-- ── Publier (clé de service) ────────────────────────────────────────────────
-- Destinataires : `all` = tous les employés actifs (employé, contremaître, sous-traitant, bureau), `groups` = les membres non en pause des groupes donnés,
-- `selected` = les numéros donnés (les numéros inconnus ou en pause sont ignorés).
create function public.publish_announcement(
  p_action_key uuid, p_body text, p_audience text, p_group_ids uuid[] default null, p_employee_numbers integer[] default null,
  p_attachments jsonb default '[]'::jsonb)
returns table (id uuid, recipient_count integer)
language plpgsql security definer set search_path = '' as $$
declare
  clean_body text := btrim(coalesce(p_body, ''));
  attachments jsonb := coalesce(p_attachments, '[]'::jsonb);
  existing public.announcements%rowtype;
  new_id uuid;
  n integer;
begin
  if p_action_key is null then
    raise exception using errcode = '22023', message = 'action_key_required';
  end if;
  -- Relance (réponse perdue) : la même annonce, sans doublon.
  select * into existing from public.announcements a where a.action_key = p_action_key;
  if existing.id is not null then
    return query select existing.id, (select count(*)::integer from public.announcement_recipients r where r.announcement_id = existing.id);
    return;
  end if;
  if p_audience is null or p_audience not in ('all', 'groups', 'selected') then
    raise exception using errcode = '22023', message = 'announcement_audience_invalid';
  end if;
  if not public.announcement_attachments_valid(attachments) then
    raise exception using errcode = '22023', message = 'announcement_attachments_invalid';
  end if;
  if char_length(clean_body) > 5000 then
    raise exception using errcode = '22023', message = 'announcement_too_long';
  end if;
  if clean_body = '' and jsonb_array_length(attachments) = 0 then
    raise exception using errcode = '22023', message = 'announcement_empty';
  end if;

  insert into public.announcements (action_key, body, audience, attachments) values (p_action_key, clean_body, p_audience, attachments) returning announcements.id into new_id;
  if p_audience = 'all' then
    insert into public.announcement_recipients (announcement_id, employee_id)
    select new_id, p.id from public.profiles p where p.role in ('employee', 'foreman', 'subcontractor_1', 'admin') and not p.is_paused;
  elsif p_audience = 'groups' then
    insert into public.announcement_recipients (announcement_id, employee_id)
    select distinct new_id, p.id from public.employee_group_members m join public.profiles p on p.id = m.user_id
     where m.group_id = any (coalesce(p_group_ids, '{}')) and not p.is_paused and p.role in ('employee', 'foreman', 'subcontractor_1', 'admin');
  else
    insert into public.announcement_recipients (announcement_id, employee_id)
    select distinct new_id, p.id from public.profiles p
     where p.employee_number = any (coalesce(p_employee_numbers, '{}')) and not p.is_paused and p.role in ('employee', 'foreman', 'subcontractor_1', 'admin');
  end if;
  get diagnostics n = row_count;
  if n = 0 then
    raise exception using errcode = '22023', message = 'announcement_no_recipients';
  end if;
  perform public.write_audit(null, 'announcement_published', null, null, jsonb_build_object('count', n));
  return query select new_id, n;
end;
$$;

-- ── Modifier (clé de service, version attendue) ─────────────────────────────
-- `p_expected_version` = coalesce(edited_at, created_at) lu avant la modification. Si `p_reread`, ceux qui avaient accusé réception doivent relire.
create function public.edit_announcement(p_announcement_id uuid, p_expected_version timestamptz, p_body text, p_attachments jsonb, p_reread boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  old_row public.announcements%rowtype;
  new_body text := btrim(coalesce(p_body, ''));
  new_attachments jsonb := coalesce(p_attachments, '[]'::jsonb);
  reread_count integer := 0;
  pending_count integer := 0;
begin
  if not public.announcement_attachments_valid(new_attachments) then
    raise exception using errcode = '22023', message = 'announcement_attachments_invalid';
  end if;
  if char_length(new_body) > 5000 then
    raise exception using errcode = '22023', message = 'announcement_too_long';
  end if;
  if new_body = '' and jsonb_array_length(new_attachments) = 0 then
    raise exception using errcode = '22023', message = 'announcement_empty';
  end if;
  select * into old_row from public.announcements a where a.id = p_announcement_id for update;
  if old_row.id is null then
    raise exception using errcode = 'P0002', message = 'announcement_not_found';
  end if;
  if p_expected_version is null or coalesce(old_row.edited_at, old_row.created_at) is distinct from p_expected_version then
    raise exception using errcode = '40001', message = 'announcement_state_changed';
  end if;
  if coalesce(p_reread, false) then
    update public.announcement_recipients set acknowledged_at = null
     where announcement_id = p_announcement_id and acknowledged_at is not null and withdrawn_at is null;
    get diagnostics reread_count = row_count;
  end if;
  select count(*) into pending_count from public.announcement_recipients where announcement_id = p_announcement_id and acknowledged_at is null and withdrawn_at is null;
  insert into public.announcement_revisions (announcement_id, body, attachments, reread, reread_count)
  values (p_announcement_id, old_row.body, old_row.attachments, coalesce(p_reread, false), reread_count);
  update public.announcements set body = new_body, attachments = new_attachments, edited_at = clock_timestamp() where id = p_announcement_id;
  perform public.write_audit(null, 'announcement_edited', null, null,
                             jsonb_build_object('count', reread_count, 'reason_code', case when coalesce(p_reread, false) then 'reread' else 'edit' end));
  return jsonb_build_object('reread_count', reread_count, 'pending_count', pending_count);
end;
$$;

-- ── Retirer l'annonce à ceux qui ne l'ont pas encore lue (clé de service) ───
create function public.withdraw_announcement_unread(p_announcement_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare withdrawn integer;
begin
  perform 1 from public.announcements a where a.id = p_announcement_id for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'announcement_not_found';
  end if;
  update public.announcement_recipients set withdrawn_at = now()
   where announcement_id = p_announcement_id and acknowledged_at is null and withdrawn_at is null;
  get diagnostics withdrawn = row_count;
  if withdrawn > 0 then
    perform public.write_audit(null, 'announcement_withdrawn', null, null, jsonb_build_object('count', withdrawn));
  end if;
  return withdrawn;
end;
$$;

-- ── Pièces jointes : compartiment privé, lisibles par les destinataires de CETTE annonce ──
create function public.announcement_file_readable(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.announcement_recipients r join public.announcements a on a.id = r.announcement_id
     where r.employee_id = auth.uid() and r.withdrawn_at is null
       and a.attachments @> jsonb_build_array(jsonb_build_object('path', p_name))
  );
$$;
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('announcement-files', 'announcement-files', false, 10485760, array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
create policy "announcement files: recipient read" on storage.objects for select to authenticated
  using (bucket_id = 'announcement-files' and public.announcement_file_readable(name));

-- ── Droits et règles d'accès ────────────────────────────────────────────────
revoke all on table public.announcements, public.announcement_recipients, public.announcement_revisions from anon, public, authenticated;
alter table public.announcements enable row level security;
alter table public.announcement_recipients enable row level security;
alter table public.announcement_revisions enable row level security;
grant select on public.announcements, public.announcement_recipients to authenticated;
grant update (acknowledged_at) on public.announcement_recipients to authenticated;

create policy announcements_recipient_read on public.announcements for select to authenticated
  using (exists (select 1 from public.announcement_recipients r where r.announcement_id = announcements.id and r.employee_id = (select auth.uid()) and r.withdrawn_at is null));
create policy announcement_recipients_read_own on public.announcement_recipients for select to authenticated
  using (employee_id = (select auth.uid()) and withdrawn_at is null);
create policy announcement_recipients_ack_own on public.announcement_recipients for update to authenticated
  using (employee_id = (select auth.uid()) and withdrawn_at is null) with check (employee_id = (select auth.uid()) and withdrawn_at is null);

revoke all on function public.announcement_attachments_valid(jsonb), public.announcement_recipients_guard(), public.publish_announcement(uuid, text, text, uuid[], integer[], jsonb),
  public.edit_announcement(uuid, timestamptz, text, jsonb, boolean), public.withdraw_announcement_unread(uuid), public.announcement_file_readable(text) from public, anon, authenticated;
grant execute on function public.announcement_file_readable(text) to authenticated;
grant execute on function public.announcement_attachments_valid(jsonb), public.publish_announcement(uuid, text, text, uuid[], integer[], jsonb),
  public.edit_announcement(uuid, timestamptz, text, jsonb, boolean), public.withdraw_announcement_unread(uuid) to service_role;

-- ════════════════════════════════════════════════════════════════════
-- 0012_sync_api.sql
-- ════════════════════════════════════════════════════════════════════
-- Sparklog-Employés — schéma neuf du côté 1. Migration 0012 : interface d'échange avec le côté 2 (Sparklog-Gestion). `PLAN.md`, étapes 3, 4, 5 et 9.
-- Aucun équivalent dans Sparklog : c'est la porte d'entrée unique et étroite par laquelle le côté 2 (qui connaît les noms) lit les fiches, approuve, retourne et gère les comptes.
--
-- Principes (invariants I1 à I4 du plan) :
--  * **le côté 1 n'appelle jamais le côté 2** : tout part du côté 2, avec sa clé ; le côté 1 n'a ni adresse ni secret du côté 2 ;
--  * **aucun nom, courriel, téléphone ni montant de paie** ne sort ni n'entre : les personnes sont des numéros d'employé (jamais l'identifiant de compte) ;
--  * toute écriture est **idempotente** (clé d'action unique) ; une approbation ou un retour exige la **version attendue** ;
--  * le secret d'un client n'est jamais stocké en clair (bcrypt), un code d'activation non plus (jamais conservé, même dans le résultat d'une action rejouée) ;
--  * le journal des appels ne garde ni IP, ni appareil, ni nom : client, route, nombre de lignes, résultat.
-- La fonction Edge `pointage_api` (à écrire, étape 12) valide le secret avec `sync_authenticate`, puis appelle ces fonctions avec la clé de service (`service_role`).
-- Rien de tout cela n'est appelable par le navigateur.
--
-- Version du contrat : 1 (`sync_health`). Un champ n'est jamais retiré ni renommé dans la version 1.
-- Limite à connaître : un enregistrement validé en retard peut porter une date de modification antérieure au curseur du côté 2 : le côté 2 relit avec un chevauchement de 5 minutes
-- et un passage complet chaque nuit (`sync_job_ids`, étape 4.3).

-- ── Clients, journal, actions, suppressions ─────────────────────────────────
create table public.sync_clients (
  id uuid primary key default gen_random_uuid(),
  label text not null unique check (char_length(btrim(label)) between 1 and 60),
  secret_hash text not null,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  last_used_at timestamptz
);

create table public.sync_request_log (
  id bigint generated always as identity primary key,
  client_id uuid references public.sync_clients(id) on delete set null,
  route text not null check (char_length(route) <= 40),
  rows_count integer,
  status text not null check (status in ('ok', 'invalid', 'rate_limited', 'conflict', 'error')),
  created_at timestamptz not null default now()
);
create index sync_request_log_recent_idx on public.sync_request_log (route, status, created_at desc);

create table public.sync_actions (
  action_key uuid primary key,
  client_id uuid references public.sync_clients(id) on delete set null,
  type text not null,
  result jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- Suppression d'une fiche : le côté 2 doit l'apprendre.
create table public.job_tombstones (
  job_id uuid primary key,
  employee_number integer,
  job_date date,
  deleted_at timestamptz not null default now()
);
create index job_tombstones_deleted_idx on public.job_tombstones (deleted_at, job_id);
create function public.record_job_tombstone()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.job_tombstones (job_id, employee_number, job_date)
  values (old.id, (select p.employee_number from public.profiles p where p.id = old.user_id), old.job_date)
  on conflict (job_id) do nothing;
  return old;
end;
$$;
create trigger jobs_record_tombstone after delete on public.jobs for each row execute function public.record_job_tombstone();

-- Une réouverture de journée peut venir du côté 2 : elle n'a pas de profil auteur.
alter table public.job_entry_unlocks alter column created_by drop not null;

-- ── Secrets de clients ──────────────────────────────────────────────────────
-- Jeton aléatoire de n caractères (62 symboles, tirage par rejet : aucun biais).
create function public.sync_random_token(n integer)
returns text language plpgsql volatile set search_path = '' as $$
declare
  alphabet constant text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  bytes bytea;
  token text := '';
  i integer;
begin
  while length(token) < n loop
    bytes := extensions.gen_random_bytes(64);
    for i in 0..63 loop
      exit when length(token) >= n;
      if get_byte(bytes, i) < 248 then token := token || substr(alphabet, (get_byte(bytes, i) % 62) + 1, 1); end if;
    end loop;
  end loop;
  return token;
end;
$$;

-- Crée un client et renvoie son secret UNE SEULE FOIS. Rotation : en créer un second, basculer le côté 2, puis révoquer l'ancien.
create function public.sync_create_client(p_label text)
returns table (id uuid, secret text)
language plpgsql security definer set search_path = '' as $$
declare s text := 'skc_' || public.sync_random_token(40); new_id uuid;
begin
  insert into public.sync_clients (label, secret_hash) values (btrim(p_label), extensions.crypt(s, extensions.gen_salt('bf', 10))) returning sync_clients.id into new_id;
  return query select new_id, s;
end;
$$;

create function public.sync_revoke_client(p_client uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.sync_clients set revoked_at = coalesce(revoked_at, now()) where id = p_client;
  if not found then raise exception using errcode = 'P0002', message = 'sync_client_not_found'; end if;
end;
$$;

-- Vérifie un secret et renvoie l'identifiant du client, ou NULL si le secret est faux ou révoqué (l'appelant répond 401).
-- Un secret faux **ne lève pas d'erreur** : une erreur annulerait la transaction et avec elle la ligne de journal de la tentative, et le blocage ne se déclencherait jamais.
-- Limites : 20 tentatives ratées par minute pour l'ensemble (puis erreur `rate_limited`), et 120 appels par minute pour un client.
create function public.sync_authenticate(p_secret text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare c public.sync_clients%rowtype; found_id uuid;
begin
  if (select count(*) from public.sync_request_log where route = 'authenticate' and status = 'invalid' and created_at > now() - interval '1 minute') >= 20 then
    raise exception using errcode = '54000', message = 'rate_limited';
  end if;
  for c in select * from public.sync_clients where revoked_at is null loop
    if c.secret_hash = extensions.crypt(coalesce(p_secret, ''), c.secret_hash) then found_id := c.id; exit; end if;
  end loop;
  if found_id is null then
    perform extensions.crypt(coalesce(p_secret, ''), extensions.gen_salt('bf', 10));   -- temps de réponse comparable
    insert into public.sync_request_log (route, status) values ('authenticate', 'invalid');
    return null;
  end if;
  if (select count(*) from public.sync_request_log where client_id = found_id and route = 'authenticate' and status = 'ok' and created_at > now() - interval '1 minute') >= 120 then
    raise exception using errcode = '54000', message = 'rate_limited';
  end if;
  update public.sync_clients set last_used_at = now() where id = found_id;
  insert into public.sync_request_log (client_id, route, status) values (found_id, 'authenticate', 'ok');
  return found_id;
end;
$$;

create function public.sync_require_client(p_client uuid)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if p_client is null or not exists (select 1 from public.sync_clients where id = p_client and revoked_at is null) then
    raise exception using errcode = '28000', message = 'invalid_client';
  end if;
end;
$$;

create function public.sync_log(p_client uuid, p_route text, p_rows integer, p_status text default 'ok')
returns void language sql security definer set search_path = '' as $$
  insert into public.sync_request_log (client_id, route, rows_count, status) values (p_client, p_route, p_rows, p_status);
$$;

-- ── Lecture (côté 2) ────────────────────────────────────────────────────────
create function public.sync_health(p_client uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public.sync_require_client(p_client);
  perform public.sync_log(p_client, 'health', 0);
  return jsonb_build_object('contract_version', 1, 'server_time', now());
end;
$$;

-- Fiches modifiées après le curseur (updated_at, id), ordre stable, au plus 500 lignes. Les personnes sont des NUMÉROS.
create function public.sync_jobs_changed(p_client uuid, p_after_ts timestamptz default null, p_after_id uuid default null, p_limit integer default 500)
returns table (
  id uuid, employee_number integer, job_date date, ot text, depart time, arrivee time, fin time, started_at timestamptz, ended_at timestamptz,
  depart_fold smallint, fin_fold smallint, km_aller numeric, km_retour numeric, km_total numeric, return_time_minutes integer,
  status text, locked boolean, submission_key uuid, overtime_evidence_captured boolean, parking_receipt_captured boolean, meal_claim_captured boolean,
  manager_entry_at timestamptz, employee_confirmed_at timestamptz, updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare lim integer := least(greatest(coalesce(p_limit, 500), 1), 500); n integer;
begin
  perform public.sync_require_client(p_client);
  return query
    select j.id, p.employee_number, j.job_date, j.ot, j.depart, j.arrivee, j.fin, j.started_at, j.ended_at, j.depart_fold, j.fin_fold, j.km_aller, j.km_retour, j.km_total,
           j.return_time_minutes, j.status, j.locked, j.submission_key, j.overtime_evidence_captured, j.parking_receipt_captured, j.meal_claim_captured,
           j.manager_entry_at, j.employee_confirmed_at, j.updated_at
      from public.jobs j join public.profiles p on p.id = j.user_id
     where (j.updated_at, j.id) > (coalesce(p_after_ts, '-infinity'::timestamptz), coalesce(p_after_id, '00000000-0000-0000-0000-000000000000'::uuid))
     order by j.updated_at, j.id
     limit lim;
  get diagnostics n = row_count;
  perform public.sync_log(p_client, 'jobs_changed', n);
end;
$$;

create function public.sync_jobs_deleted(p_client uuid, p_after timestamptz default null, p_after_id uuid default null, p_limit integer default 500)
returns table (job_id uuid, employee_number integer, job_date date, deleted_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  perform public.sync_require_client(p_client);
  return query select t.job_id, t.employee_number, t.job_date, t.deleted_at from public.job_tombstones t
    where (t.deleted_at, t.job_id) > (coalesce(p_after, '-infinity'::timestamptz), coalesce(p_after_id, '00000000-0000-0000-0000-000000000000'::uuid))
    order by t.deleted_at, t.job_id limit least(greatest(coalesce(p_limit, 500), 1), 500);
  get diagnostics n = row_count;
  perform public.sync_log(p_client, 'jobs_deleted', n);
end;
$$;

-- Identifiants et versions d'une période (détection des trous, passage de nuit du côté 2). Au plus 92 jours.
create function public.sync_job_ids(p_client uuid, p_from date, p_to date)
returns table (id uuid, employee_number integer, updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  perform public.sync_require_client(p_client);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 92 then
    raise exception using errcode = '22023', message = 'invalid_range';
  end if;
  return query select j.id, p.employee_number, j.updated_at from public.jobs j join public.profiles p on p.id = j.user_id
    where j.job_date between p_from and p_to order by j.job_date, j.id;
  get diagnostics n = row_count;
  perform public.sync_log(p_client, 'job_ids', n);
end;
$$;

create function public.sync_employees(p_client uuid)
returns table (employee_number integer, role text, is_paused boolean, first_activated_at timestamptz, first_trip_unpaid boolean, ten_hour_days boolean,
               km_apart_from_capture boolean, return_with_benefits_to_8h boolean, overtime_first_hour_double boolean,
               inventory_screenshots_enabled boolean, parking_receipts_enabled boolean, admin_sections text[])
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  perform public.sync_require_client(p_client);
  return query select p.employee_number, p.role, p.is_paused, p.first_activated_at, p.first_trip_unpaid, p.ten_hour_days, p.km_apart_from_capture,
                      p.return_with_benefits_to_8h, p.overtime_first_hour_double, p.inventory_screenshots_enabled, p.parking_receipts_enabled, p.admin_sections
                 from public.profiles p order by p.employee_number;
  get diagnostics n = row_count;
  perform public.sync_log(p_client, 'employees', n);
end;
$$;

-- Repas et stationnement (état de la demande, montant, traitement) : jamais les photos. Curseur (changed_at, id).
create function public.sync_claims_changed(p_client uuid, p_after_ts timestamptz default null, p_after_id uuid default null, p_limit integer default 500)
returns table (kind text, id uuid, job_id uuid, employee_number integer, job_date date, amount numeric, status text, payroll_treatment text, reviewed_at timestamptz, changed_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare lim integer := least(greatest(coalesce(p_limit, 500), 1), 500); n integer;
begin
  perform public.sync_require_client(p_client);
  return query
    select u.kind, u.id, u.job_id, u.employee_number, u.job_date, u.amount, u.status, u.payroll_treatment, u.reviewed_at, u.changed_at from (
      select 'meal'::text as kind, c.id, c.job_id, p.employee_number, c.job_date, c.amount, c.status, c.payroll_treatment, c.reviewed_at, greatest(c.created_at, coalesce(c.reviewed_at, c.created_at)) as changed_at
        from public.meal_claims c join public.profiles p on p.id = c.user_id
      union all
      select 'parking'::text, r.id, r.job_id, p.employee_number, r.job_date, r.amount, r.status, null::text, r.reviewed_at, greatest(r.created_at, coalesce(r.reviewed_at, r.created_at))
        from public.parking_receipts r join public.profiles p on p.id = r.user_id
    ) u
    where (u.changed_at, u.id) > (coalesce(p_after_ts, '-infinity'::timestamptz), coalesce(p_after_id, '00000000-0000-0000-0000-000000000000'::uuid))
    order by u.changed_at, u.id limit lim;
  get diagnostics n = row_count;
  perform public.sync_log(p_client, 'claims_changed', n);
end;
$$;

-- ── Écriture (côté 2) : une seule porte, idempotente ────────────────────────
-- Types : approve_jobs, return_job, set_pause, register_account, reissue_activation_code, unlock_day, upsert_group, set_group_members.
-- Une relance avec la même clé renvoie le résultat enregistré (sans code d'activation : `code` est alors null et `replayed` vrai).
-- Une erreur annule tout (y compris l'enregistrement de la clé) : la relance réessaie. Une clé réutilisée pour un autre type est refusée.
create function public.apply_sync_action(p_client uuid, p_action_key uuid, p_type text, p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  existing public.sync_actions%rowtype;
  res jsonb := '{}'::jsonb;
  stored jsonb;
  prof public.profiles%rowtype;
  job public.jobs%rowtype;
  gid uuid;
  n integer;
  num integer;
  code text;
  items jsonb;
begin
  perform public.sync_require_client(p_client);
  if p_action_key is null or p_type is null or jsonb_typeof(coalesce(p_payload, '{}'::jsonb)) <> 'object' then
    raise exception using errcode = '22023', message = 'invalid_payload';
  end if;
  insert into public.sync_actions (action_key, client_id, type) values (p_action_key, p_client, p_type) on conflict (action_key) do nothing;
  get diagnostics n = row_count;
  if n = 0 then
    select * into existing from public.sync_actions where action_key = p_action_key;
    if existing.type <> p_type then
      raise exception using errcode = '23505', message = 'action_key_reused';
    end if;
    perform public.sync_log(p_client, 'action:' || p_type, 0, 'ok');
    return existing.result || jsonb_build_object('replayed', true);
  end if;

  if p_type = 'approve_jobs' then
    items := p_payload -> 'jobs';
    if jsonb_typeof(items) <> 'array' then raise exception using errcode = '22023', message = 'invalid_payload'; end if;
    res := jsonb_build_object('results', coalesce((select jsonb_agg(jsonb_build_object('job_id', r.job_id, 'result', r.result)) from public.approve_jobs(items) r), '[]'::jsonb));

  elsif p_type = 'return_job' then
    select * into job from public.jobs j where j.id = (p_payload ->> 'job_id')::uuid for update;
    if job.id is null then raise exception using errcode = 'P0002', message = 'job_not_found'; end if;
    if job.status <> 'submitted' or not job.locked or (p_payload ->> 'expected_updated_at') is null
       or job.updated_at is distinct from (p_payload ->> 'expected_updated_at')::timestamptz then
      raise exception using errcode = '40001', message = 'job_state_changed';
    end if;
    update public.jobs j set status = 'updated', locked = false where j.id = job.id;
    perform public.write_audit(null, 'job_returned_for_correction', job.user_id, job.id, jsonb_build_object('from', 'submitted', 'to', 'updated', 'job_date', job.job_date));
    perform public.notify_employee(job.user_id, job.id, 'job_returned', job.job_date);
    res := jsonb_build_object('job_id', job.id, 'status', 'updated');

  elsif p_type = 'set_pause' then
    if jsonb_typeof(p_payload -> 'paused') <> 'boolean' then raise exception using errcode = '22023', message = 'invalid_payload'; end if;
    update public.profiles set is_paused = (p_payload ->> 'paused')::boolean where employee_number = (p_payload ->> 'employee_number')::integer returning * into prof;
    if prof.id is null then raise exception using errcode = 'P0002', message = 'employee_not_found'; end if;
    perform public.write_audit(null, 'account_pause_changed', prof.id, null, jsonb_build_object('to', case when prof.is_paused then 'paused' else 'active' end));
    res := jsonb_build_object('employee_number', prof.employee_number, 'is_paused', prof.is_paused);

  elsif p_type = 'register_account' then
    -- Le compte d'authentification (adresse factice) est créé AVANT par la fonction Edge ; ici le profil minimal et le code d'activation.
    if (p_payload ->> 'role') is null or (p_payload ->> 'role') not in ('employee', 'foreman', 'subcontractor_1', 'admin') then
      raise exception using errcode = '22023', message = 'invalid_role';
    end if;
    begin
      insert into public.profiles (id, employee_number, role) values ((p_payload ->> 'user_id')::uuid, (p_payload ->> 'employee_number')::integer, p_payload ->> 'role') returning * into prof;
    exception when unique_violation then
      raise exception using errcode = '23505', message = 'employee_number_taken';
    end;
    code := public.issue_activation_code(prof.id);
    perform public.write_audit(null, 'account_registered', prof.id, null, '{}'::jsonb);
    stored := jsonb_build_object('employee_number', prof.employee_number, 'role', prof.role);
    insert into public.sync_actions (action_key, client_id, type, result) values (p_action_key, p_client, p_type, stored) on conflict (action_key) do update set result = excluded.result;
    perform public.sync_log(p_client, 'action:' || p_type, 1, 'ok');
    return stored || jsonb_build_object('code', code);

  elsif p_type = 'reissue_activation_code' then
    select * into prof from public.profiles where employee_number = (p_payload ->> 'employee_number')::integer;
    if prof.id is null then raise exception using errcode = 'P0002', message = 'employee_not_found'; end if;
    code := public.issue_activation_code(prof.id);
    perform public.write_audit(null, 'activation_code_reissued', prof.id, null, '{}'::jsonb);
    stored := jsonb_build_object('employee_number', prof.employee_number);
    insert into public.sync_actions (action_key, client_id, type, result) values (p_action_key, p_client, p_type, stored) on conflict (action_key) do update set result = excluded.result;
    perform public.sync_log(p_client, 'action:' || p_type, 1, 'ok');
    return stored || jsonb_build_object('code', code);

  elsif p_type = 'unlock_day' then
    if (p_payload ->> 'job_date') is null then raise exception using errcode = '22023', message = 'invalid_payload'; end if;
    insert into public.job_entry_unlocks (user_id, job_date, unlocked_until, reason, created_by)
    select p.id, (p_payload ->> 'job_date')::date, null, 'side2', null from public.profiles p
     where not p.is_paused and p.role in ('employee', 'foreman', 'subcontractor_1', 'admin')
       and ((p_payload ->> 'all')::boolean is true or p.employee_number in (select (x)::integer from jsonb_array_elements_text(coalesce(p_payload -> 'employee_numbers', '[]'::jsonb)) x))
    on conflict (user_id, job_date) do update set unlocked_until = null;
    get diagnostics n = row_count;
    perform public.write_audit(null, 'day_unlocked', null, null, jsonb_build_object('job_date', (p_payload ->> 'job_date')::date, 'count', n));
    res := jsonb_build_object('unlocked', n);

  elsif p_type = 'upsert_group' then
    if char_length(btrim(coalesce(p_payload ->> 'name', ''))) not between 1 and 60 then raise exception using errcode = '22023', message = 'invalid_payload'; end if;
    select id into gid from public.employee_groups where lower(btrim(name)) = lower(btrim(p_payload ->> 'name'));
    if gid is null then
      insert into public.employee_groups (name, note, low_stock_alert, created_by) values (btrim(p_payload ->> 'name'), nullif(p_payload ->> 'note', ''), coalesce((p_payload ->> 'low_stock_alert')::boolean, false), null) returning id into gid;
    else
      update public.employee_groups set note = coalesce(nullif(p_payload ->> 'note', ''), note), low_stock_alert = coalesce((p_payload ->> 'low_stock_alert')::boolean, low_stock_alert) where id = gid;
    end if;
    res := jsonb_build_object('group_id', gid);

  elsif p_type = 'set_group_members' then
    gid := (p_payload ->> 'group_id')::uuid;
    if not exists (select 1 from public.employee_groups where id = gid) then raise exception using errcode = 'P0002', message = 'group_not_found'; end if;
    insert into public.employee_group_members (group_id, user_id)
    select gid, p.id from public.profiles p where p.employee_number in (select (x)::integer from jsonb_array_elements_text(coalesce(p_payload -> 'add', '[]'::jsonb)) x)
    on conflict do nothing;
    delete from public.employee_group_members m using public.profiles p
     where m.group_id = gid and m.user_id = p.id and p.employee_number in (select (x)::integer from jsonb_array_elements_text(coalesce(p_payload -> 'remove', '[]'::jsonb)) x);
    res := jsonb_build_object('group_id', gid, 'members', (select count(*) from public.employee_group_members where group_id = gid));

  else
    raise exception using errcode = '22023', message = 'unknown_action_type';
  end if;

  update public.sync_actions a set result = res where a.action_key = p_action_key;
  perform public.sync_log(p_client, 'action:' || p_type, 1, 'ok');
  return res;
end;
$$;

-- ── Droits ──────────────────────────────────────────────────────────────────
revoke all on table public.sync_clients, public.sync_request_log, public.sync_actions, public.job_tombstones from anon, public, authenticated;
alter table public.sync_clients enable row level security;
alter table public.sync_request_log enable row level security;
alter table public.sync_actions enable row level security;
alter table public.job_tombstones enable row level security;   -- aucune politique : réservé aux fonctions ci-dessous

revoke all on function public.record_job_tombstone(), public.sync_random_token(integer), public.sync_create_client(text), public.sync_revoke_client(uuid),
  public.sync_authenticate(text), public.sync_require_client(uuid), public.sync_log(uuid, text, integer, text), public.sync_health(uuid),
  public.sync_jobs_changed(uuid, timestamptz, uuid, integer), public.sync_jobs_deleted(uuid, timestamptz, uuid, integer), public.sync_job_ids(uuid, date, date),
  public.sync_employees(uuid), public.sync_claims_changed(uuid, timestamptz, uuid, integer), public.apply_sync_action(uuid, uuid, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.sync_create_client(text), public.sync_revoke_client(uuid), public.sync_authenticate(text), public.sync_health(uuid),
  public.sync_jobs_changed(uuid, timestamptz, uuid, integer), public.sync_jobs_deleted(uuid, timestamptz, uuid, integer), public.sync_job_ids(uuid, date, date),
  public.sync_employees(uuid), public.sync_claims_changed(uuid, timestamptz, uuid, integer), public.apply_sync_action(uuid, uuid, text, jsonb) to service_role;

-- ════════════════════════════════════════════════════════════════════
-- 0013_manager_tools.sql
-- ════════════════════════════════════════════════════════════════════
-- Sparklog-Employés — migration 0013 : six fonctions de pointage que l'application appelle encore (docs/ecarts-app-schema.md, groupe C).
--  * job_entry_sources    : comment une fiche a été remplie (capture lue / à la main) ; étoile rouge côté gestionnaire. Informatif, pas un contrôle de sécurité.
--  * manager_job_counts   : quatre compteurs en un seul agrégat (règle « Database load regression »).
--  * ot_reuse_for_jobs    : « OT déjà utilisé » avant approbation. Renvoie le NUMÉRO de l'autre employé, jamais un nom.
--  * evidence_download_alert : preuves gardées et pas encore téléchargées, bientôt supprimées (compteurs seulement).
--  * file_read_errors + log_file_read_error : pourquoi une photo n'a pas pu être lue (diagnostic). Table à part : le journal d'audit n'accepte que des clés fixes
--    (0005) ; ni nom, ni appareil, ni navigateur (clé `browser` de Sparklog abandonnée). 20 entrées par heure et par compte.
--  * delete_manager_entry / remind_manager_entry : feuille d'urgence du propriétaire (supprimer un brouillon non validé ; rappeler l'employé, 1 par heure).
--    Le rappel passe par `employee_notices` (nouveau genre `manager_entry_reminder`), plus par une annonce.
-- « État du service » (get_infra_stats) : abandonné (décision du 2026-11-14).

-- ── Source de saisie ────────────────────────────────────────────────────────
create table public.job_entry_sources (
  job_id uuid primary key references public.jobs(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  source text not null check (source in ('screenshot', 'manual')),
  created_at timestamptz not null default now()
);
revoke all on table public.job_entry_sources from anon, public, authenticated;
alter table public.job_entry_sources enable row level security;
grant select, insert on public.job_entry_sources to authenticated;
-- Qui peut lire la fiche (son employé, les gestionnaires) lit sa source ; la sous-requête applique la RLS de `jobs`.
create policy job_entry_sources_read on public.job_entry_sources for select to authenticated
  using (exists (select 1 from public.jobs j where j.id = job_entry_sources.job_id));
-- L'employé l'inscrit une fois, pour sa propre fiche. Ni modification ni suppression.
create policy job_entry_sources_insert_own on public.job_entry_sources for insert to authenticated
  with check (user_id = (select auth.uid())
              and exists (select 1 from public.jobs j where j.id = job_entry_sources.job_id and j.user_id = (select auth.uid())));

-- ── Compteurs ───────────────────────────────────────────────────────────────
create function public.manager_job_counts(p_employee_id uuid default null, p_job_date date default null)
returns table (all_count bigint, saved_count bigint, submitted_count bigint, approved_count bigint)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or public.get_my_role() is distinct from 'manager' then
    raise exception using errcode = '42501', message = 'manager_role_required';
  end if;
  return query
    select count(*),
           count(*) filter (where j.status in ('saved', 'updated')),
           count(*) filter (where j.status = 'submitted'),
           count(*) filter (where j.status = 'approved')
      from public.jobs j
     where (p_employee_id is null or j.user_id = p_employee_id)
       and (p_job_date is null or j.job_date = p_job_date);
end;
$$;

-- ── OT déjà utilisé ─────────────────────────────────────────────────────────
-- Pour chaque fiche donnée qui porte un vrai numéro d'OT (4 chiffres ou plus), toutes les AUTRES fiches du même numéro (tout employé, toute date).
-- Gestionnaire seulement (aal2) ; les autres n'obtiennent aucune ligne. 1000 identifiants au plus par appel.
create function public.ot_reuse_for_jobs(p_job_ids uuid[])
returns table (job_id uuid, other_job_id uuid, other_user_id uuid, other_employee_number integer, other_date date, other_depart time, other_fin time, other_status text)
language sql stable security definer set search_path = '' as $$
  select j.id, o.id, o.user_id, p.employee_number, o.job_date, o.depart, o.fin, o.status
    from public.jobs j
    join public.jobs o on public.normalized_ot(o.ot) = public.normalized_ot(j.ot) and o.id <> j.id
    left join public.profiles p on p.id = o.user_id
   where public.get_my_role() = 'manager'
     and j.id = any ((coalesce(p_job_ids, '{}'::uuid[]))[1:1000])
     and public.normalized_ot(j.ot) is not null
   order by j.id, o.job_date, o.depart;
$$;

-- ── Preuves à télécharger ───────────────────────────────────────────────────
create function public.evidence_download_alert(p_days integer default 21)
returns table (total integer, overtime integer, parking integer, oldest_days integer, days_left integer)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
begin
  if public.get_my_role() is distinct from 'manager' then
    return query select 0, 0, 0, 0, null::integer;
    return;
  end if;
  return query
  with files as (
    select 'overtime-evidence'::text as bucket, e.storage_path as path, e.created_at, e.expires_at
      from public.overtime_evidence e where e.expires_at > now() and e.storage_path is not null
    union all
    select 'parking-receipts', p.path, r.created_at, r.expires_at
      from public.parking_receipts r cross join lateral unnest(array[r.storage_path] || r.extra_storage_paths) as p(path)
     where r.storage_path is not null and r.expires_at > now()
  ), pending as (
    select f.* from files f
     where (f.created_at <= now() - make_interval(days => greatest(1, p_days)) or f.expires_at <= now() + interval '3 days')
       and not exists (select 1 from public.evidence_downloads d where d.bucket = f.bucket and d.storage_path = f.path)
  )
  select count(*)::integer,
         (count(*) filter (where bucket = 'overtime-evidence'))::integer,
         (count(*) filter (where bucket = 'parking-receipts'))::integer,
         coalesce(max(extract(day from now() - created_at))::integer, 0),
         min(greatest(0, ceil(extract(epoch from expires_at - now()) / 86400)))::integer
    from pending;
end;
$$;

-- ── Lecture de photo impossible : diagnostic sans nom ni appareil ───────────
create table public.file_read_errors (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  context text not null check (context in ('overtime', 'inventory', 'parking')),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index file_read_errors_user_idx on public.file_read_errors (user_id, created_at desc);
revoke all on table public.file_read_errors from anon, public, authenticated;
alter table public.file_read_errors enable row level security;
grant select on public.file_read_errors to authenticated;
create policy file_read_errors_manager_read on public.file_read_errors for select to authenticated using (public.get_my_role() = 'manager');

create function public.log_file_read_error(p_context text, p_details jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_details jsonb := '{}'::jsonb;
  v_key text;
  v_value jsonb;
begin
  if v_uid is null then raise exception using errcode = '42501', message = 'not_authenticated'; end if;
  if p_context is null or p_context not in ('overtime', 'inventory', 'parking') then
    raise exception using errcode = '22023', message = 'invalid_context';
  end if;
  if (select count(*) from public.file_read_errors e where e.user_id = v_uid and e.created_at > now() - interval '1 hour') >= 20 then
    return; -- assez pour diagnostiquer ; ne jamais bloquer l'employé
  end if;
  for v_key, v_value in select key, value from jsonb_each(coalesce(p_details, '{}'::jsonb)) loop
    if v_key in ('size', 'age_s', 'attempts') and jsonb_typeof(v_value) = 'number' then
      v_details := v_details || jsonb_build_object(v_key, v_value);
    elsif v_key in ('type', 'step', 'error', 'reason') and jsonb_typeof(v_value) = 'string' then
      v_details := v_details || jsonb_build_object(v_key, left(v_value #>> '{}', 80));
    end if; -- toute autre clé (dont `browser` et `app`) est ignorée : aucun appareil ni navigateur conservé
  end loop;
  insert into public.file_read_errors (user_id, context, details) values (v_uid, p_context, v_details);
end;
$$;

-- ── Feuille d'urgence : supprimer un brouillon, rappeler l'employé ──────────
alter table public.employee_notices drop constraint employee_notices_kind_check;
alter table public.employee_notices add constraint employee_notices_kind_check
  check (kind in ('job_created_by_manager', 'job_submitted_by_owner', 'job_returned', 'manager_entry_reminder'));

create function public.delete_manager_entry(p_job_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid := auth.uid();
  cur public.jobs%rowtype;
begin
  if actor_id is null or not public.is_privileged() then
    raise exception using errcode = '42501', message = 'owner_role_required';
  end if;
  select * into cur from public.jobs j where j.id = p_job_id for update;
  if cur.id is null or cur.manager_entry_at is null then
    raise exception using errcode = 'P0002', message = 'job_not_found';
  end if;
  if cur.employee_confirmed_at is not null or cur.locked or cur.status not in ('saved', 'updated') then
    raise exception using errcode = '40001', message = 'job_state_changed';
  end if;
  delete from public.jobs j where j.id = cur.id;
  -- Referme la réouverture créée pour ce brouillon, sauf si un autre brouillon du même jour en a encore besoin. Les autres réouvertures restent.
  delete from public.job_entry_unlocks u
   where u.user_id = cur.user_id and u.job_date = cur.job_date and u.reason = 'manager_entry'
     and not exists (select 1 from public.jobs o where o.user_id = cur.user_id and o.job_date = cur.job_date
                        and o.manager_entry_at is not null and o.employee_confirmed_at is null);
  perform public.write_audit(actor_id, 'manager_entry_deleted', cur.user_id, null, jsonb_build_object('job_date', cur.job_date));
end;
$$;

create function public.remind_manager_entry(p_job_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid := auth.uid();
  cur public.jobs%rowtype;
begin
  if actor_id is null or not public.is_privileged() then
    raise exception using errcode = '42501', message = 'owner_role_required';
  end if;
  select * into cur from public.jobs j where j.id = p_job_id for update;
  if cur.id is null or cur.manager_entry_at is null then
    raise exception using errcode = 'P0002', message = 'job_not_found';
  end if;
  if cur.employee_confirmed_at is not null or cur.locked or cur.status not in ('saved', 'updated') then
    raise exception using errcode = '40001', message = 'job_state_changed';
  end if;
  if cur.manager_entry_reminded_at is not null and cur.manager_entry_reminded_at > now() - interval '1 hour' then
    raise exception using errcode = '55000', message = 'reminder_too_soon';
  end if;
  update public.jobs j set manager_entry_reminded_at = now() where j.id = cur.id;
  perform public.notify_employee(cur.user_id, cur.id, 'manager_entry_reminder', cur.job_date);
  perform public.write_audit(actor_id, 'manager_entry_reminded', cur.user_id, cur.id, jsonb_build_object('job_date', cur.job_date));
end;
$$;

-- ── Droits ──────────────────────────────────────────────────────────────────
revoke all on function public.manager_job_counts(uuid, date), public.ot_reuse_for_jobs(uuid[]), public.evidence_download_alert(integer),
  public.log_file_read_error(text, jsonb), public.delete_manager_entry(uuid), public.remind_manager_entry(uuid) from public, anon, authenticated;
grant execute on function public.manager_job_counts(uuid, date), public.ot_reuse_for_jobs(uuid[]), public.evidence_download_alert(integer),
  public.log_file_read_error(text, jsonb), public.delete_manager_entry(uuid), public.remind_manager_entry(uuid) to authenticated;

-- ════════════════════════════════════════════════════════════════════
-- 0014_orphan_cleanup.sql
-- ════════════════════════════════════════════════════════════════════
-- Sparklog-Employés — migration 0014 : photos orphelines (téléversées, mais dont la ligne n'a jamais été enregistrée).
-- Sert à `cleanup_overtime_evidence` (destruction automatique des preuves en photo : exigence de PLAN.md / OFFICIEL.md).
--  * Un objet de stockage est orphelin s'il n'est référencé par aucune ligne de son compartiment, depuis plus longtemps que le délai de grâce
--    (au moins 1 heure : un téléversement en cours n'est jamais ramassé).
--  * Stationnement : la première photo (`storage_path`) ET les photos suivantes (`extra_storage_paths`) comptent comme référencées.
--  * Les compartiments `announcement-files` (gérés par le côté 2) et tout autre compartiment ne sont jamais touchés.
--  * Réservée à la clé de service ; l'ordonnanceur du serveur appelle la fonction Edge avec cette clé (pas de pg_cron ni de Vault dans la base).
create function public.find_orphaned_evidence_objects(p_older_than interval default interval '2 hours', p_limit integer default 500)
returns table (bucket_id text, object_name text)
language sql stable security definer set search_path = '' as $$
  select o.bucket_id, o.name
    from storage.objects o
   where o.bucket_id in ('overtime-evidence', 'parking-receipts', 'meal-receipts', 'inventory-screenshots')
     and o.created_at < now() - greatest(p_older_than, interval '1 hour')
     and (
       (o.bucket_id = 'overtime-evidence' and not exists (select 1 from public.overtime_evidence e where e.storage_path = o.name))
       or (o.bucket_id = 'parking-receipts' and not exists (
             select 1 from public.parking_receipts p where p.storage_path = o.name or o.name = any (p.extra_storage_paths)))
       or (o.bucket_id = 'meal-receipts' and not exists (select 1 from public.meal_claims m where m.storage_path = o.name))
       or (o.bucket_id = 'inventory-screenshots' and not exists (select 1 from public.inventory_screenshots i where i.storage_path = o.name))
     )
   order by o.created_at
   limit least(greatest(p_limit, 1), 1000);
$$;

revoke all on function public.find_orphaned_evidence_objects(interval, integer) from public, anon, authenticated;
grant execute on function public.find_orphaned_evidence_objects(interval, integer) to service_role;
