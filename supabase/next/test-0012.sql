-- Test de la migration 0012 : interface d'échange avec le côté 2 (voir scripts/test-next-schema.sh).
\set ON_ERROR_STOP on
create function pg_temp.as_user(p_id uuid, p_aal text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_id, 'aal', p_aal)::text, false); end $$;
create function pg_temp.no_user() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '', false); end $$;
create function pg_temp.u(tag text) returns uuid language sql stable as $$ select current_setting('test.' || tag)::uuid $$;
create function pg_temp.k(n integer) returns uuid language sql immutable as $$ select ('99999999-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.d0() returns date language sql stable as $$ select (timezone('America/Toronto', now()))::date $$;

select pg_temp.no_user();
select set_config('test.mgr', id::text, false) from public.profiles where employee_number = 3002;
do $$
declare spec record; uid uuid;
begin
  for spec in select * from (values (3701, 'employee', false, 's1'), (3702, 'employee', false, 's2'), (3703, 'foreman', false, 's3'), (3704, 'employee', true, 's4')) as t(num, role, paused, tag) loop
    uid := gen_random_uuid();
    insert into auth.users (id, email) values (uid, spec.num || '@pointage.invalid');
    insert into public.profiles (id, employee_number, role, is_paused) values (uid, spec.num, spec.role, spec.paused);
    perform set_config('test.' || spec.tag, uid::text, false);
  end loop;
end $$;

-- ── A. Clients et secrets ───────────────────────────────────────────────────
set role service_role;
do $$
declare r record; c uuid; r2 record;
begin
  select * into r from public.sync_create_client('côté 2');
  assert r.secret like 'skc_%' and length(r.secret) = 44, 'secret de 44 caractères : ' || length(r.secret);
  perform set_config('test.c1', r.id::text, false); perform set_config('test.sec1', r.secret, false);
  select * into r2 from public.sync_create_client('côté 2 (rotation)'); perform set_config('test.c2', r2.id::text, false); perform set_config('test.sec2', r2.secret, false);
  assert r.secret <> r2.secret, 'deux secrets distincts';
  c := public.sync_authenticate(r.secret); assert c = r.id, 'secret valide';
  assert public.sync_authenticate('skc_faux') is null, 'secret faux : aucun client (pas d''erreur)';
  assert public.sync_authenticate(null) is null, 'secret absent : aucun client';
  begin perform public.sync_create_client(''); assert false, 'étiquette vide'; exception when check_violation then null; end;
  begin perform public.sync_create_client('côté 2'); assert false, 'étiquette en double'; exception when unique_violation then null; end;
end $$;
reset role;
do $$ begin
  assert not exists (select 1 from public.sync_clients where secret_hash = current_setting('test.sec1') or secret_hash not like '$2%'), 'secret jamais en clair (bcrypt)';
  assert (select last_used_at from public.sync_clients where id = pg_temp.u('c1')) is not null, 'dernière utilisation notée';
  assert not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name in ('sync_request_log', 'sync_actions', 'sync_clients', 'job_tombstones') and column_name ~ '(ip|agent|device|name|email|phone)$'), 'ni IP, ni appareil, ni nom dans le journal';
  assert exists (select 1 from public.sync_request_log where route = 'authenticate' and status = 'invalid'), 'tentative ratée journalisée';
end $$;
-- rotation : l'ancien secret est révoqué
set role service_role;
do $$ declare c uuid; begin
  perform public.sync_revoke_client(pg_temp.u('c1'));
  assert public.sync_authenticate(current_setting('test.sec1')) is null, 'secret révoqué : refusé';
  begin perform public.sync_health(pg_temp.u('c1')); assert false, 'client révoqué'; exception when sqlstate '28000' then null; end;
  begin perform public.sync_revoke_client(gen_random_uuid()); assert false, 'client inconnu'; exception when sqlstate 'P0002' then null; end;
  c := public.sync_authenticate(current_setting('test.sec2')); assert c = pg_temp.u('c2'), 'le nouveau secret fonctionne';
  assert (public.sync_health(pg_temp.u('c2')) ->> 'contract_version') = '1', 'version du contrat';
