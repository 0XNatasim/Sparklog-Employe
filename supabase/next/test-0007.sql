-- Test de la migration 0007 : repas, stationnement, avis de modification, téléchargements (voir scripts/test-next-schema.sh).
\set ON_ERROR_STOP on
create function pg_temp.as_user(p_id uuid, p_aal text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_id, 'aal', p_aal)::text, false); end $$;
create function pg_temp.no_user() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '', false); end $$;
create function pg_temp.d0() returns date language sql stable as $$ select (timezone('America/Toronto', now()))::date $$;
create function pg_temp.mon() returns date language sql stable as $$ select date_trunc('week', pg_temp.d0())::date $$;
create function pg_temp.wed1() returns date language sql stable as $$ select pg_temp.mon() - 5 $$;   -- mercredi de la semaine précédente
create function pg_temp.wed2() returns date language sql stable as $$ select pg_temp.mon() - 12 $$;  -- et celui d'avant
create function pg_temp.sat() returns date language sql stable as $$ select pg_temp.mon() - 2 $$;    -- samedi précédent
create function pg_temp.u(tag text) returns uuid language sql stable as $$ select current_setting('test.' || tag)::uuid $$;
-- fiche posée par le service (sans session), brouillon
create function pg_temp.mkjob(p_user uuid, p_date date, p_dep time, p_arr time, p_fin time, p_ret integer default 0, p_km numeric default 0) returns uuid language plpgsql as $$
declare i uuid;
begin
  insert into public.jobs (user_id, job_date, ot, depart, arrivee, fin, return_time_minutes, km_total, km_aller)
  values (p_user, p_date, 'OT 100', p_dep, p_arr, p_fin, p_ret, p_km, p_km) returning id into i;
  return i;
end $$;

select pg_temp.no_user();
select set_config('test.mgr', id::text, false) from public.profiles where employee_number = 3002;
select set_config('test.own', id::text, false) from public.profiles where employee_number = 3001;
do $$
declare spec record; uid uuid; n integer;
begin
  for spec in select * from (values (3201, false, false, 'm1'), (3202, true, false, 'm2'), (3203, false, true, 'm3'), (3204, false, false, 'm4')) as t(num, ten, trip, tag) loop
    uid := gen_random_uuid();
    insert into auth.users (id, email) values (uid, spec.num || '@pointage.invalid');
    insert into public.profiles (id, employee_number, role, ten_hour_days, first_trip_unpaid) values (uid, spec.num, 'employee', spec.ten, spec.trip);
    perform set_config('test.' || spec.tag, uid::text, false);
    for n in 1..20 loop
      insert into public.job_entry_unlocks (user_id, job_date, created_by) values (uid, pg_temp.d0() - n, current_setting('test.mgr')::uuid) on conflict (user_id, job_date) do nothing;
    end loop;
  end loop;
  assert extract(dow from pg_temp.wed1()) = 3 and extract(dow from pg_temp.wed2()) = 3 and extract(dow from pg_temp.sat()) = 6, 'jours de test : mercredis et samedi';
end $$;

-- fiches des scénarios de souper (posées par le service)
do $$
declare
  m1 uuid := pg_temp.u('m1'); m2 uuid := pg_temp.u('m2'); m3 uuid := pg_temp.u('m3'); m4 uuid := pg_temp.u('m4');
  j uuid;
begin
  perform set_config('test.m1_w1', pg_temp.mkjob(m1, pg_temp.wed1(), '06:00', null, '16:30')::text, false);         -- 630 min : souper dû
  perform set_config('test.m1_w2', pg_temp.mkjob(m1, pg_temp.wed2(), '07:00', null, '15:00')::text, false);         -- 480 min : non
  perform set_config('test.m1_sat', pg_temp.mkjob(m1, pg_temp.sat(), '06:00', null, '17:00')::text, false);         -- samedi : non
  perform set_config('test.m2_w1', pg_temp.mkjob(m2, pg_temp.wed1(), '06:00', null, '17:00')::text, false);         -- 4×10 h : jamais
  perform set_config('test.m3_w1', pg_temp.mkjob(m3, pg_temp.wed1(), '06:00', '07:00', '16:30', 0, 10)::text, false);  -- 630 - 60 de trajet = 570 : non
  perform set_config('test.m3_w2', pg_temp.mkjob(m3, pg_temp.wed2(), '06:00', '07:00', '16:30', 0, 70)::text, false);  -- 65 km+ : trajet payé = 630 : oui
  perform set_config('test.m4_w1', pg_temp.mkjob(m4, pg_temp.wed1(), '06:00', null, '17:00', 60)::text, false);     -- 660 - retour 60 = 600 : non
  perform set_config('test.m4_w2', pg_temp.mkjob(m4, pg_temp.wed2(), '06:00', null, '17:00', 30)::text, false);     -- 660 - retour 30 = 630 : oui
