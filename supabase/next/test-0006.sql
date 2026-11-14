-- Test de la migration 0006 : preuve de temps supplémentaire (voir scripts/test-next-schema.sh).
\set ON_ERROR_STOP on
create function pg_temp.as_user(p_id uuid, p_aal text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_id, 'aal', p_aal)::text, false); end $$;
create function pg_temp.no_user() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '', false); end $$;
create function pg_temp.d0() returns date language sql stable as $$ select (timezone('America/Toronto', now()))::date $$;
create function pg_temp.k(n integer) returns uuid language sql immutable as $$ select ('cccccccc-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;
-- save_own_job avec Arrivée et indicateur de preuve
create function pg_temp.sj(p_job uuid, p_key uuid, p_submit boolean, p_date date, p_dep time, p_arr time, p_fin time,
  p_km_total numeric default 0, p_km_aller numeric default 0, p_km_ret numeric default 0, p_flag boolean default false)
returns table (id uuid, status text, locked boolean) language sql as $$
  select * from public.save_own_job(p_job, null, p_key, p_submit, p_date, 'OT 100', p_dep, p_arr, p_fin, p_km_total, p_km_aller, 0, p_km_ret, p_flag, false, false)
$$;
create function pg_temp.proof(p_job uuid, p_key uuid, p_submit boolean, p_date date, p_dep time, p_fin time, p_ev uuid, p_path text, p_minutes integer)
returns table (id uuid, status text, locked boolean, evidence_id uuid) language sql as $$
  select * from public.save_own_job_with_overtime_evidence(p_job, null, p_key, p_submit, p_date, 'OT 100', p_dep, null, p_fin, 0, 0, 0, 0, false, p_ev, p_path, p_minutes)
$$;

select pg_temp.no_user();
select set_config('test.mgr', id::text, false) from public.profiles where employee_number = 3002;
select set_config('test.own', id::text, false) from public.profiles where employee_number = 3001;
select set_config('test.pau', id::text, false) from public.profiles where employee_number = 3008;

-- employés de test : régulier, 4×10 h, premier trajet non payé, bureau, contremaître 4×10 h, autre
do $$
declare spec record; uid uuid; n integer;
begin
  for spec in select * from (values (3101, 'employee', false, false, 'e1'), (3102, 'employee', true, false, 'e2'), (3103, 'employee', false, true, 'e3'),
                                    (3104, 'admin', false, false, 'e4'), (3105, 'foreman', true, false, 'e5'), (3106, 'employee', false, false, 'e6')) as t(num, role, ten, trip, tag) loop
    uid := gen_random_uuid();
    insert into auth.users (id, email) values (uid, spec.num || '@pointage.invalid');
    insert into public.profiles (id, employee_number, role, ten_hour_days, first_trip_unpaid) values (uid, spec.num, spec.role, spec.ten, spec.trip);
    perform set_config('test.' || spec.tag, uid::text, false);
    for n in 1..20 loop
      insert into public.job_entry_unlocks (user_id, job_date, created_by) values (uid, pg_temp.d0() - n, current_setting('test.mgr')::uuid) on conflict (user_id, job_date) do nothing;
    end loop;
  end loop;
end $$;

-- ── A. Contrat de soumission : preuve exigée au-delà de 8 h payées ──────────
set role authenticated;
select pg_temp.as_user(current_setting('test.e1')::uuid, 'aal1');
do $$
declare d0 date := pg_temp.d0(); r record;
begin
  select * into r from pg_temp.sj(null, pg_temp.k(1), true, d0 - 1, '07:00', null, '15:00'); assert r.status = 'submitted', '8 h pile : sans preuve';
  begin perform * from pg_temp.sj(null, pg_temp.k(2), true, d0 - 2, '07:00', null, '15:30'); assert false, '8 h 30 sans preuve acceptée';
  exception when sqlstate '23514' then if sqlerrm <> 'overtime_evidence_required' then raise; end if; end;
  assert not exists (select 1 from public.jobs where submission_key = pg_temp.k(2)), 'rien d''enregistré après le refus';
  -- deux fiches dans la journée : le total compte (5 h + 4 h = 9 h)
  perform * from pg_temp.sj(null, pg_temp.k(3), false, d0 - 3, '06:00', null, '11:00');
  begin perform * from pg_temp.sj(null, pg_temp.k(4), true, d0 - 3, '12:00', null, '16:00'); assert false, 'total de 9 h sans preuve acceptée';
  exception when sqlstate '23514' then if sqlerrm <> 'overtime_evidence_required' then raise; end if; end;
end $$;
select pg_temp.as_user(current_setting('test.e4')::uuid, 'aal1');
do $$ declare r record; begin
  select * into r from pg_temp.sj(null, pg_temp.k(5), true, pg_temp.d0() - 1, '06:00', null, '16:00'); assert r.status = 'submitted', 'employé de bureau : exempté de la preuve';
end $$;
select pg_temp.as_user(current_setting('test.e2')::uuid, 'aal1');
do $$
declare d0 date := pg_temp.d0(); r record;
begin
  select * into r from pg_temp.sj(null, pg_temp.k(6), true, d0 - 3, '07:00', null, '16:00'); assert r.status = 'submitted', '4×10 h : 9 h sans preuve';
  select * into r from pg_temp.sj(null, pg_temp.k(7), true, d0 - 5, '07:00', null, '17:00'); assert r.status = 'submitted', '4×10 h : 10 h pile sans preuve';
  begin perform * from pg_temp.sj(null, pg_temp.k(8), true, d0 - 4, '07:00', null, '17:30'); assert false, '4×10 h : 10 h 30 sans preuve acceptée';
  exception when sqlstate '23514' then if sqlerrm <> 'overtime_evidence_required' then raise; end if; end;
end $$;
select pg_temp.as_user(current_setting('test.e5')::uuid, 'aal1');
do $$ begin
  begin perform * from pg_temp.sj(null, pg_temp.k(9), true, pg_temp.d0() - 3, '07:00', null, '16:00'); assert false, 'contremaître 4×10 h : seuil de 8 h conservé';
  exception when sqlstate '23514' then if sqlerrm <> 'overtime_evidence_required' then raise; end if; end;
end $$;
select pg_temp.as_user(current_setting('test.e3')::uuid, 'aal1');
do $$
declare d0 date := pg_temp.d0(); r record;
begin
  -- premier trajet non payé : 8 h 30 dont 1 h de trajet = 7 h 30 payées → pas de preuve
  select * into r from pg_temp.sj(null, pg_temp.k(10), true, d0 - 6, '07:00', '08:00', '15:30', 10, 10, 0); assert r.status = 'submitted', 'trajet non payé retiré du seuil';
  -- 65 km ou plus : le trajet est payé → 8 h 30 payées → preuve exigée
  begin perform * from pg_temp.sj(null, pg_temp.k(11), true, d0 - 7, '07:00', '08:00', '15:30', 70, 70, 0); assert false, '65 km : trajet payé, preuve exigée';
  exception when sqlstate '23514' then if sqlerrm <> 'overtime_evidence_required' then raise; end if; end;
  select * into r from pg_temp.sj(null, pg_temp.k(12), true, d0 - 8, '07:00', '08:00', '15:30', 64, 64, 0);
  assert r.status = 'submitted', '64 km : trajet encore non payé';
end $$;
reset role;

-- le propriétaire soumet pour l'employé : la preuve est sautée, l'intervalle reste contrôlé
set role authenticated;
select pg_temp.as_user(current_setting('test.own')::uuid, 'aal2');
do $$
declare e1 uuid := current_setting('test.e1')::uuid; d0 date := pg_temp.d0(); r record;
begin
  select * into r from public.create_job_for_employee(e1, pg_temp.k(13), d0 - 11, 'OT 700', '06:00', null, '16:00', 5, 'Employé non disponible', null, null, true);
  assert (select status from public.jobs where id = r.id) = 'submitted', 'propriétaire : 10 h soumises sans preuve';
  assert coalesce(current_setting('sparklog.owner_submit', true), 'off') = 'off', 'l''indicateur est remis à zéro';
end $$;
reset role;

-- ── B. Fiche + preuve + avis en une seule transaction ───────────────────────
-- fichiers téléversés (en tant que service)
do $$
declare e1 text := current_setting('test.e1'); e6 text := current_setting('test.e6'); d0 date := pg_temp.d0();
begin
  insert into storage.objects (bucket_id, name, owner, owner_id) values
    ('overtime-evidence', e1 || '/' || (d0 - 9) || '/p1.jpg', e1::uuid, e1),
    ('overtime-evidence', e1 || '/' || (d0 - 10) || '/p2.jpg', e1::uuid, e1),
    ('overtime-evidence', e1 || '/' || (d0 - 10) || '/p3.jpg', e1::uuid, e1),
    ('overtime-evidence', e1 || '/' || (d0 - 12) || '/p4.jpg', e1::uuid, e1),
    ('overtime-evidence', e1 || '/' || (d0 - 14) || '/p5.jpg', e1::uuid, e1);
end $$;
set role authenticated;
select pg_temp.as_user(current_setting('test.e1')::uuid, 'aal1');
do $$
declare d0 date := pg_temp.d0(); e1 text := current_setting('test.e1'); r record; j1 uuid; n integer;
begin
  -- B1 : 9 h 30, soumise avec sa preuve
  select * into r from pg_temp.proof(null, pg_temp.k(21), true, d0 - 9, '07:00', '16:30', pg_temp.k(101), e1 || '/' || (d0 - 9) || '/p1.jpg', 570);
  assert r.status = 'submitted' and r.locked and r.evidence_id = pg_temp.k(101), 'fiche soumise avec sa preuve'; j1 := r.id;
  assert (select overtime_evidence_captured from public.jobs where id = j1), 'indicateur posé';
  -- B2 : relance (réponse perdue) : même fiche, une preuve, un avis
  select * into r from pg_temp.proof(null, pg_temp.k(21), true, d0 - 9, '07:00', '16:30', pg_temp.k(101), e1 || '/' || (d0 - 9) || '/p1.jpg', 570);
  assert r.id = j1, 'relance : même fiche';
  -- B4 : chemins et paramètres
  begin perform * from pg_temp.proof(null, pg_temp.k(22), true, d0 - 10, '07:00', '16:30', pg_temp.k(102), current_setting('test.e6') || '/' || (d0 - 10) || '/x.jpg', 570); assert false, 'dossier d''un autre';
  exception when sqlstate '23514' then if sqlerrm <> 'invalid_evidence_path' then raise; end if; end;
  begin perform * from pg_temp.proof(null, pg_temp.k(22), true, d0 - 10, '07:00', '16:30', pg_temp.k(102), e1 || '/' || (d0 - 10) || '/absent.jpg', 570); assert false, 'fichier absent';
  exception when sqlstate 'P0002' then if sqlerrm <> 'evidence_file_missing' then raise; end if; end;
  begin perform * from pg_temp.proof(null, pg_temp.k(22), true, d0 - 10, '07:00', '16:30', null, e1 || '/' || (d0 - 10) || '/p2.jpg', 570); assert false, 'identifiant de preuve absent';
  exception when sqlstate '23514' then if sqlerrm <> 'overtime_evidence_required' then raise; end if; end;
  assert not exists (select 1 from public.jobs where submission_key = pg_temp.k(22)), 'les refus ne laissent aucune fiche';
  -- B5 : une soumission refusée annule aussi la preuve (un jour sans preuve : 8 h soumises, puis un chevauchement avec preuve)
  select * into r from pg_temp.sj(null, pg_temp.k(23), true, d0 - 10, '07:00', null, '15:00');
  assert r.status = 'submitted', 'première fiche du jour';
  begin perform * from pg_temp.proof(null, pg_temp.k(24), true, d0 - 10, '14:00', '18:00', pg_temp.k(104), e1 || '/' || (d0 - 10) || '/p3.jpg', 720); assert false, 'chevauchement accepté';
  exception when sqlstate '23P01' then null; end;
  assert not exists (select 1 from public.overtime_evidence where id = pg_temp.k(104)), 'preuve annulée avec le refus';
  assert not exists (select 1 from public.jobs where submission_key = pg_temp.k(24)), 'fiche annulée avec le refus';
end $$;
select pg_temp.as_user(current_setting('test.e6')::uuid, 'aal1');
do $$ begin
  begin perform * from pg_temp.proof(null, pg_temp.k(25), true, pg_temp.d0() - 9, '07:00', '16:30', pg_temp.k(101), current_setting('test.e6') || '/' || (pg_temp.d0() - 9) || '/x.jpg', 570); assert false, 'preuve d''un autre';
  exception when sqlstate '42501' then if sqlerrm <> 'evidence_not_owned' then raise; end if; end;
end $$;
reset role;
do $$
declare d0 date := pg_temp.d0(); e1 uuid := current_setting('test.e1')::uuid; n integer;
begin
  select count(*) into n from public.overtime_evidence where id = pg_temp.k(101); assert n = 1, 'une seule preuve malgré la relance';
  select count(*) into n from public.manager_notifications where evidence_id = pg_temp.k(101); assert n = 1, 'un seul avis malgré la relance';
  assert (select expires_at from public.overtime_evidence where id = pg_temp.k(101)) between now() + make_interval(days => (select evidence_retention_days from public.overtime_settings)) - interval '1 hour'
    and now() + make_interval(days => (select evidence_retention_days from public.overtime_settings)) + interval '1 hour', 'conservée selon le réglage de conservation';
  assert (select ocr_status from public.overtime_evidence where id = pg_temp.k(101)) = 'pending', 'lecture de la preuve en attente';
  assert (select job_id from public.manager_notifications where evidence_id = pg_temp.k(101)) = (select job_id from public.overtime_evidence where id = pg_temp.k(101)), 'l''avis pointe la fiche de la preuve';
end $$;

-- B6 : une deuxième fiche le même jour : la preuve (et l'indicateur) passent à la dernière fiche
set role authenticated;
select pg_temp.as_user(current_setting('test.e1')::uuid, 'aal1');
do $$
declare d0 date := pg_temp.d0(); e1 text := current_setting('test.e1'); r record; first_job uuid; second_job uuid;
begin
  select * into r from pg_temp.proof(null, pg_temp.k(31), false, d0 - 12, '07:00', '16:30', pg_temp.k(105), e1 || '/' || (d0 - 12) || '/p4.jpg', 570); first_job := r.id;
  assert r.status = 'saved', 'brouillon avec preuve';
  select * into r from pg_temp.sj(null, pg_temp.k(32), true, d0 - 12, '17:00', null, '18:00'); second_job := r.id;
  assert r.status = 'submitted', 'deuxième fiche du jour sans nouvelle preuve (le jour en porte une)';
  perform set_config('test.b6a', first_job::text, false); perform set_config('test.b6b', second_job::text, false);
end $$;
reset role;
do $$
declare a uuid := current_setting('test.b6a')::uuid; b uuid := current_setting('test.b6b')::uuid;
begin
  assert (select job_id from public.overtime_evidence where id = pg_temp.k(105)) = b, 'la preuve suit la dernière fiche';
  assert (select overtime_evidence_captured from public.jobs where id = b) and not (select overtime_evidence_captured from public.jobs where id = a), 'indicateur sur la dernière fiche seulement';
  assert (select job_id from public.manager_notifications where evidence_id = pg_temp.k(105)) = b, 'l''avis suit la preuve';
  -- B8 : supprimer la fiche qui porte la preuve : elle passe à l'autre fiche du jour
  delete from public.jobs where id = b and status = 'submitted';
end $$;
do $$
declare a uuid := current_setting('test.b6a')::uuid; b uuid := current_setting('test.b6b')::uuid;
begin
  -- b est soumise : on la remet en brouillon (superuser) pour tester la suppression
  update public.jobs set status = 'updated', locked = false where id = b;
  delete from public.jobs where id = b;
  assert (select job_id from public.overtime_evidence where id = pg_temp.k(105)) = a, 'la preuve passe à la fiche restante';
  assert (select overtime_evidence_captured from public.jobs where id = a), 'indicateur reporté';
  -- B7 : la journée redescend à 8 h : la preuve est retirée, l'avis disparaît avec elle
  update public.jobs set fin = '12:00' where id = a;
  assert not exists (select 1 from public.overtime_evidence where id = pg_temp.k(105)), 'preuve retirée sous 8 h';
  assert not exists (select 1 from public.manager_notifications where evidence_id = pg_temp.k(105)), 'avis retiré avec la preuve';
  assert not (select overtime_evidence_captured from public.jobs where id = a), 'indicateur effacé';
end $$;

-- B9 : l'indicateur n'est retenu que si une preuve existe ce jour-là
set role authenticated;
select pg_temp.as_user(current_setting('test.e1')::uuid, 'aal1');
do $$ declare r record; begin
  select * into r from pg_temp.sj(null, pg_temp.k(41), false, pg_temp.d0() - 13, '07:00', null, '16:30', 0, 0, 0, true);  -- plus de 8 h : le nettoyage de 8 h ne masque rien
  assert not (select overtime_evidence_captured from public.jobs where id = r.id), 'indicateur sans preuve : ignoré';
  -- idem en modifiant une fiche existante
  select * into r from pg_temp.sj(r.id, pg_temp.k(41), false, pg_temp.d0() - 13, '07:00', null, '17:00', 0, 0, 0, true);
  assert not (select overtime_evidence_captured from public.jobs where id = r.id), 'indicateur sans preuve ignoré aussi à la modification';
end $$;
reset role;

-- ── C. Stockage : dossier de l'employé, lecture par les gestionnaires seulement ─
do $$ begin
  assert exists (select 1 from storage.buckets where id = 'overtime-evidence' and not public and file_size_limit = 10485760
                 and allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']), 'compartiment privé, 10 Mo, images';
end $$;
set role authenticated;
select pg_temp.as_user(current_setting('test.e1')::uuid, 'aal1');
do $$ declare e1 text := current_setting('test.e1'); e6 text := current_setting('test.e6'); begin
  insert into storage.objects (bucket_id, name, owner, owner_id) values ('overtime-evidence', e1 || '/2026-01-01/ok.jpg', e1::uuid, e1);
  begin insert into storage.objects (bucket_id, name, owner, owner_id) values ('overtime-evidence', e6 || '/2026-01-01/x.jpg', e1::uuid, e1); assert false, 'écriture dans le dossier d''un autre';
  exception when insufficient_privilege then null; end;
  assert (select count(*) from storage.objects where bucket_id = 'overtime-evidence') = 0, 'un employé ne relit pas les preuves';
end $$;
select pg_temp.as_user(current_setting('test.pau')::uuid, 'aal1');
do $$ declare p text := current_setting('test.pau'); begin
  begin insert into storage.objects (bucket_id, name, owner, owner_id) values ('overtime-evidence', p || '/2026-01-01/x.jpg', p::uuid, p); assert false, 'employé en pause téléverse';
  exception when insufficient_privilege then null; end;
end $$;
select pg_temp.as_user(current_setting('test.mgr')::uuid, 'aal1');
do $$ begin assert (select count(*) from storage.objects where bucket_id = 'overtime-evidence') = 0, 'gestionnaire sans aal2 : aucune preuve'; end $$;
select pg_temp.as_user(current_setting('test.mgr')::uuid, 'aal2');
do $$ begin assert (select count(*) from storage.objects where bucket_id = 'overtime-evidence') > 3, 'gestionnaire aal2 : lit les preuves'; end $$;

-- ── D. Tables : lecture par les gestionnaires, aucune écriture directe ──────
do $$
declare n integer;
begin
  assert (select count(*) from public.overtime_evidence) > 0 and (select count(*) from public.manager_notifications) > 0, 'gestionnaire aal2 lit preuves et avis';
  begin insert into public.overtime_evidence (job_id, user_id, job_date, storage_path, daily_minutes, expires_at) select id, user_id, job_date, 'x', 1, now() from public.jobs limit 1; assert false, 'insertion directe de preuve';
  exception when insufficient_privilege then null; end;
  begin update public.overtime_evidence set daily_minutes = 1; assert false, 'modification directe'; exception when insufficient_privilege then null; end;
  begin perform public.overtime_day_minutes(current_setting('test.e1')::uuid, pg_temp.d0()); assert false, 'overtime_day_minutes appelable';
  exception when insufficient_privilege then null; end;
  -- accusé de lecture : le sien seulement
  insert into public.manager_notification_reads (notification_id, manager_id) select id, current_setting('test.mgr')::uuid from public.manager_notifications limit 1;
  begin insert into public.manager_notification_reads (notification_id, manager_id) select id, current_setting('test.own')::uuid from public.manager_notifications limit 1; assert false, 'accusé au nom d''un autre';
  exception when insufficient_privilege then null; end;
  assert not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name in ('manager_notifications', 'overtime_evidence') and column_name ~ '(name|email|phone)'), 'aucune colonne nominative';
end $$;
select pg_temp.as_user(current_setting('test.e1')::uuid, 'aal1');
do $$ begin
  assert (select count(*) from public.overtime_evidence) = 0 and (select count(*) from public.manager_notifications) = 0, 'un employé ne voit ni preuves ni avis';
end $$;
reset role;
select 'OK : migration 0006' as resultat;
