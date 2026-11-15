-- Test de la migration 0016 : `upsert_group` avec identifiant choisi par le côté 2.
\set ON_ERROR_STOP on
create function pg_temp.u(tag text) returns uuid language sql stable as $$ select current_setting('test.' || tag)::uuid $$;
create function pg_temp.k(n integer) returns uuid language sql immutable as $$ select ('77777777-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;
-- lecture des résultats : fonction du propriétaire du banc (la RLS cache les tables à service_role)
create function pg_temp.g(p_id uuid) returns public.employee_groups language sql security definer as $$ select * from public.employee_groups where id = p_id $$;
create function pg_temp.gcount(p_id uuid) returns bigint language sql security definer as $$ select count(*) from public.employee_groups where id = p_id $$;
set role service_role;
select set_config('test.client', (select id::text from public.sync_create_client('test 0016')), false);
do $$
declare c uuid := pg_temp.u('client'); r jsonb; g1 uuid := pg_temp.k(500); g2 uuid := pg_temp.k(501); n integer;
begin
  -- création avec l'identifiant donné
  r := public.apply_sync_action(c, pg_temp.k(1), 'upsert_group', jsonb_build_object('id', g1, 'name', 'Entrepôt Nord', 'note', 'Équipe A', 'low_stock_alert', true));
  assert (r ->> 'group_id')::uuid = g1, 'identifiant rendu = celui du côté 2';
  assert (select name = 'Entrepôt Nord' and note = 'Équipe A' and low_stock_alert from pg_temp.g(g1)), 'groupe créé';
  -- rejeu de la même action : même résultat, un seul groupe
  r := public.apply_sync_action(c, pg_temp.k(1), 'upsert_group', jsonb_build_object('id', g1, 'name', 'Entrepôt Nord', 'note', 'Équipe A', 'low_stock_alert', true));
  assert (r ->> 'replayed')::boolean is true or (r ->> 'group_id')::uuid = g1, 'rejeu';
  n := pg_temp.gcount(g1); assert n = 1, 'un seul groupe';
  -- renommage et changement de la note, même identifiant
  r := public.apply_sync_action(c, pg_temp.k(2), 'upsert_group', jsonb_build_object('id', g1, 'name', 'Entrepôt Nord-Est', 'note', null, 'low_stock_alert', false));
  assert (select name = 'Entrepôt Nord-Est' and note is null and not low_stock_alert from pg_temp.g(g1)), 'renommé, note effacée, alerte retirée';
  -- un nom déjà pris par un AUTRE groupe est refusé, la casse et les espaces ne comptent pas
  perform public.apply_sync_action(c, pg_temp.k(3), 'upsert_group', jsonb_build_object('id', g2, 'name', 'Entrepôt Sud'));
  begin perform public.apply_sync_action(c, pg_temp.k(4), 'upsert_group', jsonb_build_object('id', g2, 'name', '  ENTREPÔT nord-est ')); assert false, 'nom pris';
  exception when unique_violation then if sqlerrm <> 'group_name_taken' then raise; end if; end;
  assert (select name from pg_temp.g(g2)) = 'Entrepôt Sud', 'le refus ne change rien';
  -- son propre nom, autrement écrit : permis
  perform public.apply_sync_action(c, pg_temp.k(5), 'upsert_group', jsonb_build_object('id', g2, 'name', ' ENTREPÔT SUD '));
  assert (select name from pg_temp.g(g2)) = 'ENTREPÔT SUD', 'même groupe, autre écriture';
  -- charges refusées
  begin perform public.apply_sync_action(c, pg_temp.k(6), 'upsert_group', jsonb_build_object('id', g1, 'name', '   ')); assert false, 'nom vide';
  exception when sqlstate '22023' then null; end;
  begin perform public.apply_sync_action(c, pg_temp.k(7), 'upsert_group', '{"id": "pas-un-uuid", "name": "x"}'); assert false, 'identifiant invalide';
  exception when invalid_text_representation then null; end;
  -- sans identifiant : comportement de la 0015 (recherche par nom)
  r := public.apply_sync_action(c, pg_temp.k(8), 'upsert_group', '{"name": "entrepôt sud", "low_stock_alert": true}');
  assert (r ->> 'group_id')::uuid = g2 and (select low_stock_alert from pg_temp.g(g2)), 'sans id : trouvé par le nom';
  -- les membres s'ajoutent au groupe créé avec l'identifiant donné
  r := public.apply_sync_action(c, pg_temp.k(9), 'set_group_members', jsonb_build_object('group_id', g1, 'add', '[]'::jsonb));
  assert (r ->> 'group_id')::uuid = g1, 'groupe connu des membres';
end $$;
reset role;
select 'OK : migration 0016' as resultat;
