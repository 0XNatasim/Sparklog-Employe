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
