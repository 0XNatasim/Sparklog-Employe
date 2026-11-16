-- Sparklog-Employés (côté 1) — migration 0019 : suppression d'un compte demandée par le côté 2 (action `delete_account`).
-- Comme l'ancien `delete_user` de Sparklog : seulement pour nettoyer une erreur (doublon, mauvais numéro, test), JAMAIS pour un employé qui a des fiches
-- (on le met alors en pause, côté 2). Deux étapes, parce que le compte de connexion se supprime dans la fonction Edge (clé de service) :
--   1. `sync_delete_account_prepare(client, numéro)` : vérifie le client, refuse un compte de gestion et un compte qui a des fiches (409 `account_has_jobs`),
--      renvoie l'identifiant du compte (nul + `already` = déjà supprimé : l'action est rejouable) ;
--   2. la fonction Edge supprime le compte de connexion : le profil et tout ce qui lui appartient partent en cascade ;
--   3. `sync_delete_account_done(client, numéro)` écrit au journal (sans nom : le numéro seulement).
create function public.sync_delete_account_prepare(p_client uuid, p_number integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare prof public.profiles%rowtype;
begin
  perform public.sync_require_client(p_client);
  select * into prof from public.profiles where employee_number = p_number;
  if not found then return jsonb_build_object('user_id', null, 'already', true); end if;
  if prof.role not in ('employee', 'foreman', 'subcontractor_1', 'admin') then raise exception using errcode = '22023', message = 'role_not_supported'; end if;
  if exists (select 1 from public.jobs where user_id = prof.id) then raise exception using errcode = '40001', message = 'account_has_jobs'; end if;
  return jsonb_build_object('user_id', prof.id, 'already', false);
end;
$$;

create function public.sync_delete_account_done(p_client uuid, p_number integer)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.sync_require_client(p_client);
  insert into public.audit_log (actor_id, actor_number, action, target_user_id, target_number, job_id, details)
  values (null, null, 'account_deleted', null, p_number, null, '{}'::jsonb);
end;
$$;

revoke all on function public.sync_delete_account_prepare(uuid, integer), public.sync_delete_account_done(uuid, integer) from public, anon, authenticated;
grant execute on function public.sync_delete_account_prepare(uuid, integer), public.sync_delete_account_done(uuid, integer) to service_role;
