-- Test de la migration 0008 : notes du contremaître et journal d'activité (voir scripts/test-next-schema.sh).
\set ON_ERROR_STOP on
create function pg_temp.as_user(p_id uuid, p_aal text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_id, 'aal', p_aal)::text, false); end $$;
create function pg_temp.no_user() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '', false); end $$;
create function pg_temp.d0() returns date language sql stable as $$ select (timezone('America/Toronto', now()))::date $$;
create function pg_temp.u(tag text) returns uuid language sql stable as $$ select current_setting('test.' || tag)::uuid $$;
create function pg_temp.k(n integer) returns uuid language sql immutable as $$ select ('dddddddd-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.mkjob(p_user uuid, p_date date, p_dep time, p_fin time) returns uuid language plpgsql as $$
declare i uuid;
begin
  insert into public.jobs (user_id, job_date, ot, depart, fin) values (p_user, p_date, 'OT 100', p_dep, p_fin) returning id into i;
  return i;
end $$;

select pg_temp.no_user();
select set_config('test.mgr', id::text, false) from public.profiles where employee_number = 3002;
select set_config('test.mgr2', id::text, false) from public.profiles where employee_number = 3001;
do $$
declare spec record; uid uuid; n integer;
begin
  for spec in select * from (values (3301, 'foreman', false, 'f1'), (3302, 'foreman', false, 'f2'), (3303, 'employee', false, 'e'), (3304, 'foreman', true, 'fp')) as t(num, role, paused, tag) loop
    uid := gen_random_uuid();
    insert into auth.users (id, email) values (uid, spec.num || '@pointage.invalid');
    insert into public.profiles (id, employee_number, role, is_paused) values (uid, spec.num, spec.role, spec.paused);
    perform set_config('test.' || spec.tag, uid::text, false);
    for n in 1..20 loop
      insert into public.job_entry_unlocks (user_id, job_date, created_by) values (uid, pg_temp.d0() - n, pg_temp.u('mgr')) on conflict (user_id, job_date) do nothing;
    end loop;
  end loop;
  perform set_config('test.j1', pg_temp.mkjob(pg_temp.u('f1'), pg_temp.d0() - 1, '07:00', '15:00')::text, false);
  perform set_config('test.j2', pg_temp.mkjob(pg_temp.u('f1'), pg_temp.d0() - 2, '07:00', '15:00')::text, false);
  perform set_config('test.je', pg_temp.mkjob(pg_temp.u('e'), pg_temp.d0() - 1, '07:00', '15:00')::text, false);
  perform set_config('test.jf2', pg_temp.mkjob(pg_temp.u('f2'), pg_temp.d0() - 1, '07:00', '15:00')::text, false);
end $$;

-- ── A. Écrire une note ──────────────────────────────────────────────────────
set role authenticated;
select pg_temp.as_user(pg_temp.u('f1'), 'aal1');
do $$
declare n public.foreman_reports%rowtype;
begin
  insert into public.foreman_reports (submission_key, report_date, audited_employee_number, body, job_id, returned_at, returned_by, return_reason, created_at)
  values (pg_temp.k(1), pg_temp.d0() - 1, 3303, '  Chantier propre  ', pg_temp.u('j1'), now(), pg_temp.u('mgr'), 'fausse raison', '2000-01-01') returning * into n;
  assert n.body = 'Chantier propre', 'texte nettoyé';
  assert n.returned_at is null and n.returned_by is null and n.return_reason is null, 'fausse étiquette « retournée » effacée à l''insertion';
  assert n.created_at > now() - interval '1 minute', 'heure de création fixée par le serveur';
  assert n.user_id = pg_temp.u('f1'), 'auteur = l''utilisateur connecté';
  perform set_config('test.n1', n.id::text, false);
  -- une note sans fiche est permise
  insert into public.foreman_reports (submission_key, report_date, body) values (pg_temp.k(2), pg_temp.d0() - 1, 'Note libre') returning id into n.id;
  perform set_config('test.n0', n.id::text, false);
  -- une seule note par fiche, une clé par auteur
  begin insert into public.foreman_reports (submission_key, report_date, body, job_id) values (pg_temp.k(3), pg_temp.d0() - 1, 'deuxième', pg_temp.u('j1')); assert false, 'deux notes pour une fiche';
  exception when unique_violation then null; end;
  begin insert into public.foreman_reports (submission_key, report_date, body) values (pg_temp.k(1), pg_temp.d0() - 1, 'même clé'); assert false, 'clé en double';
  exception when unique_violation then null; end;
  -- bornes
  begin insert into public.foreman_reports (submission_key, report_date, body, audited_employee_number) values (pg_temp.k(4), pg_temp.d0() - 1, 'x', 12); assert false, 'numéro hors bornes';
  exception when check_violation then null; end;
  begin insert into public.foreman_reports (submission_key, report_date, body) values (pg_temp.k(5), pg_temp.d0() - 1, '    '); assert false, 'note vide';
  exception when check_violation then null; end;
  begin insert into public.foreman_reports (submission_key, report_date, body) values (pg_temp.k(6), pg_temp.d0() - 1, repeat('x', 5001)); assert false, 'note trop longue';
  exception when check_violation then null; end;
  -- la fiche d'un autre employé
  begin insert into public.foreman_reports (submission_key, report_date, body, job_id) values (pg_temp.k(7), pg_temp.d0() - 1, 'x', pg_temp.u('je')); assert false, 'note sur la fiche d''un autre';
  exception when insufficient_privilege then null; end;
  -- au nom d'un autre
  begin insert into public.foreman_reports (user_id, submission_key, report_date, body) values (pg_temp.u('f2'), pg_temp.k(8), pg_temp.d0() - 1, 'x'); assert false, 'note au nom d''un autre';
  exception when insufficient_privilege then null; end;
end $$;
select pg_temp.as_user(pg_temp.u('e'), 'aal1');
do $$ begin
  begin insert into public.foreman_reports (submission_key, report_date, body) values (pg_temp.k(9), pg_temp.d0() - 1, 'x'); assert false, 'employé non contremaître écrit';
  exception when insufficient_privilege then null; end;
end $$;
select pg_temp.as_user(pg_temp.u('fp'), 'aal1');
do $$ begin
  begin insert into public.foreman_reports (submission_key, report_date, body) values (pg_temp.k(10), pg_temp.d0() - 1, 'x'); assert false, 'contremaître en pause écrit';
  exception when insufficient_privilege then null; end;
end $$;

-- ── B. Modifier sa note tant que la fiche est modifiable ────────────────────
select pg_temp.as_user(pg_temp.u('f1'), 'aal1');
do $$
declare before_ts timestamptz; after_ts timestamptz; nrows integer;
begin
  select updated_at into before_ts from public.foreman_reports where id = pg_temp.u('n1');
  perform pg_sleep(0.05);
  update public.foreman_reports set body = 'Chantier propre' where id = pg_temp.u('n1');
  assert (select updated_at from public.foreman_reports where id = pg_temp.u('n1')) = before_ts, 'rien n''a changé : updated_at inchangé';
  update public.foreman_reports set body = '  Chantier très propre ' where id = pg_temp.u('n1');
  select updated_at into after_ts from public.foreman_reports where id = pg_temp.u('n1');
  assert after_ts > before_ts and (select body from public.foreman_reports where id = pg_temp.u('n1')) = 'Chantier très propre', 'texte modifié : updated_at avance';
  begin update public.foreman_reports set returned_at = now() where id = pg_temp.u('n1'); assert false, 'colonne returned_at modifiable';
  exception when insufficient_privilege then null; end;
  begin update public.foreman_reports set user_id = pg_temp.u('f2') where id = pg_temp.u('n1'); assert false, 'auteur modifiable';
  exception when insufficient_privilege then null; end;
end $$;
-- changer le numéro audité fait avancer updated_at (instruction séparée : now() est constant dans une transaction)
select set_config('test.ts_before', updated_at::text, false) from public.foreman_reports where id = pg_temp.u('n1');
update public.foreman_reports set audited_employee_number = 3302 where id = pg_temp.u('n1');
do $$ begin assert (select updated_at from public.foreman_reports where id = pg_temp.u('n1')) > current_setting('test.ts_before')::timestamptz, 'numéro modifié : updated_at avance'; end $$;
reset role;
update public.jobs set status = 'submitted', locked = true where id = current_setting('test.j1')::uuid;   -- la fiche est soumise
set role authenticated;
select pg_temp.as_user(pg_temp.u('f1'), 'aal1');
do $$ declare n integer; begin
  update public.foreman_reports set body = 'tardif' where id = pg_temp.u('n1'); get diagnostics n = row_count; assert n = 0, 'fiche soumise : note non modifiable';
  update public.foreman_reports set body = 'libre modifiée' where id = pg_temp.u('n0'); get diagnostics n = row_count; assert n = 0, 'note sans fiche : non modifiable par le contremaître (aucune fiche modifiable)';
  assert (select count(*) from public.foreman_reports) = 2, 'le contremaître lit ses notes';
  delete from public.foreman_reports where id = pg_temp.u('n0'); get diagnostics n = row_count; assert n = 0, 'le contremaître ne supprime pas';
end $$;
select pg_temp.as_user(pg_temp.u('f2'), 'aal1');
do $$ begin assert (select count(*) from public.foreman_reports) = 0, 'un autre contremaître ne lit rien'; end $$;

-- ── C. Lecture, suppression et accusé de lecture par les gestionnaires ──────
select pg_temp.as_user(pg_temp.u('mgr'), 'aal1');
do $$ begin assert (select count(*) from public.foreman_reports) = 0, 'gestionnaire sans aal2 : aucune note'; end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$
declare n integer;
begin
  assert (select count(*) from public.foreman_reports) = 2, 'gestionnaire aal2 lit les notes';
  insert into public.foreman_report_reads (report_id, manager_id) values (pg_temp.u('n1'), pg_temp.u('mgr2'));
  assert (select manager_id from public.foreman_report_reads where report_id = pg_temp.u('n1')) = pg_temp.u('mgr'), 'accusé de lecture au nom du gestionnaire connecté';
  begin insert into public.foreman_report_reads (report_id) values (pg_temp.u('n1')); assert false, 'accusé en double'; exception when unique_violation then null; end;
  update public.foreman_report_reads set read_at = now() where report_id = pg_temp.u('n1'); get diagnostics n = row_count; assert n = 1, 'accusé de lecture mis à jour';
end $$;
select pg_temp.as_user(pg_temp.u('f1'), 'aal1');
do $$ begin
  assert (select count(*) from public.foreman_report_reads) = 0, 'le contremaître ne lit pas les accusés';
  begin insert into public.foreman_report_reads (report_id) values (pg_temp.u('n1')); assert false, 'contremaître écrit un accusé'; exception when insufficient_privilege then null; end;
end $$;

-- ── D. Retourner la fiche d'un contremaître avec une raison ─────────────────
select pg_temp.as_user(pg_temp.u('f1'), 'aal1');
do $$ begin begin perform * from public.return_foreman_note_sheet(pg_temp.u('n1'), now(), 'x'); assert false, 'contremaître retourne'; exception when sqlstate '42501' then null; end; end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal1');
do $$ begin begin perform * from public.return_foreman_note_sheet(pg_temp.u('n1'), now(), 'x'); assert false, 'gestionnaire sans aal2'; exception when sqlstate '42501' then null; end; end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$
declare ts timestamptz; note_ts timestamptz; r record;
begin
  select updated_at into ts from public.jobs where id = pg_temp.u('j1');
  select updated_at into note_ts from public.foreman_reports where id = pg_temp.u('n1');
  begin perform * from public.return_foreman_note_sheet(pg_temp.u('n1'), ts - interval '1 second', 'x'); assert false, 'version périmée'; exception when sqlstate '40001' then null; end;
  begin perform * from public.return_foreman_note_sheet(pg_temp.u('n1'), ts, repeat('r', 501)); assert false, 'raison trop longue'; exception when sqlstate '23514' then if sqlerrm <> 'return_reason_too_long' then raise; end if; end;
  begin perform * from public.return_foreman_note_sheet(pg_temp.u('n0'), ts, 'x'); assert false, 'note sans fiche'; exception when sqlstate 'P0002' then if sqlerrm <> 'note_has_no_sheet' then raise; end if; end;
  begin perform * from public.return_foreman_note_sheet(gen_random_uuid(), ts, 'x'); assert false, 'note inconnue'; exception when sqlstate 'P0002' then null; end;
  select * into r from public.return_foreman_note_sheet(pg_temp.u('n1'), ts, '  Heures à corriger ');
  assert r.status = 'updated', 'fiche retournée';
  assert (select returned_by from public.foreman_reports where id = pg_temp.u('n1')) = pg_temp.u('mgr') and (select return_reason from public.foreman_reports where id = pg_temp.u('n1')) = 'Heures à corriger', 'raison et auteur du retour';
  assert (select returned_at from public.foreman_reports where id = pg_temp.u('n1')) is not null, 'date du retour';
  assert (select updated_at from public.foreman_reports where id = pg_temp.u('n1')) = note_ts, 'un retour ne remet pas la note « non lue »';
  begin perform * from public.return_foreman_note_sheet(pg_temp.u('n1'), ts, 'x'); assert false, 'double retour'; exception when sqlstate '40001' then null; end;
end $$;
select pg_temp.as_user(pg_temp.u('f1'), 'aal1');
do $$ declare n integer; begin
  update public.foreman_reports set body = 'Corrigée' where id = pg_temp.u('n1'); get diagnostics n = row_count; assert n = 1, 'la fiche retournée rend la note modifiable';
end $$;
reset role;
do $$ begin
  assert exists (select 1 from public.audit_log where action = 'job_returned_for_correction' and job_id = pg_temp.u('j1') and actor_number = 3002 and target_number = 3301), 'audit du retour, par numéros';
  assert exists (select 1 from public.employee_notices where job_id = pg_temp.u('j1') and kind = 'job_returned' and user_id = pg_temp.u('f1')), 'avis au contremaître';
  assert not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name in ('foreman_reports', 'foreman_report_reads', 'employee_activity_log') and column_name ~ '(name|email|phone|device)'), 'aucune colonne nominative ni d''appareil';