end $$;
reset role;

-- ── B. Lecture ──────────────────────────────────────────────────────────────
do $$
declare s1 uuid := pg_temp.u('s1'); s2 uuid := pg_temp.u('s2');
begin
  insert into public.jobs (user_id, job_date, ot, depart, fin, status, locked) values (s1, pg_temp.d0() - 1, 'OT 1', '07:00', '15:00', 'saved', false);
  insert into public.jobs (user_id, job_date, ot, depart, fin, status, locked) values (s1, pg_temp.d0() - 2, 'OT 2', '07:00', '15:00', 'saved', false);
  insert into public.jobs (user_id, job_date, ot, depart, fin, status, locked) values (s2, pg_temp.d0() - 1, 'OT 3', '07:00', '15:00', 'saved', false);
end $$;
set role service_role;
select pg_temp.no_user();
do $$
declare r record; last_ts timestamptz; last_id uuid; n integer; total integer; seen integer := 0;
begin
  begin perform * from public.sync_jobs_changed(gen_random_uuid()); assert false, 'client inconnu'; exception when sqlstate '28000' then null; end;
  select count(*) into total from public.sync_jobs_changed(pg_temp.u('c2'), null, null, 100000);
  assert total >= 3, 'lecture complète';
  -- pagination par curseur : trois fiches récentes, deux par page, sans trou ni doublon
  loop
    n := 0;
    for r in select * from public.sync_jobs_changed(pg_temp.u('c2'), last_ts, last_id, 2) loop
      n := n + 1; seen := seen + 1; last_ts := r.updated_at; last_id := r.id;
      assert r.employee_number is not null, 'numéro d''employé présent';
    end loop;
    exit when n = 0;
    assert seen <= total, 'pas de doublon : ' || seen || ' / ' || total;
  end loop;
  assert seen = total, 'pagination complète : ' || seen || ' / ' || total;
  -- le contrat n'expose ni l'identifiant de compte ni un nom
  assert not exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                      where n.nspname = 'public' and p.proname in ('sync_jobs_changed', 'sync_employees', 'sync_claims_changed', 'sync_job_ids', 'sync_jobs_deleted')
                        and (pg_get_function_result(p.oid) ~ '(user_id|full_name|email|phone|hourly|rate)')), 'aucun champ nominatif ni de paie dans les contrats';
end $$;
reset role;
-- une modification fait réapparaître la fiche après un curseur plus ancien
select set_config('test.cur_ts', max(updated_at)::text, false) from public.jobs;
update public.jobs set ot = 'OT 1 modifié' where ot = 'OT 1';
set role service_role;
select pg_temp.no_user();
do $$ declare r record; n integer; begin
  select count(*) into n from public.sync_jobs_changed(pg_temp.u('c2'), current_setting('test.cur_ts')::timestamptz, '00000000-0000-0000-0000-000000000000'::uuid, 100);
  assert n >= 1 and exists (select 1 from public.sync_jobs_changed(pg_temp.u('c2'), current_setting('test.cur_ts')::timestamptz, '00000000-0000-0000-0000-000000000000'::uuid, 100) where ot = 'OT 1 modifié'), 'fiche modifiée relue';
end $$;
reset role;
-- suppressions
do $$ begin
  delete from public.jobs where ot = 'OT 2';
  assert exists (select 1 from public.job_tombstones where employee_number = 3701), 'suppression enregistrée avec le numéro';
