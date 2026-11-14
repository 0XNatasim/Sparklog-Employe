-- Sparklog-Employés — schéma neuf du côté 1. Migration 0009 : inventaire de fin de quart, groupes d'employés, stock minimum par groupe.
-- Relevé dans une base reconstruite à partir des 150 migrations de Sparklog V2.4.258 (0071, 0097, 0105, 0114, 0121, 0122, 0127, 0128 et voisines).
--
-- Écarts voulus par rapport à Sparklog :
--  * un groupe est un entrepôt ou une équipe (nom du groupe) ; ses membres sont des **numéros** : `inventory_negative_alerts` renvoie `employee_number` et non un nom ;
--  * `dismiss_inventory_negative_alert` écrit dans le journal d'audit sans nom (0005), clés permises seulement ;
--  * `inventory_stock_levels` et `inventory_negative_alerts` comptent les 7 derniers jours en heure de Montréal (Sparklog : date du serveur) ;
--  * chaque table a ses droits écrits en toutes lettres (`revoke all` avant `grant`) ;
--  * `validate_job_submission_contract` (0006) est remplacée : elle ajoute l'inventaire de fin de quart.
-- Les lectures de captures (OCR) sont faites par la fonction Edge `process_inventory_screenshot` avec la clé de service : elle écrit `inventory_items`.
-- Le domaine d'OCR (aujourd'hui un service externe) est à revoir (`PLAN.md`, étape 12.3) : les captures ne doivent jamais contenir de nom.

-- ── Groupes d'employés (entrepôts, équipes) ─────────────────────────────────
create table public.employee_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 60),
  note text check (note is null or char_length(note) <= 300),
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  low_stock_alert boolean not null default false
);
create unique index employee_groups_name_uniq on public.employee_groups (lower(btrim(name)));
create trigger employee_groups_updated_at before update on public.employee_groups for each row execute function public.set_updated_at();

create table public.employee_group_members (
  group_id uuid not null references public.employee_groups(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  added_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index employee_group_members_user_idx on public.employee_group_members (user_id);

-- ── Captures d'inventaire et lignes lues ────────────────────────────────────
create table public.inventory_screenshots (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  job_date date not null,
  slot smallint not null check (slot between 1 and 5),
  storage_path text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  ocr_status text not null default 'pending' check (ocr_status in ('pending', 'processed', 'needs_review', 'failed')),
  list_total integer check (list_total is null or list_total between 0 and 1000),
  defective_total integer check (defective_total is null or defective_total between 0 and 1000),
  unique (user_id, job_date, slot)
);
comment on column public.inventory_screenshots.slot is '1 à 3 : captures de la liste d''équipement ; 4 : photo « Produits défectueux ».';
create index inventory_screenshots_date_idx on public.inventory_screenshots (job_date, user_id);
create index inventory_screenshots_expires_at_idx on public.inventory_screenshots (expires_at);

create table public.inventory_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  job_date date not null,
  slot smallint not null check (slot between 1 and 5),
  code text not null check (code ~ '^EQ[0-9]{6}$'),
  name text not null,
  quantity numeric(10, 2) check (quantity between -99999 and 99999),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  section text not null default 'inventory' check (section in ('inventory', 'defective')),
  unique (user_id, job_date, slot, section, code)
);
comment on column public.inventory_items.section is 'inventory : liste d''équipement ; defective : lignes lues sous « Produits défectueux ».';
create index inventory_items_date_user_idx on public.inventory_items (job_date, user_id);
create index inventory_items_expires_at_idx on public.inventory_items (expires_at);
create index inventory_items_neg_alert_idx on public.inventory_items (user_id, job_date, section) where quantity < 0 and section = 'inventory';

create table public.inventory_alert_dismissals (
  user_id uuid not null references public.profiles(id) on delete cascade,
  job_date date not null,
  dismissed_by uuid not null,
  dismissed_at timestamptz not null default now(),
  primary key (user_id, job_date)
);

-- Minimum par employé et par appareil, pour chaque groupe.
create table public.inventory_min_ratios (
  group_id uuid not null references public.employee_groups(id) on delete cascade,
  code text not null check (code ~ '^EQ[0-9]{6}$'),
  name text not null check (char_length(btrim(name)) between 1 and 200),
  per_employee numeric(8, 3) not null check (per_employee > 0 and per_employee <= 1000),
  updated_by uuid default auth.uid() references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (group_id, code)
);

-- Journal (compteurs seulement) de la lecture d'une liste : sert à comprendre pourquoi un employé a été bloqué à l'étape Inventaire.
create table public.inventory_reading_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  job_date date not null,
  reading_state text,
  lines_read integer check (lines_read is null or lines_read between 0 and 1000),
  lines_expected integer check (lines_expected is null or lines_expected between 0 and 1000),
  lines_missing integer check (lines_missing is null or lines_missing between 0 and 1000),
  lines_unreadable integer check (lines_unreadable is null or lines_unreadable between 0 and 1000),
  step_block text check (step_block is null or step_block in ('wait', 'retake', 'override')),
  reading_known boolean not null default true,
  complement_tried boolean not null default false,
  created_at timestamptz not null default now()
);
create index inventory_reading_log_day_idx on public.inventory_reading_log (job_date desc, user_id);