end $$;
-- un gestionnaire (aal2) supprime une note
set role authenticated;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$ declare n integer; begin delete from public.foreman_reports where id = pg_temp.u('n0'); get diagnostics n = row_count; assert n = 1, 'gestionnaire supprime une note'; end $$;
reset role;

-- ── E. Journal d'activité ───────────────────────────────────────────────────
set role authenticated;
select pg_temp.as_user(pg_temp.u('e'), 'aal1');
do $$
declare n integer;
begin
  perform public.log_employee_activity('login', 'iPhone Safari');
  perform public.log_employee_activity('login', 'iPhone Safari');
  perform public.log_employee_activity('app_open');
  perform public.log_employee_activity('inconnu');
  perform public.log_employee_activity('job_saved');
end $$;
reset role;
do $$ declare n integer; begin
  select count(*) into n from public.employee_activity_log where user_id = pg_temp.u('e'); assert n = 1, 'doublons de présence écartés : ' || n;
  assert (select details from public.employee_activity_log where user_id = pg_temp.u('e')) = '{}'::jsonb, 'appareil non conservé';
  assert (select event from public.employee_activity_log where user_id = pg_temp.u('e')) = 'login', 'seule la connexion est notée';
  -- fenêtres : une connexion vieille de 2 minutes ne bloque plus une connexion, mais bloque encore une visite
  update public.employee_activity_log set created_at = now() - interval '2 minutes' where user_id = pg_temp.u('e');