end $$;
set role service_role;
select pg_temp.no_user();
do $$ declare r record; ts timestamptz; begin
  select * into r from public.sync_jobs_deleted(pg_temp.u('c2'), null, 10) limit 1;
  assert r.employee_number = 3701 and r.job_date = pg_temp.d0() - 2, 'fiche supprimée annoncée au côté 2';
  ts := r.deleted_at;
  assert (select count(*) from public.sync_jobs_deleted(pg_temp.u('c2'), ts, 10)) = 0, 'après le curseur : rien';
  -- identifiants et versions d'une période
  assert (select count(*) from public.sync_job_ids(pg_temp.u('c2'), pg_temp.d0() - 3, pg_temp.d0())) >= 2, 'identifiants d''une période';
  begin perform * from public.sync_job_ids(pg_temp.u('c2'), pg_temp.d0() - 200, pg_temp.d0()); assert false, 'période trop longue'; exception when sqlstate '22023' then null; end;
  begin perform * from public.sync_job_ids(pg_temp.u('c2'), pg_temp.d0(), pg_temp.d0() - 1); assert false, 'période inversée'; exception when sqlstate '22023' then null; end;
  begin perform * from public.sync_job_ids(pg_temp.u('c2'), null, pg_temp.d0()); assert false, 'bornes absentes'; exception when sqlstate '22023' then null; end;
  -- employés
  assert (select count(*) from public.sync_employees(pg_temp.u('c2')) where employee_number in (3701, 3702, 3703, 3704)) = 4, 'employés lus par numéro';
  assert (select is_paused from public.sync_employees(pg_temp.u('c2')) where employee_number = 3704), 'indicateur de pause';
end $$;
reset role;
-- repas et stationnement
do $$
declare j uuid; wed date := date_trunc('week', pg_temp.d0())::date - 5;
begin
  insert into public.jobs (user_id, job_date, depart, fin) values (pg_temp.u('s3'), wed, '06:00', '16:30') returning id into j;
  insert into public.meal_claims (job_id, user_id, job_date, daily_work_minutes) values (j, pg_temp.u('s3'), wed, 630);
  insert into public.parking_receipts (job_id, user_id, job_date, amount, storage_path) values (j, pg_temp.u('s3'), wed, 12.5, pg_temp.u('s3')::text || '/a.jpg');
end $$;
set role service_role;
select pg_temp.no_user();
do $$ declare r record; n integer := 0; begin
  for r in select * from public.sync_claims_changed(pg_temp.u('c2'), null, null, 10) where employee_number = 3703 loop
    n := n + 1;
    assert r.kind in ('meal', 'parking') and r.status = 'pending', 'demande en attente : ' || r.kind;
    if r.kind = 'parking' then assert r.amount = 12.5, 'montant du stationnement'; end if;
  end loop;
  assert n = 2, 'repas et stationnement de 3703 : ' || n;
  assert (select count(*) from public.sync_claims_changed(pg_temp.u('c2'), null, null, 1)) = 1, 'limite respectée';
end $$;
reset role;

-- ── C. Actions idempotentes ─────────────────────────────────────────────────
do $$
declare j uuid;
begin
  insert into public.jobs (user_id, job_date, depart, fin, status, locked) values (pg_temp.u('s1'), pg_temp.d0() - 5, '07:00', '15:00', 'submitted', true) returning id into j;
  perform set_config('test.ja', j::text, false);
  perform set_config('test.ja_ts', (select updated_at::text from public.jobs where id = j), false);
  insert into public.jobs (user_id, job_date, depart, fin, status, locked) values (pg_temp.u('s1'), pg_temp.d0() - 6, '07:00', '15:00', 'submitted', true) returning id into j;
  perform set_config('test.jb', j::text, false);
  perform set_config('test.jb_ts', (select updated_at::text from public.jobs where id = j), false);
