-- Test de la migration 0010 : abonnements aux notifications (voir scripts/test-next-schema.sh).
\set ON_ERROR_STOP on
create function pg_temp.as_user(p_id uuid, p_aal text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_id, 'aal', p_aal)::text, false); end $$;
create function pg_temp.no_user() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '', false); end $$;
create function pg_temp.u(tag text) returns uuid language sql stable as $$ select current_setting('test.' || tag)::uuid $$;
create function pg_temp.ep(n integer) returns text language sql immutable as $$ select 'https://push.example.invalid/send/' || lpad(n::text, 12, '0') $$;
create function pg_temp.key(n integer) returns text language sql immutable as $$ select 'BPublicKey' || lpad(n::text, 30, 'x') $$;

select pg_temp.no_user();
select set_config('test.mgr', id::text, false) from public.profiles where employee_number = 3002;
select set_config('test.pau', id::text, false) from public.profiles where employee_number = 3008;
do $$
declare spec record; uid uuid;
begin
  for spec in select * from (values (3501, 'employee', 'p1'), (3502, 'employee', 'p2'), (3503, 'foreman', 'p3')) as t(num, role, tag) loop
    uid := gen_random_uuid();
    insert into auth.users (id, email) values (uid, spec.num || '@pointage.invalid');
    insert into public.profiles (id, employee_number, role) values (uid, spec.num, spec.role);
    perform set_config('test.' || spec.tag, uid::text, false);
  end loop;
end $$;

set role authenticated;
select pg_temp.as_user(pg_temp.u('p1'), 'aal1');
do $$
begin
  perform public.register_push_subscription(pg_temp.ep(1), pg_temp.key(1), 'authsecret1', 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0)');
  assert (select count(*) from public.push_subscriptions) = 1, 'abonnement enregistré';
  assert not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'push_subscriptions' and column_name in ('user_agent', 'device')), 'aucun appareil conservé';
  -- champs trop courts
  begin perform public.register_push_subscription('http://x', pg_temp.key(2), 'authsecret1'); assert false, 'adresse trop courte'; exception when check_violation then null; end;
  begin perform public.register_push_subscription(pg_temp.ep(2), 'court', 'authsecret1'); assert false, 'clé trop courte'; exception when check_violation then null; end;
  begin perform public.register_push_subscription(pg_temp.ep(2), pg_temp.key(2), 'court'); assert false, 'secret trop court'; exception when check_violation then null; end;
  begin perform public.register_push_subscription(repeat('h', 2049), pg_temp.key(2), 'authsecret1'); assert false, 'adresse trop longue'; exception when check_violation then null; end;
  -- une relance reprend la ligne (une seule par adresse)
  perform public.register_push_subscription(pg_temp.ep(1), pg_temp.key(9), 'authsecret9');
  assert (select count(*) from public.push_subscriptions) = 1 and (select p256dh from public.push_subscriptions) = pg_temp.key(9), 'relance : même ligne, clés remplacées';
  perform public.register_push_subscription(pg_temp.ep(3), pg_temp.key(3), 'authsecret3');
  assert (select count(*) from public.push_subscriptions) = 2, 'deuxième appareil du même employé';
  -- accès directs
  begin insert into public.push_subscriptions (user_id, endpoint, p256dh, auth) values (pg_temp.u('p1'), pg_temp.ep(4), pg_temp.key(4), 'authsecret4'); assert false, 'insertion directe'; exception when insufficient_privilege then null; end;
  begin update public.push_subscriptions set user_id = pg_temp.u('p2'); assert false, 'modification directe'; exception when insufficient_privilege then null; end;
