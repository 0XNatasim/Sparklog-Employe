-- Test de la migration 0001 sur un PostgreSQL local (voir scripts/test-next-schema.sh). Échoue (exit != 0) au premier écart.
\set ON_ERROR_STOP on
do $$
declare
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid();
  code text; code2 text; r record; n integer; ok boolean;
begin
  insert into auth.users (id, email) values (u1, '1042@pointage.invalid'), (u2, '2077@pointage.invalid');
  insert into public.profiles (id, employee_number) values (u1, 1042), (u2, 2077);

  -- 1. le code a 10 caractères de l'alphabet, et seul son condensat est stocké
  code := public.issue_activation_code(u1);
  assert code ~ '^[A-HJKMNP-Z2-9]{10}$', 'format du code : ' || code;
  assert (select count(*) from public.activation_codes where profile_id = u1 and code_hash like '$2%') = 1, 'condensat bcrypt';
  assert not exists (select 1 from public.activation_codes where code_hash = code), 'jamais en clair';

  -- 2. mauvais code : invalid, essai compté ; numéro inconnu : même réponse
  select * into r from public.consume_activation_code(1042, 'AAAAAAAAAA'); assert r.status = 'invalid', 'mauvais code';
  select * into r from public.consume_activation_code(9999, code);        assert r.status = 'invalid', 'numéro inconnu';
  assert (select attempts from public.activation_codes where profile_id = u1) = 1, 'essai compté malgré le retour';

  -- 3. bon code : ok, usage unique
  select * into r from public.consume_activation_code(1042, code); assert r.status = 'ok' and r.profile_id = u1, 'bon code';
  assert (select first_activated_at from public.profiles where id = u1) is not null, 'activation notée';
  select * into r from public.consume_activation_code(1042, code); assert r.status = 'invalid', 'code déjà utilisé';

  -- 4. blocage après 5 essais ratés, même avec le bon code ensuite
  code := public.issue_activation_code(u2);
  for n in 1..5 loop perform public.consume_activation_code(2077, 'ZZZZZZZZZZ'); end loop;
  select * into r from public.consume_activation_code(2077, code); assert r.status = 'locked', 'verrouillé après 5 essais';

  -- 5. un nouveau code révoque l'ancien (et repart à zéro)
  code2 := public.issue_activation_code(u2);
  select * into r from public.consume_activation_code(2077, code);  assert r.status = 'invalid', 'ancien code révoqué';
  select * into r from public.consume_activation_code(2077, code2); assert r.status = 'ok', 'nouveau code';

  -- 6. expiration
  code := public.issue_activation_code(u1, interval '-1 minute');
  select * into r from public.consume_activation_code(1042, code); assert r.status = 'expired', 'expiré';

  -- 7. profil en pause : pas d'activation
  update public.profiles set is_paused = true where id = u1;
  code := public.issue_activation_code(u1);
  select * into r from public.consume_activation_code(1042, code); assert r.status = 'invalid', 'pause';

  -- 8. numéro hors bornes refusé
  begin
    insert into public.profiles (id, employee_number) values (gen_random_uuid(), 12);
    assert false, 'numéro trop court accepté';
  exception when foreign_key_violation or check_violation then null; end;
end $$;

-- 9. droits : le navigateur (authenticated / anon) ne touche ni aux codes ni aux fonctions
set role authenticated;
do $$ begin
  begin perform 1 from public.activation_codes; assert false, 'authenticated lit les codes'; exception when insufficient_privilege then null; end;
  begin perform public.issue_activation_code(gen_random_uuid()); assert false, 'authenticated émet un code'; exception when insufficient_privilege then null; end;
  begin perform * from public.consume_activation_code(1042, 'x'); assert false, 'authenticated consomme un code'; exception when insufficient_privilege then null; end;
end $$;
set role anon;
do $$ begin
  begin perform 1 from public.profiles; assert false, 'anon lit les profils'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'OK : migration 0001' as resultat;
