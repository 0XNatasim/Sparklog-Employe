-- Sparklog-Employés (côté 1) — migration 0018 : les numéros d'employé peuvent aller de 1 à 999999 (décision de la propriétaire du 2026-11-16 : numéros 0001, 0002… à 4 chiffres).
-- Avant : 1000 à 999999. Le numéro reste un ENTIER ; l'écran l'affiche sur 4 chiffres (« 0001 ») avec `formatEmployeeNumber`.
do $$
declare c record;
begin
  for c in select conrelid::regclass as tbl, conname from pg_constraint
           where contype = 'c' and connamespace = 'public'::regnamespace and pg_get_constraintdef(oid) like '%1000%' and pg_get_constraintdef(oid) like '%999999%' loop
    execute format('alter table %s drop constraint %I', c.tbl, c.conname);
  end loop;
end $$;
alter table public.profiles add constraint profiles_employee_number_range check (employee_number between 1 and 999999);
alter table public.foreman_reports add constraint foreman_reports_audited_number_range check (audited_employee_number is null or audited_employee_number between 1 and 999999);
