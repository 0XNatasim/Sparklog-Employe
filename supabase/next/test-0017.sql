-- Test de la migration 0017 : delete_group, set_holiday, set_time_options.
\set ON_ERROR_STOP on
create function pg_temp.u(tag text) returns uuid language sql stable as $$ select current_setting('test.' || tag)::uuid $$;
create function pg_temp.k(n integer) returns uuid language sql immutable as $$ select ('66666666-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;
-- lecture des résultats : fonctions du propriétaire du banc (la RLS cache les tables à service_role)
create function pg_temp.g(p_id uuid) returns bigint language sql security definer as $$ select count(*) from public.employee_groups where id = p_id $$;
create function pg_temp.members(p_id uuid) returns bigint language sql security definer as $$ select count(*) from public.employee_group_members where group_id = p_id $$;
create function pg_temp.h(p_d date) returns text language sql security definer as $$ select label from public.company_holidays where holiday_date = p_d $$;
create function pg_temp.opts(p_n integer) returns text language sql security definer as $$ select concat_ws(',', first_trip_unpaid, ten_hour_days, return_with_benefits_to_8h, overtime_first_hour_double) from public.profiles where employee_number = p_n $$;
create function pg_temp.audits(p_action text) returns bigint language sql security definer as $$ select count(*) from public.audit_log where action = p_action $$;
create function pg_temp.audit_text(p_action text) returns text language sql security definer as $$ select string_agg(details::text, ' ') from public.audit_log where action = p_action $$;
do $$ declare uid uuid := gen_random_uuid(); begin
  insert into auth.users (id, email) values (uid, '4801@pointage.invalid');
  insert into public.profiles (id, employee_number, role) values (uid, 4801, 'employee');
end $$;
set role service_role;
select set_config('test.client', (select id::text from public.sync_create_client('test 0017')), false);
do $$
declare c uuid := pg_temp.u('client'); r jsonb; g uuid := pg_temp.k(700);
begin
  -- ── delete_group ──
  perform public.apply_sync_action(c, pg_temp.k(1), 'upsert_group', jsonb_build_object('id', g, 'name', 'À retirer'));
  perform public.apply_sync_action(c, pg_temp.k(2), 'set_group_members', jsonb_build_object('group_id', g, 'add', '[4801]'::jsonb));
  assert pg_temp.g(g) = 1 and pg_temp.members(g) = 1, 'groupe et membre créés';
  r := public.apply_sync_action(c, pg_temp.k(3), 'delete_group', jsonb_build_object('id', g));
  assert r = jsonb_build_object('group_id', g, 'deleted', true), 'groupe retiré : ' || r::text;
  assert pg_temp.g(g) = 0 and pg_temp.members(g) = 0, 'les membres partent avec le groupe';
  r := public.apply_sync_action(c, pg_temp.k(4), 'delete_group', jsonb_build_object('id', g));   -- autre clé, déjà absent : pas une erreur
  assert (r ->> 'deleted')::boolean is false, 'déjà absent';
  r := public.apply_sync_action(c, pg_temp.k(3), 'delete_group', jsonb_build_object('id', g));   -- même clé : résultat rejoué
  assert (r ->> 'deleted')::boolean is true, 'rejeu : même résultat qu''au premier passage';
  assert pg_temp.audits('group_deleted') = 1, 'un seul audit (le retrait réel)';
  begin perform public.apply_sync_action(c, pg_temp.k(5), 'delete_group', '{}'); assert false, 'sans identifiant';
  exception when sqlstate '22023' then null; end;
  begin perform public.apply_sync_action(c, pg_temp.k(6), 'delete_group', '{"id": "pas-un-uuid"}'); assert false, 'identifiant invalide';
  exception when invalid_text_representation then null; end;
  -- ── set_holiday ──
  r := public.apply_sync_action(c, pg_temp.k(10), 'set_holiday', '{"holiday_date": "2029-01-01", "label": "  Jour de l''An  "}');
  assert r = '{"holiday_date": "2029-01-01", "deleted": false}', 'férié ajouté : ' || r::text;
  assert pg_temp.h('2029-01-01') = 'Jour de l''An', 'libellé nettoyé';
  perform public.apply_sync_action(c, pg_temp.k(11), 'set_holiday', '{"holiday_date": "2029-01-01", "label": "Nouvel An"}');
  assert pg_temp.h('2029-01-01') = 'Nouvel An', 'libellé remplacé';
  r := public.apply_sync_action(c, pg_temp.k(12), 'set_holiday', '{"holiday_date": "2029-01-01", "delete": true}');
  assert (r ->> 'deleted')::boolean and pg_temp.h('2029-01-01') is null, 'férié retiré';
  r := public.apply_sync_action(c, pg_temp.k(13), 'set_holiday', '{"holiday_date": "2029-01-01", "delete": true}');
  assert (r ->> 'deleted')::boolean is false, 'déjà absent';
  assert pg_temp.h('2026-12-25') = 'Noël', 'les fériés de départ ne bougent pas';
  for i in 1..5 loop
    begin
      perform public.apply_sync_action(c, pg_temp.k(20 + i), 'set_holiday', (array['{"label": "x"}', '{"holiday_date": "2019-12-31", "label": "x"}', '{"holiday_date": "2101-01-01", "label": "x"}', '{"holiday_date": "2029-02-01"}', '{"holiday_date": "2029-02-01", "label": "   "}'])[i]::jsonb);
      assert false, 'refusé ' || i;
    exception when sqlstate '22023' then null; end;
  end loop;
  assert pg_temp.audits('holiday_changed') = 4, 'audit : ajout, remplacement, deux retraits';
  -- ── set_time_options ──
  assert pg_temp.opts(4801) = 'f,f,f,f', 'options de départ';
  r := public.apply_sync_action(c, pg_temp.k(30), 'set_time_options', '{"employee_number": 4801, "ten_hour_days": true}');
  assert (r ->> 'ten_hour_days')::boolean and pg_temp.opts(4801) = 'f,t,f,f', 'seule la clé donnée change';
  perform public.apply_sync_action(c, pg_temp.k(31), 'set_time_options', '{"employee_number": 4801, "first_trip_unpaid": true, "overtime_first_hour_double": true}');
  assert pg_temp.opts(4801) = 't,t,f,t', 'deux clés, la précédente gardée';
  perform public.apply_sync_action(c, pg_temp.k(32), 'set_time_options', '{"employee_number": 4801, "ten_hour_days": false, "return_with_benefits_to_8h": true}');
  assert pg_temp.opts(4801) = 't,f,t,t', 'faux explicite écrit';
  for i in 1..7 loop
    begin
      perform public.apply_sync_action(c, pg_temp.k(40 + i), 'set_time_options', (array['{"employee_number": 4801}', '{"employee_number": 4801, "hourly_rate": 50}', '{"employee_number": 4801, "ten_hour_days": "oui"}',
        '{"employee_number": 4801, "ten_hour_days": null}', '{"ten_hour_days": true}', '{"employee_number": 4801, "role": "admin"}', '{"employee_number": 4801, "is_paused": true}'])[i]::jsonb);
      assert false, 'refusé ' || i;
    exception when sqlstate '22023' or sqlstate 'P0002' or sqlstate '22004' then null; end;
  end loop;
  begin perform public.apply_sync_action(c, pg_temp.k(50), 'set_time_options', '{"employee_number": 9999, "ten_hour_days": true}'); assert false, 'inconnu';
  exception when sqlstate 'P0002' then null; end;
  assert pg_temp.opts(4801) = 't,f,t,t', 'les refus ne changent rien';
  assert pg_temp.audits('time_options_changed') = 3, 'trois écritures notées';
  assert pg_temp.audit_text('time_options_changed') !~ 'true|false', 'le journal note le nombre d''options, jamais les valeurs';
  assert pg_temp.audit_text('time_options_changed') ~ '"count": 1' and pg_temp.audit_text('time_options_changed') ~ '"count": 2', 'nombre d''options notées';
end $$;
reset role;
select 'OK : migration 0017' as resultat;