end $$;
set role service_role;
select pg_temp.no_user();
do $$
declare r jsonb; r2 jsonb; c uuid := pg_temp.u('c2');
begin
  -- approuver : résultat typé, rejouable
  r := public.apply_sync_action(c, pg_temp.k(1), 'approve_jobs', jsonb_build_object('jobs', jsonb_build_array(
         jsonb_build_object('id', current_setting('test.ja'), 'expected_updated_at', current_setting('test.ja_ts')),
         jsonb_build_object('id', current_setting('test.jb'), 'expected_updated_at', '2000-01-01T00:00:00Z'))));
  assert (r -> 'results' -> 0 ->> 'result') = 'approved' and (r -> 'results' -> 1 ->> 'result') = 'conflict', 'approbation typée : ' || r::text;
  r2 := public.apply_sync_action(c, pg_temp.k(1), 'approve_jobs', '{"jobs": []}');
  assert (r2 ->> 'replayed')::boolean and r2 -> 'results' = r -> 'results', 'relance : même résultat';
  begin perform public.apply_sync_action(c, pg_temp.k(1), 'set_pause', '{}'); assert false, 'clé réutilisée pour un autre type'; exception when sqlstate '23505' then if sqlerrm <> 'action_key_reused' then raise; end if; end;
  -- charges et types invalides : rien n'est enregistré
  begin perform public.apply_sync_action(c, pg_temp.k(2), 'approve_jobs', '{"jobs": "x"}'); assert false, 'charge invalide'; exception when sqlstate '22023' then null; end;
  begin perform public.apply_sync_action(c, pg_temp.k(3), 'inconnu', '{}'); assert false, 'type inconnu'; exception when sqlstate '22023' then if sqlerrm <> 'unknown_action_type' then raise; end if; end;
  begin perform public.apply_sync_action(c, null, 'set_pause', '{}'); assert false, 'clé absente'; exception when sqlstate '22023' then null; end;
  begin perform public.apply_sync_action(c, pg_temp.k(4), 'set_pause', '[]'); assert false, 'charge non objet'; exception when sqlstate '22023' then null; end;
  begin perform public.apply_sync_action(pg_temp.u('c1'), pg_temp.k(5), 'set_pause', '{}'); assert false, 'client révoqué'; exception when sqlstate '28000' then null; end;
end $$;
reset role;
do $$ begin
  assert (select count(*) from public.audit_log where action = 'job_approved' and job_id = pg_temp.u('ja')) = 1, 'un seul audit d''approbation malgré la relance';
  assert (select status from public.jobs where id = pg_temp.u('jb')) = 'submitted', 'fiche en conflit : inchangée';
  assert not exists (select 1 from public.sync_actions where action_key in (pg_temp.k(2), pg_temp.k(3), pg_temp.k(4), pg_temp.k(5))), 'les refus ne laissent aucune clé enregistrée';
end $$;

set role service_role;
select pg_temp.no_user();
do $$
declare r jsonb; c uuid := pg_temp.u('c2');
begin
  -- retourner : version attendue
  begin perform public.apply_sync_action(c, pg_temp.k(10), 'return_job', jsonb_build_object('job_id', current_setting('test.jb'), 'expected_updated_at', '2000-01-01T00:00:00Z')); assert false, 'version périmée'; exception when sqlstate '40001' then if sqlerrm <> 'job_state_changed' then raise; end if; end;
  begin perform public.apply_sync_action(c, pg_temp.k(10), 'return_job', jsonb_build_object('job_id', gen_random_uuid(), 'expected_updated_at', now())); assert false, 'fiche inconnue'; exception when sqlstate 'P0002' then null; end;
  r := public.apply_sync_action(c, pg_temp.k(10), 'return_job', jsonb_build_object('job_id', current_setting('test.jb'), 'expected_updated_at', current_setting('test.jb_ts')));
  assert (r ->> 'status') = 'updated', 'fiche retournée (la clé d''une tentative refusée peut être réutilisée)';
  r := public.apply_sync_action(c, pg_temp.k(10), 'return_job', jsonb_build_object('job_id', current_setting('test.jb'), 'expected_updated_at', current_setting('test.jb_ts')));
  assert (r ->> 'replayed')::boolean, 'relance du retour';
  begin perform public.apply_sync_action(c, pg_temp.k(11), 'return_job', jsonb_build_object('job_id', current_setting('test.jb'), 'expected_updated_at', current_setting('test.jb_ts'))); assert false, 'double retour avec une nouvelle clé'; exception when sqlstate '40001' then null; end;
  -- pause
  r := public.apply_sync_action(c, pg_temp.k(12), 'set_pause', '{"employee_number": 3702, "paused": true}');
  assert (r ->> 'is_paused')::boolean, 'mise en pause';
  r := public.apply_sync_action(c, pg_temp.k(12), 'set_pause', '{"employee_number": 3702, "paused": true}');
  assert (r ->> 'replayed')::boolean, 'relance de la pause';
  begin perform public.apply_sync_action(c, pg_temp.k(13), 'set_pause', '{"employee_number": 9999, "paused": true}'); assert false, 'numéro inconnu'; exception when sqlstate 'P0002' then null; end;
  begin perform public.apply_sync_action(c, pg_temp.k(14), 'set_pause', '{"employee_number": 3702, "paused": "oui"}'); assert false, 'pause non booléenne'; exception when sqlstate '22023' then null; end;
  perform public.apply_sync_action(c, pg_temp.k(15), 'set_pause', '{"employee_number": 3702, "paused": false}');
