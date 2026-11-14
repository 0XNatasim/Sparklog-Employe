-- Sparklog-Employés — schéma neuf du côté 1. Migration 0002 : rôles, double authentification des gestionnaires, lecture des profils.
-- Mêmes noms et même logique que Sparklog (0103, 0133) : `get_my_role()` ne renvoie `manager` qu'avec une session `aal2` ;
-- `is_privileged()` = propriétaire + `aal2`. Aucune donnée nominative : le profil ne contient que le numéro, le rôle et la pause.

alter table public.profiles
  add column admin_sections text[] not null default '{}';

-- Vrai quand la session a passé le deuxième facteur (jeton `aal` = aal2).
create function public.session_is_aal2()
returns boolean language sql stable set search_path = '' as $$
  select coalesce((select auth.jwt() ->> 'aal'), '') = 'aal2';
$$;

-- owner / manager (et admin avec sections accordées) → 'manager' seulement avec aal2, sinon 'employee' ;
-- admin sans section, sous-traitant et contremaître → 'employee' ; employé → 'employee'.
create function public.get_my_role()
returns text language sql stable security definer set search_path = '' as $$
  select case
           when p.role in ('owner', 'manager')
             or (p.role = 'admin' and coalesce(array_length(p.admin_sections, 1), 0) > 0)
             then case when public.session_is_aal2() then 'manager' else 'employee' end
           when p.role in ('admin', 'subcontractor_1', 'foreman') then 'employee'
           else p.role
         end
    from public.profiles p where p.id = auth.uid();
$$;

create function public.is_privileged()
returns boolean language sql stable security definer set search_path = '' as $$
  select public.session_is_aal2() and exists (
    select 1 from public.profiles where id = auth.uid() and role = 'owner'
  );
$$;

create function public.is_active_employee()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles
     where id = auth.uid() and role in ('employee', 'foreman', 'subcontractor_1') and is_paused = false
  );
$$;

revoke all on function public.session_is_aal2(), public.get_my_role(), public.is_privileged(), public.is_active_employee() from public, anon;
grant execute on function public.session_is_aal2(), public.get_my_role(), public.is_privileged(), public.is_active_employee() to authenticated;

-- Un gestionnaire (aal2) lit tous les profils (numéros et rôles seulement) ; chacun lit le sien (0001).
create policy profiles_select_managers on public.profiles for select to authenticated
  using (public.get_my_role() = 'manager');

-- Aucune écriture par le navigateur : créer, mettre en pause ou changer un rôle passe par une fonction serveur (côté 2, `PLAN.md` 9.4).
