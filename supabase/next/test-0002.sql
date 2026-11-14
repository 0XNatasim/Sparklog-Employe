-- Test de la migration 0002 (voir scripts/test-next-schema.sh).
\set ON_ERROR_STOP on
create function pg_temp.as_user(p_id uuid, p_aal text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_id, 'aal', p_aal)::text, false);
end $$;

do $$
declare
  own uuid := gen_random_uuid(); mgr uuid := gen_random_uuid(); adm0 uuid := gen_random_uuid(); adm1 uuid := gen_random_uuid();
  emp uuid := gen_random_uuid(); frm uuid := gen_random_uuid(); sub uuid := gen_random_uuid(); pau uuid := gen_random_uuid();
begin
  insert into auth.users (id, email) select x, x || '@pointage.invalid' from unnest(array[own, mgr, adm0, adm1, emp, frm, sub, pau]) x;
  insert into public.profiles (id, employee_number, role, admin_sections, is_paused) values
    (own, 3001, 'owner', '{}', false), (mgr, 3002, 'manager', '{}', false),
    (adm0, 3003, 'admin', '{}', false), (adm1, 3004, 'admin', '{timesheet}', false),
    (emp, 3005, 'employee', '{}', false), (frm, 3006, 'foreman', '{}', false),
    (sub, 3007, 'subcontractor_1', '{}', false), (pau, 3008, 'employee', '{}', true);

  -- rôle effectif selon aal1 / aal2
  perform pg_temp.as_user(own, 'aal1'); assert public.get_my_role() = 'employee', 'owner sans aal2';  assert not public.is_privileged(), 'owner sans aal2 non privilégié';
  perform pg_temp.as_user(own, 'aal2'); assert public.get_my_role() = 'manager',  'owner aal2';       assert public.is_privileged(), 'owner aal2 privilégié';
  perform pg_temp.as_user(mgr, 'aal2'); assert public.get_my_role() = 'manager',  'manager aal2';     assert not public.is_privileged(), 'manager jamais privilégié';
  perform pg_temp.as_user(mgr, 'aal1'); assert public.get_my_role() = 'employee', 'manager sans aal2';
  perform pg_temp.as_user(adm0, 'aal2'); assert public.get_my_role() = 'employee', 'admin sans section';
  perform pg_temp.as_user(adm1, 'aal2'); assert public.get_my_role() = 'manager',  'admin avec section, aal2';
  perform pg_temp.as_user(adm1, 'aal1'); assert public.get_my_role() = 'employee', 'admin avec section, sans aal2';
  perform pg_temp.as_user(emp, 'aal2');  assert public.get_my_role() = 'employee', 'employé';
  perform pg_temp.as_user(frm, 'aal2');  assert public.get_my_role() = 'employee', 'contremaître au niveau employé';
  perform pg_temp.as_user(sub, 'aal2');  assert public.get_my_role() = 'employee', 'sous-traitant au niveau employé';

  -- employé actif
  perform pg_temp.as_user(emp, 'aal1'); assert public.is_active_employee(), 'employé actif';
  perform pg_temp.as_user(frm, 'aal1'); assert public.is_active_employee(), 'contremaître actif';
  perform pg_temp.as_user(sub, 'aal1'); assert public.is_active_employee(), 'sous-traitant actif';
  perform pg_temp.as_user(pau, 'aal1'); assert not public.is_active_employee(), 'employé en pause non actif';
  perform pg_temp.as_user(mgr, 'aal2'); assert not public.is_active_employee(), 'gestionnaire non employé actif';
  perform pg_temp.as_user(gen_random_uuid(), 'aal2'); assert public.get_my_role() is null and not public.is_active_employee(), 'inconnu';
end $$;

-- lecture des profils selon le rôle (politiques RLS, session `authenticated`)
select set_config('test.emp', id::text, false) from public.profiles where employee_number = 3005;
select set_config('test.mgr', id::text, false) from public.profiles where employee_number = 3002;
select set_config('test.total', count(*)::text, false) from public.profiles;
set role authenticated;
select pg_temp.as_user(current_setting('test.emp')::uuid, 'aal1');
do $$ begin assert (select count(*) from public.profiles) = 1, 'un employé ne voit que son profil'; end $$;
select pg_temp.as_user(current_setting('test.mgr')::uuid, 'aal1');
do $$ begin assert (select count(*) from public.profiles) = 1, 'un gestionnaire sans aal2 ne voit que son profil'; end $$;
select pg_temp.as_user(current_setting('test.mgr')::uuid, 'aal2');
do $$ begin assert (select count(*) from public.profiles) = current_setting('test.total')::int, 'un gestionnaire aal2 voit tous les profils'; end $$;
-- aucune écriture par le navigateur, même pour un gestionnaire
do $$ begin
  begin update public.profiles set role = 'owner'; assert false, 'authenticated modifie un profil'; exception when insufficient_privilege then null; end;
  begin insert into public.profiles (id, employee_number) values (gen_random_uuid(), 5555); assert false, 'authenticated crée un profil'; exception when insufficient_privilege then null; end;
  begin delete from public.profiles; assert false, 'authenticated supprime un profil'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'OK : migration 0002' as resultat;
