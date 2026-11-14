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
