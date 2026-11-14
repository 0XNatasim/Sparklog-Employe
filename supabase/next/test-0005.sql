-- Test de la migration 0005 : fonctions d'écriture des fiches, audit sans nom, avis à l'employé (voir scripts/test-next-schema.sh).
\set ON_ERROR_STOP on
create function pg_temp.as_user(p_id uuid, p_aal text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_id, 'aal', p_aal)::text, false); end $$;
create function pg_temp.no_user() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '', false); end $$;
create function pg_temp.sj(p_job uuid, p_key uuid, p_submit boolean, p_date date, p_dep time, p_fin time,
  p_km_total numeric default 0, p_km_aller numeric default 0, p_km_ret numeric default 0, p_confirm boolean default false)
returns table (id uuid, status text, locked boolean) language sql as $$
  select * from public.save_own_job(p_job, null, p_key, p_submit, p_date, 'OT 100', p_dep, null, p_fin, p_km_total, p_km_aller, 0, p_km_ret, false, false, p_confirm)
$$;
create function pg_temp.k(n integer) returns uuid language sql immutable as $$ select ('bbbbbbbb-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.d0() returns date language sql stable as $$ select (timezone('America/Toronto', now()))::date $$;

select pg_temp.no_user();
select set_config('test.emp', id::text, false) from public.profiles where employee_number = 3005;
select set_config('test.mgr', id::text, false) from public.profiles where employee_number = 3002;
select set_config('test.own', id::text, false) from public.profiles where employee_number = 3001;
select set_config('test.pau', id::text, false) from public.profiles where employee_number = 3008;
-- un deuxième employé, et des journées rouvertes pour les deux
do $$
declare e2 uuid := gen_random_uuid(); n integer; emp uuid := current_setting('test.emp')::uuid;
begin
  insert into auth.users (id, email) values (e2, '3010@pointage.invalid');
  insert into public.profiles (id, employee_number, role) values (e2, 3010, 'employee');
  perform set_config('test.emp2', e2::text, false);
  for n in 1..20 loop
    insert into public.job_entry_unlocks (user_id, job_date, created_by) values
      (emp, pg_temp.d0() - n, current_setting('test.mgr')::uuid), (e2, pg_temp.d0() - n, current_setting('test.mgr')::uuid)
      on conflict (user_id, job_date) do nothing;
  end loop;
end $$;

-- ── A. Enregistrer et soumettre sa propre fiche ─────────────────────────────
set role authenticated;
select pg_temp.as_user(current_setting('test.emp')::uuid, 'aal1');
do $$
declare r record; a1 uuid; a2 uuid; n integer; d0 date := pg_temp.d0();
begin
  select * into r from pg_temp.sj(null, pg_temp.k(1), false, d0 - 1, '07:00', '15:00');
  assert r.status = 'saved' and not r.locked, 'brouillon : saved'; a1 := r.id;
  select * into r from pg_temp.sj(null, pg_temp.k(1), false, d0 - 1, '07:00', '15:00');
  assert r.id = a1, 'relance de la même clé : même fiche';
  select count(*) into n from public.jobs where submission_key = pg_temp.k(1); assert n = 1, 'une seule ligne pour la clé';
  perform set_config('test.a1', a1::text, false);

  select * into r from pg_temp.sj(null, pg_temp.k(2), true, d0 - 2, '07:00', '15:00', 10, 6, 4);
  assert r.status = 'submitted' and r.locked, 'soumission directe : submitted + locked'; a2 := r.id;
  select * into r from pg_temp.sj(null, pg_temp.k(2), true, d0 - 2, '07:00', '15:00', 10, 6, 4);
  assert r.id = a2 and r.status = 'submitted', 'relance après validation : même fiche';
  perform set_config('test.a2', a2::text, false);

  select * into r from pg_temp.sj(a1, pg_temp.k(1), false, d0 - 1, '08:00', '16:00');
  assert r.status = 'updated' and not r.locked, 'modification : updated';
  select * into r from pg_temp.sj(a1, pg_temp.k(1), true, d0 - 1, '08:00', '16:00');
  assert r.status = 'submitted' and r.locked, 'soumission d''une fiche existante';
  select * into r from pg_temp.sj(a1, pg_temp.k(1), true, d0 - 1, '08:00', '16:00');
  assert r.status = 'submitted', 'relance de soumission : sans effet';
  begin perform * from pg_temp.sj(a1, pg_temp.k(1), false, d0 - 1, '09:00', '17:00'); assert false, 'fiche soumise modifiable';
  exception when sqlstate '55000' then if sqlerrm <> 'job_not_editable' then raise; end if; end;
  assert (select depart from public.jobs where id = a1) = '08:00', 'heures inchangées après le refus';
end $$;

do $$
declare d0 date := pg_temp.d0(); r record;
begin
  -- intervalle invalide : refusé par le contrat de soumission, rien n'est enregistré
  begin perform * from pg_temp.sj(null, pg_temp.k(3), true, d0 - 3, '04:00', '21:00'); assert false, 'intervalle de 17 h accepté';
  exception when sqlstate '23514' then if sqlerrm <> 'invalid_job_interval' then raise; end if; end;
  assert not exists (select 1 from public.jobs where submission_key = pg_temp.k(3)), 'rien d''enregistré après le refus';
  -- champs obligatoires
  begin perform * from pg_temp.sj(null, null, false, d0 - 4, '07:00', '15:00'); assert false, 'clé absente';
  exception when sqlstate '23514' then if sqlerrm <> 'submission_key_required' then raise; end if; end;
  begin perform * from pg_temp.sj(null, pg_temp.k(4), false, null, '07:00', '15:00'); assert false, 'date absente';
  exception when sqlstate '23514' then if sqlerrm <> 'job_date_required' then raise; end if; end;
  -- chevauchement : la relance de la première soumission reste possible
  select * into r from pg_temp.sj(null, pg_temp.k(5), true, d0 - 5, '07:00', '15:00');
  begin perform * from pg_temp.sj(null, pg_temp.k(6), true, d0 - 5, '14:00', '16:00'); assert false, 'chevauchement accepté';
  exception when sqlstate '23P01' then null; end;
  assert (select id from pg_temp.sj(null, pg_temp.k(5), true, d0 - 5, '07:00', '15:00')) = r.id, 'relance malgré le chevauchement : même fiche';
  -- échéance dépassée sans réouverture
  begin perform * from pg_temp.sj(null, pg_temp.k(7), false, d0 - 25, '07:00', '15:00'); assert false, 'saisie après l''échéance';
  exception when others then if sqlerrm not like 'The entry deadline%' then raise; end if; end;
end $$;

-- fiche d'un autre employé, employé en pause, non connecté
select pg_temp.as_user(current_setting('test.emp2')::uuid, 'aal1');
do $$ begin
  begin perform * from pg_temp.sj(current_setting('test.a1')::uuid, pg_temp.k(1), false, pg_temp.d0() - 1, '07:00', '15:00'); assert false, 'fiche d''un autre modifiée';
  exception when sqlstate 'P0002' then null; end;
end $$;
select pg_temp.as_user(current_setting('test.pau')::uuid, 'aal1');
do $$ begin
  begin perform * from pg_temp.sj(null, pg_temp.k(8), false, pg_temp.d0(), '07:00', '15:00'); assert false, 'employé en pause écrit';
  exception when sqlstate '42501' then if sqlerrm <> 'job_write_not_allowed' then raise; end if; end;
end $$;
select pg_temp.no_user();
do $$ begin
  begin perform * from pg_temp.sj(null, pg_temp.k(9), false, pg_temp.d0(), '07:00', '15:00'); assert false, 'anonyme écrit';
  exception when sqlstate '42501' then if sqlerrm <> 'authentication_required' then raise; end if; end;
end $$;
reset role;

-- ── C. Feuille d'urgence : le propriétaire crée pour l'employé ──────────────
set role authenticated;
select pg_temp.as_user(current_setting('test.own')::uuid, 'aal2');
do $$
declare emp uuid := current_setting('test.emp')::uuid; d0 date := pg_temp.d0(); c1 uuid; c1b uuid; n integer; r record;
begin
  select c.id into c1 from public.create_job_for_employee(emp, pg_temp.k(21), d0 - 6, 'OT 200', '07:00', '08:00', '15:00', 12, 'Oubli de saisie') c;
  select * into r from public.jobs where id = c1;
  assert r.status = 'saved' and r.manager_entry_at is not null and r.manager_entry_by = current_setting('test.own')::uuid and r.manager_entry_note = 'Oubli de saisie', 'fiche d''urgence créée';
  perform set_config('test.c1', c1::text, false);
  select c.id into c1b from public.create_job_for_employee(emp, pg_temp.k(21), d0 - 6, 'OT 200', '07:00', '08:00', '15:00', 12, 'Oubli de saisie') c;
  assert c1b = c1, 'relance : même fiche';

  -- fenêtre de dates, champs obligatoires
  begin perform public.create_job_for_employee(emp, pg_temp.k(22), d0 + 1, 'OT', '07:00', null, '15:00', 1, 'note ok'); assert false, 'date future';
  exception when sqlstate '23514' then if sqlerrm <> 'manager_entry_date_out_of_window' then raise; end if; end;
  begin perform public.create_job_for_employee(emp, pg_temp.k(23), d0 - 40, 'OT', '07:00', null, '15:00', 1, 'note ok'); assert false, 'date trop ancienne';
  exception when sqlstate '23514' then if sqlerrm <> 'manager_entry_date_out_of_window' then raise; end if; end;
  begin perform public.create_job_for_employee(emp, pg_temp.k(24), d0 - 7, 'OT', '07:00', null, '15:00', 1, 'ab'); assert false, 'note trop courte';
  exception when sqlstate '23514' then if sqlerrm <> 'manager_entry_note_required' then raise; end if; end;
  begin perform public.create_job_for_employee(emp, pg_temp.k(25), d0 - 7, '  ', '07:00', null, '15:00', 1, 'note ok'); assert false, 'OT vide';
  exception when sqlstate '23514' then if sqlerrm <> 'manager_entry_ot_required' then raise; end if; end;
  begin perform public.create_job_for_employee(emp, null, d0 - 7, 'OT', '07:00', null, '15:00', 1, 'note ok'); assert false, 'clé absente';
  exception when sqlstate '23514' then if sqlerrm <> 'manager_entry_missing_field' then raise; end if; end;
  begin perform public.create_job_for_employee(emp, pg_temp.k(26), d0 - 7, 'OT', '07:00', null, '07:00', 1, 'note ok'); assert false, 'départ = fin';
  exception when sqlstate '23514' then if sqlerrm <> 'invalid_job_interval' then raise; end if; end;
  -- cibles non admissibles : un gestionnaire ; un employé en pause (sauf soumission)
  begin perform public.create_job_for_employee(current_setting('test.mgr')::uuid, pg_temp.k(27), d0 - 7, 'OT', '07:00', null, '15:00', 1, 'note ok'); assert false, 'cible gestionnaire';
  exception when sqlstate 'P0002' then null; end;
  begin perform public.create_job_for_employee(current_setting('test.pau')::uuid, pg_temp.k(28), d0 - 7, 'OT', '07:00', null, '15:00', 1, 'note ok'); assert false, 'cible en pause';
  exception when sqlstate 'P0002' then null; end;
  -- variante « soumise par le propriétaire » : soumise ET verrouillée, pas de réouverture, avis différent, employé en pause accepté
  select c.id into c1b from public.create_job_for_employee(emp, pg_temp.k(29), d0 - 8, 'OT 300', '07:00', null, '15:00', 5, 'Employé non disponible', null, null, true) c;
  select * into r from public.jobs where id = c1b;
  assert r.status = 'submitted' and r.locked, 'soumise par le propriétaire : submitted + locked';
  perform set_config('test.c2', c1b::text, false);
  select count(*) into n from public.job_entry_unlocks where user_id = emp and job_date = d0 - 8 and reason = 'manager_entry'; assert n = 0, 'pas de réouverture pour une fiche soumise';
  select c.id into c1b from public.create_job_for_employee(current_setting('test.pau')::uuid, pg_temp.k(30), d0 - 9, 'OT 400', '07:00', null, '15:00', 0, 'Employé parti', null, null, true) c;
  assert exists (select 1 from public.jobs where id = c1b and status = 'submitted'), 'soumission pour un employé en pause';
  -- fiche à confirmer par l'employé
  select c.id into c1b from public.create_job_for_employee(emp, pg_temp.k(31), d0 - 10, 'OT 500', '07:00', null, '15:00', 3, 'À confirmer') c;
  perform set_config('test.c3', c1b::text, false);
end $$;
reset role;
do $$
declare emp uuid := current_setting('test.emp')::uuid; d0 date := pg_temp.d0(); n integer;
begin
  -- une réouverture sans fin déjà posée (préparation du test) n'est jamais raccourcie
  assert (select unlocked_until from public.job_entry_unlocks where user_id = emp and job_date = d0 - 6) is null, 'réouverture sans fin conservée';
  -- sans réouverture préalable : 14 jours
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.own'), 'aal', 'aal2')::text, false);
  perform public.create_job_for_employee(emp, pg_temp.k(51), d0 - 30, 'OT 600', '07:00', null, '15:00', 2, 'Journée ancienne');
  assert (select reason from public.job_entry_unlocks where user_id = emp and job_date = d0 - 30) = 'manager_entry', 'réouverture créée';
  assert (select unlocked_until from public.job_entry_unlocks where user_id = emp and job_date = d0 - 30) between now() + interval '13 days 23 hours' and now() + interval '14 days 1 hour', 'réouverture de 14 jours';
  select count(*) into n from public.employee_notices where job_id = current_setting('test.c1')::uuid and kind = 'job_created_by_manager' and user_id = emp; assert n = 1, 'un avis (la relance n''en ajoute pas)';
  select count(*) into n from public.employee_notices where job_id = current_setting('test.c2')::uuid and kind = 'job_submitted_by_owner'; assert n = 1, 'avis de soumission par le propriétaire';
  select count(*) into n from public.audit_log where job_id = current_setting('test.c1')::uuid and action = 'job_created_by_owner' and target_number = 3005 and actor_number = 3001; assert n = 1, 'un seul audit, par numéros';
end $$;
-- un gestionnaire (non propriétaire) et un propriétaire sans aal2 sont refusés
set role authenticated;
select pg_temp.as_user(current_setting('test.mgr')::uuid, 'aal2');
do $$ begin
  begin perform public.create_job_for_employee(current_setting('test.emp')::uuid, pg_temp.k(41), pg_temp.d0() - 7, 'OT', '07:00', null, '15:00', 1, 'note ok'); assert false, 'gestionnaire crée';
  exception when sqlstate '42501' then if sqlerrm <> 'owner_role_required' then raise; end if; end;
end $$;
select pg_temp.as_user(current_setting('test.own')::uuid, 'aal1');
do $$ begin
  begin perform public.create_job_for_employee(current_setting('test.emp')::uuid, pg_temp.k(42), pg_temp.d0() - 7, 'OT', '07:00', null, '15:00', 1, 'note ok'); assert false, 'propriétaire sans aal2 crée';
  exception when sqlstate '42501' then null; end;
end $$;

-- ── D. Soumettre la fiche d'urgence ─────────────────────────────────────────
select pg_temp.as_user(current_setting('test.own')::uuid, 'aal2');
do $$
declare c1 uuid := current_setting('test.c1')::uuid; r record; n integer;
begin
  perform public.submit_manager_entry_for_employee(c1);
  select * into r from public.jobs where id = c1; assert r.status = 'submitted', 'fiche d''urgence soumise';
  perform public.submit_manager_entry_for_employee(c1);
  begin perform public.submit_manager_entry_for_employee(current_setting('test.a1')::uuid); assert false, 'fiche de l''employé soumise par le propriétaire';
  exception when sqlstate 'P0002' then if sqlerrm <> 'manager_entry_not_found' then raise; end if; end;
end $$;
reset role;
do $$ declare n integer; begin
  select count(*) into n from public.employee_notices where job_id = current_setting('test.c1')::uuid and kind = 'job_submitted_by_owner'; assert n = 1, 'un seul avis malgré la relance';
  select count(*) into n from public.audit_log where job_id = current_setting('test.c1')::uuid and action = 'job_submitted_by_owner'; assert n = 1, 'un seul audit malgré la relance';
  assert (select locked from public.jobs where id = current_setting('test.c1')::uuid), 'soumise = verrouillée';
end $$;

-- ── B. L'employé confirme une fiche créée par un gestionnaire ───────────────
set role authenticated;
select pg_temp.as_user(current_setting('test.emp')::uuid, 'aal1');
do $$
declare c3 uuid := current_setting('test.c3')::uuid; d0 date := pg_temp.d0(); r record;
begin
  begin perform * from pg_temp.sj(c3, pg_temp.k(31), true, d0 - 10, '07:00', '15:00', 3, 3, 0); assert false, 'soumission sans confirmation';
  exception when sqlstate '55000' then if sqlerrm <> 'manager_entry_confirmation_required' then raise; end if; end;
  select * into r from pg_temp.sj(c3, pg_temp.k(31), false, d0 - 10, '07:00', '15:00', 3, 3, 0);
  assert r.status = 'updated', 'modifier sans soumettre : permis';
  select * into r from pg_temp.sj(c3, pg_temp.k(31), true, d0 - 10, '07:00', '15:00', 3, 3, 0, true);
  assert r.status = 'submitted', 'soumission avec confirmation';
  assert (select employee_confirmed_at from public.jobs where id = c3) is not null, 'confirmation horodatée';
end $$;
reset role;
do $$ begin
  assert exists (select 1 from public.audit_log where job_id = current_setting('test.c3')::uuid and action = 'manager_entry_confirmed' and actor_number = 3005), 'audit de la confirmation';
end $$;

-- ── E. Retourner pour correction ────────────────────────────────────────────
set role authenticated;
select pg_temp.as_user(current_setting('test.emp')::uuid, 'aal1');
do $$ begin
  begin perform * from public.return_job_for_correction(current_setting('test.a2')::uuid, now()); assert false, 'employé retourne';
  exception when sqlstate '42501' then null; end;
end $$;
select pg_temp.as_user(current_setting('test.mgr')::uuid, 'aal1');
do $$ begin
  begin perform * from public.return_job_for_correction(current_setting('test.a2')::uuid, now()); assert false, 'gestionnaire sans aal2 retourne';
  exception when sqlstate '42501' then null; end;
end $$;
select pg_temp.as_user(current_setting('test.mgr')::uuid, 'aal2');
do $$
declare a2 uuid := current_setting('test.a2')::uuid; ts timestamptz; r record;
begin
  select updated_at into ts from public.jobs where id = a2;
  begin perform * from public.return_job_for_correction(a2, ts - interval '1 second'); assert false, 'version périmée acceptée';
  exception when sqlstate '40001' then if sqlerrm <> 'job_state_changed' then raise; end if; end;
  begin perform * from public.return_job_for_correction(a2, null); assert false, 'version absente acceptée';
  exception when sqlstate '40001' then null; end;
  select * into r from public.return_job_for_correction(a2, ts);
  assert r.status = 'updated' and not r.locked, 'retournée : updated + déverrouillée';
  begin perform * from public.return_job_for_correction(a2, ts); assert false, 'double retour';
  exception when sqlstate '40001' then null; end;
  begin perform * from public.return_job_for_correction(gen_random_uuid(), now()); assert false, 'fiche inconnue';
  exception when sqlstate 'P0002' then null; end;
end $$;
select pg_temp.as_user(current_setting('test.emp')::uuid, 'aal1');
do $$ declare r record; begin
  select * into r from pg_temp.sj(current_setting('test.a2')::uuid, pg_temp.k(2), false, pg_temp.d0() - 2, '07:30', '15:00', 10, 6, 4);
  assert r.status = 'updated', 'la fiche retournée est de nouveau modifiable';
  select * into r from pg_temp.sj(current_setting('test.a2')::uuid, pg_temp.k(2), true, pg_temp.d0() - 2, '07:30', '15:00', 10, 6, 4);
  assert r.status = 'submitted', 'et peut être soumise à nouveau';
end $$;
reset role;
do $$ begin
  assert (select count(*) from public.employee_notices where job_id = current_setting('test.a2')::uuid and kind = 'job_returned' and user_id = current_setting('test.emp')::uuid) = 1, 'avis de retour';
  assert exists (select 1 from public.audit_log where job_id = current_setting('test.a2')::uuid and action = 'job_returned_for_correction' and actor_number = 3002 and target_number = 3005), 'audit du retour';
end $$;

-- ── F. Approuver (clé de service seulement) ─────────────────────────────────
set role authenticated;
select pg_temp.as_user(current_setting('test.mgr')::uuid, 'aal2');
do $$ begin
  begin perform * from public.approve_jobs('[]'::jsonb); assert false, 'gestionnaire approuve';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
select set_config('test.a1ts', updated_at::text, false) from public.jobs where id = current_setting('test.a1')::uuid;
select set_config('test.c1ts', updated_at::text, false) from public.jobs where id = current_setting('test.c1')::uuid;
select set_config('test.savedid', id::text, false) from public.jobs where user_id = current_setting('test.emp')::uuid and status in ('saved', 'updated') limit 1;
set role service_role;
select pg_temp.no_user();
do $$
declare a1 uuid := current_setting('test.a1')::uuid; c1 uuid := current_setting('test.c1')::uuid; r record; saved_id uuid;
begin
  saved_id := nullif(current_setting('test.savedid', true), '')::uuid;
  assert saved_id is not null, 'fiche non soumise disponible pour le test';
  for r in select * from public.approve_jobs(jsonb_build_array(
      jsonb_build_object('id', a1, 'expected_updated_at', current_setting('test.a1ts')),
      jsonb_build_object('id', c1, 'expected_updated_at', (current_setting('test.c1ts')::timestamptz - interval '1 second')),
      jsonb_build_object('id', gen_random_uuid(), 'expected_updated_at', now()),
      jsonb_build_object('id', saved_id, 'expected_updated_at', now()))) loop
    if r.job_id = a1 then assert r.result = 'approved', 'approuvée : ' || r.result;
    elsif r.job_id = c1 then assert r.result = 'conflict', 'version périmée : ' || r.result;
    elsif r.job_id = saved_id then assert r.result = 'not_submitted', 'non soumise : ' || r.result;
    else assert r.result = 'not_found', 'inconnue : ' || r.result; end if;
  end loop;
  assert (select result from public.approve_jobs(jsonb_build_array(jsonb_build_object('id', a1, 'expected_updated_at', current_setting('test.a1ts'))))) = 'already_approved', 'déjà approuvée';
  assert (select result from public.approve_jobs(jsonb_build_array(jsonb_build_object('id', c1, 'expected_updated_at', current_setting('test.c1ts'))))) = 'approved', 'approuvée avec la bonne version';
  begin perform * from public.approve_jobs('{}'::jsonb); assert false, 'lot invalide'; exception when sqlstate '22023' then null; end;
end $$;
reset role;
do $$ begin
  assert (select status from public.jobs where id = current_setting('test.a1')::uuid) = 'approved', 'a1 approuvée';
  assert exists (select 1 from public.audit_log where job_id = current_setting('test.a1')::uuid and action = 'job_approved' and actor_id is null and target_number = 3005), 'audit de l''approbation (acteur : le service)';
end $$;
set role authenticated;
select pg_temp.as_user(current_setting('test.emp')::uuid, 'aal1');
do $$ begin
  begin perform * from pg_temp.sj(current_setting('test.a1')::uuid, pg_temp.k(1), false, pg_temp.d0() - 1, '07:00', '15:00'); assert false, 'fiche approuvée modifiable';
  exception when sqlstate '55000' then null; end;
end $$;
select pg_temp.as_user(current_setting('test.mgr')::uuid, 'aal2');
do $$ begin
  begin perform * from public.return_job_for_correction(current_setting('test.a1')::uuid, now()); assert false, 'fiche approuvée retournée';
  exception when sqlstate '40001' then null; end;
end $$;
reset role;

-- ── G. Journal d'audit : sans nom, non modifiable ───────────────────────────
do $$
declare n integer;
begin
  assert not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'audit_log' and column_name ~ '(name|email|phone|note)'), 'aucune colonne nominative';
  begin update public.audit_log set action = 'x_x_x'; assert false, 'audit modifiable'; exception when sqlstate '42501' then if sqlerrm <> 'audit_log_immutable' then raise; end if; end;
  begin delete from public.audit_log; assert false, 'audit supprimable'; exception when sqlstate '42501' then null; end;
  begin insert into public.audit_log (action, details) values ('test_action', '{"note": "Jean"}'); assert false, 'clé libre acceptée';
  exception when sqlstate '23514' then if sqlerrm not like 'audit_details_key_not_allowed%' then raise; end if; end;
  begin insert into public.audit_log (action, details) values ('test_action', '[]'); assert false, 'détails non objet';
  exception when sqlstate '23514' then null; end;
  insert into public.audit_log (action, details) values ('test_action', '{"count": 3, "reason_code": "oubli"}');
