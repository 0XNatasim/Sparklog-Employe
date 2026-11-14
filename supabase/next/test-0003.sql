-- Test de la migration 0003 (voir scripts/test-next-schema.sh).
\set ON_ERROR_STOP on
create function pg_temp.as_user(p_id uuid, p_aal text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_id, 'aal', p_aal)::text, false);
end $$;

-- contenu initial
do $$ begin
  assert (select count(*) from public.company_time_settings) = 1 and (select timezone from public.company_time_settings) = 'America/Toronto', 'réglages du temps';
  assert (select evidence_retention_days from public.overtime_settings) = 30, 'conservation des preuves : 30 jours';
  assert (select count(*) from public.company_holidays) = 32, '32 jours fériés (2026-2028)';
  assert exists (select 1 from public.company_holidays where holiday_date = '2026-12-25' and label = 'Noël'), 'Noël 2026';
  assert exists (select 1 from public.company_holidays where holiday_date = '2027-07-02' and label = 'Fête du Canada'), 'Fête du Canada 2027 (jour de la convention)';
  assert (select count(*) from public.preset_work_orders) = 5, 'cinq OT prédéfinis';
  assert not exists (select 1 from public.preset_work_orders where label ilike '%karine%'), 'aucun prénom dans les OT prédéfinis';
  assert to_regclass('public.company_capture_settings') is null, 'aucun réglage de capture de renseignements personnels';
end $$;

-- contraintes
do $$ begin
  begin update public.company_time_settings set timezone = 'UTC'; assert false, 'fuseau libre'; exception when check_violation then null; end;
  begin update public.company_time_settings set anomaly_high_km = 0; assert false, 'km hors bornes'; exception when check_violation then null; end;
  begin update public.company_time_settings set anomaly_long_day_minutes = 30; assert false, 'durée hors bornes'; exception when check_violation then null; end;
  begin update public.overtime_settings set evidence_retention_days = 400; assert false, 'conservation hors bornes'; exception when check_violation then null; end;
  begin insert into public.company_time_settings (id) values (false); assert false, 'deuxième ligne'; exception when check_violation then null; end;
  begin insert into public.preset_work_orders (label) values ('12345'); assert false, 'libellé = numéro d''OT'; exception when check_violation then null; end;
  begin insert into public.preset_work_orders (label) values ('X'); assert false, 'libellé trop court'; exception when check_violation then null; end;
  begin insert into public.preset_work_orders (label) values ('  pause sécurité '); assert false, 'doublon sans casse'; exception when unique_violation then null; end;
  insert into public.preset_work_orders (label) values ('OT 123');  -- 3 chiffres : permis
end $$;

-- accès selon le rôle
select set_config('test.emp', id::text, false) from public.profiles where employee_number = 3005;
select set_config('test.mgr', id::text, false) from public.profiles where employee_number = 3002;

set role anon;
do $$ begin
  begin perform 1 from public.company_holidays; assert false, 'anon lit les jours fériés'; exception when insufficient_privilege then null; end;
  begin perform 1 from public.preset_work_orders; assert false, 'anon lit les OT'; exception when insufficient_privilege then null; end;
end $$;

set role authenticated;
select pg_temp.as_user(current_setting('test.emp')::uuid, 'aal1');
do $$ declare n integer; begin
  assert (select count(*) from public.company_holidays) = 32, 'employé lit les jours fériés';
  assert (select count(*) from public.preset_work_orders) = 6, 'employé lit les OT';
  update public.company_time_settings set anomaly_high_km = 999; get diagnostics n = row_count; assert n = 0, 'employé ne modifie pas les réglages';
  update public.overtime_settings set evidence_retention_days = 90; get diagnostics n = row_count; assert n = 0, 'employé ne modifie pas la conservation';
  begin insert into public.preset_work_orders (label) values ('PAR EMPLOYE'); assert false, 'employé crée un OT'; exception when insufficient_privilege or others then
    if sqlerrm like 'employé%' then raise; end if; end;
  delete from public.preset_work_orders; get diagnostics n = row_count; assert n = 0, 'employé ne supprime pas les OT';
  begin delete from public.company_holidays; assert false, 'employé supprime un jour férié'; exception when insufficient_privilege then null; end;
  begin insert into public.company_holidays values ('2030-01-01', 'x'); assert false, 'employé crée un jour férié'; exception when insufficient_privilege then null; end;
end $$;

select pg_temp.as_user(current_setting('test.mgr')::uuid, 'aal1');
do $$ declare n integer; begin
  update public.company_time_settings set anomaly_high_km = 999; get diagnostics n = row_count; assert n = 0, 'gestionnaire sans aal2 ne modifie pas';
end $$;

select pg_temp.as_user(current_setting('test.mgr')::uuid, 'aal2');
do $$ declare n integer; begin
  update public.company_time_settings set anomaly_high_km = 400; get diagnostics n = row_count; assert n = 1, 'gestionnaire aal2 modifie les réglages';
  update public.overtime_settings set evidence_retention_days = 45; get diagnostics n = row_count; assert n = 1, 'gestionnaire aal2 modifie la conservation';
  insert into public.preset_work_orders (label, sort_order) values ('NOUVEAU TYPE', 60);
  update public.preset_work_orders set active = false where label = 'NOUVEAU TYPE'; get diagnostics n = row_count; assert n = 1, 'gestionnaire modifie un OT';
  delete from public.preset_work_orders where label = 'NOUVEAU TYPE'; get diagnostics n = row_count; assert n = 1, 'gestionnaire supprime un OT';
  begin update public.company_time_settings set id = false; assert false, 'id modifiable'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'OK : migration 0003' as resultat;
