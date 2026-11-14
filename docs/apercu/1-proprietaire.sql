-- À coller dans l'éditeur SQL APRÈS avoir créé l'utilisateur 1000@pointage.invalid dans Authentication › Users (mode d'emploi, étape 5).
-- Crée le profil « propriétaire » de TEST (numéro 1000, donnée inventée).
insert into public.profiles (id, employee_number, role)
select id, 1000, 'owner' from auth.users where email = '1000@pointage.invalid'
on conflict (id) do nothing;

-- Doit afficher 1 ligne : si 0, l'utilisateur 1000@pointage.invalid n'existe pas encore dans Authentication › Users.
select employee_number, role from public.profiles where employee_number = 1000;
