-- Sparklog-Employés (côté 1) — migration 0017 : trois actions de plus pour la gestion (V0.28.0).
--  * `delete_group` : retire un groupe (membres et minimums du stock avec lui) ; un groupe déjà absent n'est pas une erreur (rejeu sûr).
--  * `set_holiday` : ajoute / renomme un jour férié ou un congé de la construction, ou le retire (`delete: true`). La liste existe des deux côtés : la gestion est la source.
--  * `set_time_options` : les quatre options qui changent le temps (`first_trip_unpaid`, `ten_hour_days`, `return_with_benefits_to_8h`, `overtime_first_hour_double`), valeur de vérité au côté 2 ;
--    seules les clés données changent, une clé inconnue ou non booléenne est refusée. Aucun montant ni taux ne passe ici.
-- Le reste de la fonction est celui de la migration 0016. Audit sans nom (clés permises par `audit_log_guard`) : le nombre d'options changées, jamais leur valeur ; la date d'un férié ; rien pour un groupe.
create or replace function public.apply_sync_action(p_client uuid, p_action_key uuid, p_type text, p_payload jsonb)
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
  ann record;
  hd date;
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
    if nullif(p_payload ->> 'id', '') is not null then
      -- Identifiant choisi par le côté 2 (même uuid des deux côtés) : création, ou mise à jour avec RENOMMAGE possible. Un nom déjà pris par un AUTRE groupe est refusé.
      gid := (p_payload ->> 'id')::uuid;
      if exists (select 1 from public.employee_groups g where lower(btrim(g.name)) = lower(btrim(p_payload ->> 'name')) and g.id <> gid) then
        raise exception using errcode = '23505', message = 'group_name_taken';
      end if;
      insert into public.employee_groups (id, name, note, low_stock_alert, created_by) values (gid, btrim(p_payload ->> 'name'), nullif(p_payload ->> 'note', ''), coalesce((p_payload ->> 'low_stock_alert')::boolean, false), null)
      on conflict (id) do update set name = excluded.name, note = excluded.note, low_stock_alert = excluded.low_stock_alert;
    else
      select id into gid from public.employee_groups where lower(btrim(name)) = lower(btrim(p_payload ->> 'name'));
      if gid is null then
        insert into public.employee_groups (name, note, low_stock_alert, created_by) values (btrim(p_payload ->> 'name'), nullif(p_payload ->> 'note', ''), coalesce((p_payload ->> 'low_stock_alert')::boolean, false), null) returning id into gid;
      else
        update public.employee_groups set note = coalesce(nullif(p_payload ->> 'note', ''), note), low_stock_alert = coalesce((p_payload ->> 'low_stock_alert')::boolean, low_stock_alert) where id = gid;
      end if;
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

  elsif p_type = 'set_role' then
    -- Rôles de terrain seulement (jamais manager ni owner : un accès de gestion au côté 1 se donne à la main, jamais par l'API).
    if (p_payload ->> 'role') is null or (p_payload ->> 'role') not in ('employee', 'foreman', 'subcontractor_1', 'admin') then
      raise exception using errcode = '22023', message = 'invalid_role';
    end if;
    if jsonb_typeof(p_payload -> 'admin_sections') is not null and jsonb_typeof(p_payload -> 'admin_sections') <> 'array' then
      raise exception using errcode = '22023', message = 'invalid_payload';
    end if;
    select * into prof from public.profiles where employee_number = (p_payload ->> 'employee_number')::integer for update;
    if prof.id is null then raise exception using errcode = 'P0002', message = 'employee_not_found'; end if;
    if prof.role in ('manager', 'owner') then raise exception using errcode = '55000', message = 'role_not_changeable'; end if;
    items := coalesce(p_payload -> 'admin_sections', '[]'::jsonb);
    if exists (select 1 from jsonb_array_elements_text(items) s where s not in ('live', 'timesheet', 'notifications', 'employees', 'forms')) then
      raise exception using errcode = '22023', message = 'invalid_admin_section';
    end if;
    update public.profiles set role = p_payload ->> 'role',
           admin_sections = case when p_payload ->> 'role' = 'admin' then array(select jsonb_array_elements_text(items)) else '{}' end
     where id = prof.id returning * into prof;
    perform public.write_audit(null, 'account_role_changed', prof.id, null, jsonb_build_object('to', prof.role));
    res := jsonb_build_object('employee_number', prof.employee_number, 'role', prof.role);

  elsif p_type = 'publish_announcement' then
    select * into ann from public.publish_announcement(p_action_key, p_payload ->> 'body', p_payload ->> 'audience',
        case when jsonb_typeof(p_payload -> 'group_ids') = 'array' then array(select jsonb_array_elements_text(p_payload -> 'group_ids')::uuid) end,
        case when jsonb_typeof(p_payload -> 'employee_numbers') = 'array' then array(select jsonb_array_elements_text(p_payload -> 'employee_numbers')::integer) end,
        coalesce(p_payload -> 'attachments', '[]'::jsonb));
    res := jsonb_build_object('announcement_id', ann.id, 'recipient_count', ann.recipient_count);

  elsif p_type = 'edit_announcement' then
    res := public.edit_announcement((p_payload ->> 'announcement_id')::uuid, (p_payload ->> 'expected_version')::timestamptz, p_payload ->> 'body',
                                    coalesce(p_payload -> 'attachments', '[]'::jsonb), coalesce((p_payload ->> 'reread')::boolean, false));

  elsif p_type = 'withdraw_announcement' then
    res := jsonb_build_object('withdrawn', public.withdraw_announcement_unread((p_payload ->> 'announcement_id')::uuid));

  elsif p_type = 'delete_group' then
    -- Suppression d'un groupe (membres et minimums du stock partent avec lui : `on delete cascade`). Idempotent : un groupe déjà absent n'est pas une erreur.
    gid := nullif(p_payload ->> 'id', '')::uuid;
    if gid is null then raise exception using errcode = '22023', message = 'invalid_payload'; end if;
    delete from public.employee_groups where id = gid;
    res := jsonb_build_object('group_id', gid, 'deleted', found);
    if found then perform public.write_audit(null, 'group_deleted', null, null, '{}'::jsonb); end if;

  elsif p_type = 'set_holiday' then
    -- Jour férié ou congé de la construction : ajout / changement du libellé, ou retrait avec `delete: true`.
    hd := nullif(p_payload ->> 'holiday_date', '')::date;
    if hd is null or hd < date '2020-01-01' or hd > date '2100-12-31' then raise exception using errcode = '22023', message = 'invalid_payload'; end if;
    if coalesce((p_payload ->> 'delete')::boolean, false) then
      delete from public.company_holidays where holiday_date = hd;
      res := jsonb_build_object('holiday_date', hd, 'deleted', found);
    else
      if char_length(btrim(coalesce(p_payload ->> 'label', ''))) not between 1 and 80 then raise exception using errcode = '22023', message = 'invalid_payload'; end if;
      insert into public.company_holidays (holiday_date, label) values (hd, btrim(p_payload ->> 'label')) on conflict (holiday_date) do update set label = excluded.label;
      res := jsonb_build_object('holiday_date', hd, 'deleted', false);
    end if;
    perform public.write_audit(null, 'holiday_changed', null, null, jsonb_build_object('job_date', hd, 'reason_code', case when (res ->> 'deleted')::boolean then 'deleted' else 'set' end));

  elsif p_type = 'set_time_options' then
    -- Les quatre options qui changent le TEMPS (seuil de la preuve de temps supp., souper, premier trajet) : valeur de vérité au côté 2. Seules les clés données changent.
    if exists (select 1 from jsonb_object_keys(p_payload - 'employee_number') k where k not in ('first_trip_unpaid', 'ten_hour_days', 'return_with_benefits_to_8h', 'overtime_first_hour_double'))
       or exists (select 1 from jsonb_each(p_payload - 'employee_number') e where jsonb_typeof(e.value) <> 'boolean')
       or (p_payload - 'employee_number') = '{}'::jsonb then
      raise exception using errcode = '22023', message = 'invalid_payload';
    end if;
    update public.profiles set
      first_trip_unpaid = coalesce((p_payload ->> 'first_trip_unpaid')::boolean, first_trip_unpaid),
      ten_hour_days = coalesce((p_payload ->> 'ten_hour_days')::boolean, ten_hour_days),
      return_with_benefits_to_8h = coalesce((p_payload ->> 'return_with_benefits_to_8h')::boolean, return_with_benefits_to_8h),
      overtime_first_hour_double = coalesce((p_payload ->> 'overtime_first_hour_double')::boolean, overtime_first_hour_double)
     where employee_number = (p_payload ->> 'employee_number')::integer returning * into prof;
    if prof.id is null then raise exception using errcode = 'P0002', message = 'employee_not_found'; end if;
    perform public.write_audit(null, 'time_options_changed', prof.id, null, jsonb_build_object('count', (select count(*) from jsonb_object_keys(p_payload - 'employee_number'))));
    res := jsonb_build_object('employee_number', prof.employee_number, 'first_trip_unpaid', prof.first_trip_unpaid, 'ten_hour_days', prof.ten_hour_days,
                              'return_with_benefits_to_8h', prof.return_with_benefits_to_8h, 'overtime_first_hour_double', prof.overtime_first_hour_double);

  else
    raise exception using errcode = '22023', message = 'unknown_action_type';
  end if;

  update public.sync_actions a set result = res where a.action_key = p_action_key;
  perform public.sync_log(p_client, 'action:' || p_type, 1, 'ok');
  return res;
end;
$$;
