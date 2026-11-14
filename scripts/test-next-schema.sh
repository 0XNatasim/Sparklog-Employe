#!/usr/bin/env bash
# Applique supabase/next/*.sql sur un PostgreSQL 16 local jetable (avec de faux schémas Supabase) puis lance les tests SQL.
# Usage : scripts/test-next-schema.sh   (à lancer en root : le serveur tourne sous l'utilisateur système `postgres`)
set -euo pipefail
BIN=/usr/lib/postgresql/16/bin
DIR=$(mktemp -d); chown postgres "$DIR"; PORT=54329
ROOT=$(cd "$(dirname "$0")/.." && pwd)
trap 'su postgres -c "$BIN/pg_ctl -D $DIR/data -m immediate stop" >/dev/null 2>&1 || true; rm -rf "$DIR"' EXIT
su postgres -c "$BIN/initdb -D $DIR/data -A trust -U postgres >/dev/null"
su postgres -c "$BIN/pg_ctl -D $DIR/data -o '-p $PORT -k $DIR' -w -l $DIR/log start >/dev/null"
PSQL="psql -X -q -v ON_ERROR_STOP=1 -h $DIR -p $PORT -U postgres -d postgres"
$PSQL <<'SQL'
create role anon nologin; create role authenticated nologin; create role service_role nologin;
create schema auth; create schema extensions; create schema storage;
create table auth.users (id uuid primary key, email text);
create function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
create function auth.uid() returns uuid language sql stable as $$ select nullif(auth.jwt() ->> 'sub', '')::uuid $$;
create table storage.buckets (id text primary key, name text, public boolean default false, file_size_limit bigint, allowed_mime_types text[], created_at timestamptz default now());
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner uuid, owner_id text, created_at timestamptz default now(), updated_at timestamptz default now(), metadata jsonb);
alter table storage.objects enable row level security;
create function storage.foldername(name text) returns text[] language sql immutable as $$ select string_to_array(name, '/') $$;
grant usage on schema public, auth, extensions, storage to anon, authenticated, service_role;
grant select, insert on storage.objects to authenticated;
SQL
# Chaque migration est appliquée puis son test est lancé AVANT la suivante : un test décrit l'état de sa propre migration
# (une migration ultérieure peut remplacer une fonction, ce que son propre test vérifie).
for f in "$ROOT"/supabase/next/[0-9]*.sql; do
  n=$(basename "$f" | cut -c1-4)
  echo "-- $(basename "$f")"; $PSQL -f "$f"
  t="$ROOT/supabase/next/test-$n.sql"
  if [ -f "$t" ]; then echo "-- test-$n.sql"; $PSQL -f "$t"; fi
done
# Relevé de la structure obtenue (pour scripts/check-app-against-schema.mjs) : DUMP_SCHEMA=/chemin/schema.json scripts/test-next-schema.sh
if [ -n "${DUMP_SCHEMA:-}" ]; then
  $PSQL -At -c "select jsonb_build_object(
    'columns', (select jsonb_object_agg(table_name, cols) from (select table_name, jsonb_agg(column_name order by ordinal_position) cols from information_schema.columns where table_schema = 'public' group by table_name) t),
    'functions', (select coalesce(jsonb_agg(distinct proname), '[]') from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'))" > "$DUMP_SCHEMA"
fi