create function public.inventory_min_ratios_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_by := auth.uid();
  new.updated_at := now();
  return new;
end;
$$;
create trigger inventory_min_ratios_guard before insert or update on public.inventory_min_ratios for each row execute function public.inventory_min_ratios_guard();

create function public.inventory_reading_log_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.user_id := auth.uid();
  new.created_at := now();
  return new;
end;
$$;
create trigger inventory_reading_log_guard before insert on public.inventory_reading_log for each row execute function public.inventory_reading_log_guard();

-- ── Alertes de quantité négative (dernière liste de chacun, 7 derniers jours) ──
create function public.inventory_negative_alerts()
returns table (user_id uuid, employee_number integer, job_date date, code text, item_name text, quantity numeric)
language sql stable security definer set search_path = '' as $$
  with latest as (
    select i.user_id, max(i.job_date) as job_date
      from public.inventory_items i
     where public.get_my_role() = 'manager' and i.section = 'inventory'
       and i.job_date >= (timezone('America/Toronto', now()))::date - 7
     group by i.user_id
  )
  select distinct on (l.user_id, l.job_date, i.code) l.user_id, p.employee_number, l.job_date, i.code, i.name as item_name, i.quantity
    from latest l
    join public.inventory_items i on i.user_id = l.user_id and i.job_date = l.job_date
    join public.profiles p on p.id = l.user_id
   where i.section = 'inventory' and i.quantity < 0
     and not exists (select 1 from public.inventory_alert_dismissals d where d.user_id = l.user_id and d.job_date = l.job_date)
   order by l.user_id, l.job_date, i.code, i.slot desc;
$$;

create function public.dismiss_inventory_negative_alert(p_user_id uuid, p_job_date date)
returns void language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  inserted uuid;
begin
  if actor is null or not public.session_is_aal2() or not exists (
    select 1 from public.profiles where id = actor and role in ('manager', 'owner') and not coalesce(is_paused, false)
  ) then
    raise exception 'inventory_alert_not_allowed' using errcode = '42501';
  end if;
  if p_user_id is null or p_job_date is null then
    raise exception 'inventory_alert_missing' using errcode = '22023';
  end if;
  if not exists (select 1 from public.inventory_items where user_id = p_user_id and job_date = p_job_date and section = 'inventory' and quantity < 0) then
    raise exception 'inventory_alert_none' using errcode = 'P0002';
  end if;
  insert into public.inventory_alert_dismissals (user_id, job_date, dismissed_by) values (p_user_id, p_job_date, actor)
  on conflict (user_id, job_date) do nothing returning user_id into inserted;
  if inserted is null then return; end if;
  perform public.write_audit(actor, 'inventory_negative_dismissed', p_user_id, null, jsonb_build_object('job_date', p_job_date));
end;
$$;

-- ── Stock par groupe : minimum = ratio × effectif (membres non en pause), contre la dernière liste de chacun ──
create function public.inventory_stock_levels()
returns table (group_id uuid, group_name text, code text, item_name text, per_employee numeric, headcount integer, minimum numeric,
               on_hand numeric, lists_counted integer, is_low boolean, alert_enabled boolean)