end $$;
-- une relance remet la date « vu pour la dernière fois » à jour
reset role;
update public.push_subscriptions set last_seen_at = now() - interval '40 days' where endpoint = pg_temp.ep(1);
set role authenticated;
select pg_temp.as_user(pg_temp.u('p1'), 'aal1');
select public.register_push_subscription(pg_temp.ep(1), pg_temp.key(9), 'authsecret9');
reset role;
do $$ begin assert (select last_seen_at from public.push_subscriptions where endpoint = pg_temp.ep(1)) > now() - interval '1 minute', 'relance : last_seen_at remis à jour'; end $$;
set role authenticated;
-- un appareil qui change de compte reprend son abonnement
select pg_temp.as_user(pg_temp.u('p2'), 'aal1');
do $$ declare n integer; begin
  assert (select count(*) from public.push_subscriptions) = 0, 'un autre employé ne voit pas ces abonnements';
  perform public.register_push_subscription(pg_temp.ep(3), pg_temp.key(5), 'authsecret5');
  assert (select count(*) from public.push_subscriptions) = 1, 'l''appareil est passé au nouveau compte';
  delete from public.push_subscriptions where endpoint = pg_temp.ep(1); get diagnostics n = row_count; assert n = 0, 'on ne supprime pas l''abonnement d''un autre';
end $$;
select pg_temp.as_user(pg_temp.u('p1'), 'aal1');
do $$ declare n integer; begin
  assert (select count(*) from public.push_subscriptions) = 1, 'le premier employé n''a plus que son premier appareil';
  delete from public.push_subscriptions; get diagnostics n = row_count; assert n = 1, 'on supprime son propre abonnement';
  perform public.register_push_subscription(pg_temp.ep(1), pg_temp.key(1), 'authsecret1');
end $$;
-- employé en pause, gestionnaire, non connecté
select pg_temp.as_user(pg_temp.u('pau'), 'aal1');
do $$ begin begin perform public.register_push_subscription(pg_temp.ep(6), pg_temp.key(6), 'authsecret6'); assert false, 'employé en pause'; exception when sqlstate '42501' then if sqlerrm <> 'account_paused' then raise; end if; end; end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$ begin begin perform public.register_push_subscription(pg_temp.ep(7), pg_temp.key(7), 'authsecret7'); assert false, 'gestionnaire abonné'; exception when sqlstate '42501' then if sqlerrm <> 'account_paused' then raise; end if; end; end $$;
select pg_temp.no_user();
do $$ begin begin perform public.register_push_subscription(pg_temp.ep(8), pg_temp.key(8), 'authsecret8'); assert false, 'non connecté'; exception when sqlstate '42501' then if sqlerrm <> 'not_authenticated' then raise; end if; end; end $$;

-- qui a les notifications activées
select pg_temp.as_user(pg_temp.u('p3'), 'aal1');
do $$ begin perform public.register_push_subscription(pg_temp.ep(10), pg_temp.key(10), 'authsecret10'); end $$;
do $$ begin assert (select count(*) from public.push_enabled_users()) = 0, 'un employé ne voit pas qui est abonné'; end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal1');
do $$ begin
  assert (select count(*) from public.push_enabled_users()) = 0, 'gestionnaire sans aal2 : aucune liste';
  assert (select count(*) from public.push_subscriptions) = 0, 'le gestionnaire ne lit pas les abonnements (adresses)';
end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$ begin
  assert (select count(*) from public.push_enabled_users()) = 3 and (select array_agg(employee_number order by employee_number) from public.push_enabled_users()) = array[3501, 3502, 3503], 'liste des numéros abonnés';
  assert (select count(*) from public.push_subscriptions) = 0, 'même avec aal2, les adresses d''abonnement ne sont pas lisibles';
  begin perform public.purge_stale_push_subscriptions(30); assert false, 'gestionnaire purge'; exception when insufficient_privilege then null; end;
end $$;
reset role;

-- ménage des abonnements anciens (service seulement)
update public.push_subscriptions set last_seen_at = now() - interval '200 days' where endpoint = pg_temp.ep(10);
update public.push_subscriptions set last_seen_at = now() - interval '100 days' where endpoint = pg_temp.ep(1);
set role service_role;
select pg_temp.no_user();
do $$ declare n integer; begin
  begin perform public.purge_stale_push_subscriptions(3); assert false, 'délai trop court'; exception when sqlstate '22023' then null; end;
  n := public.purge_stale_push_subscriptions(180);
  assert n = 1, 'un abonnement de plus de 180 jours supprimé : ' || n;
  n := public.purge_stale_push_subscriptions(90);
  assert n = 1, 'puis celui de plus de 90 jours : ' || n;
end $$;
reset role;
do $$ begin assert (select count(*) from public.push_subscriptions) = 1, 'les abonnements récents restent'; end $$;
select 'OK : migration 0010' as resultat;
