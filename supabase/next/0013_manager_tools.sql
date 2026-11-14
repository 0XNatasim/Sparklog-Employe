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