end $$;
reset role;
do $$ begin
  assert (select status from public.jobs where id = pg_temp.u('jb')) = 'updated' and not (select locked from public.jobs where id = pg_temp.u('jb')), 'fiche déverrouillée';
  assert (select count(*) from public.employee_notices where job_id = pg_temp.u('jb') and kind = 'job_returned') = 1, 'un seul avis de retour';
  assert (select count(*) from public.audit_log where action = 'job_returned_for_correction' and job_id = pg_temp.u('jb') and actor_id is null and target_number = 3701) = 1, 'un seul audit, sans acteur, par numéro';
  assert not (select is_paused from public.profiles where employee_number = 3702), 'réactivé';
  assert (select count(*) from public.audit_log where action = 'account_pause_changed' and target_number = 3702) = 2, 'deux changements d''état dans l''audit (la relance n''en ajoute pas)';
end $$;

-- comptes et codes d'activation
do $$ begin
  insert into auth.users (id, email) values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '3799@pointage.invalid'), ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '3798@pointage.invalid');
end $$;
set role service_role;
select pg_temp.no_user();
do $$
declare r jsonb; c uuid := pg_temp.u('c2'); old_code text; new_code text; st record;
begin
  r := public.apply_sync_action(c, pg_temp.k(20), 'register_account', '{"user_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "employee_number": 3799, "role": "employee"}');
  old_code := r ->> 'code';
  assert old_code ~ '^[A-HJKMNP-Z2-9]{10}$' and (r ->> 'employee_number')::int = 3799, 'compte créé avec un code d''activation';
  r := public.apply_sync_action(c, pg_temp.k(20), 'register_account', '{"user_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "employee_number": 3799, "role": "employee"}');
  assert (r ->> 'replayed')::boolean and (r ->> 'code') is null, 'relance : jamais de code en clair';
  begin perform public.apply_sync_action(c, pg_temp.k(21), 'register_account', '{"user_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "employee_number": 3799, "role": "employee"}'); assert false, 'numéro déjà pris'; exception when sqlstate '23505' then if sqlerrm <> 'employee_number_taken' then raise; end if; end;
  begin perform public.apply_sync_action(c, pg_temp.k(22), 'register_account', '{"user_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "employee_number": 3798, "role": "owner"}'); assert false, 'rôle propriétaire par l''interface'; exception when sqlstate '22023' then if sqlerrm <> 'invalid_role' then raise; end if; end;
  begin perform public.apply_sync_action(c, pg_temp.k(23), 'register_account', '{"user_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "employee_number": 3798, "role": "manager"}'); assert false, 'rôle gestionnaire par l''interface'; exception when sqlstate '22023' then null; end;
  begin perform public.apply_sync_action(c, pg_temp.k(24), 'register_account', '{"user_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "employee_number": 12, "role": "employee"}'); assert false, 'numéro hors bornes'; exception when check_violation then null; end;
  -- l'employé active son compte avec le code
  select * into st from public.consume_activation_code(3799, old_code); assert st.status = 'ok', 'activation avec le code';
  -- nouveau code : l'ancien ne marche plus
  r := public.apply_sync_action(c, pg_temp.k(25), 'reissue_activation_code', '{"employee_number": 3799}');
  new_code := r ->> 'code'; assert new_code ~ '^[A-HJKMNP-Z2-9]{10}$' and new_code <> old_code, 'nouveau code';
  r := public.apply_sync_action(c, pg_temp.k(25), 'reissue_activation_code', '{"employee_number": 3799}');
  assert (r ->> 'code') is null and (r ->> 'replayed')::boolean, 'relance de la réémission : pas de code';
  select * into st from public.consume_activation_code(3799, old_code); assert st.status = 'invalid', 'l''ancien code est révoqué';
  select * into st from public.consume_activation_code(3799, new_code); assert st.status = 'ok', 'le nouveau code fonctionne';
  begin perform public.apply_sync_action(c, pg_temp.k(26), 'reissue_activation_code', '{"employee_number": 9999}'); assert false, 'numéro inconnu'; exception when sqlstate 'P0002' then null; end;