language sql stable security definer set search_path = '' as $$
  with members as (
    select m.group_id, p.id as user_id
      from public.employee_group_members m join public.profiles p on p.id = m.user_id
     where public.get_my_role() = 'manager' and not p.is_paused
  ),
  latest as (
    select i.user_id, max(i.job_date) as job_date
      from public.inventory_items i
     where i.section = 'inventory' and i.job_date >= (timezone('America/Toronto', now()))::date - 7
       and i.user_id in (select user_id from members)
     group by i.user_id
  ),
  -- Une ligne par employé et par code : une quantité lue l'emporte sur une quantité coupée au bord d'une capture, puis la dernière case.
  merged as (
    select distinct on (i.user_id, i.code) i.user_id, i.code, i.quantity
      from public.inventory_items i join latest l on l.user_id = i.user_id and l.job_date = i.job_date
     where i.section = 'inventory'
     order by i.user_id, i.code, (i.quantity is not null) desc, i.slot desc
  ),
  heads as (select m.group_id, count(*)::integer as headcount from members m group by m.group_id),
  lists as (select m.group_id, count(*)::integer as n from members m join latest l on l.user_id = m.user_id group by m.group_id),
  held as (select m.group_id, x.code, sum(coalesce(x.quantity, 0)) as on_hand from members m join merged x on x.user_id = m.user_id group by m.group_id, x.code)
  select r.group_id, g.name, r.code, r.name, r.per_employee, coalesce(h.headcount, 0), round(r.per_employee * coalesce(h.headcount, 0), 2),
         coalesce(d.on_hand, 0), coalesce(l.n, 0),
         coalesce(l.n, 0) > 0 and coalesce(d.on_hand, 0) < r.per_employee * coalesce(h.headcount, 0), g.low_stock_alert
    from public.inventory_min_ratios r
    join public.employee_groups g on g.id = r.group_id
    left join heads h on h.group_id = r.group_id
    left join lists l on l.group_id = r.group_id
    left join held d on d.group_id = r.group_id and d.code = r.code
   where public.get_my_role() = 'manager'
   order by g.name, r.name, r.code;
$$;

-- ── Contrat de soumission COMPLET avec l'inventaire (remplace celui de 0006) ──
create or replace function public.validate_job_submission_contract()
returns trigger language plpgsql set search_path = '' as $$
declare
  duration_minutes integer;
  other_minutes integer;
  day_has_evidence boolean;
  is_office_employee boolean;
  daily_regular_minutes integer := 480;
  first_trip_unpaid boolean;
  inventory_enabled boolean;
  unpaid_trip_minutes integer := 0;
  -- Le propriétaire soumet pour l'employé (create_job_for_employee / submit_manager_entry_for_employee) : la preuve ne peut venir que
  -- de l'employé, donc seul ce contrôle est sauté ; intervalle, chevauchement et kilomètres restent contrôlés. L'indicateur n'est posé
  -- que dans ces fonctions `security definer`, pour leur transaction.
  owner_submit boolean := coalesce(current_setting('sparklog.owner_submit', true), '') = 'on';
