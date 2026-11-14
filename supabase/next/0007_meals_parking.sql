-- Sparklog-Employés — schéma neuf du côté 1. Migration 0007 : repas, stationnement, avis de modification d'une fiche à preuve, téléchargements de preuves.
-- Relevé dans une base reconstruite à partir des 150 migrations de Sparklog V2.4.258 (0012, 0016, 0086, 0125, 0126, 0139 et voisines).
--
-- Écarts voulus par rapport à Sparklog :
--  * le **souper est refusé à l'insertion** si la journée n'y donne pas droit, et le nombre de minutes enregistré est **calculé par le serveur** : dans Sparklog,
--    seul un `check (>= 615)` sur une valeur fournie par le navigateur protégeait l'insertion (le ménage ne passait qu'à la modification d'une fiche) ;
--  * un employé ne peut insérer des avis que de type `meal_claim` ou `parking_receipt` (il pouvait en fabriquer de tout type) ;
--  * le journal d'audit est celui de 0005 (numéros, aucune clé libre) : pas de `actor_name`, et `ot` n'y figure plus ;
--  * pas de trigger d'audit d'approbation d'une fiche : toute approbation passe par `approve_jobs` (0005), qui écrit son audit.
-- À décider (non modifié ici) : `payroll_treatment` (remboursement ou avantage imposable) est une décision de PAIE prise à l'approbation dans Sparklog ; si vous voulez
-- l'invariant « aucun montant de paie » au sens strict, elle passe au côté 2. Même question pour les montants de repas (30 $) et de stationnement saisis par l'employé.

-- ── Tables ──────────────────────────────────────────────────────────────────
create table public.meal_claims (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  job_date date not null,
  amount numeric not null default 30 check (amount = 30),
  storage_path text,
  daily_work_minutes integer not null check (daily_work_minutes >= 615),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  payroll_treatment text check (payroll_treatment in ('expense_reimbursement', 'taxable_benefit')),
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, job_date)
);
create index meal_claims_job_idx on public.meal_claims (job_id);
create index meal_claims_reviewed_by_idx on public.meal_claims (reviewed_by);
create index meal_claims_pending_created_idx on public.meal_claims (created_at desc, job_id) where status = 'pending';

