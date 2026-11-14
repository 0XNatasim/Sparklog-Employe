-- Sparklog-Employés — migration 0014 : photos orphelines (téléversées, mais dont la ligne n'a jamais été enregistrée).
-- Sert à `cleanup_overtime_evidence` (destruction automatique des preuves en photo : exigence de PLAN.md / OFFICIEL.md).
--  * Un objet de stockage est orphelin s'il n'est référencé par aucune ligne de son compartiment, depuis plus longtemps que le délai de grâce
--    (au moins 1 heure : un téléversement en cours n'est jamais ramassé).
--  * Stationnement : la première photo (`storage_path`) ET les photos suivantes (`extra_storage_paths`) comptent comme référencées.
--  * Les compartiments `announcement-files` (gérés par le côté 2) et tout autre compartiment ne sont jamais touchés.
--  * Réservée à la clé de service ; l'ordonnanceur du serveur appelle la fonction Edge avec cette clé (pas de pg_cron ni de Vault dans la base).
create function public.find_orphaned_evidence_objects(p_older_than interval default interval '2 hours', p_limit integer default 500)
returns table (bucket_id text, object_name text)
language sql stable security definer set search_path = '' as $$
  select o.bucket_id, o.name
    from storage.objects o
   where o.bucket_id in ('overtime-evidence', 'parking-receipts', 'meal-receipts', 'inventory-screenshots')
     and o.created_at < now() - greatest(p_older_than, interval '1 hour')
     and (
       (o.bucket_id = 'overtime-evidence' and not exists (select 1 from public.overtime_evidence e where e.storage_path = o.name))
       or (o.bucket_id = 'parking-receipts' and not exists (
             select 1 from public.parking_receipts p where p.storage_path = o.name or o.name = any (p.extra_storage_paths)))
       or (o.bucket_id = 'meal-receipts' and not exists (select 1 from public.meal_claims m where m.storage_path = o.name))
       or (o.bucket_id = 'inventory-screenshots' and not exists (select 1 from public.inventory_screenshots i where i.storage_path = o.name))
     )
   order by o.created_at
   limit least(greatest(p_limit, 1), 1000);
$$;

revoke all on function public.find_orphaned_evidence_objects(interval, integer) from public, anon, authenticated;
grant execute on function public.find_orphaned_evidence_objects(interval, integer) to service_role;