end $$;

-- ── A. Souper : droit vérifié à l'insertion, minutes du serveur ─────────────
set role authenticated;
select pg_temp.as_user(pg_temp.u('m1'), 'aal1');
do $$
declare r public.meal_claims%rowtype;
begin
  insert into public.meal_claims (job_id, user_id, job_date, daily_work_minutes, status, payroll_treatment, reviewed_by)
  values (pg_temp.u('m1_w1'), pg_temp.u('m1'), pg_temp.wed1(), 9999, 'approved', 'taxable_benefit', pg_temp.u('mgr')) returning * into r;
  assert r.status = 'pending' and r.payroll_treatment is null and r.reviewed_by is null and r.reviewed_at is null, 'champs de révision remis à zéro';
  assert r.daily_work_minutes = 630, 'minutes calculées par le serveur : ' || r.daily_work_minutes;
  perform set_config('test.claim1', r.id::text, false);
  begin insert into public.meal_claims (job_id, user_id, job_date, daily_work_minutes) values (pg_temp.u('m1_w1'), pg_temp.u('m1'), pg_temp.wed1(), 630); assert false, 'deuxième souper le même jour';
  exception when unique_violation then null; end;
  -- journée trop courte, samedi
  begin insert into public.meal_claims (job_id, user_id, job_date, daily_work_minutes) values (pg_temp.u('m1_w2'), pg_temp.u('m1'), pg_temp.wed2(), 700); assert false, 'journée de 8 h';
  exception when sqlstate '23514' then if sqlerrm <> 'meal_not_eligible' then raise; end if; end;
  begin insert into public.meal_claims (job_id, user_id, job_date, daily_work_minutes) values (pg_temp.u('m1_sat'), pg_temp.u('m1'), pg_temp.sat(), 700); assert false, 'samedi';
  exception when sqlstate '23514' then if sqlerrm <> 'meal_not_eligible' then raise; end if; end;
  -- la fiche d'un autre employé
  begin insert into public.meal_claims (job_id, user_id, job_date, daily_work_minutes) values (pg_temp.u('m4_w2'), pg_temp.u('m1'), pg_temp.wed1(), 630); assert false, 'fiche d''un autre';  -- m1 a droit au souper ce jour-là : seule la règle d''accès refuse
  exception when insufficient_privilege then null; end;
  begin update public.meal_claims set storage_path = 'x'; assert false, 'modification directe'; exception when insufficient_privilege then null; end;
  begin delete from public.meal_claims; assert false, 'suppression directe'; exception when insufficient_privilege then null; end;
end $$;
select pg_temp.as_user(pg_temp.u('m2'), 'aal1');
do $$ begin
  begin insert into public.meal_claims (job_id, user_id, job_date, daily_work_minutes) values (pg_temp.u('m2_w1'), pg_temp.u('m2'), pg_temp.wed1(), 660); assert false, '4 jours de 10 h : souper accepté';
  exception when sqlstate '23514' then if sqlerrm <> 'meal_not_eligible' then raise; end if; end;
end $$;
select pg_temp.as_user(pg_temp.u('m3'), 'aal1');
do $$ begin
  begin insert into public.meal_claims (job_id, user_id, job_date, daily_work_minutes) values (pg_temp.u('m3_w1'), pg_temp.u('m3'), pg_temp.wed1(), 630); assert false, 'trajet non payé ignoré';
  exception when sqlstate '23514' then if sqlerrm <> 'meal_not_eligible' then raise; end if; end;
  insert into public.meal_claims (job_id, user_id, job_date, daily_work_minutes) values (pg_temp.u('m3_w2'), pg_temp.u('m3'), pg_temp.wed2(), 630);  -- 65 km+ : dû
