-- Test de la migration 0014 : photos orphelines (voir scripts/test-next-schema.sh).
\set ON_ERROR_STOP on
create function pg_temp.as_user(p_id uuid, p_aal text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_id, 'aal', p_aal)::text, false); end $$;
create function pg_temp.no_user() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '', false); end $$;

select pg_temp.no_user();
do $$
declare uid uuid := gen_random_uuid(); jid uuid := gen_random_uuid(); old_ts timestamptz := now() - interval '3 hours';
begin
  insert into auth.users (id, email) values (uid, '4501@pointage.invalid');
  insert into public.profiles (id, employee_number, role) values (uid, 4501, 'employee');
  insert into public.jobs (id, user_id, job_date, ot, depart, fin, status) values (jid, uid, current_date - 2, 'OT 1', '07:00', '15:00', 'saved');
  -- références : une preuve de temps supp., un stationnement avec 2 photos supplémentaires, un repas, une capture d'inventaire
  insert into public.overtime_evidence (job_id, user_id, job_date, storage_path, daily_minutes, expires_at) values (jid, uid, current_date - 2, 't4501/ot.jpg', 600, now() + interval '20 days');
  insert into public.parking_receipts (job_id, user_id, job_date, amount, storage_path, extra_storage_paths)
    values (jid, uid, current_date - 2, 5, uid || '/' || (current_date - 2) || '/p1.jpg', array[uid || '/' || (current_date - 2) || '/p2.jpg', uid || '/' || (current_date - 2) || '/p3.jpg']);
  insert into public.meal_claims (job_id, user_id, job_date, amount, storage_path, daily_work_minutes) values (jid, uid, current_date - 2, 30, 'm4501/meal.jpg', 700);
  insert into public.inventory_screenshots (user_id, job_date, slot, storage_path, expires_at) values (uid, current_date - 2, 1, 'i4501/inv.jpg', now() + interval '20 days');
  perform set_config('test.uid', uid::text, false);
  -- objets de stockage : référencés (ne doivent PAS sortir) et orphelins (doivent sortir), tous anciens
  insert into storage.objects (bucket_id, name, created_at) values
    ('overtime-evidence', 't4501/ot.jpg', old_ts), ('overtime-evidence', 't4501/orphan.jpg', old_ts),
    ('parking-receipts', uid || '/' || (current_date - 2) || '/p1.jpg', old_ts), ('parking-receipts', uid || '/' || (current_date - 2) || '/p2.jpg', old_ts),
    ('parking-receipts', uid || '/' || (current_date - 2) || '/p3.jpg', old_ts), ('parking-receipts', uid || '/' || (current_date - 2) || '/orphan.jpg', old_ts),
    ('meal-receipts', 'm4501/meal.jpg', old_ts), ('meal-receipts', 'm4501/orphan.jpg', old_ts),
    ('inventory-screenshots', 'i4501/inv.jpg', old_ts), ('inventory-screenshots', 'i4501/orphan.jpg', old_ts),
    -- délai de grâce : orphelin mais récent (téléversement en cours)
    ('overtime-evidence', 't4501/recent.jpg', now() - interval '10 minutes'),
    ('overtime-evidence', 't4501/borderline.jpg', now() - interval '30 minutes'),
    -- compartiment du côté 2 : jamais touché
    ('announcement-files', 'a/annexe.pdf', old_ts);
end $$;

-- ── A. Seule la clé de service l'appelle ────────────────────────────────────
set role authenticated;
select pg_temp.as_user(current_setting('test.uid')::uuid, 'aal2');
do $$ begin perform * from public.find_orphaned_evidence_objects(); assert false, 'employé'; exception when insufficient_privilege then null; end $$;
select pg_temp.no_user();
set role anon;
do $$ begin perform * from public.find_orphaned_evidence_objects(); assert false, 'anonyme'; exception when insufficient_privilege then null; end $$;

-- ── B. Orphelins ────────────────────────────────────────────────────────────
reset role;
set role service_role;
do $$
declare names text[]; uid text := current_setting('test.uid');
begin
  select array_agg(bucket_id || ':' || object_name order by bucket_id, object_name) into names from public.find_orphaned_evidence_objects();
  assert names = array[
    'inventory-screenshots:i4501/orphan.jpg', 'meal-receipts:m4501/orphan.jpg', 'overtime-evidence:t4501/orphan.jpg',
    'parking-receipts:' || uid || '/' || (current_date - 2) || '/orphan.jpg'
  ], 'seuls les orphelins anciens : ' || names::text;
  -- délai de grâce : même demandé à 0, jamais moins d'une heure ; un objet de 30 minutes n'est pas ramassé
  select array_agg(object_name) into names from public.find_orphaned_evidence_objects(interval '0', 500) where object_name like 't4501/%';
  assert not ('t4501/recent.jpg' = any (names)) and not ('t4501/borderline.jpg' = any (names)), 'grâce minimale d''une heure : ' || names::text;
  -- limite
  assert (select count(*) from public.find_orphaned_evidence_objects(interval '2 hours', 2)) = 2, 'limite';
  assert (select count(*) from public.find_orphaned_evidence_objects(interval '2 hours', 0)) = 1, 'limite minimale de 1';
  -- un délai plus long écarte ce qui est plus récent
  assert (select count(*) from public.find_orphaned_evidence_objects(interval '5 hours', 500)) = 0, 'délai de 5 heures : rien d''assez vieux';
end $$;
select 'OK : migration 0014' as resultat;
