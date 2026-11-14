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