end $$;
set role authenticated;
select pg_temp.as_user(pg_temp.u('e'), 'aal1');
select public.log_employee_activity('login');
reset role;
update public.employee_activity_log set created_at = now() - interval '2 minutes' where user_id = pg_temp.u('e');
set role authenticated;
select pg_temp.as_user(pg_temp.u('e'), 'aal1');
select public.log_employee_activity('app_open');
reset role;
do $$ declare n integer; begin
  select count(*) into n from public.employee_activity_log where user_id = pg_temp.u('e'); assert n = 2, 'nouvelle connexion après 1 minute, visite encore écartée (30 min) : ' || n;
  update public.employee_activity_log set created_at = now() - interval '31 minutes' where user_id = pg_temp.u('e');
end $$;
set role authenticated;
select pg_temp.as_user(pg_temp.u('e'), 'aal1');
select public.log_employee_activity('app_open');
reset role;
select set_config('test.total_before', count(*)::text, false) from public.employee_activity_log;
set role authenticated;
select pg_temp.no_user();
select public.log_employee_activity('login');
reset role;
do $$ declare n integer; begin
  select count(*) into n from public.employee_activity_log where user_id = pg_temp.u('e') and event = 'app_open'; assert n = 1, 'visite après 30 minutes : notée';
  select count(*) into n from public.employee_activity_log; assert n = current_setting('test.total_before')::int, 'un appel sans session ne note rien';
