-- Test de la migration 0013 : source de saisie, compteurs, OT réutilisé, alerte de téléchargement, journal de lecture, feuille d'urgence (voir scripts/test-next-schema.sh).
\set ON_ERROR_STOP on
create function pg_temp.as_user(p_id uuid, p_aal text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_id, 'aal', p_aal)::text, false); end $$;
create function pg_temp.no_user() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '', false); end $$;
create function pg_temp.u(tag text) returns uuid language sql stable as $$ select current_setting('test.' || tag)::uuid $$;
create function pg_temp.k(n integer) returns uuid language sql immutable as $$ select ('cccccccc-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.d0() returns date language sql stable as $$ select (timezone('America/Toronto', now()))::date $$;

select pg_temp.no_user();
select set_config('test.own', id::text, false) from public.profiles where employee_number = 3001;
select set_config('test.mgr', id::text, false) from public.profiles where employee_number = 3002;
do $$
declare spec record; uid uuid;
begin
  for spec in select * from (values (4001, 'a'), (4002, 'b'), (4003, 'c')) as t(num, tag) loop
    uid := gen_random_uuid();
    insert into auth.users (id, email) values (uid, spec.num || '@pointage.invalid');
    insert into public.profiles (id, employee_number, role) values (uid, spec.num, 'employee');
    perform set_config('test.' || spec.tag, uid::text, false);
  end loop;
  -- fiches de départ (insérées par le propriétaire de la base : seule la RLS et les fonctions sont mises à l'épreuve ensuite)
  insert into public.jobs (id, user_id, job_date, ot, depart, fin, status) values
    (pg_temp.k(1), pg_temp.u('a'), pg_temp.d0() - 2, '654321', '07:00', '15:00', 'saved'),
    (pg_temp.k(2), pg_temp.u('b'), pg_temp.d0() - 2, '654321', '08:00', '16:00', 'saved'),
    (pg_temp.k(3), pg_temp.u('b'), pg_temp.d0() - 3, 'FORMATION', '08:00', '12:00', 'saved'),
    (pg_temp.k(4), pg_temp.u('c'), pg_temp.d0() - 3, 'FORMATION', '08:00', '12:00', 'saved'),
    (pg_temp.k(5), pg_temp.u('c'), pg_temp.d0() - 4, '12', '08:00', '12:00', 'saved'),
    (pg_temp.k(6), pg_temp.u('a'), pg_temp.d0() - 4, '12', '08:00', '12:00', 'saved');
end $$;

-- ── A. Source de saisie ─────────────────────────────────────────────────────
set role authenticated;
select pg_temp.as_user(pg_temp.u('a'), 'aal1');
do $$
declare n integer;
begin
  insert into public.job_entry_sources (job_id, user_id, source) values (pg_temp.k(1), pg_temp.u('a'), 'manual');
  begin insert into public.job_entry_sources (job_id, user_id, source) values (pg_temp.k(1), pg_temp.u('a'), 'screenshot'); assert false, 'une seule fois';
  exception when unique_violation then null; end;
  begin insert into public.job_entry_sources (job_id, user_id, source) values (pg_temp.k(6), pg_temp.u('a'), 'telepathie'); assert false, 'source libre';
  exception when check_violation then null; end;
  begin insert into public.job_entry_sources (job_id, user_id, source) values (pg_temp.k(2), pg_temp.u('a'), 'manual'); assert false, 'fiche d''un autre';
  exception when insufficient_privilege then null; end;
  begin insert into public.job_entry_sources (job_id, user_id, source) values (pg_temp.k(2), pg_temp.u('b'), 'manual'); assert false, 'au nom d''un autre';
  exception when insufficient_privilege then null; end;
  begin update public.job_entry_sources set source = 'screenshot'; assert false, 'modification';
  exception when insufficient_privilege then null; end;
  begin delete from public.job_entry_sources; assert false, 'suppression';
  exception when insufficient_privilege then null; end;
  select count(*) into n from public.job_entry_sources; assert n = 1, 'lecture de la sienne';
end $$;
select pg_temp.as_user(pg_temp.u('b'), 'aal1');
do $$ declare n integer; begin select count(*) into n from public.job_entry_sources; assert n = 0, 'un autre employé ne lit pas la source'; end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$ declare n integer; begin select count(*) into n from public.job_entry_sources; assert n = 1, 'le gestionnaire lit'; end $$;

-- ── B. Compteurs ────────────────────────────────────────────────────────────
do $$
declare r record;
begin
  select * into r from public.manager_job_counts(null, null);
  assert r.all_count >= 6 and r.saved_count >= 6, 'compteurs globaux';
  select * into r from public.manager_job_counts(pg_temp.u('b'), null);
  assert r.all_count = 2 and r.saved_count = 2 and r.submitted_count = 0 and r.approved_count = 0, 'un employé : ' || r.all_count;
  select * into r from public.manager_job_counts(pg_temp.u('b'), pg_temp.d0() - 3);
  assert r.all_count = 1, 'un employé, un jour';
end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal1');
do $$ begin perform * from public.manager_job_counts(null, null); assert false, 'gestionnaire sans double authentification';
  exception when insufficient_privilege then if sqlerrm <> 'manager_role_required' then raise; end if; end $$;
select pg_temp.as_user(pg_temp.u('a'), 'aal1');
do $$ begin perform * from public.manager_job_counts(null, null); assert false, 'employé';
  exception when insufficient_privilege then if sqlerrm <> 'manager_role_required' then raise; end if; end $$;
select pg_temp.no_user();
do $$ begin perform * from public.manager_job_counts(null, null); assert false, 'anonyme';
  exception when insufficient_privilege then null; end $$;

-- ── C. OT déjà utilisé ──────────────────────────────────────────────────────
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$
declare r record; n integer;
begin
  select * into r from public.ot_reuse_for_jobs(array[pg_temp.k(1)]);
  assert r.job_id = pg_temp.k(1) and r.other_job_id = pg_temp.k(2) and r.other_employee_number = 4002 and r.other_status = 'saved', 'OT réutilisé : numéro de l''autre employé';
  select count(*) into n from public.ot_reuse_for_jobs(array[pg_temp.k(1), pg_temp.k(2)]); assert n = 2, 'dans les deux sens';
  select count(*) into n from public.ot_reuse_for_jobs(array[pg_temp.k(3), pg_temp.k(4)]); assert n = 0, 'texte libre ignoré';
  select count(*) into n from public.ot_reuse_for_jobs(array[pg_temp.k(5), pg_temp.k(6)]); assert n = 0, 'numéro de moins de 4 chiffres ignoré';
  select count(*) into n from public.ot_reuse_for_jobs(null); assert n = 0, 'liste nulle';
end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal1');
do $$ declare n integer; begin select count(*) into n from public.ot_reuse_for_jobs(array[pg_temp.k(1)]); assert n = 0, 'sans double authentification : rien'; end $$;
select pg_temp.as_user(pg_temp.u('a'), 'aal1');
do $$ declare n integer; begin select count(*) into n from public.ot_reuse_for_jobs(array[pg_temp.k(1)]); assert n = 0, 'employé : rien'; end $$;

-- ── D. Preuves à télécharger ────────────────────────────────────────────────
reset role;
select pg_temp.no_user();
do $$
begin
  insert into public.overtime_evidence (job_id, user_id, job_date, storage_path, daily_minutes, created_at, expires_at) values
    (pg_temp.k(1), pg_temp.u('a'), pg_temp.d0() - 2, 'a/old.jpg', 600, now() - interval '25 days', now() + interval '5 days'),
    (pg_temp.k(2), pg_temp.u('b'), pg_temp.d0() - 2, 'b/new.jpg', 600, now() - interval '1 day', now() + interval '29 days');
  insert into public.parking_receipts (job_id, user_id, job_date, amount, storage_path, extra_storage_paths, created_at, expires_at)
    values (pg_temp.k(3), pg_temp.u('b'), pg_temp.d0() - 3, 10, pg_temp.u('b') || '/' || (pg_temp.d0() - 3) || '/p1.jpg', array[pg_temp.u('b') || '/' || (pg_temp.d0() - 3) || '/p2.jpg'], now() - interval '22 days', now() + interval '8 days');
  -- le déclencheur fixe l'échéance et la date à l'insertion : on les place ici pour le scénario
  update public.parking_receipts set created_at = now() - interval '22 days', expires_at = now() + interval '8 days' where job_id = pg_temp.k(3);
end $$;
set role authenticated;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$
declare r record;
begin
  select * into r from public.evidence_download_alert();
  assert r.total = 3 and r.overtime = 1 and r.parking = 2, 'photos anciennes non téléchargées : ' || r.total || '/' || r.overtime || '/' || r.parking;
  assert r.oldest_days = 25 and r.days_left = 5, 'plus vieille et jours restants : ' || r.oldest_days || '/' || r.days_left;
  select * into r from public.evidence_download_alert(30);
  assert r.total = 0, 'seuil de 30 jours : rien d''assez vieux ni qui expire dans 3 jours : ' || r.total;
end $$;

-- une photo téléchargée ne compte plus
insert into public.evidence_downloads (bucket, storage_path) values ('overtime-evidence', 'a/old.jpg');
do $$ declare r record; begin
  select * into r from public.evidence_download_alert(); assert r.total = 2 and r.overtime = 0 and r.parking = 2, 'après téléchargement : ' || r.total;
end $$;
-- une photo qui expire dans 3 jours ou moins compte, même récente
reset role;
update public.overtime_evidence set expires_at = now() + interval '2 days' where storage_path = 'b/new.jpg';
set role authenticated;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$ declare r record; begin
  select * into r from public.evidence_download_alert(); assert r.total = 3 and r.overtime = 1 and r.days_left = 2, 'expire bientôt : ' || r.total || '/' || r.days_left;
end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal1');
do $$ declare r record; begin select * into r from public.evidence_download_alert(); assert r.total = 0 and r.days_left is null, 'sans double authentification : zéros'; end $$;
select pg_temp.as_user(pg_temp.u('a'), 'aal1');
do $$ declare r record; begin select * into r from public.evidence_download_alert(); assert r.total = 0, 'employé : zéros'; end $$;

-- ── E. Lecture de photo impossible ──────────────────────────────────────────
do $$
declare n integer; d jsonb;
begin
  perform public.log_file_read_error('overtime', '{"size": 0, "age_s": 3, "step": "read", "error": "NotReadableError", "browser": "Mozilla/5.0 (secret)", "app": "x", "nom": "Zoé", "attempts": "beaucoup"}'::jsonb);
  reset role;
  select details into d from public.file_read_errors where user_id = pg_temp.u('a');
  assert d = '{"size": 0, "age_s": 3, "step": "read", "error": "NotReadableError"}'::jsonb, 'seules les clés connues, ni navigateur ni nom : ' || d::text;
  set role authenticated; perform pg_temp.as_user(pg_temp.u('a'), 'aal1');
  begin perform public.log_file_read_error('autre', '{}'); assert false, 'contexte libre'; exception when sqlstate '22023' then if sqlerrm <> 'invalid_context' then raise; end if; end;
  begin perform public.log_file_read_error(null, '{}'); assert false, 'contexte nul'; exception when sqlstate '22023' then null; end;
  begin insert into public.file_read_errors (user_id, context) values (pg_temp.u('a'), 'parking'); assert false, 'insertion directe'; exception when insufficient_privilege then null; end;
  select count(*) into n from public.file_read_errors; assert n = 0, 'l''employé ne relit pas le journal';
  for n in 1..30 loop perform public.log_file_read_error('inventory', '{"step": "decode"}'); end loop;
end $$;
reset role;
do $$ declare n integer; begin
  select count(*) into n from public.file_read_errors where user_id = pg_temp.u('a'); assert n = 20, '20 entrées par heure au plus : ' || n;
end $$;
set role authenticated;
select pg_temp.no_user();
do $$ begin perform public.log_file_read_error('overtime', '{}'); assert false, 'anonyme'; exception when insufficient_privilege then null; end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$ declare n integer; begin select count(*) into n from public.file_read_errors; assert n = 20, 'le gestionnaire lit'; end $$;

-- ── F. Feuille d'urgence : rappeler et supprimer ────────────────────────────
select pg_temp.as_user(pg_temp.u('own'), 'aal2');
do $$
declare c1 uuid; c2 uuid; n integer; r record; d0 date := pg_temp.d0();
begin
  select c.id into c1 from public.create_job_for_employee(pg_temp.u('c'), pg_temp.k(31), d0 - 6, 'OT 700', '07:00', '08:00', '15:00', 12, 'Oubli') c;
  perform set_config('test.e1', c1::text, false);
  select c.id into c2 from public.create_job_for_employee(pg_temp.u('c'), pg_temp.k(32), d0 - 6, 'OT 701', '16:00', null, '17:00', 5, 'Oubli bis') c;
  perform set_config('test.e2', c2::text, false);
  -- rappel
  perform public.remind_manager_entry(c1);
  begin perform public.remind_manager_entry(c1); assert false, 'rappel trop tôt'; exception when sqlstate '55000' then if sqlerrm <> 'reminder_too_soon' then raise; end if; end;
  begin perform public.remind_manager_entry(pg_temp.k(1)); assert false, 'fiche qui n''est pas une saisie du propriétaire'; exception when sqlstate 'P0002' then null; end;
  begin perform public.remind_manager_entry(gen_random_uuid()); assert false, 'fiche inconnue'; exception when sqlstate 'P0002' then null; end;
end $$;
reset role;
do $$ declare n integer; a record; begin
  select count(*) into n from public.employee_notices where user_id = pg_temp.u('c') and kind = 'manager_entry_reminder' and job_id = current_setting('test.e1')::uuid;
  assert n = 1, 'un avis de rappel';
  assert (select manager_entry_reminded_at from public.jobs where id = current_setting('test.e1')::uuid) is not null, 'rappel noté sur la fiche';
  select * into a from public.audit_log where action = 'manager_entry_reminded' and job_id = current_setting('test.e1')::uuid;
  assert a.target_number = 4003 and a.details = jsonb_build_object('job_date', (select job_date from public.jobs where id = current_setting('test.e1')::uuid)), 'audit par numéro, sans nom';
end $$;
set role authenticated;
-- seul le propriétaire (aal2)
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$ begin perform public.remind_manager_entry(current_setting('test.e2')::uuid); assert false, 'gestionnaire non propriétaire'; exception when insufficient_privilege then if sqlerrm <> 'owner_role_required' then raise; end if; end;
$$;
do $$ begin perform public.delete_manager_entry(current_setting('test.e2')::uuid); assert false, 'gestionnaire non propriétaire'; exception when insufficient_privilege then if sqlerrm <> 'owner_role_required' then raise; end if; end;
$$;
select pg_temp.as_user(pg_temp.u('own'), 'aal1');
do $$ begin perform public.delete_manager_entry(current_setting('test.e2')::uuid); assert false, 'propriétaire sans double authentification'; exception when insufficient_privilege then null; end;
$$;
select pg_temp.as_user(pg_temp.u('c'), 'aal1');
do $$ begin perform public.delete_manager_entry(current_setting('test.e2')::uuid); assert false, 'employé'; exception when insufficient_privilege then null; end;
$$;
-- suppression : le brouillon part, la réouverture reste tant qu'un autre brouillon du jour en a besoin
select pg_temp.as_user(pg_temp.u('own'), 'aal2');
do $$
declare n integer; d date := pg_temp.d0() - 6;
begin
  perform public.delete_manager_entry(current_setting('test.e2')::uuid);
  select count(*) into n from public.jobs where id = current_setting('test.e2')::uuid; assert n = 0, 'brouillon supprimé';
  select count(*) into n from public.job_entry_unlocks where user_id = pg_temp.u('c') and job_date = d and reason = 'manager_entry'; assert n = 1, 'réouverture gardée : un autre brouillon du jour';
  perform public.delete_manager_entry(current_setting('test.e1')::uuid);
  select count(*) into n from public.job_entry_unlocks where user_id = pg_temp.u('c') and job_date = d and reason = 'manager_entry'; assert n = 0, 'réouverture refermée';
  begin perform public.delete_manager_entry(current_setting('test.e1')::uuid); assert false, 'déjà supprimé'; exception when sqlstate 'P0002' then null; end;
end $$;
-- une saisie soumise par le propriétaire ne se supprime plus
do $$
declare c1 uuid;
begin
  select c.id into c1 from public.create_job_for_employee(pg_temp.u('c'), pg_temp.k(33), pg_temp.d0() - 7, 'OT 702', '07:00', '08:00', '15:00', 12, 'Urgence', null, null, true) c;
  begin perform public.delete_manager_entry(c1); assert false, 'fiche soumise'; exception when sqlstate '40001' then if sqlerrm <> 'job_state_changed' then raise; end if; end;
  begin perform public.remind_manager_entry(c1); assert false, 'rappel d''une fiche soumise'; exception when sqlstate '40001' then null; end;
end $$;
reset role;
do $$ declare n integer; begin
  select count(*) into n from public.audit_log where action = 'manager_entry_deleted' and target_number = 4003; assert n = 2, 'deux suppressions auditées par numéro';
end $$;
select 'OK : migration 0013' as resultat;
