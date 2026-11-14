-- Sparklog-Employés — schéma neuf du côté 1. Migration 0003 : réglages du temps, jours fériés, OT prédéfinis, durée de conservation des preuves.
-- Structure relevée dans une base reconstruite à partir des 150 migrations de Sparklog V2.4.258 ; mêmes contraintes et mêmes règles d'accès.
--
-- Écarts voulus par rapport à Sparklog :
--  * `company_capture_settings` (lecture de la carte CCQ, de la date de naissance, du syndicat) n'existe pas : le côté 1 ne recueille aucun de ces renseignements ;
--  * les OT prédéfinis ne contiennent aucun prénom ni nom (l'ancienne liste avait un libellé nominatif : il n'est pas repris) ;
--  * chaque table a ses droits écrits en toutes lettres (`revoke all` avant `grant`).

-- ── Réglages du temps (une seule ligne) ─────────────────────────────────────
create table public.company_time_settings (
  id boolean primary key default true check (id = true),
  timezone text not null default 'America/Toronto' check (timezone = 'America/Toronto'),
  daily_deadline time not null default '23:59:00',
  anomaly_long_day_minutes integer not null default 720 check (anomaly_long_day_minutes between 60 and 1440),
  anomaly_high_km integer not null default 300 check (anomaly_high_km between 1 and 5000),
  updated_at timestamptz not null default now()
);
insert into public.company_time_settings (id) values (true);

-- ── Conservation des preuves de temps supplémentaire (une seule ligne) ──────
create table public.overtime_settings (
  id boolean primary key default true check (id = true),
  evidence_retention_days integer not null default 30 check (evidence_retention_days between 1 and 365),
  updated_at timestamptz not null default now()
);
insert into public.overtime_settings (id) values (true);

-- ── Jours fériés de l'entreprise ────────────────────────────────────────────
create table public.company_holidays (
  holiday_date date primary key,
  label text not null,
  created_at timestamptz not null default now()
);
insert into public.company_holidays (holiday_date, label) values
  ('2026-01-01', 'Jour de l''An'),
  ('2026-01-02', 'Vacances de la construction — hiver'),
  ('2026-01-03', 'Vacances de la construction — hiver'),
  ('2026-04-03', 'Vendredi saint'),
  ('2026-04-06', 'Lundi de Pâques'),
  ('2026-05-18', 'Journée nationale des patriotes'),
  ('2026-06-24', 'Fête nationale du Québec'),
  ('2026-07-03', 'Fête du Canada'),
  ('2026-09-07', 'Fête du Travail'),
  ('2026-10-12', 'Action de grâces'),
  ('2026-11-13', 'Jour du Souvenir'),
  ('2026-12-25', 'Noël'),
  ('2027-01-01', 'Jour de l''An'),
  ('2027-03-26', 'Vendredi saint'),
  ('2027-03-29', 'Lundi de Pâques'),
  ('2027-05-24', 'Journée nationale des patriotes'),
  ('2027-06-24', 'Fête nationale du Québec'),
  ('2027-07-02', 'Fête du Canada'),
  ('2027-09-06', 'Fête du Travail'),
  ('2027-10-11', 'Action de grâces'),
  ('2027-11-12', 'Jour du Souvenir'),
  ('2027-12-25', 'Noël'),
  ('2028-01-01', 'Jour de l''An'),
  ('2028-04-14', 'Vendredi saint'),
  ('2028-04-17', 'Lundi de Pâques'),
  ('2028-05-22', 'Journée nationale des patriotes'),
  ('2028-06-23', 'Fête nationale du Québec'),
  ('2028-06-30', 'Fête du Canada'),
  ('2028-09-04', 'Fête du Travail'),
  ('2028-10-09', 'Action de grâces'),
  ('2028-11-10', 'Jour du Souvenir'),
  ('2028-12-25', 'Noël');

-- ── OT prédéfinis (la liste déroulante de la saisie) ────────────────────────
-- Jamais un numéro de 4 chiffres ou plus : les numéros d'OT sont repérés ailleurs (réutilisation d'un OT), un libellé ne doit pas les imiter.
create table public.preset_work_orders (
  id uuid primary key default gen_random_uuid(),
  label text not null check (char_length(btrim(label)) between 2 and 60 and btrim(label) !~ '^[0-9]{4,}$'),
  sort_order integer not null default 100 check (sort_order between 0 and 10000),
  active boolean not null default true,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create unique index preset_work_orders_label_uniq on public.preset_work_orders (lower(btrim(label)));
insert into public.preset_work_orders (label, sort_order) values
  ('PAUSE SÉCURITÉ', 10), ('FORMATION HILO EMBAUCHE', 20), ('FORMATION BRITTON', 30), ('FORMATION HQ', 40), ('CONTREMAÎTRE', 51);

-- ── Droits et règles d'accès ────────────────────────────────────────────────
revoke all on table public.company_time_settings, public.overtime_settings, public.company_holidays, public.preset_work_orders from anon, public, authenticated;
alter table public.company_time_settings enable row level security;
alter table public.overtime_settings enable row level security;
alter table public.company_holidays enable row level security;
alter table public.preset_work_orders enable row level security;

-- Tout compte connecté lit ; seuls les gestionnaires (aal2) modifient les réglages. Les jours fériés ne s'écrivent que par migration.
grant select on public.company_time_settings, public.overtime_settings, public.company_holidays, public.preset_work_orders to authenticated;
grant update (timezone, daily_deadline, anomaly_long_day_minutes, anomaly_high_km, updated_at) on public.company_time_settings to authenticated;
grant update (evidence_retention_days, updated_at) on public.overtime_settings to authenticated;
grant insert, update, delete on public.preset_work_orders to authenticated;

create policy time_settings_read on public.company_time_settings for select to authenticated using (true);
create policy time_settings_manager_update on public.company_time_settings for update to authenticated
  using ((select public.get_my_role()) = 'manager') with check ((select public.get_my_role()) = 'manager');
create policy overtime_settings_read on public.overtime_settings for select to authenticated using (true);
create policy overtime_settings_manager_update on public.overtime_settings for update to authenticated
  using ((select public.get_my_role()) = 'manager') with check ((select public.get_my_role()) = 'manager');
create policy holidays_read on public.company_holidays for select to authenticated using (true);
create policy preset_work_orders_read on public.preset_work_orders for select to authenticated using (true);
create policy preset_work_orders_manager_insert on public.preset_work_orders for insert to authenticated with check (public.get_my_role() = 'manager');
create policy preset_work_orders_manager_update on public.preset_work_orders for update to authenticated
  using (public.get_my_role() = 'manager') with check (public.get_my_role() = 'manager');
create policy preset_work_orders_manager_delete on public.preset_work_orders for delete to authenticated using (public.get_my_role() = 'manager');
