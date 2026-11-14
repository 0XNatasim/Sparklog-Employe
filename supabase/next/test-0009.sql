-- Test de la migration 0009 : inventaire, groupes, stock minimum (voir scripts/test-next-schema.sh).
\set ON_ERROR_STOP on
create function pg_temp.as_user(p_id uuid, p_aal text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_id, 'aal', p_aal)::text, false); end $$;
create function pg_temp.no_user() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '', false); end $$;
create function pg_temp.d0() returns date language sql stable as $$ select (timezone('America/Toronto', now()))::date $$;
create function pg_temp.u(tag text) returns uuid language sql stable as $$ select current_setting('test.' || tag)::uuid $$;
create function pg_temp.k(n integer) returns uuid language sql immutable as $$ select ('eeeeeeee-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.sj(p_key uuid, p_submit boolean, p_date date) returns table (id uuid, status text, locked boolean) language sql as $$
  select * from public.save_own_job(null, null, p_key, p_submit, p_date, 'OT 100', '07:00', null, '15:00', 0, 0, 0, 0, false, false, false)
$$;

select pg_temp.no_user();
select set_config('test.mgr', id::text, false) from public.profiles where employee_number = 3002;
select set_config('test.own', id::text, false) from public.profiles where employee_number = 3001;
do $$
declare spec record; uid uuid; n integer;
begin
  for spec in select * from (values (3401, 'employee', true, false, 'g1'), (3402, 'employee', false, false, 'g2'), (3403, 'employee', true, true, 'g3'), (3404, 'admin', true, false, 'g4')) as t(num, role, inv, paused, tag) loop
    uid := gen_random_uuid();
    insert into auth.users (id, email) values (uid, spec.num || '@pointage.invalid');
    insert into public.profiles (id, employee_number, role, inventory_screenshots_enabled, is_paused) values (uid, spec.num, spec.role, spec.inv, spec.paused);
    perform set_config('test.' || spec.tag, uid::text, false);
    for n in 1..20 loop
      insert into public.job_entry_unlocks (user_id, job_date, created_by) values (uid, pg_temp.d0() - n, pg_temp.u('mgr')) on conflict (user_id, job_date) do nothing;
    end loop;
    insert into public.job_entry_unlocks (user_id, job_date, created_by) values (uid, date '2026-10-01', pg_temp.u('mgr')) on conflict (user_id, job_date) do nothing;
  end loop;
end $$;

-- ── A. L'inventaire de fin de quart est exigé à la soumission ───────────────
set role authenticated;
select pg_temp.as_user(pg_temp.u('g1'), 'aal1');
do $$
declare d date := pg_temp.d0() - 2; g1 text := current_setting('test.g1'); r record;
begin
  begin perform * from pg_temp.sj(pg_temp.k(1), true, d); assert false, 'soumission sans capture';
  exception when sqlstate '23514' then if sqlerrm <> 'inventory_screenshots_required' then raise; end if; end;
  assert not exists (select 1 from public.jobs where submission_key = pg_temp.k(1)), 'rien d''enregistré après le refus';
  insert into public.inventory_screenshots (user_id, job_date, slot, storage_path, expires_at) values (pg_temp.u('g1'), d, 4, g1 || '/' || d || '/s4.jpg', now() + interval '30 days');
  begin perform * from pg_temp.sj(pg_temp.k(1), true, d); assert false, 'la photo des produits défectueux ne compte pas';
  exception when sqlstate '23514' then if sqlerrm <> 'inventory_screenshots_required' then raise; end if; end;
  insert into public.inventory_screenshots (user_id, job_date, slot, storage_path, expires_at) values (pg_temp.u('g1'), d, 1, g1 || '/' || d || '/s1.jpg', now() + interval '30 days');
  select * into r from pg_temp.sj(pg_temp.k(1), true, d); assert r.status = 'submitted', 'soumission avec une capture';
  -- jour avant le déploiement : toléré
  select * into r from pg_temp.sj(pg_temp.k(2), true, date '2026-10-01'); assert r.status = 'submitted', 'jour antérieur à 2026-10-08 : toléré';
end $$;
select pg_temp.as_user(pg_temp.u('g2'), 'aal1');
do $$ declare r record; begin select * into r from pg_temp.sj(pg_temp.k(3), true, pg_temp.d0() - 2); assert r.status = 'submitted', 'inventaire non activé pour cet employé : exempté'; end $$;
select pg_temp.as_user(pg_temp.u('g4'), 'aal1');
do $$ declare r record; begin select * into r from pg_temp.sj(pg_temp.k(4), true, pg_temp.d0() - 2); assert r.status = 'submitted', 'employé de bureau : exempté'; end $$;
select pg_temp.as_user(pg_temp.u('own'), 'aal2');
do $$ declare r record; begin
  select * into r from public.create_job_for_employee(pg_temp.u('g1'), pg_temp.k(5), pg_temp.d0() - 3, 'OT 800', '07:00', null, '15:00', 3, 'Employé non disponible', null, null, true);
  assert (select status from public.jobs where id = r.id) = 'submitted', 'le propriétaire soumet sans capture';
end $$;
reset role;

-- ── B. Table des captures ───────────────────────────────────────────────────
set role authenticated;
select pg_temp.as_user(pg_temp.u('g1'), 'aal1');
do $$
declare g1 text := current_setting('test.g1'); d date := pg_temp.d0() - 2;
begin
  insert into public.inventory_screenshots (user_id, job_date, slot, storage_path, expires_at) values (pg_temp.u('g1'), d, 2, g1 || '/' || d || '/s2.jpg', now() + interval '30 days');
  begin insert into public.inventory_screenshots (user_id, job_date, slot, storage_path, expires_at) values (pg_temp.u('g1'), d, 2, g1 || '/x.jpg', now()); assert false, 'même case deux fois';
  exception when unique_violation then null; end;
  begin insert into public.inventory_screenshots (user_id, job_date, slot, storage_path, expires_at) values (pg_temp.u('g1'), d, 6, g1 || '/x.jpg', now()); assert false, 'case hors bornes';
  exception when check_violation then null; end;
  begin insert into public.inventory_screenshots (user_id, job_date, slot, storage_path, expires_at, ocr_status) values (pg_temp.u('g1'), d, 3, g1 || '/x.jpg', now(), 'inconnu'); assert false, 'statut libre';
  exception when check_violation then null; end;
  begin insert into public.inventory_screenshots (user_id, job_date, slot, storage_path, expires_at) values (pg_temp.u('g2'), d, 3, 'x/x.jpg', now()); assert false, 'capture au nom d''un autre';
  exception when insufficient_privilege then null; end;
  update public.inventory_screenshots set list_total = 12, ocr_status = 'processed' where user_id = pg_temp.u('g1') and slot = 2;
  begin delete from public.inventory_screenshots; assert false, 'suppression directe'; exception when insufficient_privilege then null; end;
end $$;
select pg_temp.as_user(pg_temp.u('g3'), 'aal1');
do $$ begin
  begin insert into public.inventory_screenshots (user_id, job_date, slot, storage_path, expires_at) values (pg_temp.u('g3'), pg_temp.d0() - 2, 1, 'x/x.jpg', now()); assert false, 'employé en pause';
  exception when insufficient_privilege then null; end;
end $$;
select pg_temp.as_user(pg_temp.u('g2'), 'aal1');
do $$ begin assert (select count(*) from public.inventory_screenshots) = 0, 'un employé ne lit pas les captures d''un autre'; end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$ begin assert (select count(*) from public.inventory_screenshots) >= 3, 'gestionnaire aal2 lit les captures'; end $$;
reset role;

-- ── C. Lignes lues : écrites par le service seulement ───────────────────────
do $$
declare d date := pg_temp.d0();
begin
  begin insert into public.inventory_items (user_id, job_date, slot, code, name, quantity, expires_at) values (pg_temp.u('g1'), d, 1, 'XX1', 'x', 1, now()); assert false, 'code invalide'; exception when check_violation then null; end;
  begin insert into public.inventory_items (user_id, job_date, slot, code, name, quantity, expires_at) values (pg_temp.u('g1'), d, 1, 'EQ000001', 'x', 100000, now()); assert false, 'quantité hors bornes'; exception when check_violation then null; end;
  begin insert into public.inventory_items (user_id, job_date, slot, code, name, quantity, expires_at, section) values (pg_temp.u('g1'), d, 1, 'EQ000001', 'x', 1, now(), 'autre'); assert false, 'section libre'; exception when check_violation then null; end;
  -- g1 : case 1 non lue, case 2 = 3 ; g2 : case 1 = 5, case 2 non lue (une quantité lue l'emporte sur une quantité coupée)
  insert into public.inventory_items (user_id, job_date, slot, code, name, quantity, expires_at) values
    (pg_temp.u('g1'), d, 1, 'EQ000001', 'Appareil test', null, now() + interval '30 days'),
    (pg_temp.u('g1'), d, 2, 'EQ000001', 'Appareil test', 3, now() + interval '30 days'),
    (pg_temp.u('g2'), d, 1, 'EQ000001', 'Appareil test', 5, now() + interval '30 days'),
    (pg_temp.u('g2'), d, 2, 'EQ000001', 'Appareil test', null, now() + interval '30 days');
  begin insert into public.inventory_items (user_id, job_date, slot, code, name, quantity, expires_at) values (pg_temp.u('g1'), d, 1, 'EQ000001', 'Appareil test', 1, now()); assert false, 'ligne en double'; exception when unique_violation then null; end;
end $$;
set role authenticated;
select pg_temp.as_user(pg_temp.u('g1'), 'aal1');
do $$ begin
  assert (select count(*) from public.inventory_items) = 2 and not exists (select 1 from public.inventory_items where user_id <> pg_temp.u('g1')), 'un employé lit ses lignes seulement';
  begin insert into public.inventory_items (user_id, job_date, slot, code, name, quantity, expires_at) values (pg_temp.u('g1'), pg_temp.d0(), 3, 'EQ000009', 'x', 1, now()); assert false, 'employé écrit une ligne'; exception when insufficient_privilege then null; end;
end $$;
reset role;

-- ── D. Stock minimum par groupe ─────────────────────────────────────────────
set role authenticated;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$
declare gid uuid;
begin
  insert into public.employee_groups (name, note) values ('Entrepôt A', 'Équipe du sud') returning id into gid;
  perform set_config('test.grp', gid::text, false);
  insert into public.employee_group_members (group_id, user_id) values (gid, pg_temp.u('g1')), (gid, pg_temp.u('g2')), (gid, pg_temp.u('g3'));
  insert into public.inventory_min_ratios (group_id, code, name, per_employee, updated_by) values (gid, 'EQ000001', 'Appareil test', 2, pg_temp.u('own'));
  assert (select updated_by from public.inventory_min_ratios where group_id = gid) = pg_temp.u('mgr'), 'auteur du minimum fixé par le serveur';
  -- employés non en pause : g1 et g2 (g3 en pause) → minimum 4 ; en main : 3 + 5 = 8
  perform * from public.inventory_stock_levels() where false;
end $$;
do $$
declare r record;
begin
  select * into r from public.inventory_stock_levels() where code = 'EQ000001';
  assert r.group_name = 'Entrepôt A' and r.headcount = 2 and r.minimum = 4 and r.on_hand = 8 and r.lists_counted = 2, 'stock : ' || row(r.*)::text;
  assert not r.is_low, 'au-dessus du minimum';
  assert not r.alert_enabled, 'alerte désactivée par défaut';
end $$;
reset role;
update public.inventory_items set quantity = 0 where user_id = current_setting('test.g2')::uuid and slot = 1;   -- en main : 3 + 0 = 3 < 4
update public.employee_groups set low_stock_alert = true where id = current_setting('test.grp')::uuid;
set role authenticated;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$ declare r record; begin
  select * into r from public.inventory_stock_levels() where code = 'EQ000001';
  assert r.is_low and r.alert_enabled and r.on_hand = 3, 'sous le minimum, alerte activée';
end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal1');
do $$ begin assert (select count(*) from public.inventory_stock_levels()) = 0, 'gestionnaire sans aal2 : aucun stock'; end $$;
select pg_temp.as_user(pg_temp.u('g1'), 'aal1');
do $$ begin assert (select count(*) from public.inventory_stock_levels()) = 0, 'un employé ne voit pas le stock'; end $$;
reset role;
-- une liste de plus de 7 jours ne compte pas
update public.inventory_items set job_date = pg_temp.d0() - 9 where user_id = current_setting('test.g2')::uuid;
set role authenticated;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$ declare r record; begin
  select * into r from public.inventory_stock_levels() where code = 'EQ000001';
  assert r.lists_counted = 1 and r.on_hand = 3, 'liste de plus de 7 jours ignorée : ' || row(r.*)::text;
end $$;
reset role;

-- ── E. Alertes de quantité négative ─────────────────────────────────────────
do $$ begin
  insert into public.inventory_items (user_id, job_date, slot, code, name, quantity, expires_at) values (pg_temp.u('g1'), pg_temp.d0(), 1, 'EQ000002', 'Autre appareil', -2, now() + interval '30 days');
end $$;
set role authenticated;
-- l'alerte existe, mais ni un gestionnaire sans double authentification ni un employé ne la voient
select pg_temp.as_user(pg_temp.u('mgr'), 'aal1');
do $$ begin assert (select count(*) from public.inventory_negative_alerts()) = 0, 'sans aal2 : aucune alerte'; end $$;
select pg_temp.as_user(pg_temp.u('g1'), 'aal1');
do $$ begin assert (select count(*) from public.inventory_negative_alerts()) = 0, 'un employé ne voit pas les alertes'; end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$ declare r record; n integer;
begin
  select * into r from public.inventory_negative_alerts();
  assert r.employee_number = 3401 and r.code = 'EQ000002' and r.quantity = -2, 'alerte pour le numéro 3401';
  assert not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name in ('inventory_items', 'inventory_screenshots', 'inventory_reading_log') and column_name ~ '(name$|email|phone)' and column_name <> 'name'), 'aucune colonne nominative';
  begin perform public.dismiss_inventory_negative_alert(pg_temp.u('g2'), pg_temp.d0()); assert false, 'aucune alerte à fermer';
  exception when sqlstate 'P0002' then null; end;
  begin perform public.dismiss_inventory_negative_alert(null, pg_temp.d0()); assert false, 'paramètre absent'; exception when sqlstate '22023' then null; end;
  perform public.dismiss_inventory_negative_alert(pg_temp.u('g1'), pg_temp.d0());
  perform public.dismiss_inventory_negative_alert(pg_temp.u('g1'), pg_temp.d0());
  select count(*) into n from public.inventory_negative_alerts(); assert n = 0, 'alerte fermée';
end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal1');
do $$ begin
  begin perform public.dismiss_inventory_negative_alert(pg_temp.u('g1'), pg_temp.d0()); assert false, 'fermeture sans aal2'; exception when sqlstate '42501' then null; end;
end $$;
select pg_temp.as_user(pg_temp.u('g1'), 'aal1');
do $$ begin begin perform public.dismiss_inventory_negative_alert(pg_temp.u('g1'), pg_temp.d0()); assert false, 'employé ferme'; exception when sqlstate '42501' then null; end; end $$;
reset role;
do $$ declare n integer; begin
  select count(*) into n from public.audit_log where action = 'inventory_negative_dismissed' and actor_number = 3002 and target_number = 3401; assert n = 1, 'une seule fermeture dans l''audit, par numéros : ' || n;
end $$;

-- ── F. Journal de lecture ───────────────────────────────────────────────────
set role authenticated;
select pg_temp.as_user(pg_temp.u('g1'), 'aal1');
do $$ begin
  insert into public.inventory_reading_log (user_id, job_date, reading_state, lines_read, lines_expected, step_block, created_at) values (pg_temp.u('g2'), pg_temp.d0(), 'ok', 10, 12, 'wait', '2000-01-01');
  begin insert into public.inventory_reading_log (job_date, step_block) values (pg_temp.d0(), 'inconnu'); assert false, 'bloc libre'; exception when check_violation then null; end;
  begin insert into public.inventory_reading_log (job_date, lines_read) values (pg_temp.d0(), 5000); assert false, 'compteur hors bornes'; exception when check_violation then null; end;
end $$;
reset role;
do $$ begin assert (select user_id from public.inventory_reading_log) = pg_temp.u('g1') and (select created_at from public.inventory_reading_log) > now() - interval '1 minute', 'auteur et heure fixés par le serveur'; end $$;
set role authenticated;
select pg_temp.as_user(pg_temp.u('g1'), 'aal1');
do $$ begin assert (select count(*) from public.inventory_reading_log) = 0, 'l''employé ne relit pas ce journal'; end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$ begin assert (select count(*) from public.inventory_reading_log) = 1, 'gestionnaire lit le journal de lecture'; end $$;
reset role;

-- ── G. Groupes ──────────────────────────────────────────────────────────────
set role authenticated;
select pg_temp.as_user(pg_temp.u('g1'), 'aal1');
do $$ begin
  begin insert into public.employee_groups (name) values ('Pirate'); assert false, 'employé crée un groupe'; exception when insufficient_privilege then null; end;
  assert (select count(*) from public.employee_groups) = 0 and (select count(*) from public.employee_group_members) = 0, 'un employé ne lit ni groupes ni membres';
end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$ declare gid uuid; n integer; begin
  begin insert into public.employee_groups (name) values ('  ENTREPÔT a '); assert false, 'nom en double sans casse'; exception when unique_violation then null; end;
  begin insert into public.employee_groups (name) values ('   '); assert false, 'nom vide'; exception when check_violation then null; end;
  begin insert into public.employee_groups (name, note) values ('Équipe B', repeat('x', 301)); assert false, 'note trop longue'; exception when check_violation then null; end;
  insert into public.employee_groups (name) values ('Équipe B') returning id into gid;
  insert into public.employee_group_members (group_id, user_id) values (gid, pg_temp.u('g4'));
  begin insert into public.employee_group_members (group_id, user_id) values (gid, pg_temp.u('g4')); assert false, 'membre en double'; exception when unique_violation then null; end;
  delete from public.employee_group_members where group_id = gid; get diagnostics n = row_count; assert n = 1, 'retirer un membre';
  begin insert into public.inventory_min_ratios (group_id, code, name, per_employee) values (gid, 'EQ000001', 'x', 0); assert false, 'ratio nul'; exception when check_violation then null; end;
end $$;
reset role;

-- ── H. Stockage des captures ────────────────────────────────────────────────
do $$ begin assert exists (select 1 from storage.buckets where id = 'inventory-screenshots' and not public and file_size_limit = 10485760), 'compartiment privé'; end $$;
set role authenticated;
select pg_temp.as_user(pg_temp.u('g1'), 'aal1');
do $$
declare g1 text := current_setting('test.g1'); g2 text := current_setting('test.g2'); n integer;
begin
  insert into storage.objects (bucket_id, name, owner, owner_id) values ('inventory-screenshots', g1 || '/a.jpg', g1::uuid, g1);
  begin insert into storage.objects (bucket_id, name, owner, owner_id) values ('inventory-screenshots', g2 || '/a.jpg', g1::uuid, g1); assert false, 'dossier d''un autre';
  exception when insufficient_privilege then null; end;
  assert (select count(*) from storage.objects where bucket_id = 'inventory-screenshots') = 1, 'l''employé relit ses captures';
end $$;
select pg_temp.as_user(pg_temp.u('g3'), 'aal1');
do $$ declare g3 text := current_setting('test.g3'); begin
  begin insert into storage.objects (bucket_id, name, owner, owner_id) values ('inventory-screenshots', g3 || '/a.jpg', g3::uuid, g3); assert false, 'employé en pause téléverse';
  exception when insufficient_privilege then null; end;
end $$;
select pg_temp.as_user(pg_temp.u('g2'), 'aal1');
do $$ begin assert (select count(*) from storage.objects where bucket_id = 'inventory-screenshots') = 0, 'un autre employé ne relit pas ces captures'; end $$;
select pg_temp.as_user(pg_temp.u('mgr'), 'aal2');
do $$ begin assert (select count(*) from storage.objects where bucket_id = 'inventory-screenshots') = 1, 'gestionnaire lit les captures'; end $$;
reset role;
select 'OK : migration 0009' as resultat;
