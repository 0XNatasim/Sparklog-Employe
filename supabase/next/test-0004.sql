-- Test de la migration 0004 : fiche de temps, instants de Montréal, contrat de soumission, accès (voir scripts/test-next-schema.sh).
\set ON_ERROR_STOP on
create function pg_temp.as_user(p_id uuid, p_aal text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_id, 'aal', p_aal)::text, false);
end $$;
select set_config('request.jwt.claims', '', false);
select set_config('test.emp', id::text, false) from public.profiles where employee_number = 3005;
select set_config('test.mgr', id::text, false) from public.profiles where employee_number = 3002;
select set_config('test.pau', id::text, false) from public.profiles where employee_number = 3008;
select set_config('test.frm', id::text, false) from public.profiles where employee_number = 3006;

-- ── Fuseau, changement d'heure, nuit (en tant que service : sans session) ───
do $$
declare emp uuid := current_setting('test.emp')::uuid; j public.jobs; ok boolean;
begin
  -- hiver (UTC-5) : 07:00 → 15:30 le 2026-11-02 = 12:00Z → 20:30Z
  insert into public.jobs (user_id, job_date, ot, depart, arrivee, fin) values (emp, '2026-11-02', 'OT 123', '07:00', '08:00', '15:30') returning * into j;
  assert j.started_at = '2026-11-02 12:00:00+00' and j.ended_at = '2026-11-02 20:30:00+00', 'heure d''hiver : ' || j.started_at || ' / ' || j.ended_at;
  -- été (UTC-4)
  insert into public.jobs (user_id, job_date, depart, fin) values (emp, '2026-07-06', '07:00', '15:00') returning * into j;
  assert j.started_at = '2026-07-06 11:00:00+00', 'heure d''été : ' || j.started_at;
  -- nuit : fin <= départ = lendemain
  insert into public.jobs (user_id, job_date, depart, fin) values (emp, '2026-07-07', '22:00', '02:00') returning * into j;
  assert j.ended_at - j.started_at = interval '4 hours', 'travail de nuit : 4 h';
  -- sans fin : pas d'instants
  insert into public.jobs (user_id, job_date, depart) values (emp, '2026-07-08', '07:00') returning * into j;
  assert j.started_at is null and j.ended_at is null, 'fiche incomplète sans instants';
  -- printemps : 02:30 le 2026-03-08 n'existe pas
  begin insert into public.jobs (user_id, job_date, depart, fin) values (emp, '2026-03-08', '02:30', '09:00'); assert false, 'heure inexistante acceptée';
  exception when sqlstate '22007' then if sqlerrm <> 'nonexistent_montreal_local_time' then raise; end if; end;
  -- automne : 01:30 le 2026-11-01 existe deux fois : choix obligatoire
  begin insert into public.jobs (user_id, job_date, depart, fin) values (emp, '2026-11-01', '01:30', '09:00'); assert false, 'heure ambiguë acceptée';
  exception when sqlstate '22007' then if sqlerrm <> 'ambiguous_montreal_local_time' then raise; end if; end;
  insert into public.jobs (user_id, job_date, depart, fin, depart_fold) values (emp, '2026-11-01', '01:30', '09:00', 1) returning * into j;
  assert j.started_at = '2026-11-01 05:30:00+00', '1re 01:30 = 05:30Z : ' || j.started_at;
  insert into public.jobs (user_id, job_date, depart, fin, depart_fold) values (emp, '2026-11-01', '01:30', '09:00', 2) returning * into j;
  assert j.started_at = '2026-11-01 06:30:00+00', '2e 01:30 = 06:30Z : ' || j.started_at;
  -- un choix hors de l'heure répétée est effacé
  insert into public.jobs (user_id, job_date, depart, fin, depart_fold) values (emp, '2026-07-09', '07:00', '15:00', 1) returning * into j;
  assert j.depart_fold is null, 'choix inutile effacé';
end $$;

-- ── Contraintes de colonnes ─────────────────────────────────────────────────
do $$
declare emp uuid := current_setting('test.emp')::uuid; m integer;
begin
  foreach m in array array[0, 5, 10, 120, 235, 240] loop
    insert into public.jobs (user_id, job_date, depart, fin, return_time_minutes) values (emp, '2026-08-03', '07:00', '15:00', m);
  end loop;
  foreach m in array array[1, 7, 245, 300, -5] loop
    begin insert into public.jobs (user_id, job_date, depart, fin, return_time_minutes) values (emp, '2026-08-04', '07:00', '15:00', m);
      assert false, 'retour accepté : ' || m;
    exception when check_violation then null; end;
  end loop;
  begin insert into public.jobs (user_id, job_date, status) values (emp, '2026-08-05', 'brouillon'); assert false, 'statut libre'; exception when check_violation then null; end;
  begin insert into public.jobs (user_id, job_date, km_total) values (emp, '2026-08-05', -1); assert false, 'km négatifs'; exception when check_violation then null; end;
  insert into public.jobs (user_id, job_date, submission_key) values (emp, '2026-08-06', 'aaaaaaaa-0000-4000-8000-000000000001');
  begin insert into public.jobs (user_id, job_date, submission_key) values (emp, '2026-08-06', 'aaaaaaaa-0000-4000-8000-000000000001'); assert false, 'clé de soumission en double'; exception when unique_violation then null; end;
  insert into public.jobs (user_id, job_date) values (emp, '2026-08-07'), (emp, '2026-08-07');  -- deux fiches sans clé : permis