begin
  if new.status <> 'submitted' then return new; end if;
  if tg_op = 'UPDATE' and old.status not in ('saved', 'updated') then return new; end if;
  if new.started_at is null or new.ended_at is null then
    raise exception using errcode = '23514', message = 'invalid_job_interval';
  end if;
  duration_minutes := extract(epoch from (new.ended_at - new.started_at))::integer / 60;
  if duration_minutes <= 0 or duration_minutes > 960 then
    raise exception using errcode = '23514', message = 'invalid_job_interval';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(new.user_id::text, 0));
  select coalesce(p.role = 'admin', false), coalesce(p.first_trip_unpaid, false), coalesce(p.inventory_screenshots_enabled, false)
    into is_office_employee, first_trip_unpaid, inventory_enabled
    from public.profiles p where p.id = new.user_id;
  -- « 4 jours de 10 h » : le temps supplémentaire, donc sa preuve, commence après 10 h (jamais pour contremaître ni sous-traitant).
  if exists (select 1 from public.profiles p where p.id = new.user_id and p.ten_hour_days and p.role not in ('foreman', 'subcontractor_1')) then
    daily_regular_minutes := 600;
  end if;
  select
    coalesce(sum(case
      when j.started_at is not null and j.ended_at is not null then extract(epoch from (j.ended_at - j.started_at))::integer / 60
      when j.depart is not null and j.fin is not null then (extract(epoch from (j.fin - j.depart))::integer / 60 + 1440) % 1440
      else 0 end), 0)::integer,
    coalesce(bool_or(j.overtime_evidence_captured), false)
  into other_minutes, day_has_evidence
  from public.jobs j
  where j.user_id = new.user_id and j.job_date = new.job_date and j.id <> new.id
    and j.status in ('saved', 'updated', 'submitted', 'approved');

  -- Employé « premier trajet non payé » : le seuil se compte sur le temps PAYÉ. Premier trajet de la journée (Départ le plus tôt, puis id),
  -- limité à la durée de cette fiche, nul sans Arrivée, et nul quand cette première fiche fait 65 km ou plus (depuis le 2026-10-11).
  -- Jumeau de dayFirstTripUnpaidMinutes dans supabase/functions/_shared/payroll_engine.js.
  if coalesce(first_trip_unpaid, false) then
    select case
             when d.depart is null or d.arrivee is null or d.fin is null then 0
             when new.job_date >= date '2026-10-11' and d.km >= 65 then 0
             else least(((extract(epoch from (d.arrivee - d.depart))::integer / 60) + 1440) % 1440,
                        ((extract(epoch from (d.fin - d.depart))::integer / 60) + 1440) % 1440)
           end
      into unpaid_trip_minutes
      from (
        select x.id, x.depart, x.arrivee, x.fin, x.km from (
          select j.id, j.depart, j.arrivee, j.fin, greatest(coalesce(j.km_total, 0), coalesce(j.km_aller, 0) + coalesce(j.km_retour, 0)) as km
            from public.jobs j
           where j.user_id = new.user_id and j.job_date = new.job_date and j.id <> new.id and j.status in ('saved', 'updated', 'submitted', 'approved')
          union all
          select new.id, new.depart, new.arrivee, new.fin, greatest(coalesce(new.km_total, 0), coalesce(new.km_aller, 0) + coalesce(new.km_retour, 0))
        ) x
        order by coalesce(left(x.depart::text, 5), '') collate "C", x.id::text collate "C"
        limit 1
      ) d;
  end if;

  if not owner_submit and not coalesce(is_office_employee, false)
     and duration_minutes + other_minutes - coalesce(unpaid_trip_minutes, 0) > daily_regular_minutes
     and not (coalesce(new.overtime_evidence_captured, false) or day_has_evidence) then
    raise exception using errcode = '23514', message = 'overtime_evidence_required';
  end if;
  -- Inventaire de fin de quart : la journée doit porter au moins une capture d'inventaire Field Service (le personnel de bureau en est exempté,
  -- et les jours avant la date de déploiement sont tolérés). La complétude se juge par le nombre de lignes de la liste, pas par le nombre de photos.
  -- La photo « produits défectueux » (case 4) ne compte pas comme capture d'inventaire.
  if not owner_submit and not coalesce(is_office_employee, false) and coalesce(inventory_enabled, false)
     and new.job_date >= date '2026-10-08'
     and not exists (select 1 from public.inventory_screenshots s where s.user_id = new.user_id and s.job_date = new.job_date and s.slot between 1 and 3) then
    raise exception using errcode = '23514', message = 'inventory_screenshots_required';
  end if;

  if exists (
    select 1 from public.jobs j
     where j.user_id = new.user_id and j.id <> new.id and j.status in ('submitted', 'approved')
       and j.started_at is not null and j.ended_at is not null
       and tstzrange(j.started_at, j.ended_at, '[)') && tstzrange(new.started_at, new.ended_at, '[)')
  ) then
    raise exception using errcode = '23P01', message = 'overlapping_job_interval';
  end if;
  if new.return_time_minutes > duration_minutes then
    raise exception using errcode = '23514', message = 'return_time_exceeds_job_interval';
  end if;
  if new.km_total is null or new.km_aller is null or new.km_retour is null
     or new.km_total < 0 or new.km_aller < 0 or new.km_retour < 0
     or new.km_retour > new.km_total
     or abs((new.km_aller + new.km_retour) - new.km_total) > 0.001 then
    raise exception using errcode = '23514', message = 'invalid_job_kilometres';
  end if;
  return new;
