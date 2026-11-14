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