end $$;

-- ── Contrat de soumission ───────────────────────────────────────────────────
do $$
declare emp uuid := current_setting('test.emp')::uuid; a uuid; b uuid; code text;
  function_ok boolean;
begin
  insert into public.jobs (user_id, job_date, depart, fin, km_aller, km_retour, km_total, status)
    values (emp, '2026-09-01', '07:00', '15:00', 10, 5, 15, 'submitted') returning id into a;     -- valide
  -- chevauchement avec une fiche soumise
  begin insert into public.jobs (user_id, job_date, depart, fin, status) values (emp, '2026-09-01', '14:00', '16:00', 'submitted'); assert false, 'chevauchement accepté';
  exception when sqlstate '23P01' then null; end;
  -- juste après la fin : permis ; une fiche seulement « saved » qui chevauche : permis (la règle vise les soumises)
  insert into public.jobs (user_id, job_date, depart, fin, status) values (emp, '2026-09-01', '15:00', '16:00', 'submitted');
  insert into public.jobs (user_id, job_date, depart, fin, status) values (emp, '2026-09-01', '08:00', '09:00', 'saved');
  -- intervalle invalide : sans heures, de 0 minute (départ = fin → 24 h), au-delà de 16 h
  for code in select unnest(array['sans', 'zero', 'long']) loop
    begin
      if code = 'sans' then insert into public.jobs (user_id, job_date, status) values (emp, '2026-09-02', 'submitted');
      elsif code = 'zero' then insert into public.jobs (user_id, job_date, depart, fin, status) values (emp, '2026-09-02', '06:30', '06:30', 'submitted');
      else insert into public.jobs (user_id, job_date, depart, fin, status) values (emp, '2026-09-02', '04:00', '21:00', 'submitted'); end if;
      assert false, 'intervalle invalide accepté : ' || code;
    exception when sqlstate '23514' then if sqlerrm <> 'invalid_job_interval' then raise; end if; end;
  end loop;
  insert into public.jobs (user_id, job_date, depart, fin, status) values (emp, '2026-09-03', '04:00', '20:00', 'submitted');   -- exactement 16 h : permis
  -- retour plus long que la fiche
  begin insert into public.jobs (user_id, job_date, depart, fin, return_time_minutes, status) values (emp, '2026-09-04', '07:00', '08:00', 65, 'submitted'); assert false, 'retour > fiche';
  exception when sqlstate '23514' then if sqlerrm <> 'return_time_exceeds_job_interval' then raise; end if; end;
  insert into public.jobs (user_id, job_date, depart, fin, return_time_minutes, status) values (emp, '2026-09-04', '07:00', '08:00', 60, 'submitted');  -- égal : permis
  -- kilomètres incohérents
  begin insert into public.jobs (user_id, job_date, depart, fin, km_aller, km_retour, km_total, status) values (emp, '2026-09-05', '07:00', '15:00', 10, 5, 20, 'submitted'); assert false, 'km incohérents';
  exception when sqlstate '23514' then if sqlerrm <> 'invalid_job_kilometres' then raise; end if; end;
  begin insert into public.jobs (user_id, job_date, depart, fin, km_aller, km_retour, km_total, status) values (emp, '2026-09-05', '07:00', '15:00', 10, 12, 12, 'submitted'); assert false, 'retour > total';
  exception when sqlstate '23514' then if sqlerrm <> 'invalid_job_kilometres' then raise; end if; end;
  -- passer une fiche saved à submitted passe par la même validation
  insert into public.jobs (user_id, job_date, depart, fin, km_aller, km_retour, km_total) values (emp, '2026-09-06', '07:00', '15:00', 1, 1, 5) returning id into b;
  begin update public.jobs set status = 'submitted' where id = b; assert false, 'soumission invalide par mise à jour';
  exception when sqlstate '23514' then null; end;
  update public.jobs set km_total = 2, status = 'submitted' where id = b;
  -- une fiche approuvée n'est plus revalidée
  update public.jobs set status = 'approved' where id = b;
end $$;