end;
$$;

-- ── Stockage des captures : compartiment privé, dossier = identifiant de l'employé ──
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('inventory-screenshots', 'inventory-screenshots', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
create policy "inventory storage: owner upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'inventory-screenshots' and public.is_not_paused() and (storage.foldername(name))[1] = (auth.uid())::text);
create policy "inventory storage: owner read" on storage.objects for select to authenticated
  using (bucket_id = 'inventory-screenshots' and (storage.foldername(name))[1] = (auth.uid())::text);
create policy "inventory storage: owner delete" on storage.objects for delete to authenticated
  using (bucket_id = 'inventory-screenshots' and public.is_not_paused() and (storage.foldername(name))[1] = (auth.uid())::text);
create policy "inventory storage: manager read" on storage.objects for select to authenticated
  using (bucket_id = 'inventory-screenshots' and (select public.get_my_role()) = 'manager');

-- ── Droits et règles d'accès ────────────────────────────────────────────────
revoke all on table public.employee_groups, public.employee_group_members, public.inventory_screenshots, public.inventory_items,
  public.inventory_alert_dismissals, public.inventory_min_ratios, public.inventory_reading_log from anon, public, authenticated;
alter table public.employee_groups enable row level security;
alter table public.employee_group_members enable row level security;
alter table public.inventory_screenshots enable row level security;
alter table public.inventory_items enable row level security;
alter table public.inventory_alert_dismissals enable row level security;
alter table public.inventory_min_ratios enable row level security;
alter table public.inventory_reading_log enable row level security;
grant select, insert, update, delete on public.employee_groups, public.employee_group_members, public.inventory_min_ratios to authenticated;
grant select, insert, update on public.inventory_screenshots to authenticated;
grant select on public.inventory_items to authenticated;
grant select, insert on public.inventory_reading_log to authenticated;

create policy employee_groups_managers on public.employee_groups for all to authenticated
  using (public.get_my_role() = 'manager') with check (public.get_my_role() = 'manager');
create policy employee_group_members_managers on public.employee_group_members for all to authenticated
  using (public.get_my_role() = 'manager') with check (public.get_my_role() = 'manager');
create policy inventory_min_ratios_managers on public.inventory_min_ratios for all to authenticated
  using (public.get_my_role() = 'manager') with check (public.get_my_role() = 'manager');
create policy inventory_items_owner_read on public.inventory_items for select to authenticated using (user_id = (select auth.uid()));
create policy inventory_items_manager_read on public.inventory_items for select to authenticated using ((select public.get_my_role()) = 'manager');
create policy inventory_screenshots_owner_read on public.inventory_screenshots for select to authenticated using (user_id = (select auth.uid()));
create policy inventory_screenshots_manager_read on public.inventory_screenshots for select to authenticated using ((select public.get_my_role()) = 'manager');
create policy inventory_screenshots_owner_insert on public.inventory_screenshots for insert to authenticated
  with check (public.is_not_paused() and user_id = (select auth.uid()));
create policy inventory_screenshots_owner_update on public.inventory_screenshots for update to authenticated
  using (public.is_not_paused() and user_id = (select auth.uid())) with check (public.is_not_paused() and user_id = (select auth.uid()));
create policy inventory_reading_log_manager_read on public.inventory_reading_log for select to authenticated using (public.get_my_role() = 'manager');
create policy inventory_reading_log_own_insert on public.inventory_reading_log for insert to authenticated with check (user_id = auth.uid());

revoke all on function public.inventory_min_ratios_guard(), public.inventory_reading_log_guard(), public.inventory_negative_alerts(),
  public.dismiss_inventory_negative_alert(uuid, date), public.inventory_stock_levels() from public, anon, authenticated;
grant execute on function public.inventory_negative_alerts(), public.dismiss_inventory_negative_alert(uuid, date), public.inventory_stock_levels() to authenticated;
