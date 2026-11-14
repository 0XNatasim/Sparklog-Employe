#!/usr/bin/env bash
# Reconstruit, sur un PostgreSQL 16 local jetable (/tmp/legacydb, port 54330), la base de Sparklog V2.4.258 à partir de supabase/migrations/ (avec de faux schémas Supabase).
# Sert de RÉFÉRENCE pour relever la structure exacte avant d'écrire le schéma neuf de supabase/next/ :
#   pg_dump -h /tmp/legacydb -p 54330 -U postgres -s -x -O -t public.jobs postgres
#   psql -h /tmp/legacydb -p 54330 -U postgres -c "select pg_get_functiondef(...)"
# Usage : scripts/rebuild-legacy-db.sh (en root). Résultat attendu : ok=150 bad=0.
set -uo pipefail
BIN=/usr/lib/postgresql/16/bin; ROOT=$(cd "$(dirname "$0")/.." && pwd); S=/tmp
DIR=/tmp/legacydb; PORT=54330
su postgres -c "$BIN/pg_ctl -D $DIR/data -m immediate stop" >/dev/null 2>&1 || true
rm -rf $DIR; mkdir -p $DIR; chown postgres $DIR
su postgres -c "$BIN/initdb -D $DIR/data -A trust -U postgres >/dev/null"
su postgres -c "$BIN/pg_ctl -D $DIR/data -o '-p $PORT -k $DIR' -w -l $DIR/log start >/dev/null"
export PGOPTIONS="-c check_function_bodies=off"
PSQL="psql -X -q -h $DIR -p $PORT -U postgres -d postgres"
$PSQL -v ON_ERROR_STOP=1 <<'SQL'
create role anon nologin; create role authenticated nologin; create role service_role nologin; create role supabase_auth_admin nologin; create role postgres_admin nologin;
create schema auth; create schema extensions; create schema storage; create schema vault; create schema cron; create schema net;
create extension pgcrypto with schema extensions; create extension btree_gist with schema extensions;
create table auth.users (id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb, raw_app_meta_data jsonb, encrypted_password text, created_at timestamptz default now(), last_sign_in_at timestamptz, banned_until timestamptz, email_confirmed_at timestamptz, phone text);
create table auth.mfa_factors (id uuid primary key default gen_random_uuid(), user_id uuid, status text, factor_type text);
create function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
create function auth.uid() returns uuid language sql stable as $$ select nullif(auth.jwt() ->> 'sub', '')::uuid $$;
create function auth.role() returns text language sql stable as $$ select coalesce(auth.jwt() ->> 'role', 'anon') $$;
create table storage.buckets (id text primary key, name text, public boolean default false, file_size_limit bigint, allowed_mime_types text[], created_at timestamptz default now());
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner uuid, created_at timestamptz default now(), updated_at timestamptz default now(), metadata jsonb);
alter table storage.objects enable row level security;
create function storage.foldername(name text) returns text[] language sql immutable as $$ select string_to_array(name, '/') $$;
create table vault.secrets (id uuid primary key default gen_random_uuid(), name text, secret text, description text, created_at timestamptz default now());
create view vault.decrypted_secrets as select id, name, secret as decrypted_secret from vault.secrets;
create function vault.create_secret(s text, n text default null, d text default '') returns uuid language sql as $$ insert into vault.secrets(name, secret, description) values (n, s, d) returning id $$;
create function vault.update_secret(i uuid, s text default null, n text default null, d text default null) returns void language sql as $$ update vault.secrets set secret = coalesce(s, secret) where id = i $$;
create table cron.job (jobid serial primary key, jobname text, schedule text, command text);
create function cron.schedule(n text, s text, c text) returns bigint language sql as $$ insert into cron.job(jobname, schedule, command) values (n, s, c) returning jobid::bigint $$;
create function cron.unschedule(n text) returns boolean language sql as $$ delete from cron.job where jobname = n returning true $$;
create function net.http_post(url text, body jsonb default '{}', params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds int default 5000) returns bigint language sql as $$ select 1::bigint $$;
create table net._http_response (id bigint, status_code int, content text, created timestamptz default now());
grant usage on schema public, auth, extensions, storage to anon, authenticated, service_role;
SQL
ok=0; bad=0; : > $S/legacy_errors.txt
for f in $(ls $ROOT/supabase/migrations/*.sql | sort); do
  if $PSQL -v ON_ERROR_STOP=1 -f $f >/dev/null 2>$S/err.tmp; then ok=$((ok+1)); else bad=$((bad+1)); echo "== $(basename $f)" >> $S/legacy_errors.txt; head -3 $S/err.tmp >> $S/legacy_errors.txt; fi
done
echo "ok=$ok bad=$bad"; head -60 $S/legacy_errors.txt
