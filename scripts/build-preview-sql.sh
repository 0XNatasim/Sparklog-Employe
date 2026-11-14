#!/usr/bin/env bash
# Assemble supabase/next/[0-9]*.sql (sans les tests) en UN fichier à coller dans l'éditeur SQL d'un projet Supabase de TEST.
# Usage : scripts/build-preview-sql.sh > docs/apercu/schema-apercu.sql   (un test vérifie que le fichier commité est à jour)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
echo "-- Sparklog-Employés : schéma complet du côté 1 (généré par scripts/build-preview-sql.sh ; ne pas modifier à la main)."
echo "-- À coller UNE SEULE FOIS dans l'éditeur SQL d'un projet Supabase VIERGE de test (docs/mode-emploi-apercu.md)."
for f in "$ROOT"/supabase/next/[0-9]*.sql; do
  case "$(basename "$f")" in test-*) continue;; esac
  printf '\n-- ════════════════════════════════════════════════════════════════════\n-- %s\n-- ════════════════════════════════════════════════════════════════════\n' "$(basename "$f")"
  cat "$f"
done