end $$;
select pg_temp.as_user(pg_temp.u('m4'), 'aal1');
do $$
declare c uuid;
begin
  begin insert into public.meal_claims (job_id, user_id, job_date, daily_work_minutes) values (pg_temp.u('m4_w1'), pg_temp.u('m4'), pg_temp.wed1(), 660); assert false, 'retour compté dans le souper';
  exception when sqlstate '23514' then if sqlerrm <> 'meal_not_eligible' then raise; end if; end;
  insert into public.meal_claims (job_id, user_id, job_date, daily_work_minutes) values (pg_temp.u('m4_w2'), pg_temp.u('m4'), pg_temp.wed2(), 630) returning id into c;
  perform set_config('test.claim4', c::text, false);
  -- avis aux gestionnaires (l'employé en crée de deux types seulement, pour sa propre fiche)
  insert into public.manager_notifications (type, employee_id, job_id, meal_claim_id, daily_minutes) values ('meal_claim', pg_temp.u('m4'), pg_temp.u('m4_w2'), c, 630);
  begin insert into public.manager_notifications (type, employee_id, job_id, daily_minutes) values ('overtime_evidence', pg_temp.u('m4'), pg_temp.u('m4_w2'), 630); assert false, 'avis de preuve fabriqué';
  exception when insufficient_privilege then null; end;
  begin insert into public.manager_notifications (type, employee_id, job_id, daily_minutes) values ('meal_claim', pg_temp.u('m4'), pg_temp.u('m1_w1'), 630); assert false, 'avis sur la fiche d''un autre';
  exception when insufficient_privilege then null; end;
  begin insert into public.manager_notifications (type, employee_id, job_id, daily_minutes) values ('meal_claim', pg_temp.u('m1'), pg_temp.u('m4_w2'), 630); assert false, 'avis au nom d''un autre';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin
  begin insert into public.manager_notifications (type, employee_id, daily_minutes) values ('inconnu', pg_temp.u('m4'), 1); assert false, 'type libre'; exception when check_violation then null; end;
end $$;

-- ── B. Ménage : la journée redescend sous le seuil ──────────────────────────
do $$
declare n integer;
begin
  update public.jobs set meal_claim_captured = true where id = pg_temp.u('m4_w2');
  assert exists (select 1 from public.meal_claims where id = pg_temp.u('claim4')), 'souper en attente présent';
  update public.jobs set fin = '12:00' where id = pg_temp.u('m4_w2');
  assert not exists (select 1 from public.meal_claims where id = pg_temp.u('claim4')), 'souper en attente retiré';
  assert not exists (select 1 from public.manager_notifications where meal_claim_id = pg_temp.u('claim4')), 'avis retiré';
  assert not (select meal_claim_captured from public.jobs where id = pg_temp.u('m4_w2')), 'indicateur effacé';
end $$;

-- ── C. Révision d'un souper ─────────────────────────────────────────────────
set role authenticated;
select pg_temp.as_user(pg_temp.u('m1'), 'aal1');
do $$ begin begin perform * from public.review_meal_claim(pg_temp.u('claim1'), 'approved', 'taxable_benefit'); assert false, 'employé révise'; exception when sqlstate '42501' then null; end; end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal1');
do $$ begin begin perform * from public.review_meal_claim(pg_temp.u('claim1'), 'approved', 'taxable_benefit'); assert false, 'gestionnaire sans aal2 révise'; exception when sqlstate '42501' then null; end; end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$
declare r record;
begin
  begin perform * from public.review_meal_claim(pg_temp.u('claim1'), 'peut-être'); assert false, 'décision libre'; exception when sqlstate '22023' then if sqlerrm <> 'invalid_review_decision' then raise; end if; end;
  begin perform * from public.review_meal_claim(pg_temp.u('claim1'), 'approved'); assert false, 'approbation sans traitement'; exception when sqlstate '22023' then if sqlerrm <> 'invalid_payroll_treatment' then raise; end if; end;
  begin perform * from public.review_meal_claim(gen_random_uuid(), 'rejected'); assert false, 'souper inconnu'; exception when sqlstate 'P0002' then null; end;
  select * into r from public.review_meal_claim(pg_temp.u('claim1'), 'approved', 'expense_reimbursement');
  assert r.status = 'approved' and r.payroll_treatment = 'expense_reimbursement' and r.reviewed_by = pg_temp.u('mgr'), 'souper approuvé';
  begin perform * from public.review_meal_claim(pg_temp.u('claim1'), 'rejected'); assert false, 'double révision'; exception when sqlstate '40001' then if sqlerrm <> 'meal_claim_already_reviewed' then raise; end if; end;
end $$;
reset role;
do $$ begin
  assert exists (select 1 from public.audit_log where action = 'meal_reviewed' and job_id = pg_temp.u('m1_w1') and actor_number = 3002 and target_number = 3201 and details ->> 'to' = 'approved'), 'audit de la révision, par numéros';
  -- un souper déjà révisé n'est pas retiré quand la journée raccourcit
  update public.jobs set fin = '12:00' where id = pg_temp.u('m1_w1');
  assert exists (select 1 from public.meal_claims where id = pg_temp.u('claim1')), 'souper révisé conservé';
end $$;

-- ── D. Stationnement ────────────────────────────────────────────────────────
do $$
declare m4 uuid := pg_temp.u('m4');
begin
  perform set_config('test.p_a', pg_temp.mkjob(m4, pg_temp.d0() - 2, '07:00', null, '15:00')::text, false);
  perform set_config('test.p_b', pg_temp.mkjob(m4, pg_temp.d0() - 2, '16:00', null, '17:00')::text, false);
end $$;
set role authenticated;
select pg_temp.as_user(pg_temp.u('m4'), 'aal1');
do $$
declare m4 text := current_setting('test.m4'); d date := pg_temp.d0() - 2; r public.parking_receipts%rowtype;
begin
  insert into public.parking_receipts (job_id, user_id, job_date, amount, storage_path) values (pg_temp.u('p_a'), pg_temp.u('m4'), d, 12, m4 || '/' || d || '/a.jpg') returning * into r;
  assert r.status = 'pending' and r.expires_at is not null and r.pictures_purged_at is null, 'reçu en attente, échéance posée';
  -- plafond de 20 $ par jour
  begin insert into public.parking_receipts (job_id, user_id, job_date, amount, storage_path) values (pg_temp.u('p_b'), pg_temp.u('m4'), d, 9, m4 || '/' || d || '/b.jpg'); assert false, 'plafond dépassé';
  exception when others then if sqlerrm not like 'The daily parking maximum%' then raise; end if; end;
  insert into public.parking_receipts (job_id, user_id, job_date, amount, storage_path) values (pg_temp.u('p_b'), pg_temp.u('m4'), d, 8, m4 || '/' || d || '/b.jpg');  -- 20 $ pile : permis
  -- champs de révision
  begin update public.parking_receipts set status = 'approved' where job_id = pg_temp.u('p_a'); assert false, 'employé approuve';
  exception when others then if sqlerrm not like 'Employees cannot set parking review fields%' and sqlstate <> '42501' then raise; end if; end;
  begin insert into public.parking_receipts (job_id, user_id, job_date, amount, status) select id, user_id, job_date, 0, 'approved' from public.jobs where id = pg_temp.u('m4_w1'); assert false, 'reçu inséré approuvé';
  exception when others then if sqlerrm not like 'Employees cannot set parking review fields%' and sqlstate <> '42501' then raise; end if; end;
  -- l'échéance ne se prolonge pas
  update public.parking_receipts set expires_at = now() + interval '3650 days', amount = 11 where job_id = pg_temp.u('p_a');
  assert (select expires_at from public.parking_receipts where job_id = pg_temp.u('p_a')) < now() + interval '400 days', 'échéance non modifiable par l''employé';
  assert (select amount from public.parking_receipts where job_id = pg_temp.u('p_a')) = 11, 'montant modifiable tant qu''en attente';
  -- chemins
  begin update public.parking_receipts set storage_path = current_setting('test.m1') || '/x.jpg' where job_id = pg_temp.u('p_a'); assert false, 'photo dans le dossier d''un autre';
  exception when check_violation then null; end;
  begin update public.parking_receipts set extra_storage_paths = array[m4 || '/1.jpg', m4 || '/1.jpg'] where job_id = pg_temp.u('p_a'); assert false, 'photos en double';
  exception when check_violation then null; end;
  begin update public.parking_receipts set extra_storage_paths = array(select m4 || '/' || g || '.jpg' from generate_series(1, 10) g) where job_id = pg_temp.u('p_a'); assert false, 'plus de 9 photos';
  exception when check_violation then null; end;
  begin update public.parking_receipts set storage_path = null where job_id = pg_temp.u('p_a'); assert false, 'sans photo et sans nettoyage';
  exception when check_violation then null; end;
  update public.parking_receipts set extra_storage_paths = array[m4 || '/2.jpg', m4 || '/3.jpg'] where job_id = pg_temp.u('p_a');
end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$
declare r record;
begin
  begin perform * from public.review_parking_claim(pg_temp.u('p_a'), 'peut-être'); assert false, 'décision libre'; exception when sqlstate '22023' then null; end;
  begin perform * from public.review_parking_claim(gen_random_uuid(), 'approved'); assert false, 'reçu inconnu'; exception when sqlstate 'P0002' then null; end;
  select * into r from public.review_parking_claim(pg_temp.u('p_a'), 'approved'); assert r.status = 'approved' and r.reviewed_by = pg_temp.u('mgr'), 'reçu approuvé';
  begin perform * from public.review_parking_claim(pg_temp.u('p_a'), 'rejected'); assert false, 'double révision'; exception when sqlstate '40001' then null; end;
end $$;
select pg_temp.as_user(pg_temp.u('m4'), 'aal1');
do $$ declare n integer; begin
  update public.parking_receipts set amount = 1 where job_id = pg_temp.u('p_a'); get diagnostics n = row_count; assert n = 0, 'un reçu révisé ne se modifie plus';
  begin perform * from public.review_parking_claim(pg_temp.u('p_b'), 'approved'); assert false, 'employé révise le stationnement'; exception when sqlstate '42501' then null; end;
end $$;
reset role;
do $$ begin
  assert exists (select 1 from public.audit_log where action = 'parking_reviewed' and job_id = pg_temp.u('p_a') and actor_number = 3002 and target_number = 3204 and details ->> 'to' = 'approved'), 'audit du stationnement';
end $$;

-- ── E. Avis quand l'employé modifie une fiche qui porte une preuve ──────────
do $$
declare j uuid := pg_temp.mkjob(pg_temp.u('m4'), pg_temp.d0() - 15, '07:00', null, '16:30');
begin
  perform set_config('test.pj', j::text, false);
  insert into public.overtime_evidence (job_id, user_id, job_date, storage_path, daily_minutes, expires_at)
  values (j, pg_temp.u('m4'), pg_temp.d0() - 15, pg_temp.u('m4')::text || '/p.jpg', 570, now() + interval '10 days');
end $$;
set role authenticated;
select pg_temp.as_user(pg_temp.u('m4'), 'aal1');
create function pg_temp.edit(p_fin time) returns void language plpgsql as $$
begin
  perform * from public.save_own_job(pg_temp.u('pj'), null, null, false, pg_temp.d0() - 15, 'OT 100', '07:00', null, p_fin, 0, 0, 0, 0, true, false, false);
end $$;
select pg_temp.edit('17:00');
reset role;
do $$ declare n integer; ch jsonb; begin
  select count(*), max(changes::text)::jsonb into n, ch from public.manager_notifications where job_id = pg_temp.u('pj') and type = 'overtime_job_edited';
  assert n = 1, 'un avis de modification'; assert ch -> 'fin' ->> 'from' = '16:30:00' and ch -> 'fin' ->> 'to' = '17:00:00', 'différence enregistrée : ' || ch::text;
end $$;
set role authenticated;
select pg_temp.as_user(pg_temp.u('m4'), 'aal1');
select pg_temp.edit('17:30');
reset role;
do $$ declare n integer; ch jsonb; begin
  select count(*), max(changes::text)::jsonb into n, ch from public.manager_notifications where job_id = pg_temp.u('pj') and type = 'overtime_job_edited';
  assert n = 1 and ch -> 'fin' ->> 'from' = '16:30:00' and ch -> 'fin' ->> 'to' = '17:30:00', 'les modifications se fusionnent : ' || ch::text;
  -- un changement du service ne crée pas d'avis ; le retour à l'origine l'efface
  update public.jobs set fin = '18:00' where id = pg_temp.u('pj'); update public.jobs set fin = '17:30' where id = pg_temp.u('pj');
  select count(*) into n from public.manager_notifications where job_id = pg_temp.u('pj') and type = 'overtime_job_edited'; assert n = 1, 'le service ne crée pas d''avis';
  -- ni un gestionnaire (même par une fonction serveur) : seul le propriétaire de la fiche déclenche l'avis
  perform pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
  update public.jobs set fin = '18:30' where id = pg_temp.u('pj');
  assert (select changes -> 'fin' ->> 'to' from public.manager_notifications where job_id = pg_temp.u('pj') and type = 'overtime_job_edited') = '17:30:00', 'avis inchangé par le gestionnaire';
  perform pg_temp.no_user();
  update public.jobs set fin = '17:30' where id = pg_temp.u('pj');
  select count(*) into n from public.manager_notifications where job_id = pg_temp.u('pj') and type = 'overtime_job_edited'; assert n = 1, 'un gestionnaire ne crée pas d''avis de modification';
end $$;
set role authenticated;
select pg_temp.as_user(pg_temp.u('m4'), 'aal1');
select pg_temp.edit('16:30');
reset role;
do $$ begin assert not exists (select 1 from public.manager_notifications where job_id = pg_temp.u('pj') and type = 'overtime_job_edited'), 'retour à l''origine : avis retiré'; end $$;

-- ── F. Téléchargements de preuves, compartiments, droits ────────────────────
do $$ begin
  assert (select count(*) from storage.buckets where id in ('overtime-evidence', 'parking-receipts', 'meal-receipts') and not public and file_size_limit = 10485760) = 3, 'trois compartiments privés';
end $$;
set role authenticated;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$ begin
  insert into public.evidence_downloads (bucket, storage_path, downloaded_by) values ('overtime-evidence', 'a/b.jpg', gen_random_uuid());
  assert (select downloaded_by from public.evidence_downloads where storage_path = 'a/b.jpg') = pg_temp.u('mgr'), 'auteur du téléchargement fixé par le serveur';
  begin insert into public.evidence_downloads (bucket, storage_path) values ('overtime-evidence', 'a/b.jpg'); assert false, 'doublon'; exception when unique_violation then null; end;
  begin insert into public.evidence_downloads (bucket, storage_path) values ('meal-receipts', 'a/c.jpg'); assert false, 'compartiment non prévu'; exception when check_violation then null; end;
end $$;
select pg_temp.as_user(pg_temp.u('m4'), 'aal1');
do $$ begin
  begin insert into public.evidence_downloads (bucket, storage_path) values ('overtime-evidence', 'z/z.jpg'); assert false, 'employé marque un téléchargement'; exception when insufficient_privilege then null; end;
  assert (select count(*) from public.evidence_downloads) = 0, 'employé ne lit pas les téléchargements';
  insert into storage.objects (bucket_id, name, owner, owner_id) values ('parking-receipts', pg_temp.u('m4')::text || '/a.jpg', pg_temp.u('m4'), pg_temp.u('m4')::text);
  insert into storage.objects (bucket_id, name, owner, owner_id) values ('meal-receipts', pg_temp.u('m4')::text || '/a.jpg', pg_temp.u('m4'), pg_temp.u('m4')::text);
  begin insert into storage.objects (bucket_id, name, owner, owner_id) values ('meal-receipts', pg_temp.u('m1')::text || '/a.jpg', pg_temp.u('m4'), pg_temp.u('m4')::text); assert false, 'dossier d''un autre';
  exception when insufficient_privilege then null; end;
  assert (select count(*) from storage.objects where bucket_id in ('parking-receipts', 'meal-receipts')) = 0, 'employé ne relit pas ses pièces';
end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$ begin assert (select count(*) from storage.objects where bucket_id in ('parking-receipts', 'meal-receipts')) = 2, 'gestionnaire lit les pièces'; end $$;
reset role;
select 'OK : migration 0007' as resultat;
