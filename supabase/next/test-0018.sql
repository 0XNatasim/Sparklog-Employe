-- Test de la migration 0018 : plage 1 à 999999.
\set ON_ERROR_STOP on
do $$
declare cnt integer; u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); u3 uuid := gen_random_uuid();
begin
  select count(*) into cnt from pg_constraint where contype = 'c' and connamespace = 'public'::regnamespace and pg_get_constraintdef(oid) like '%1000%' and pg_get_constraintdef(oid) like '%999999%';
  assert cnt = 0, 'plus aucune ancienne borne : ' || cnt;
  select count(*) into cnt from pg_constraint where conname in ('profiles_employee_number_range', 'foreman_reports_audited_number_range');
  assert cnt = 2, 'nouvelles bornes';
  insert into auth.users (id, email) values (u1, '1@pointage.invalid'), (u2, '2@pointage.invalid'), (u3, '3@pointage.invalid');
  begin insert into public.profiles (id, employee_number, role) values (u1, 1, 'employee'); exception when check_violation then raise exception 'numéro 1 refusé : %', sqlerrm; end;
  begin insert into public.profiles (id, employee_number, role) values (u2, 0, 'employee'); assert false, '0 accepté';
  exception when check_violation then null; end;
  begin insert into public.profiles (id, employee_number, role) values (u3, 1000000, 'employee'); assert false, '1000000 accepté';
  exception when check_violation then null; end;
end $$;
select 'OK : migration 0018' as resultat;
