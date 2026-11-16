-- Test de la migration 0019 : suppression d'un compte (préparation + journal).
\set ON_ERROR_STOP on
create function pg_temp.u(tag text) returns uuid language sql stable as $$ select current_setting('test.' || tag)::uuid $$;
create function pg_temp.audits(p_action text) returns bigint language sql security definer as $$ select count(*) from public.audit_log where action = p_action $$;
do $$ declare a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); m uuid := gen_random_uuid(); begin
  insert into auth.users (id, email) values (a, '0501@pointage.invalid'), (b, '0502@pointage.invalid'), (m, '0503@pointage.invalid');
  insert into public.profiles (id, employee_number, role) values (a, 501, 'employee'), (b, 502, 'employee'), (m, 503, 'manager');
  insert into public.jobs (user_id, job_date, status) values (b, current_date, 'saved');
end $$;
set role service_role;
select set_config('test.client', (select id::text from public.sync_create_client('test 0019')), false);
do $$
declare c uuid := pg_temp.u('client'); r jsonb;
begin
  r := public.sync_delete_account_prepare(c, 501);
  assert r ->> 'already' = 'false' and (r ->> 'user_id') is not null, 'compte vide : suppression permise';
  r := public.sync_delete_account_prepare(c, 9999);
  assert r ->> 'already' = 'true' and (r ->> 'user_id') is null, 'inconnu = déjà supprimé (rejouable)';
  begin perform public.sync_delete_account_prepare(c, 502); assert false, 'compte avec fiche supprimé';
  exception when serialization_failure then if sqlerrm <> 'account_has_jobs' then raise; end if; end;
  begin perform public.sync_delete_account_prepare(c, 503); assert false, 'gestionnaire supprimé';
  exception when invalid_parameter_value then if sqlerrm <> 'role_not_supported' then raise; end if; end;
  begin perform public.sync_delete_account_prepare(gen_random_uuid(), 501); assert false, 'client inconnu';
  exception when invalid_authorization_specification then null; end;
  perform public.sync_delete_account_done(c, 501);
  assert pg_temp.audits('account_deleted') = 1, 'journal écrit';
end $$;
reset role;
-- le navigateur ne peut rien appeler
set role authenticated;
do $$ begin
  begin perform public.sync_delete_account_prepare(gen_random_uuid(), 501); assert false, 'authenticated';
  exception when insufficient_privilege then null; end;
  begin perform public.sync_delete_account_done(gen_random_uuid(), 501); assert false, 'authenticated done';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
-- supprimer le compte de connexion fait partir le profil
delete from auth.users where email = '0501@pointage.invalid';
do $$ begin assert not exists (select 1 from public.profiles where employee_number = 501), 'profil parti avec le compte'; end $$;
select 'OK : migration 0019' as resultat;
