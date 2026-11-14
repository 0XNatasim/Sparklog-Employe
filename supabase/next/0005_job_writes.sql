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