end $$;
set role authenticated;
select pg_temp.as_user(current_setting('test.emp')::uuid, 'aal1');
do $$ begin
  assert (select count(*) from public.audit_log) = 0, 'un employé ne lit aucun audit';
  begin perform public.write_audit(null, 'faux_audit', null, null); assert false, 'authenticated écrit un audit'; exception when insufficient_privilege then null; end;
  begin insert into public.audit_log (action) values ('faux_audit'); assert false, 'insertion directe'; exception when insufficient_privilege then null; end;
end $$;
select pg_temp.as_user(current_setting('test.mgr')::uuid, 'aal2');
do $$ begin assert (select count(*) from public.audit_log) > 5, 'un gestionnaire aal2 lit l''audit'; end $$;

-- ── H. Avis à l'employé ─────────────────────────────────────────────────────
select pg_temp.as_user(current_setting('test.emp')::uuid, 'aal1');
do $$ declare n integer; begin
  assert (select count(*) from public.employee_notices) >= 3, 'l''employé voit ses avis';
  assert not exists (select 1 from public.employee_notices where user_id <> current_setting('test.emp')::uuid), 'et seulement les siens';
  update public.employee_notices set read_at = now() where read_at is null; get diagnostics n = row_count; assert n >= 3, 'marquer comme lu';
  begin update public.employee_notices set kind = 'job_returned'; assert false, 'colonne autre que read_at modifiée'; exception when insufficient_privilege then null; end;
  begin insert into public.employee_notices (user_id, kind) values (current_setting('test.emp')::uuid, 'job_returned'); assert false, 'avis fabriqué'; exception when insufficient_privilege then null; end;
end $$;
select pg_temp.as_user(current_setting('test.emp2')::uuid, 'aal1');
do $$ begin assert (select count(*) from public.employee_notices) = 0, 'un autre employé ne voit rien'; end $$;
reset role;
select 'OK : migration 0005' as resultat;