end $$;

-- activité sur les fiches (les actions en tant qu'employé ; les vérifications en tant que service, car un employé ne lit pas le journal)
set role authenticated;
select pg_temp.as_user(pg_temp.u('f2'), 'aal1');
do $$
declare d date := pg_temp.d0() - 3; r record;
begin
  select * into r from public.save_own_job(null, null, pg_temp.k(41), false, d, 'OT 100', '07:00', null, '15:00', 0, 0, 0, 0, false, false, false);
  perform set_config('test.fj', r.id::text, false);
  perform * from public.save_own_job(r.id, null, null, false, d, 'OT 100', '07:00', null, '14:00', 0, 0, 0, 0, false, false, false);
  perform * from public.save_own_job(r.id, null, null, true, d, 'OT 100', '07:00', null, '14:00', 0, 0, 0, 0, false, false, false);
  select * into r from public.save_own_job(null, null, pg_temp.k(42), false, d - 1, 'OT 100', '07:00', null, '12:00', 0, 0, 0, 0, false, false, false);
  perform set_config('test.fdel', r.id::text, false);
  delete from public.jobs where id = r.id;
end $$;
reset role;
do $$
declare fj uuid := current_setting('test.fj')::uuid; fdel uuid := current_setting('test.fdel')::uuid;
begin
  assert exists (select 1 from public.employee_activity_log where job_id = fj and event = 'job_saved' and (details ->> 'edit') = 'false'), 'création notée';
  assert exists (select 1 from public.employee_activity_log where job_id = fj and event = 'job_saved' and (details ->> 'edit') = 'true'), 'modification notée';
  assert exists (select 1 from public.employee_activity_log where job_id = fj and event = 'job_submitted'), 'soumission notée';
  assert exists (select 1 from public.employee_activity_log where job_id = fdel and event = 'job_deleted'), 'suppression notée';
  assert not exists (select 1 from public.employee_activity_log where details ? 'ot' or details ? 'device'), 'aucun texte libre ni appareil dans les détails';
  assert (select details from public.employee_activity_log where job_id = fj and event = 'job_submitted') ?& array['job_date', 'depart', 'fin', 'status', 'edit'], 'détails : clés permises';
end $$;
do $$ declare n integer; begin
  -- un changement fait par un gestionnaire sur la fiche d'un employé n'est pas noté à son nom
  select count(*) into n from public.employee_activity_log where user_id = pg_temp.u('f2'); perform set_config('test.cnt', n::text, false);
end $$;
set role authenticated;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
select public.log_employee_activity('login');   -- la présence d'un gestionnaire est aussi notée, à son numéro
reset role;
do $$ declare n integer; begin
  update public.jobs set ot = 'OT 999' where id = current_setting('test.fj')::uuid and false;
  select count(*) into n from public.employee_activity_log where user_id = pg_temp.u('f2'); assert n = current_setting('test.cnt')::int, 'aucune activité ajoutée à l''employé';
  begin insert into public.employee_activity_log (user_id, event, details) values (pg_temp.u('e'), 'login', '{"ot": "OT 100"}'); assert false, 'clé libre acceptée';
  exception when sqlstate '23514' then if sqlerrm not like 'activity_details_key_not_allowed%' then raise; end if; end;
end $$;
set role authenticated;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$ begin
  assert (select count(*) from public.employee_activity_log) > 5, 'gestionnaire aal2 lit le journal';
  begin insert into public.employee_activity_log (user_id, event) values (pg_temp.u('e'), 'login'); assert false, 'insertion directe'; exception when insufficient_privilege then null; end;
end $$;
select pg_temp.as_user(pg_temp.u('e'), 'aal1');
do $$ begin assert (select count(*) from public.employee_activity_log) = 0, 'un employé ne lit pas le journal'; end $$;
reset role;
-- défense en profondeur : même avec les droits du service, le garde fige l'auteur de la note
select pg_temp.as_user(pg_temp.u('f1'), 'aal1');
update public.foreman_reports set user_id = pg_temp.u('f2'), body = body where id = pg_temp.u('n1');
do $$ begin assert (select user_id from public.foreman_reports where id = pg_temp.u('n1')) = pg_temp.u('f1'), 'auteur de la note figé par le garde'; end $$;
-- la suppression d'une fiche par un tiers n'est pas notée à son nom ni à celui de l'employé
select set_config('test.cnt2', count(*)::text, false) from public.employee_activity_log;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
delete from public.jobs where id = current_setting('test.jf2')::uuid;
do $$ begin assert (select count(*) from public.employee_activity_log) = current_setting('test.cnt2')::int, 'suppression par un tiers : rien noté'; end $$;
select pg_temp.no_user();
select 'OK : migration 0008' as resultat;
