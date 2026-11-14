-- Test de la migration 0015 : actions et export manquants pour le côté 2 (voir scripts/test-next-schema.sh).
\set ON_ERROR_STOP on
create function pg_temp.as_user(p_id uuid, p_aal text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_id, 'aal', p_aal)::text, false); end $$;
create function pg_temp.no_user() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '', false); end $$;
create function pg_temp.u(tag text) returns uuid language sql stable as $$ select current_setting('test.' || tag)::uuid $$;
create function pg_temp.k(n integer) returns uuid language sql immutable as $$ select ('88888888-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.d0() returns date language sql stable as $$ select (timezone('America/Toronto', now()))::date $$;

select pg_temp.no_user();
select set_config('test.mgr', id::text, false) from public.profiles where employee_number = 3002;
select set_config('test.emp', id::text, false) from public.profiles where employee_number = 3005;
do $$
declare spec record; uid uuid;
begin
  for spec in select * from (values (4701, 'employee', 'a1'), (4702, 'foreman', 'a2'), (4703, 'employee', 'a3')) as t(num, role, tag) loop
    uid := gen_random_uuid();
    insert into auth.users (id, email) values (uid, spec.num || '@pointage.invalid');
    insert into public.profiles (id, employee_number, role) values (uid, spec.num, spec.role);
    perform set_config('test.' || spec.tag, uid::text, false);
  end loop;
  insert into public.jobs (id, user_id, job_date, ot, depart, fin, km_aller, km_total, status) values
    (pg_temp.k(900), pg_temp.u('a1'), pg_temp.d0() - 3, 'OT 77', '07:00', '15:00', 12, 12, 'approved'),
    (pg_temp.k(901), pg_temp.u('a2'), pg_temp.d0() - 3, 'OT 78', '08:00', '12:00', 0, 0, 'saved'),
    (pg_temp.k(902), pg_temp.u('a1'), pg_temp.d0() - 40, 'OT 79', '08:00', '12:00', 0, 0, 'approved');
end $$;
-- un client d'échange de test
set role service_role;
select set_config('test.client', (select id::text from public.sync_create_client('test 0015')), false);
reset role;

-- ── A. set_role ─────────────────────────────────────────────────────────────
set role service_role;
do $$
declare c uuid := pg_temp.u('client'); r jsonb;
begin
  r := public.apply_sync_action(c, pg_temp.k(1), 'set_role', '{"employee_number": 4701, "role": "foreman"}');
  assert r = '{"employee_number": 4701, "role": "foreman"}', 'rôle changé : ' || r::text;
  r := public.apply_sync_action(c, pg_temp.k(1), 'set_role', '{"employee_number": 4701, "role": "foreman"}');
  assert (r ->> 'replayed')::boolean, 'rejeu : même résultat';
  r := public.apply_sync_action(c, pg_temp.k(2), 'set_role', '{"employee_number": 4701, "role": "admin", "admin_sections": ["live", "timesheet"]}');
  assert r ->> 'role' = 'admin', 'admin avec sections';
  r := public.apply_sync_action(c, pg_temp.k(3), 'set_role', '{"employee_number": 4701, "role": "employee", "admin_sections": ["live"]}');
  assert r ->> 'role' = 'employee', 'retour employé';
  begin perform public.apply_sync_action(c, pg_temp.k(4), 'set_role', '{"employee_number": 4701, "role": "manager"}'); assert false, 'rôle manager par l''API';
  exception when sqlstate '22023' then if sqlerrm <> 'invalid_role' then raise; end if; end;
  begin perform public.apply_sync_action(c, pg_temp.k(5), 'set_role', '{"employee_number": 4701, "role": "owner"}'); assert false, 'rôle owner par l''API';
  exception when sqlstate '22023' then null; end;
  begin perform public.apply_sync_action(c, pg_temp.k(6), 'set_role', '{"employee_number": 3002, "role": "employee"}'); assert false, 'rétrograder un gestionnaire';
  exception when sqlstate '55000' then if sqlerrm <> 'role_not_changeable' then raise; end if; end;
  begin perform public.apply_sync_action(c, pg_temp.k(7), 'set_role', '{"employee_number": 4701, "role": "admin", "admin_sections": ["tout"]}'); assert false, 'section libre';
  exception when sqlstate '22023' then if sqlerrm <> 'invalid_admin_section' then raise; end if; end;
  begin perform public.apply_sync_action(c, pg_temp.k(8), 'set_role', '{"employee_number": 99999, "role": "employee"}'); assert false, 'numéro inconnu';
  exception when sqlstate 'P0002' then null; end;
  begin perform public.apply_sync_action(c, pg_temp.k(9), 'set_role', '{"employee_number": 4701, "role": "admin", "admin_sections": "live"}'); assert false, 'sections non tableau';
  exception when sqlstate '22023' then null; end;
end $$;
reset role;
do $$
begin
  assert (select role || array_to_string(admin_sections, ',') from public.profiles where employee_number = 4701) = 'employee', 'état final : employé sans section';
  assert (select count(*) from public.audit_log where action = 'account_role_changed' and target_number = 4701) = 3, 'audit par numéro : 3 changements';
  -- une erreur annule aussi l'enregistrement de la clé : on peut réessayer
  assert not exists (select 1 from public.sync_actions where action_key = pg_temp.k(4)), 'clé non conservée après une erreur';
end $$;

-- ── B. Annonces ─────────────────────────────────────────────────────────────
set role service_role;
do $$
declare c uuid := pg_temp.u('client'); r jsonb; r2 jsonb; ann uuid; v timestamptz;
begin
  r := public.apply_sync_action(c, pg_temp.k(20), 'publish_announcement', '{"body": "  Réunion de sécurité lundi ", "audience": "selected", "employee_numbers": [4701, 4702, 99999]}');
  assert (r ->> 'recipient_count')::integer = 2 and r ->> 'announcement_id' is not null, 'publiée pour 2 destinataires : ' || r::text;
  ann := (r ->> 'announcement_id')::uuid;
  r2 := public.apply_sync_action(c, pg_temp.k(20), 'publish_announcement', '{"body": "autre texte", "audience": "all"}');
  assert (r2 ->> 'replayed')::boolean and r2 ->> 'announcement_id' = r ->> 'announcement_id', 'rejeu : même annonce';
  begin perform public.apply_sync_action(c, pg_temp.k(21), 'publish_announcement', '{"body": "x", "audience": "tous"}'); assert false, 'audience libre';
  exception when sqlstate '22023' then null; end;
  begin perform public.apply_sync_action(c, pg_temp.k(22), 'publish_announcement', '{"body": "   ", "audience": "all"}'); assert false, 'annonce vide';
  exception when sqlstate '22023' then null; end;
  -- édition avec la version attendue
  reset role;
  select coalesce(a.edited_at, a.created_at) into v from public.announcements a where a.id = ann;
  update public.announcement_recipients set acknowledged_at = now() where announcement_id = ann and employee_id = pg_temp.u('a1');   -- 4701 a déjà lu
  set role service_role;
  r := public.apply_sync_action(c, pg_temp.k(23), 'edit_announcement', jsonb_build_object('announcement_id', ann, 'expected_version', v, 'body', 'Réunion déplacée à mardi', 'reread', true));
  assert (r ->> 'pending_count')::integer = 2 and (r ->> 'reread_count')::integer = 1, 'édition avec « lire à nouveau » : ' || r::text;
  begin perform public.apply_sync_action(c, pg_temp.k(24), 'edit_announcement', jsonb_build_object('announcement_id', ann, 'expected_version', v, 'body', 'Encore')); assert false, 'version périmée';
  exception when sqlstate '40001' then if sqlerrm <> 'announcement_state_changed' then raise; end if; end;
  -- retrait
  r := public.apply_sync_action(c, pg_temp.k(25), 'withdraw_announcement', jsonb_build_object('announcement_id', ann));
  assert (r ->> 'withdrawn')::integer = 2, 'retirée pour ceux qui ne l''ont pas lue : ' || r::text;
  begin perform public.apply_sync_action(c, pg_temp.k(26), 'withdraw_announcement', jsonb_build_object('announcement_id', gen_random_uuid())); assert false, 'annonce inconnue';
  exception when sqlstate 'P0002' then null; end;
end $$;

-- ── C. Export des fiches pour l'import du côté 2 ────────────────────────────
reset role;
set role authenticated;
do $$
declare n integer; r record;
begin
  perform pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
  select count(*) into n from public.export_jobs_for_import(pg_temp.d0() - 10, pg_temp.d0()) where job_id in (pg_temp.k(900), pg_temp.k(901), pg_temp.k(902)); assert n = 1, 'fiches approuvées de la période : ' || n;
  select * into r from public.export_jobs_for_import(pg_temp.d0() - 10, pg_temp.d0()) where job_id in (pg_temp.k(900), pg_temp.k(901), pg_temp.k(902));
  assert r.employee_number = 4701 and r.job_id = pg_temp.k(900) and r.ot = 'OT 77' and r.km_total = 12 and r.status = 'approved', 'colonnes, par numéro';
  select count(*) into n from public.export_jobs_for_import(pg_temp.d0() - 10, pg_temp.d0(), array['approved', 'saved']) where job_id in (pg_temp.k(900), pg_temp.k(901), pg_temp.k(902)); assert n = 2, 'statuts demandés : ' || n;
  select count(*) into n from public.export_jobs_for_import(pg_temp.d0() - 60, pg_temp.d0()) where job_id in (pg_temp.k(900), pg_temp.k(901), pg_temp.k(902)); assert n = 2, 'période plus longue : ' || n;
  begin perform * from public.export_jobs_for_import(pg_temp.d0() - 400, pg_temp.d0()); assert false, 'période de plus de 366 jours';
  exception when sqlstate '22023' then if sqlerrm <> 'invalid_range' then raise; end if; end;
  begin perform * from public.export_jobs_for_import(pg_temp.d0(), pg_temp.d0() - 1); assert false, 'période à l''envers';
  exception when sqlstate '22023' then null; end;
  begin perform * from public.export_jobs_for_import(null, null); assert false, 'période absente';
  exception when sqlstate '22023' then null; end;
  begin perform * from public.export_jobs_for_import(pg_temp.d0() - 5, pg_temp.d0(), array['brouillon']); assert false, 'statut libre';
  exception when sqlstate '22023' then if sqlerrm <> 'invalid_statuses' then raise; end if; end;
  begin perform * from public.export_jobs_for_import(pg_temp.d0() - 5, pg_temp.d0(), '{}'); assert false, 'statuts vides';
  exception when sqlstate '22023' then null; end;
  perform pg_temp.as_user(pg_temp.u('mgr'), 'aal1');
  begin perform * from public.export_jobs_for_import(pg_temp.d0() - 5, pg_temp.d0()); assert false, 'gestionnaire sans aal2';
  exception when insufficient_privilege then if sqlerrm <> 'manager_role_required' then raise; end if; end;
  perform pg_temp.as_user(pg_temp.u('emp'), 'aal2');
  begin perform * from public.export_jobs_for_import(pg_temp.d0() - 5, pg_temp.d0()); assert false, 'employé';
  exception when insufficient_privilege then null; end;
  perform pg_temp.no_user();
  begin perform * from public.export_jobs_for_import(pg_temp.d0() - 5, pg_temp.d0()); assert false, 'anonyme';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$
declare a record;
begin
  assert (select count(*) from public.audit_log where action = 'jobs_exported') = 4, 'quatre exports réussis audités (les refus ne le sont pas)';
  select * into a from public.audit_log where action = 'jobs_exported' order by created_at limit 1;
  assert (a.details ->> 'count')::integer >= 1 and not (a.details::text ilike '%OT 77%'), 'l''audit garde le nombre, jamais le contenu';
end $$;

-- ── D. Droits des fonctions ─────────────────────────────────────────────────
set role authenticated;
do $$
begin
  perform pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
  begin perform public.apply_sync_action(pg_temp.u('client'), pg_temp.k(90), 'set_role', '{"employee_number": 4701, "role": "foreman"}'); assert false, 'apply_sync_action par le navigateur';
  exception when insufficient_privilege then null; end;
end $$;
select 'OK : migration 0015' as resultat;
