-- Sparklog-Employés — schéma neuf du côté 1. Migration 0011 : annonces aux employés, publiées par le côté 2.
-- Relevé dans une base reconstruite à partir des 150 migrations de Sparklog V2.4.258 (0002, 0010, 0096, 0107 et voisines : `manager_broadcasts`,
-- `broadcast_recipients`, `broadcast_revisions`, `edit_broadcast`, `withdraw_broadcast_unread`).
--
-- Modèle : le côté 2 (qui connaît les noms) écrit l'annonce ; le côté 1 la **diffuse** aux numéros visés et enregistre qui l'a lue. Les gestionnaires du côté 1 n'écrivent pas
-- d'annonce (décision du 2026-11-14). Toute écriture passe par une fonction réservée à la clé de service (`PLAN.md` 3.4, 9.2 et 12.1).
--
-- Écarts voulus par rapport à Sparklog :
--  * `announcements` / `announcement_recipients` / `announcement_revisions` remplacent `manager_broadcasts` / `broadcast_recipients` / `broadcast_revisions` (l'écran de l'employé est à adapter) ;
--  * pas d'expéditeur : aucune colonne `sender_id`, `edited_by` ni nom ; l'audit est écrit sans acteur (le service) et sans texte libre ;
--  * le destinataire est un **numéro d'employé** ; l'audience est `all`, `groups` (membres d'un groupe, 0009) ou `selected` (liste de numéros) ;
--  * publication **idempotente** par clé d'action : une relance ne crée ni annonce ni destinataire en double ;
--  * modification avec **version attendue** (conflit si l'annonce a changé depuis la lecture) ;
--  * un employé ne peut **que** accuser réception (une fois) : il ne peut pas se désabonner, ni modifier une autre colonne ;
--  * pièces jointes dans un compartiment privé, lisibles seulement par les destinataires non retirés **de cette annonce** (Sparklog : tout compte connecté lisait tout le compartiment).
-- Le texte d'une annonce est du texte libre : le côté 2 vérifie qu'il ne contient pas de nom (`PLAN.md` 3.5).

create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  action_key uuid not null unique,
  body text not null default '' check (char_length(body) <= 5000),
  audience text not null check (audience in ('all', 'groups', 'selected')),
  attachments jsonb not null default '[]'::jsonb check (jsonb_typeof(attachments) = 'array' and jsonb_array_length(attachments) <= 10),
  created_at timestamptz not null default now(),
  edited_at timestamptz
);
comment on column public.announcements.attachments is 'Images et PDF du message, dans l''ordre : [{path, kind: image|pdf, name}] dans le compartiment announcement-files.';

create table public.announcement_recipients (
  announcement_id uuid not null references public.announcements(id) on delete cascade,
  employee_id uuid not null references public.profiles(id) on delete cascade,
  acknowledged_at timestamptz,
  withdrawn_at timestamptz,
  primary key (announcement_id, employee_id)
);
create index announcement_recipients_unacked_idx on public.announcement_recipients (employee_id) where acknowledged_at is null;

create table public.announcement_revisions (
  id uuid primary key default gen_random_uuid(),
  announcement_id uuid not null references public.announcements(id) on delete cascade,
  body text not null,
  attachments jsonb not null default '[]'::jsonb,
  edited_at timestamptz not null default now(),
  reread boolean not null default false,
  reread_count integer not null default 0
);
create index announcement_revisions_announcement_idx on public.announcement_revisions (announcement_id, edited_at);

-- Pièces jointes valides : au plus 10, chacune {path: <identifiant>.<jpg|jpeg|png|webp|pdf>, kind: image|pdf}.
create function public.announcement_attachments_valid(p_attachments jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select jsonb_typeof(p_attachments) = 'array'
     and jsonb_array_length(p_attachments) <= 10
     and not exists (
       select 1 from jsonb_array_elements(p_attachments) a
        where jsonb_typeof(a) <> 'object'
           or coalesce(a ->> 'path', '') !~ '^[A-Za-z0-9-]+\.(jpg|jpeg|png|webp|pdf)$'
           or coalesce(a ->> 'kind', '') not in ('image', 'pdf')
     );
$$;

-- L'employé n'accuse réception qu'une fois : la date ne se remet pas à zéro ni ne se change.
create function public.announcement_recipients_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if auth.uid() is not null then
    if old.acknowledged_at is not null then
      new.acknowledged_at := old.acknowledged_at;
    elsif new.acknowledged_at is not null then
      new.acknowledged_at := now();
    end if;
  end if;
  return new;
end;
$$;
create trigger announcement_recipients_guard before update on public.announcement_recipients
  for each row execute function public.announcement_recipients_guard();

-- ── Publier (clé de service) ────────────────────────────────────────────────
-- Destinataires : `all` = tous les employés actifs (employé, contremaître, sous-traitant, bureau), `groups` = les membres non en pause des groupes donnés,
-- `selected` = les numéros donnés (les numéros inconnus ou en pause sont ignorés).
create function public.publish_announcement(
  p_action_key uuid, p_body text, p_audience text, p_group_ids uuid[] default null, p_employee_numbers integer[] default null,
  p_attachments jsonb default '[]'::jsonb)
returns table (id uuid, recipient_count integer)
language plpgsql security definer set search_path = '' as $$
declare
  clean_body text := btrim(coalesce(p_body, ''));
  attachments jsonb := coalesce(p_attachments, '[]'::jsonb);
  existing public.announcements%rowtype;
  new_id uuid;
  n integer;
begin
  if p_action_key is null then
    raise exception using errcode = '22023', message = 'action_key_required';
  end if;
  -- Relance (réponse perdue) : la même annonce, sans doublon.
  select * into existing from public.announcements a where a.action_key = p_action_key;
  if existing.id is not null then
    return query select existing.id, (select count(*)::integer from public.announcement_recipients r where r.announcement_id = existing.id);
    return;
  end if;
  if p_audience is null or p_audience not in ('all', 'groups', 'selected') then
    raise exception using errcode = '22023', message = 'announcement_audience_invalid';
  end if;
  if not public.announcement_attachments_valid(attachments) then
    raise exception using errcode = '22023', message = 'announcement_attachments_invalid';
  end if;
  if char_length(clean_body) > 5000 then
    raise exception using errcode = '22023', message = 'announcement_too_long';
  end if;
  if clean_body = '' and jsonb_array_length(attachments) = 0 then
    raise exception using errcode = '22023', message = 'announcement_empty';
  end if;

  insert into public.announcements (action_key, body, audience, attachments) values (p_action_key, clean_body, p_audience, attachments) returning announcements.id into new_id;
  if p_audience = 'all' then
    insert into public.announcement_recipients (announcement_id, employee_id)
    select new_id, p.id from public.profiles p where p.role in ('employee', 'foreman', 'subcontractor_1', 'admin') and not p.is_paused;
  elsif p_audience = 'groups' then
    insert into public.announcement_recipients (announcement_id, employee_id)
    select distinct new_id, p.id from public.employee_group_members m join public.profiles p on p.id = m.user_id
     where m.group_id = any (coalesce(p_group_ids, '{}')) and not p.is_paused and p.role in ('employee', 'foreman', 'subcontractor_1', 'admin');
  else
    insert into public.announcement_recipients (announcement_id, employee_id)
    select distinct new_id, p.id from public.profiles p
     where p.employee_number = any (coalesce(p_employee_numbers, '{}')) and not p.is_paused and p.role in ('employee', 'foreman', 'subcontractor_1', 'admin');
  end if;
  get diagnostics n = row_count;
  if n = 0 then
    raise exception using errcode = '22023', message = 'announcement_no_recipients';
  end if;
  perform public.write_audit(null, 'announcement_published', null, null, jsonb_build_object('count', n));
  return query select new_id, n;
end;
$$;

-- ── Modifier (clé de service, version attendue) ─────────────────────────────
-- `p_expected_version` = coalesce(edited_at, created_at) lu avant la modification. Si `p_reread`, ceux qui avaient accusé réception doivent relire.
create function public.edit_announcement(p_announcement_id uuid, p_expected_version timestamptz, p_body text, p_attachments jsonb, p_reread boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  old_row public.announcements%rowtype;
  new_body text := btrim(coalesce(p_body, ''));
  new_attachments jsonb := coalesce(p_attachments, '[]'::jsonb);
  reread_count integer := 0;
  pending_count integer := 0;
begin
  if not public.announcement_attachments_valid(new_attachments) then
    raise exception using errcode = '22023', message = 'announcement_attachments_invalid';
  end if;
  if char_length(new_body) > 5000 then
    raise exception using errcode = '22023', message = 'announcement_too_long';
  end if;
  if new_body = '' and jsonb_array_length(new_attachments) = 0 then
    raise exception using errcode = '22023', message = 'announcement_empty';
  end if;
  select * into old_row from public.announcements a where a.id = p_announcement_id for update;
  if old_row.id is null then
    raise exception using errcode = 'P0002', message = 'announcement_not_found';
  end if;
  if p_expected_version is null or coalesce(old_row.edited_at, old_row.created_at) is distinct from p_expected_version then
    raise exception using errcode = '40001', message = 'announcement_state_changed';
  end if;
  if coalesce(p_reread, false) then
    update public.announcement_recipients set acknowledged_at = null
     where announcement_id = p_announcement_id and acknowledged_at is not null and withdrawn_at is null;
    get diagnostics reread_count = row_count;
  end if;
  select count(*) into pending_count from public.announcement_recipients where announcement_id = p_announcement_id and acknowledged_at is null and withdrawn_at is null;
  insert into public.announcement_revisions (announcement_id, body, attachments, reread, reread_count)
  values (p_announcement_id, old_row.body, old_row.attachments, coalesce(p_reread, false), reread_count);
  update public.announcements set body = new_body, attachments = new_attachments, edited_at = clock_timestamp() where id = p_announcement_id;
  perform public.write_audit(null, 'announcement_edited', null, null,
                             jsonb_build_object('count', reread_count, 'reason_code', case when coalesce(p_reread, false) then 'reread' else 'edit' end));
  return jsonb_build_object('reread_count', reread_count, 'pending_count', pending_count);
end;
$$;

-- ── Retirer l'annonce à ceux qui ne l'ont pas encore lue (clé de service) ───
create function public.withdraw_announcement_unread(p_announcement_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare withdrawn integer;
begin
  perform 1 from public.announcements a where a.id = p_announcement_id for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'announcement_not_found';
  end if;
  update public.announcement_recipients set withdrawn_at = now()
   where announcement_id = p_announcement_id and acknowledged_at is null and withdrawn_at is null;
  get diagnostics withdrawn = row_count;
  if withdrawn > 0 then
    perform public.write_audit(null, 'announcement_withdrawn', null, null, jsonb_build_object('count', withdrawn));
  end if;
  return withdrawn;
end;
$$;

-- ── Pièces jointes : compartiment privé, lisibles par les destinataires de CETTE annonce ──
create function public.announcement_file_readable(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.announcement_recipients r join public.announcements a on a.id = r.announcement_id
     where r.employee_id = auth.uid() and r.withdrawn_at is null
       and a.attachments @> jsonb_build_array(jsonb_build_object('path', p_name))
  );
$$;
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('announcement-files', 'announcement-files', false, 10485760, array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
create policy "announcement files: recipient read" on storage.objects for select to authenticated
  using (bucket_id = 'announcement-files' and public.announcement_file_readable(name));

-- ── Droits et règles d'accès ────────────────────────────────────────────────
revoke all on table public.announcements, public.announcement_recipients, public.announcement_revisions from anon, public, authenticated;
alter table public.announcements enable row level security;
alter table public.announcement_recipients enable row level security;
alter table public.announcement_revisions enable row level security;
grant select on public.announcements, public.announcement_recipients to authenticated;
grant update (acknowledged_at) on public.announcement_recipients to authenticated;

create policy announcements_recipient_read on public.announcements for select to authenticated
  using (exists (select 1 from public.announcement_recipients r where r.announcement_id = announcements.id and r.employee_id = (select auth.uid()) and r.withdrawn_at is null));
create policy announcement_recipients_read_own on public.announcement_recipients for select to authenticated
  using (employee_id = (select auth.uid()) and withdrawn_at is null);
create policy announcement_recipients_ack_own on public.announcement_recipients for update to authenticated
  using (employee_id = (select auth.uid()) and withdrawn_at is null) with check (employee_id = (select auth.uid()) and withdrawn_at is null);

revoke all on function public.announcement_attachments_valid(jsonb), public.announcement_recipients_guard(), public.publish_announcement(uuid, text, text, uuid[], integer[], jsonb),
  public.edit_announcement(uuid, timestamptz, text, jsonb, boolean), public.withdraw_announcement_unread(uuid), public.announcement_file_readable(text) from public, anon, authenticated;
grant execute on function public.announcement_file_readable(text) to authenticated;
grant execute on function public.announcement_attachments_valid(jsonb), public.publish_announcement(uuid, text, text, uuid[], integer[], jsonb),
  public.edit_announcement(uuid, timestamptz, text, jsonb, boolean), public.withdraw_announcement_unread(uuid) to service_role;
