-- Sparklog-Employés — schéma neuf du côté 1 (pointage). Migration 0001 : identité par numéro d'employé + codes d'activation.
-- NE PAS appliquer à la base de Sparklog. Cible : la NOUVELLE base du côté 1 (PLAN.md, étapes 2, 5 et 9.4).
--
-- Principes :
--  * aucun nom, courriel, téléphone, NAS ni montant de paie ici (invariant I1) ;
--  * `auth.users.email` portera une adresse factice `<numéro>@pointage.invalid` (créée par une fonction Edge, pas par ce fichier) ;
--  * le numéro d'employé identifie, il n'authentifie pas : il ne sert qu'avec un code d'activation, puis un mot de passe choisi (idée 1) ;
--  * le code d'activation n'est jamais stocké en clair (condensat bcrypt), à usage unique, 72 h, 5 essais, et n'est lisible que par `service_role`.
-- Supabase place pgcrypto dans le schéma `extensions`.

create extension if not exists pgcrypto with schema extensions;

-- ── Profil minimal ──────────────────────────────────────────────────────────
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  employee_number integer not null unique check (employee_number between 1000 and 999999),
  role text not null default 'employee'
    check (role in ('employee', 'foreman', 'subcontractor_1', 'manager', 'admin', 'owner')),
  is_paused boolean not null default false,
  first_activated_at timestamptz,
  created_at timestamptz not null default now()
);
comment on column public.profiles.employee_number is
  'Numéro attribué par le côté 2 (aléatoire, non séquentiel, jamais réutilisé). Pseudonyme : seul le côté 2 sait à qui il appartient.';

revoke all on table public.profiles from anon, public, authenticated;
grant select on table public.profiles to authenticated;
alter table public.profiles enable row level security;
create policy profiles_select_own on public.profiles for select to authenticated using (id = auth.uid());

-- ── Codes d'activation ──────────────────────────────────────────────────────
create table public.activation_codes (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  code_hash text not null,
  expires_at timestamptz not null,
  attempts integer not null default 0 check (attempts >= 0),
  used_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);
create index activation_codes_profile_idx on public.activation_codes (profile_id, created_at desc);

-- Aucun droit pour le navigateur : uniquement les deux fonctions ci-dessous, appelées par une fonction Edge (service_role).
revoke all on table public.activation_codes from anon, public, authenticated;
alter table public.activation_codes enable row level security;

-- Code lisible : 10 caractères sans O, 0, I, 1, L (31 symboles, environ 49 bits). Tirage par rejet (octets >= 248 écartés) : aucun biais.
create function public.issue_activation_code(p_profile_id uuid, p_ttl interval default interval '72 hours')
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  bytes bytea;
  code text := '';
  i integer;
begin
  if not exists (select 1 from public.profiles where id = p_profile_id) then
    raise exception 'unknown_profile' using errcode = 'P0002';
  end if;
  while length(code) < 10 loop
    bytes := extensions.gen_random_bytes(32);
    for i in 0..31 loop
      exit when length(code) >= 10;
      if get_byte(bytes, i) < 248 then
        code := code || substr(alphabet, (get_byte(bytes, i) % 31) + 1, 1);
      end if;
    end loop;
  end loop;
  -- un seul code valide à la fois : l'ancien est révoqué
  update public.activation_codes set revoked_at = now()
   where profile_id = p_profile_id and used_at is null and revoked_at is null;
  insert into public.activation_codes (profile_id, code_hash, expires_at)
  values (p_profile_id, extensions.crypt(code, extensions.gen_salt('bf', 10)), now() + p_ttl);
  return code;
end;
$$;

-- Résultat : ok | invalid | expired | locked. Les essais ratés sont enregistrés (pas de `raise` : il annulerait le compte d'essais).
-- Un numéro inconnu répond `invalid`, comme un mauvais code (pas d'énumération des numéros).
create function public.consume_activation_code(p_employee_number integer, p_code text)
returns table (status text, profile_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  prof uuid;
  rec public.activation_codes%rowtype;
  max_attempts constant integer := 5;
begin
  select p.id into prof from public.profiles p where p.employee_number = p_employee_number and not p.is_paused;
  if prof is null then
    perform extensions.crypt(coalesce(p_code, ''), extensions.gen_salt('bf', 10)); -- temps de réponse comparable
    return query select 'invalid'::text, null::uuid;
    return;
  end if;
  select * into rec from public.activation_codes c
   where c.profile_id = prof and c.used_at is null and c.revoked_at is null
   order by c.created_at desc limit 1 for update;
  if not found then
    return query select 'invalid'::text, null::uuid;
    return;
  end if;
  if rec.attempts >= max_attempts then
    return query select 'locked'::text, null::uuid;
    return;
  end if;
  if rec.expires_at <= now() then
    return query select 'expired'::text, null::uuid;
    return;
  end if;
  if rec.code_hash = extensions.crypt(coalesce(p_code, ''), rec.code_hash) then
    update public.activation_codes set used_at = now() where id = rec.id;
    update public.profiles set first_activated_at = coalesce(first_activated_at, now()) where id = prof;
    return query select 'ok'::text, prof;
  else
    update public.activation_codes set attempts = attempts + 1 where id = rec.id;
    return query select 'invalid'::text, null::uuid;
  end if;
end;
$$;

revoke all on function public.issue_activation_code(uuid, interval) from public, anon, authenticated;
revoke all on function public.consume_activation_code(integer, text) from public, anon, authenticated;
grant execute on function public.issue_activation_code(uuid, interval) to service_role;
grant execute on function public.consume_activation_code(integer, text) to service_role;