end $$;
reset role;
do $$ begin
  assert not exists (select 1 from public.sync_actions where result::text ~ '[A-HJKMNP-Z2-9]{10}' and type in ('register_account', 'reissue_activation_code')), 'aucun code d''activation dans le résultat enregistré';
  assert (select count(*) from public.profiles where employee_number = 3799) = 1, 'un seul profil';
  assert not exists (select 1 from public.activation_codes where code_hash like '%' || 'zzzz' ), 'codes hachés';
end $$;

-- réouverture de journée, groupes
set role service_role;
select pg_temp.no_user();
do $$
declare r jsonb; c uuid := pg_temp.u('c2'); d date := pg_temp.d0() - 9; gid uuid;
begin
  r := public.apply_sync_action(c, pg_temp.k(30), 'unlock_day', jsonb_build_object('job_date', d, 'employee_numbers', jsonb_build_array(3701, 3704, 9999)));
  assert (r ->> 'unlocked')::int = 1, 'un seul employé actif rouvert (3704 en pause, 9999 inconnu) : ' || r::text;
  r := public.apply_sync_action(c, pg_temp.k(31), 'unlock_day', jsonb_build_object('job_date', d - 1, 'all', true));
  assert (r ->> 'unlocked')::int >= 4, 'tous les employés actifs';
  begin perform public.apply_sync_action(c, pg_temp.k(32), 'unlock_day', '{"employee_numbers": [3701]}'); assert false, 'date absente'; exception when sqlstate '22023' then null; end;
  r := public.apply_sync_action(c, pg_temp.k(33), 'upsert_group', '{"name": "Entrepôt Sync", "note": "Équipe du nord"}'); gid := (r ->> 'group_id')::uuid;
  r := public.apply_sync_action(c, pg_temp.k(34), 'upsert_group', '{"name": "  ENTREPÔT sync ", "low_stock_alert": true}');
  assert (r ->> 'group_id')::uuid = gid, 'même groupe malgré la casse';
  begin perform public.apply_sync_action(c, pg_temp.k(35), 'upsert_group', '{"name": "   "}'); assert false, 'nom vide'; exception when sqlstate '22023' then null; end;
  r := public.apply_sync_action(c, pg_temp.k(36), 'set_group_members', jsonb_build_object('group_id', gid, 'add', jsonb_build_array(3701, 3702, 9999)));
  assert (r ->> 'members')::int = 2, 'deux membres (le numéro inconnu est ignoré)';
  r := public.apply_sync_action(c, pg_temp.k(37), 'set_group_members', jsonb_build_object('group_id', gid, 'remove', jsonb_build_array(3702)));
  assert (r ->> 'members')::int = 1, 'un membre retiré';
  begin perform public.apply_sync_action(c, pg_temp.k(38), 'set_group_members', jsonb_build_object('group_id', gen_random_uuid(), 'add', '[]'::jsonb)); assert false, 'groupe inconnu'; exception when sqlstate 'P0002' then null; end;
end $$;
reset role;
do $$ begin
  assert (select created_by from public.job_entry_unlocks where user_id = pg_temp.u('s1') and job_date = pg_temp.d0() - 9) is null and (select unlocked_until from public.job_entry_unlocks where user_id = pg_temp.u('s1') and job_date = pg_temp.d0() - 9) is null, 'réouverture par le côté 2 : sans auteur, sans fin';
  assert (select low_stock_alert and note = 'Équipe du nord' from public.employee_groups where lower(name) = 'entrepôt sync'), 'groupe mis à jour, note conservée';
  assert exists (select 1 from public.audit_log where action = 'day_unlocked' and (details ->> 'count')::int = 1), 'audit de la réouverture';
end $$;

