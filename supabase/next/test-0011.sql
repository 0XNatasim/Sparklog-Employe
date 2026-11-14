-- Test de la migration 0011 : annonces publiées par le côté 2 (voir scripts/test-next-schema.sh).
\set ON_ERROR_STOP on
create function pg_temp.as_user(p_id uuid, p_aal text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_id, 'aal', p_aal)::text, false); end $$;
create function pg_temp.no_user() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '', false); end $$;
create function pg_temp.u(tag text) returns uuid language sql stable as $$ select current_setting('test.' || tag)::uuid $$;
create function pg_temp.k(n integer) returns uuid language sql immutable as $$ select ('ffffffff-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;

select pg_temp.no_user();
select set_config('test.mgr', id::text, false) from public.profiles where employee_number = 3002;
do $$
declare spec record; uid uuid; gid uuid;
begin
  for spec in select * from (values (3601, 'employee', false, 'a1'), (3602, 'employee', false, 'a2'), (3603, 'foreman', false, 'a3'),
                                    (3604, 'admin', false, 'a4'), (3605, 'employee', true, 'a5'), (3606, 'employee', false, 'a6')) as t(num, role, paused, tag) loop
    uid := gen_random_uuid();
    insert into auth.users (id, email) values (uid, spec.num || '@pointage.invalid');
    insert into public.profiles (id, employee_number, role, is_paused) values (uid, spec.num, spec.role, spec.paused);
    perform set_config('test.' || spec.tag, uid::text, false);
  end loop;
  insert into public.employee_groups (name) values ('Groupe annonces') returning id into gid;
  perform set_config('test.grp', gid::text, false);
  insert into public.employee_group_members (group_id, user_id) values (gid, pg_temp.u('a1')), (gid, pg_temp.u('a2')), (gid, pg_temp.u('a5')), (gid, pg_temp.u('mgr'));
end $$;

-- ── A. Publier (clé de service) ─────────────────────────────────────────────
set role service_role;
select pg_temp.no_user();
do $$
declare r record; r2 record;
begin
  -- audience « selected » : numéros ; les inconnus, les employés en pause et les doublons sont ignorés
  select * into r from public.publish_announcement(pg_temp.k(1), '  Réunion de sécurité lundi  ', 'selected', null, array[3601, 3601, 3605, 9999, 3603]);
  assert r.recipient_count = 2, 'selected : 3601 et 3603 seulement : ' || r.recipient_count;
  perform set_config('test.an1', r.id::text, false);
  -- relance avec la même clé : même annonce, mêmes destinataires, rien d'ajouté
  select * into r2 from public.publish_announcement(pg_temp.k(1), 'autre texte', 'all');
  assert r2.id = r.id and r2.recipient_count = 2, 'relance : même annonce';
  -- « groups » : les membres non en pause des groupes (le gestionnaire membre est ignoré : pas un rôle d'employé)
  select * into r from public.publish_announcement(pg_temp.k(2), 'Note pour le groupe', 'groups', array[pg_temp.u('grp')]);
  assert r.recipient_count = 2, 'groups : 3601 et 3602 : ' || r.recipient_count;
  perform set_config('test.an2', r.id::text, false);
  -- « all »
  select * into r from public.publish_announcement(pg_temp.k(3), 'Pour tout le monde', 'all');
  perform set_config('test.an3', r.id::text, false); perform set_config('test.an3n', r.recipient_count::text, false);
  -- refus
  begin perform * from public.publish_announcement(null, 'x', 'all'); assert false, 'clé absente'; exception when sqlstate '22023' then if sqlerrm <> 'action_key_required' then raise; end if; end;
  begin perform * from public.publish_announcement(pg_temp.k(4), 'x', 'tous'); assert false, 'audience libre'; exception when sqlstate '22023' then if sqlerrm <> 'announcement_audience_invalid' then raise; end if; end;
  begin perform * from public.publish_announcement(pg_temp.k(5), '   ', 'all'); assert false, 'annonce vide'; exception when sqlstate '22023' then if sqlerrm <> 'announcement_empty' then raise; end if; end;
  begin perform * from public.publish_announcement(pg_temp.k(6), repeat('x', 5001), 'all'); assert false, 'annonce trop longue'; exception when sqlstate '22023' then if sqlerrm <> 'announcement_too_long' then raise; end if; end;
  begin perform * from public.publish_announcement(pg_temp.k(7), 'x', 'selected', null, array[9999]); assert false, 'aucun destinataire'; exception when sqlstate '22023' then if sqlerrm <> 'announcement_no_recipients' then raise; end if; end;
  begin perform * from public.publish_announcement(pg_temp.k(8), 'x', 'selected', null, null); assert false, 'liste absente'; exception when sqlstate '22023' then null; end;
  begin perform * from public.publish_announcement(pg_temp.k(9), 'x', 'all', null, null, '[{"path": "../secret.jpg", "kind": "image"}]'); assert false, 'chemin de pièce jointe invalide'; exception when sqlstate '22023' then if sqlerrm <> 'announcement_attachments_invalid' then raise; end if; end;
  begin perform * from public.publish_announcement(pg_temp.k(10), 'x', 'all', null, null, '[{"path": "a1.jpg", "kind": "video"}]'); assert false, 'genre de pièce invalide'; exception when sqlstate '22023' then null; end;
  begin perform * from public.publish_announcement(pg_temp.k(11), 'x', 'all', null, null, (select jsonb_agg(jsonb_build_object('path', 'f' || g || '.jpg', 'kind', 'image')) from generate_series(1, 11) g)); assert false, 'plus de dix pièces'; exception when others then if sqlstate not in ('22023', '23514') then raise; end if; end;
  -- une pièce jointe seule suffit (texte vide)
  select * into r from public.publish_announcement(pg_temp.k(12), '', 'selected', null, array[3602], '[{"path": "11111111-1111-4111-8111-111111111111.pdf", "kind": "pdf", "name": "consignes"}]');
  perform set_config('test.an4', r.id::text, false);
end $$;
reset role;
do $$ declare n integer; expected integer; begin
  select count(*) into expected from public.profiles where role in ('employee', 'foreman', 'subcontractor_1', 'admin') and not is_paused;
  assert current_setting('test.an3n')::int = expected, 'all : tous les employés actifs (' || expected || ') : ' || current_setting('test.an3n');
  assert not exists (select 1 from public.announcement_recipients r join public.profiles p on p.id = r.employee_id where p.is_paused or p.role not in ('employee', 'foreman', 'subcontractor_1', 'admin')), 'ni employé en pause ni gestionnaire parmi les destinataires';
  assert not exists (select 1 from public.announcements where action_key in (pg_temp.k(4), pg_temp.k(5), pg_temp.k(6), pg_temp.k(7), pg_temp.k(9), pg_temp.k(10), pg_temp.k(11))), 'les refus ne laissent aucune annonce';
  select count(*) into n from public.announcements where action_key = pg_temp.k(1); assert n = 1, 'une seule annonce malgré la relance';
  assert (select body from public.announcements where id = pg_temp.u('an1')) = 'Réunion de sécurité lundi', 'texte nettoyé';
  assert exists (select 1 from public.audit_log where action = 'announcement_published' and actor_id is null and (details ->> 'count')::int = 2), 'audit de la publication, sans acteur ni texte';
  assert not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name in ('announcements', 'announcement_recipients', 'announcement_revisions') and column_name ~ '(name|email|phone|sender|edited_by)'), 'aucune colonne nominative ni expéditeur';
end $$;

-- ── B. Personne d'autre que le service ne publie, modifie ou retire ─────────
set role authenticated;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$ begin
  begin perform * from public.publish_announcement(pg_temp.k(20), 'x', 'all'); assert false, 'gestionnaire publie'; exception when insufficient_privilege then null; end;
  begin perform public.edit_announcement(pg_temp.u('an1'), now(), 'x', '[]', false); assert false, 'gestionnaire modifie'; exception when insufficient_privilege then null; end;
  begin perform public.withdraw_announcement_unread(pg_temp.u('an1')); assert false, 'gestionnaire retire'; exception when insufficient_privilege then null; end;
  begin insert into public.announcements (action_key, body, audience) values (pg_temp.k(21), 'x', 'all'); assert false, 'écriture directe'; exception when insufficient_privilege then null; end;
  assert (select count(*) from public.announcements) = 0, 'un gestionnaire du côté 1 ne lit pas les annonces';
  begin perform 1 from public.announcement_revisions; assert false, 'gestionnaire lit les révisions'; exception when insufficient_privilege then null; end;
end $$;

-- ── C. Ce que voit l'employé ────────────────────────────────────────────────
select pg_temp.as_user(pg_temp.u('a1'), 'aal1');
do $$
declare n integer;
begin
  assert exists (select 1 from public.announcements where id = pg_temp.u('an1')) and exists (select 1 from public.announcements where id = pg_temp.u('an2')) and exists (select 1 from public.announcements where id = pg_temp.u('an3')), 'a1 reçoit ses annonces';
  assert not exists (select 1 from public.announcements where id = pg_temp.u('an4')), 'a1 ne reçoit pas l''annonce destinée à 3602';
  assert (select count(*) from public.announcement_recipients) = 3 and not exists (select 1 from public.announcement_recipients where employee_id <> pg_temp.u('a1')), 'il ne voit que ses propres lignes de destinataire';
  begin insert into public.announcement_recipients (announcement_id, employee_id) values (pg_temp.u('an4'), pg_temp.u('a1')); assert false, 'ajout de soi à une annonce'; exception when insufficient_privilege then null; end;
  begin update public.announcement_recipients set withdrawn_at = now(); assert false, 'colonne autre que l''accusé'; exception when insufficient_privilege then null; end;
  -- se rattacher à l'annonce d'un autre pour la lire : refusé par le droit de colonne
  begin update public.announcement_recipients set announcement_id = pg_temp.u('an4') where announcement_id = pg_temp.u('an1'); assert false, 'déplacer sa ligne vers une autre annonce'; exception when insufficient_privilege then null; end;
  -- accusé de réception : une seule fois
  update public.announcement_recipients set acknowledged_at = '2000-01-01' where announcement_id = pg_temp.u('an1'); get diagnostics n = row_count; assert n = 1, 'accusé de réception';
  assert (select acknowledged_at from public.announcement_recipients where announcement_id = pg_temp.u('an1')) > now() - interval '1 minute', 'date fixée par le serveur';
  update public.announcement_recipients set acknowledged_at = null where announcement_id = pg_temp.u('an1');
  assert (select acknowledged_at from public.announcement_recipients where announcement_id = pg_temp.u('an1')) is not null, 'l''accusé ne se retire pas';
  begin perform 1 from public.announcement_revisions; assert false, 'employé lit les révisions'; exception when insufficient_privilege then null; end;
end $$;
select pg_temp.as_user(pg_temp.u('a6'), 'aal1');
do $$ declare n integer; begin
  assert exists (select 1 from public.announcements where id = pg_temp.u('an3')), 'a6 reçoit l''annonce générale';
  assert not exists (select 1 from public.announcements where id in (pg_temp.u('an1'), pg_temp.u('an2'))), 'a6 ne reçoit pas les annonces des autres';
  update public.announcement_recipients set acknowledged_at = now() where announcement_id = pg_temp.u('an1'); get diagnostics n = row_count; assert n = 0, 'on n''accuse pas réception pour une annonce qu''on n''a pas';
end $$;
reset role;

-- ── D. Modifier avec version attendue ───────────────────────────────────────
select set_config('test.v1', coalesce(edited_at, created_at)::text, false) from public.announcements where id = current_setting('test.an1')::uuid;
update public.announcement_recipients set acknowledged_at = now() where announcement_id = current_setting('test.an1')::uuid and employee_id = current_setting('test.a1')::uuid;
set role service_role;
select pg_temp.no_user();
do $$
declare r jsonb;
begin
  begin perform public.edit_announcement(pg_temp.u('an1'), current_setting('test.v1')::timestamptz - interval '1 second', 'x', '[]', false); assert false, 'version périmée'; exception when sqlstate '40001' then if sqlerrm <> 'announcement_state_changed' then raise; end if; end;
  begin perform public.edit_announcement(pg_temp.u('an1'), null, 'x', '[]', false); assert false, 'version absente'; exception when sqlstate '40001' then null; end;
  begin perform public.edit_announcement(gen_random_uuid(), now(), 'x', '[]', false); assert false, 'annonce inconnue'; exception when sqlstate 'P0002' then null; end;
  begin perform public.edit_announcement(pg_temp.u('an1'), current_setting('test.v1')::timestamptz, '   ', '[]', false); assert false, 'texte vide'; exception when sqlstate '22023' then null; end;
  begin perform public.edit_announcement(pg_temp.u('an1'), current_setting('test.v1')::timestamptz, 'x', '[{"path": "bad", "kind": "image"}]', false); assert false, 'pièce invalide'; exception when sqlstate '22023' then null; end;
  -- modification sans relecture : les accusés restent
  r := public.edit_announcement(pg_temp.u('an1'), current_setting('test.v1')::timestamptz, 'Réunion de sécurité mardi', '[]', false);
  assert (r ->> 'reread_count')::int = 0 and (r ->> 'pending_count')::int = 1, 'sans relecture : aucun accusé remis à zéro : ' || r::text;
end $$;
reset role;
do $$ begin
  assert (select body from public.announcements where id = pg_temp.u('an1')) = 'Réunion de sécurité mardi' and (select edited_at from public.announcements where id = pg_temp.u('an1')) is not null, 'texte modifié, date de modification posée';
  assert (select body from public.announcement_revisions where announcement_id = pg_temp.u('an1')) = 'Réunion de sécurité lundi', 'l''ancien texte est conservé en révision';
  assert (select acknowledged_at from public.announcement_recipients where announcement_id = pg_temp.u('an1') and employee_id = pg_temp.u('a1')) is not null, 'accusé conservé';
  perform set_config('test.v2', (select coalesce(edited_at, created_at)::text from public.announcements where id = pg_temp.u('an1')), false);
end $$;
set role service_role;
select pg_temp.no_user();
do $$ declare r jsonb; begin
  begin perform public.edit_announcement(pg_temp.u('an1'), current_setting('test.v1')::timestamptz, 'x', '[]', false); assert false, 'l''ancienne version est périmée après une modification'; exception when sqlstate '40001' then null; end;
  r := public.edit_announcement(pg_temp.u('an1'), current_setting('test.v2')::timestamptz, 'Réunion de sécurité mercredi', '[]', true);
  assert (r ->> 'reread_count')::int = 1 and (r ->> 'pending_count')::int = 2, 'avec relecture : un accusé remis à zéro, deux à lire : ' || r::text;
end $$;
reset role;
do $$ begin
  assert (select acknowledged_at from public.announcement_recipients where announcement_id = pg_temp.u('an1') and employee_id = pg_temp.u('a1')) is null, 'a1 doit relire';
  assert (select reread and reread_count = 1 from public.announcement_revisions where announcement_id = pg_temp.u('an1') order by edited_at desc limit 1), 'révision : relecture demandée, un destinataire';
  assert exists (select 1 from public.audit_log where action = 'announcement_edited' and details ->> 'reason_code' = 'reread'), 'audit de la modification';
end $$;

-- ── E. Retirer l'annonce à ceux qui ne l'ont pas lue ────────────────────────
update public.announcement_recipients set acknowledged_at = now() where announcement_id = current_setting('test.an2')::uuid and employee_id = current_setting('test.a2')::uuid;
set role service_role;
select pg_temp.no_user();
do $$ declare n integer; begin
  begin perform public.withdraw_announcement_unread(gen_random_uuid()); assert false, 'annonce inconnue'; exception when sqlstate 'P0002' then null; end;
  n := public.withdraw_announcement_unread(pg_temp.u('an2')); assert n = 1, 'un destinataire non lecteur retiré : ' || n;
  n := public.withdraw_announcement_unread(pg_temp.u('an2')); assert n = 0, 'deuxième retrait : rien';
end $$;
reset role;
do $$ begin assert (select count(*) from public.audit_log where action = 'announcement_withdrawn') = 1, 'un seul audit de retrait (le second retrait ne retire personne)'; end $$;
set role authenticated;
select pg_temp.as_user(pg_temp.u('a1'), 'aal1');
do $$ begin assert not exists (select 1 from public.announcements where id = pg_temp.u('an2')), 'retirée : a1 (non lecteur) ne la voit plus'; end $$;
select pg_temp.as_user(pg_temp.u('a2'), 'aal1');
do $$ begin assert exists (select 1 from public.announcements where id = pg_temp.u('an2')), 'a2 qui l''avait lue la garde'; end $$;
reset role;

-- ── F. Pièces jointes : lisibles par les destinataires de cette annonce ─────
do $$ begin
  assert exists (select 1 from storage.buckets where id = 'announcement-files' and not public and file_size_limit = 10485760), 'compartiment privé';
  insert into storage.objects (bucket_id, name) values ('announcement-files', '11111111-1111-4111-8111-111111111111.pdf'), ('announcement-files', '22222222-2222-4222-8222-222222222222.pdf');
end $$;
set role authenticated;
select pg_temp.as_user(pg_temp.u('a2'), 'aal1');
do $$ begin
  assert (select count(*) from storage.objects where bucket_id = 'announcement-files') = 1 and exists (select 1 from storage.objects where name = '11111111-1111-4111-8111-111111111111.pdf'), 'a2 lit la pièce jointe de son annonce, et seulement celle-là';
  begin insert into storage.objects (bucket_id, name) values ('announcement-files', 'faux.pdf'); assert false, 'employé téléverse'; exception when insufficient_privilege then null; end;
end $$;
select pg_temp.as_user(pg_temp.u('a1'), 'aal1');
do $$ begin assert (select count(*) from storage.objects where bucket_id = 'announcement-files') = 0, 'a1 ne lit pas la pièce jointe d''une annonce qui ne lui est pas destinée'; end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$ begin assert (select count(*) from storage.objects where bucket_id = 'announcement-files') = 0, 'un gestionnaire du côté 1 ne la lit pas non plus'; end $$;
reset role;
-- retirée à un destinataire : il ne lit plus la pièce jointe
update public.announcement_recipients set withdrawn_at = now() where announcement_id = current_setting('test.an4')::uuid;
set role authenticated;
select pg_temp.as_user(pg_temp.u('a2'), 'aal1');
do $$ begin assert (select count(*) from storage.objects where bucket_id = 'announcement-files') = 0, 'retirée : plus de lecture'; end $$;
reset role;
select 'OK : migration 0011' as resultat;
