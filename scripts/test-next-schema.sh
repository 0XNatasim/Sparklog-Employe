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
create schema auth; create schema extensions;
create table auth.users (id uuid primary key, email text);
create function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
create function auth.uid() returns uuid language sql stable as $$ select nullif(auth.jwt() ->> 'sub', '')::uuid $$;
grant usage on schema public, auth, extensions to anon, authenticated, service_role;
SQL
for f in "$ROOT"/supabase/next/[0-9]*.sql; do echo "-- $(basename "$f")"; $PSQL -f "$f"; done
for t in "$ROOT"/supabase/next/test-*.sql; do echo "-- $(basename "$t")"; $PSQL -f "$t"; done