create table public.parking_receipts (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null unique references public.jobs(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  job_date date not null,
  storage_path text,
  amount numeric not null default 0 check (amount >= 0),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  extra_storage_paths text[] not null default '{}' check (cardinality(extra_storage_paths) <= 9),
  expires_at timestamptz,
  pictures_purged_at timestamptz,
  created_at timestamptz not null default now()
);
comment on column public.parking_receipts.extra_storage_paths is 'Photos du parcomètre après la première (storage_path), dans l''ordre pris. Même compartiment, même dossier de l''employé.';
create index parking_receipts_user_idx on public.parking_receipts (user_id);
create index parking_receipts_reviewed_by_idx on public.parking_receipts (reviewed_by);
create index parking_receipts_pending_created_idx on public.parking_receipts (created_at desc, job_id) where status = 'pending';
create index parking_receipts_expiry_idx on public.parking_receipts (expires_at) where storage_path is not null;

create table public.evidence_downloads (
  bucket text not null check (bucket in ('overtime-evidence', 'parking-receipts')),
  storage_path text not null,
  downloaded_by uuid not null default auth.uid(),
  downloaded_at timestamptz not null default now(),
  primary key (bucket, storage_path)
);

-- Les avis de repas et de stationnement s'ajoutent à ceux de 0006.
alter table public.manager_notifications
  add column meal_claim_id uuid references public.meal_claims(id) on delete cascade,
  add column parking_receipt_id uuid references public.parking_receipts(id) on delete cascade,
  add constraint manager_notifications_type_chk check (type in ('overtime_evidence', 'overtime_job_edited', 'meal_claim', 'parking_receipt'));
create index manager_notifications_meal_idx on public.manager_notifications (meal_claim_id);
create index manager_notifications_parking_idx on public.manager_notifications (parking_receipt_id);

-- ── Souper : droit selon la journée ─────────────────────────────────────────
-- Minutes payées du jour pour le souper : durée de chaque fiche moins son retour (le retour n'est jamais du temps supplémentaire), moins le premier trajet non payé
-- (premier Départ du jour, jamais si cette fiche fait 65 km ou plus depuis le 2026-10-11). Jumeau de dayFirstTripUnpaidMinutes dans payroll_engine.js.
create function public.meal_day_paid_minutes(p_user uuid, p_date date)
returns integer language plpgsql stable security definer set search_path = '' as $$
declare
  daily_work_minutes integer := 0;
  unpaid_trip_minutes integer := 0;
begin
  select coalesce(sum(greatest(0, s.span - least(greatest(coalesce(s.return_time_minutes, 0), 0), s.span))), 0)
    into daily_work_minutes
    from (
      select j.return_time_minutes,
             case when j.depart is not null and j.fin is not null
                  then (extract(epoch from (j.fin - j.depart)) / 60)::int + case when j.fin < j.depart then 1440 else 0 end
                  else 0 end as span
        from public.jobs j where j.user_id = p_user and j.job_date = p_date
    ) s;
  if exists (select 1 from public.profiles p where p.id = p_user and p.first_trip_unpaid) then
    select case
             when d.depart is null or d.arrivee is null or d.fin is null then 0
             when p_date >= date '2026-10-11' and d.km >= 65 then 0
             else least(((extract(epoch from (d.arrivee - d.depart))::integer / 60) + 1440) % 1440,
                        ((extract(epoch from (d.fin - d.depart))::integer / 60) + 1440) % 1440)
           end
      into unpaid_trip_minutes
      from (
        select j.depart, j.arrivee, j.fin, greatest(coalesce(j.km_total, 0), coalesce(j.km_aller, 0) + coalesce(j.km_retour, 0)) as km
          from public.jobs j where j.user_id = p_user and j.job_date = p_date
         order by coalesce(left(j.depart::text, 5), '') collate "C", j.id::text collate "C"
         limit 1
      ) d;
  end if;
  return daily_work_minutes - coalesce(unpaid_trip_minutes, 0);
end;
$$;

-- Souper dû : jour de semaine, 615 minutes payées (journée de 8 h + 2 h 15), hors retour. « 4 jours de 10 h » : aucun souper (décision du 2026-11-13) sauf contremaître et sous-traitant.
create function public.is_meal_eligible(p_user uuid, p_date date)
returns boolean language sql stable security definer set search_path = '' as $$
  select extract(dow from p_date) not in (0, 6)
     and not exists (select 1 from public.profiles p where p.id = p_user and p.ten_hour_days and p.role not in ('foreman', 'subcontractor_1'))
     and public.meal_day_paid_minutes(p_user, p_date) >= 615;
$$;

create function public.reconcile_overtime_meal(p_user uuid, p_date date)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_user is null or p_date is null then return; end if;
  if not public.is_meal_eligible(p_user, p_date) then
    delete from public.manager_notifications n
     where n.type = 'meal_claim' and n.job_id in (select id from public.jobs where user_id = p_user and job_date = p_date);
    delete from public.meal_claims m where m.user_id = p_user and m.job_date = p_date and m.reviewed_by is null;
    update public.jobs set meal_claim_captured = false where user_id = p_user and job_date = p_date and meal_claim_captured is true;
  end if;
end;
$$;

create function public.trg_reconcile_overtime_meal()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    perform public.reconcile_overtime_meal(old.user_id, old.job_date);
    return old;
  end if;
  perform public.reconcile_overtime_meal(new.user_id, new.job_date);
  return new;
end;
$$;
create trigger reconcile_overtime_meal_after_delete after delete on public.jobs
  for each row execute function public.trg_reconcile_overtime_meal();
create trigger reconcile_overtime_meal_after_update after update of depart, arrivee, fin, return_time_minutes on public.jobs
  for each row execute function public.trg_reconcile_overtime_meal();

-- À l'insertion (employé) : seulement un souper dû, et les minutes sont celles du serveur.
create function public.meal_claims_validate()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null and public.get_my_role() is distinct from 'manager' then
    if not public.is_meal_eligible(new.user_id, new.job_date) then
      raise exception using errcode = '23514', message = 'meal_not_eligible';
    end if;
    new.daily_work_minutes := public.meal_day_paid_minutes(new.user_id, new.job_date);
  end if;
  return new;
end;
$$;
create trigger meal_claims_validate_insert before insert on public.meal_claims
  for each row execute function public.meal_claims_validate();

-- Un employé ne touche pas aux champs de révision.
create function public.protect_meal_review_fields()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null and public.get_my_role() is distinct from 'manager' then
    if tg_op = 'INSERT' then
      new.status := 'pending'; new.payroll_treatment := null; new.reviewed_by := null; new.reviewed_at := null;
    elsif new.status is distinct from old.status or new.payroll_treatment is distinct from old.payroll_treatment
       or new.reviewed_by is distinct from old.reviewed_by or new.reviewed_at is distinct from old.reviewed_at then
      raise exception 'Employees cannot change meal claim review fields';
    end if;
  end if;
  return new;
end;
$$;
create trigger meal_protect_review_fields before insert or update on public.meal_claims
  for each row execute function public.protect_meal_review_fields();

create function public.protect_parking_review_fields()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null and public.get_my_role() is distinct from 'manager' then
    if tg_op = 'INSERT' then
      if coalesce(new.status, 'pending') <> 'pending' or new.reviewed_by is not null or new.reviewed_at is not null then
        raise exception 'Employees cannot set parking review fields';
      end if;
    elsif new.status is distinct from old.status or new.reviewed_by is distinct from old.reviewed_by or new.reviewed_at is distinct from old.reviewed_at then
      raise exception 'Employees cannot set parking review fields';
    end if;
  end if;
  return new;
end;
$$;
create trigger parking_protect_review_fields before insert or update on public.parking_receipts
  for each row execute function public.protect_parking_review_fields();

-- ── Stationnement : plafond du jour, échéance des photos, chemins ───────────
create function public.enforce_daily_parking_cap()
returns trigger language plpgsql security definer set search_path = '' as $$
declare daily_total numeric;
begin
  select coalesce(sum(amount), 0) into daily_total from public.parking_receipts where user_id = new.user_id and job_date = new.job_date and id <> new.id;
  if daily_total + new.amount > 20 then
    raise exception 'The daily parking maximum is $20';
  end if;
  return new;
end;
$$;
create trigger parking_receipts_daily_cap before insert or update of amount, user_id, job_date on public.parking_receipts
  for each row execute function public.enforce_daily_parking_cap();

create function public.parking_receipts_set_expiry()
returns trigger language plpgsql security definer set search_path = '' as $$
declare retention integer;
begin
  select coalesce(o.evidence_retention_days, 30) into retention from public.overtime_settings o where o.id = true;
  retention := least(365, greatest(1, coalesce(retention, 30)));
  if tg_op = 'INSERT' then
    new.pictures_purged_at := null;
    new.expires_at := now() + make_interval(days => retention);
  elsif auth.uid() is not null then
    new.expires_at := old.expires_at;
    new.pictures_purged_at := old.pictures_purged_at;
    -- Des photos ajoutées après un nettoyage ouvrent une nouvelle fenêtre.
    if old.storage_path is null and new.storage_path is not null then
      new.pictures_purged_at := null;
      new.expires_at := now() + make_interval(days => retention);
    end if;
  end if;
  return new;
end;
$$;
create trigger parking_receipts_set_expiry before insert or update on public.parking_receipts
  for each row execute function public.parking_receipts_set_expiry();

create function public.validate_parking_receipt_paths()
returns trigger language plpgsql set search_path = '' as $$
declare p text;
begin
  if new.storage_path is null then
    if new.pictures_purged_at is null or cardinality(coalesce(new.extra_storage_paths, '{}')) > 0 then
      raise exception 'Parking receipt picture must be in the employee''s own folder' using errcode = 'check_violation';
    end if;
    return new;
  end if;
  if new.storage_path not like new.user_id::text || '/%' then
    raise exception 'Parking receipt picture must be in the employee''s own folder' using errcode = 'check_violation';
  end if;
  foreach p in array coalesce(new.extra_storage_paths, '{}') loop
    if p is null or p not like new.user_id::text || '/%' or p = new.storage_path then
      raise exception 'Parking receipt picture must be in the employee''s own folder' using errcode = 'check_violation';
    end if;
  end loop;
  if cardinality(new.extra_storage_paths) <> (select count(distinct x) from unnest(new.extra_storage_paths) x) then
    raise exception 'Duplicate parking receipt picture' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger parking_receipts_validate_paths before insert or update of storage_path, extra_storage_paths, user_id, pictures_purged_at on public.parking_receipts
  for each row execute function public.validate_parking_receipt_paths();

-- Téléchargement de preuves : l'auteur et l'heure viennent du serveur.
create function public.evidence_downloads_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.downloaded_by := auth.uid();
  new.downloaded_at := now();
  return new;
end;
$$;
create trigger evidence_downloads_guard before insert on public.evidence_downloads
  for each row execute function public.evidence_downloads_guard();

-- ── Révision par un gestionnaire (double authentification) ──────────────────
create function public.review_meal_claim(p_claim_id uuid, p_decision text, p_payroll_treatment text default null)
returns table (id uuid, status text, payroll_treatment text, reviewed_by uuid, reviewed_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid := auth.uid();
  current_claim public.meal_claims%rowtype;
  changed_claim public.meal_claims%rowtype;
begin
  if actor_id is null or public.get_my_role() <> 'manager' then
    raise exception using errcode = '42501', message = 'manager_role_required';
  end if;
  if p_decision is null or p_decision not in ('approved', 'rejected') then
    raise exception using errcode = '22023', message = 'invalid_review_decision';
  end if;
  if p_decision = 'approved' and coalesce(p_payroll_treatment, '') not in ('expense_reimbursement', 'taxable_benefit') then
    raise exception using errcode = '22023', message = 'invalid_payroll_treatment';
  end if;
  select * into current_claim from public.meal_claims c where c.id = p_claim_id for update;
  if current_claim.id is null then
    raise exception using errcode = 'P0002', message = 'meal_claim_not_found';
  end if;
  if current_claim.status <> 'pending' then
    raise exception using errcode = '40001', message = 'meal_claim_already_reviewed';
  end if;
  update public.meal_claims c
     set status = p_decision, payroll_treatment = case when p_decision = 'approved' then p_payroll_treatment else null end,
         reviewed_by = actor_id, reviewed_at = now()
   where c.id = current_claim.id returning * into changed_claim;
  return query select changed_claim.id, changed_claim.status, changed_claim.payroll_treatment, changed_claim.reviewed_by, changed_claim.reviewed_at;
end;
$$;

create function public.review_parking_claim(p_job_id uuid, p_decision text)
returns table (id uuid, job_id uuid, status text, reviewed_by uuid, reviewed_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid := auth.uid();
  current_claim public.parking_receipts%rowtype;
  changed_claim public.parking_receipts%rowtype;
begin
  if actor_id is null or public.get_my_role() <> 'manager' then
    raise exception using errcode = '42501', message = 'manager_role_required';
  end if;
  if p_decision is null or p_decision not in ('approved', 'rejected') then
    raise exception using errcode = '22023', message = 'invalid_review_decision';
  end if;
  select * into current_claim from public.parking_receipts p where p.job_id = p_job_id for update;
  if current_claim.id is null then
    raise exception using errcode = 'P0002', message = 'parking_claim_not_found';
  end if;
  if current_claim.status <> 'pending' then
    raise exception using errcode = '40001', message = 'parking_claim_already_reviewed';
  end if;
  update public.parking_receipts p set status = p_decision, reviewed_by = actor_id, reviewed_at = now()
   where p.id = current_claim.id returning * into changed_claim;
  return query select changed_claim.id, changed_claim.job_id, changed_claim.status, changed_claim.reviewed_by, changed_claim.reviewed_at;
end;
$$;

-- Audit des révisions (numéros seulement ; le statut est dans la clé permise `to`).
create function public.audit_meal_review()
returns trigger language plpgsql security definer set search_path = '' as $$
declare actor uuid := coalesce(new.reviewed_by, auth.uid());
begin
  if new.status is distinct from old.status and new.status in ('approved', 'rejected') then
    perform public.write_audit(actor, 'meal_reviewed', new.user_id, new.job_id, jsonb_build_object('to', new.status, 'job_date', new.job_date));
  end if;
  return new;
end;
$$;
create trigger audit_meal_review after update on public.meal_claims for each row execute function public.audit_meal_review();

create function public.audit_parking_review()
returns trigger language plpgsql security definer set search_path = '' as $$
declare actor uuid := coalesce(new.reviewed_by, auth.uid());
begin
  if new.status is distinct from old.status and new.status in ('approved', 'rejected') then
    perform public.write_audit(actor, 'parking_reviewed', new.user_id, new.job_id, jsonb_build_object('to', new.status, 'job_date', new.job_date));
  end if;
  return new;
end;
$$;
create trigger audit_parking_review after update on public.parking_receipts for each row execute function public.audit_parking_review();

-- ── Avis aux gestionnaires quand l'employé modifie une fiche qui porte une preuve ──
-- Une seule notification non lue par fiche : les modifications successives s'y fusionnent ; si tout revient à l'état d'origine, elle disparaît.
create function public.notify_overtime_job_edit()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  proof public.overtime_evidence%rowtype;
  diff jsonb := '{}'::jsonb;
  existing_id uuid;
  existing_changes jsonb;
  merged jsonb;
  k text;
  v jsonb;
begin
  -- Les changements d'un gestionnaire ou du service (approbation, réouverture, maintenance) ne créent pas d'avis.
  if auth.uid() is null or auth.uid() <> new.user_id then return new; end if;
  select * into proof from public.overtime_evidence where job_id = new.id order by created_at desc limit 1;
  if proof.id is null then return new; end if;
  if new.job_date is distinct from old.job_date then diff := diff || jsonb_build_object('job_date', jsonb_build_object('from', to_jsonb(old.job_date), 'to', to_jsonb(new.job_date))); end if;
  if new.ot is distinct from old.ot then diff := diff || jsonb_build_object('ot', jsonb_build_object('from', to_jsonb(old.ot), 'to', to_jsonb(new.ot))); end if;
  if new.depart is distinct from old.depart then diff := diff || jsonb_build_object('depart', jsonb_build_object('from', to_jsonb(old.depart::text), 'to', to_jsonb(new.depart::text))); end if;
  if new.arrivee is distinct from old.arrivee then diff := diff || jsonb_build_object('arrivee', jsonb_build_object('from', to_jsonb(old.arrivee::text), 'to', to_jsonb(new.arrivee::text))); end if;
  if new.fin is distinct from old.fin then diff := diff || jsonb_build_object('fin', jsonb_build_object('from', to_jsonb(old.fin::text), 'to', to_jsonb(new.fin::text))); end if;
  if new.return_time_minutes is distinct from old.return_time_minutes then diff := diff || jsonb_build_object('return_time_minutes', jsonb_build_object('from', to_jsonb(old.return_time_minutes), 'to', to_jsonb(new.return_time_minutes))); end if;
  if new.km_total is distinct from old.km_total then diff := diff || jsonb_build_object('km_total', jsonb_build_object('from', to_jsonb(old.km_total), 'to', to_jsonb(new.km_total))); end if;
  if new.km_retour is distinct from old.km_retour then diff := diff || jsonb_build_object('km_retour', jsonb_build_object('from', to_jsonb(old.km_retour), 'to', to_jsonb(new.km_retour))); end if;
  if diff = '{}'::jsonb then return new; end if;

  select id, coalesce(changes, '{}'::jsonb) into existing_id, existing_changes
    from public.manager_notifications mn
   where mn.job_id = new.id and mn.type = 'overtime_job_edited'
     and not exists (select 1 from public.manager_notification_reads r where r.notification_id = mn.id)
   order by mn.created_at desc limit 1;

  if existing_id is not null then
    merged := existing_changes;
    for k, v in select key, value from jsonb_each(diff) loop
      if merged ? k then merged := jsonb_set(merged, array[k, 'to'], v -> 'to');
      else merged := merged || jsonb_build_object(k, v); end if;
    end loop;
    for k, v in select key, value from jsonb_each(merged) loop
      if (v -> 'from') is not distinct from (v -> 'to') then merged := merged - k; end if;
    end loop;
    if merged = '{}'::jsonb then
      delete from public.manager_notifications where id = existing_id;
    else
      update public.manager_notifications set changes = merged, evidence_id = proof.id, daily_minutes = proof.daily_minutes, created_at = now() where id = existing_id;
    end if;
  else
    insert into public.manager_notifications (type, employee_id, job_id, evidence_id, daily_minutes, changes)
    values ('overtime_job_edited', new.user_id, new.id, proof.id, proof.daily_minutes, diff);
  end if;
  return new;
end;
$$;
create trigger jobs_notify_overtime_edit after update of job_date, ot, depart, arrivee, fin, km_total, km_aller, km_retour, return_time_minutes, status on public.jobs
  for each row execute function public.notify_overtime_job_edit();

-- ── Stockage : un compartiment privé par type de pièce ──────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('parking-receipts', 'parking-receipts', false, 10485760, array['image/jpeg', 'image/png', 'image/webp']),
  ('meal-receipts', 'meal-receipts', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
create policy "parking storage: owner upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'parking-receipts' and public.is_not_paused() and (storage.foldername(name))[1] = (auth.uid())::text);
create policy "parking storage: manager read" on storage.objects for select to authenticated
  using (bucket_id = 'parking-receipts' and public.get_my_role() = 'manager');
create policy "meal storage: owner upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'meal-receipts' and public.is_not_paused() and (storage.foldername(name))[1] = (auth.uid())::text);
create policy "meal storage: manager read" on storage.objects for select to authenticated
  using (bucket_id = 'meal-receipts' and public.get_my_role() = 'manager');

-- ── Droits et règles d'accès ────────────────────────────────────────────────
revoke all on table public.meal_claims, public.parking_receipts, public.evidence_downloads from anon, public, authenticated;
alter table public.meal_claims enable row level security;
alter table public.parking_receipts enable row level security;
alter table public.evidence_downloads enable row level security;
grant select, insert on public.meal_claims to authenticated;
grant select, insert, update on public.parking_receipts to authenticated;
grant select, insert on public.evidence_downloads to authenticated;
grant insert on public.manager_notifications to authenticated;

create policy meal_claims_read_own on public.meal_claims for select to authenticated using (user_id = (select auth.uid()));
create policy meal_claims_manager_read on public.meal_claims for select to authenticated using ((select public.get_my_role()) = 'manager');
create policy meal_claims_owner_insert on public.meal_claims for insert to authenticated
  with check ((select public.is_not_paused()) and user_id = (select auth.uid())
              and exists (select 1 from public.jobs j where j.id = meal_claims.job_id and j.user_id = (select auth.uid())));

create policy parking_receipts_read_own on public.parking_receipts for select to authenticated using (user_id = (select auth.uid()));
create policy parking_receipts_manager_read on public.parking_receipts for select to authenticated using ((select public.get_my_role()) = 'manager');
create policy parking_receipts_owner_insert on public.parking_receipts for insert to authenticated
  with check ((select public.is_not_paused()) and user_id = (select auth.uid())
              and exists (select 1 from public.jobs j where j.id = parking_receipts.job_id and j.user_id = (select auth.uid())));
create policy parking_receipts_owner_update_pending on public.parking_receipts for update to authenticated
  using (public.is_not_paused() and user_id = auth.uid() and status = 'pending')
  with check (public.is_not_paused() and user_id = auth.uid() and status = 'pending' and reviewed_by is null and reviewed_at is null);

-- Un employé n'ajoute que des avis de repas ou de stationnement, pour sa propre fiche.
create policy manager_notifications_owner_insert on public.manager_notifications for insert to authenticated
  with check ((select public.is_not_paused()) and employee_id = (select auth.uid()) and type in ('meal_claim', 'parking_receipt')
              and exists (select 1 from public.jobs j where j.id = manager_notifications.job_id and j.user_id = (select auth.uid())));

create policy evidence_downloads_manager_read on public.evidence_downloads for select to authenticated using (public.get_my_role() = 'manager');
create policy evidence_downloads_manager_insert on public.evidence_downloads for insert to authenticated with check (public.get_my_role() = 'manager');

revoke all on function public.meal_day_paid_minutes(uuid, date), public.is_meal_eligible(uuid, date), public.reconcile_overtime_meal(uuid, date),
  public.trg_reconcile_overtime_meal(), public.meal_claims_validate(), public.protect_meal_review_fields(), public.protect_parking_review_fields(),
  public.enforce_daily_parking_cap(), public.parking_receipts_set_expiry(), public.validate_parking_receipt_paths(), public.evidence_downloads_guard(),
  public.review_meal_claim(uuid, text, text), public.review_parking_claim(uuid, text), public.audit_meal_review(), public.audit_parking_review(),
  public.notify_overtime_job_edit() from public, anon, authenticated;
grant execute on function public.review_meal_claim(uuid, text, text), public.review_parking_claim(uuid, text) to authenticated;