-- ── Accès par rôle ──────────────────────────────────────────────────────────
set role authenticated;
select pg_temp.as_user(current_setting('test.emp')::uuid, 'aal1');
do $$
declare emp uuid := current_setting('test.emp')::uuid; own integer; n integer; id1 uuid; d date := current_date;
begin
  select count(*) into own from public.jobs; assert own > 0 and not exists (select 1 from public.jobs where user_id <> emp), 'un employé ne lit que ses fiches';
  -- insertion d'aujourd'hui : permise (échéance 23:59), mais seulement saved et pour soi
  insert into public.jobs (user_id, job_date, depart, fin) values (emp, d, '07:00', '09:00') returning id into id1;
  begin insert into public.jobs (user_id, job_date, depart, fin, status) values (emp, d, '10:00', '11:00', 'submitted'); assert false, 'employé insère une fiche soumise'; exception when insufficient_privilege then null; end;
  begin insert into public.jobs (user_id, job_date) values (current_setting('test.mgr')::uuid, d); assert false, 'employé écrit pour un autre'; exception when insufficient_privilege then null; end;
  begin insert into public.jobs (user_id, job_date, exported_to_sheet) values (emp, d, true); assert false, 'employé pose l''export'; exception when others then if sqlerrm like 'employé%' then raise; end if; end;
  -- mise à jour : permise en saved / updated, pas vers submitted ou approved
  update public.jobs set ot = 'OT 456' where id = id1; get diagnostics n = row_count; assert n = 1, 'employé modifie sa fiche';
  begin update public.jobs set status = 'submitted' where id = id1; assert false, 'employé soumet par mise à jour directe'; exception when insufficient_privilege then null; end;
  begin update public.jobs set status = 'approved' where id = id1; assert false, 'employé approuve'; exception when insufficient_privilege or others then if sqlerrm like 'employé%' then raise; end if; end;
  -- champs de saisie de gestionnaire protégés
  begin update public.jobs set manager_entry_note = 'x' where id = id1; assert false, 'employé écrit un champ de gestionnaire'; exception when insufficient_privilege then null; end;
  -- heure répétée : choix réservé au gestionnaire
  begin update public.jobs set depart_fold = 1 where id = id1; assert false, 'employé choisit l''heure répétée'; exception when insufficient_privilege then null; end;
  -- une fiche soumise ne se modifie ni ne se supprime
  update public.jobs set ot = 'X' where user_id = emp and status = 'submitted'; get diagnostics n = row_count; assert n = 0, 'fiche soumise non modifiable';
  delete from public.jobs where user_id = emp and status = 'submitted'; get diagnostics n = row_count; assert n = 0, 'fiche soumise non supprimable';
  delete from public.jobs where id = id1; get diagnostics n = row_count; assert n = 1, 'brouillon supprimable';
  -- échéance dépassée / férié : refus ; journée déverrouillée : permis (voir plus bas pour le déverrouillage)
  begin insert into public.jobs (user_id, job_date) values (emp, d - 5); assert false, 'saisie après l''échéance'; exception when others then if sqlerrm like 'saisie%' then raise; end if; end;
  begin insert into public.jobs (user_id, job_date) values (emp, '2026-12-25'); assert false, 'saisie un jour férié'; exception when others then if sqlerrm like 'saisie%' then raise; end if; end;
  begin insert into public.job_entry_unlocks (user_id, job_date) values (emp, d - 5); assert false, 'employé se déverrouille'; exception when insufficient_privilege then null; end;
end $$;

select pg_temp.as_user(current_setting('test.pau')::uuid, 'aal1');
do $$ begin
  begin insert into public.jobs (user_id, job_date) values (current_setting('test.pau')::uuid, current_date); assert false, 'employé en pause écrit';
  exception when insufficient_privilege then null; end;
end $$;

select pg_temp.as_user(current_setting('test.mgr')::uuid, 'aal1');
do $$ begin assert (select count(*) from public.jobs) = 0, 'gestionnaire sans aal2 : aucune fiche'; end $$;

select pg_temp.as_user(current_setting('test.mgr')::uuid, 'aal2');
do $$
declare emp uuid := current_setting('test.emp')::uuid; n integer; id1 uuid;
begin
  assert (select count(*) from public.jobs where user_id = emp) > 5, 'gestionnaire aal2 lit les fiches';
  -- déverrouiller une journée passée, puis l'employé peut saisir
  insert into public.job_entry_unlocks (user_id, job_date, reason) values (emp, current_date - 5, 'oubli');
  assert (select created_by from public.job_entry_unlocks where job_date = current_date - 5) = current_setting('test.mgr')::uuid, 'créateur du déverrouillage';
  select id into id1 from public.jobs where user_id = emp and status = 'approved' limit 1;
  update public.jobs set status = 'updated' where id = id1; get diagnostics n = row_count; assert n = 0, 'gestionnaire ne réécrit pas une fiche approuvée (aucune politique de mise à jour)';
end $$;
select pg_temp.as_user(current_setting('test.emp')::uuid, 'aal1');
do $$ begin insert into public.jobs (user_id, job_date) values (current_setting('test.emp')::uuid, current_date - 5); end $$;
reset role;
select 'OK : migration 0004' as resultat;