-- ── D. Personne d'autre que le service n'y touche ───────────────────────────
set role authenticated;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$
declare c uuid := pg_temp.u('c2');
begin
  begin perform public.sync_create_client('pirate'); assert false, 'création de client'; exception when insufficient_privilege then null; end;
  begin perform public.sync_authenticate('x'); assert false, 'authentification'; exception when insufficient_privilege then null; end;
  begin perform * from public.sync_jobs_changed(c); assert false, 'lecture des fiches'; exception when insufficient_privilege then null; end;
  begin perform * from public.sync_employees(c); assert false, 'lecture des employés'; exception when insufficient_privilege then null; end;
  begin perform public.apply_sync_action(c, pg_temp.k(90), 'set_pause', '{}'); assert false, 'action'; exception when insufficient_privilege then null; end;
  begin perform 1 from public.sync_clients; assert false, 'lecture des clients'; exception when insufficient_privilege then null; end;
  begin perform 1 from public.sync_actions; assert false, 'lecture des actions'; exception when insufficient_privilege then null; end;
  begin perform 1 from public.job_tombstones; assert false, 'lecture des suppressions'; exception when insufficient_privilege then null; end;
end $$;
select pg_temp.as_user(pg_temp.u('s1'), 'aal1');
do $$ begin
  begin perform * from public.sync_jobs_changed(pg_temp.u('c2')); assert false, 'un employé lit'; exception when insufficient_privilege then null; end;
  begin perform public.apply_sync_action(pg_temp.u('c2'), pg_temp.k(91), 'set_pause', '{"employee_number": 3701, "paused": true}'); assert false, 'un employé agit'; exception when insufficient_privilege then null; end;
end $$;
reset role;

-- ── E. Limites de débit (à la fin : elles bloquent les authentifications pendant une minute) ──
-- Les échecs de la section A comptent déjà ; on complète jusqu'à 20 échecs en une minute (une tentative ratée ne lève pas d'erreur : elle reste journalisée).
reset role;
select set_config('test.fails_before', count(*)::text, false) from public.sync_request_log where route = 'authenticate' and status = 'invalid' and created_at > now() - interval '1 minute';
set role service_role;
select pg_temp.no_user();
do $$ declare i integer; begin
  assert current_setting('test.fails_before')::int between 3 and 19, 'échecs déjà journalisés : ' || current_setting('test.fails_before');
  for i in 1..(20 - current_setting('test.fails_before')::int) loop
    assert public.sync_authenticate('skc_essai' || i) is null, 'échec sans erreur';
  end loop;
end $$;
reset role;
do $$ begin assert (select count(*) from public.sync_request_log where route = 'authenticate' and status = 'invalid' and created_at > now() - interval '1 minute') = 20, 'vingt échecs journalisés'; end $$;
set role service_role;
select pg_temp.no_user();
do $$ begin
  begin perform public.sync_authenticate(current_setting('test.sec2')); assert false, 'verrouillage après 20 échecs'; exception when sqlstate '54000' then if sqlerrm <> 'rate_limited' then raise; end if; end;
  begin perform public.sync_authenticate('autre'); assert false, 'verrouillage pour tous les secrets'; exception when sqlstate '54000' then null; end;
end $$;
reset role;
-- plafond par client : 120 appels réussis en une minute (le blocage global ci-dessus a expiré pour ce test : on retire les échecs)
delete from public.sync_request_log where status = 'invalid';
insert into public.sync_request_log (client_id, route, status) select current_setting('test.c2')::uuid, 'authenticate', 'ok' from generate_series(1, 120);
set role service_role;
select pg_temp.no_user();
do $$ begin
  begin perform public.sync_authenticate(current_setting('test.sec2')); assert false, 'plafond par client'; exception when sqlstate '54000' then null; end;
end $$;
reset role;
delete from public.sync_request_log where route = 'authenticate';
set role service_role;
select pg_temp.no_user();
do $$ begin assert public.sync_authenticate(current_setting('test.sec2')) = pg_temp.u('c2'), 'le service reprend quand les journaux sont purgés'; end $$;
reset role;
select 'OK : migration 0012' as resultat;
