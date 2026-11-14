#!/usr/bin/env bash
# Mutation du schéma neuf : scripts/mutate-next.sh <migration.sql> <NNNN> "<texte exact>" "<remplacement>"
set -uo pipefail
f="$1"; n="$2"; a="$3"; b="$4"
cp "$f" /tmp/mutnext.bak
python3 - "$f" "$a" "$b" <<'PY'
import sys
p,a,b=sys.argv[1:4]; s=open(p).read()
if a not in s: sys.exit("texte introuvable : "+a[:60])
open(p,"w").write(s.replace(a,b,1))
PY
[ $? -ne 0 ] && { cp /tmp/mutnext.bak "$f"; exit 2; }
out=$(./scripts/test-next-schema.sh 2>&1 | grep -E "OK : migration $n|ERROR" | head -1 | cut -c1-130)
cp /tmp/mutnext.bak "$f"
echo "[$n] ${a:0:55} => ${out:-?}"
