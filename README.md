# Sparklog-Employés (côté 1 : pointage) — V0.4.0

Application de **pointage** de Sparklog, version « en deux côtés ». Elle remplace, à terme, le dépôt `Sparklog` (mis de côté).
Le **côté 2** (noms, courriels, téléphones, paie, NAS) est dans `Sparklog-Gestion` (privé).

**État (V0.4.0, étape 1bis de `PLAN.md`) :** squelette copié de Sparklog V2.4.258, sans les écrans de gestion et de paie. Il compile (`npm run build`) et ses tests
passent, mais il utilise encore la base et les noms de Sparklog : **il n'est pas encore branché sur une nouvelle base** et ne doit pas être utilisé en production.
Ce qui reste à faire est dans `PLAN.md` (étapes 2 et suivantes) et la liste des écarts dans `OFFICIEL.md`.

- Ce que fait l'app : saisie du temps par l'employé (Départ / Arrivée / Fin), preuve de temps supplémentaire, repas, stationnement, inventaire, feuille d'urgence, révision des fiches par les gestionnaires, notes, notifications.
- Ce qu'elle ne fait plus : paie, talons, DAS, relevé d'emploi, cumul, taux, barèmes, accidents, annonces, formulaires, dossier d'employé (tout cela est dans `Sparklog-Gestion`).
- Provenance et liste des fichiers retirés : `COPIE-DEPUIS-SPARKLOG.md`.

**V0.4.0 :** schéma neuf du côté 1 commencé dans `supabase/next/` (migration `0001_identity` : profil minimal par numéro d'employé, codes d'activation) ; décisions table par table dans `docs/schema-cote1.md` ; banc d'essai SQL : `scripts/test-next-schema.sh` (PostgreSQL local jetable, non branché sur la CI).

**V0.4.0 :** décisions de répartition inscrites (temps libre et notes de gestionnaires → côté 2 ; groupes → côté 1 par numéro) ; migration `0002_roles` (rôles, aal2, lecture des profils) ajoutée à `supabase/next/`.

**V0.4.0 :** `supabase/next/` : migrations `0003_company_settings` et `0004_jobs` (fiche de temps, instants de Montréal, contrat de soumission de base, fenêtre de saisie, RLS), chacune avec son test SQL ; `scripts/rebuild-legacy-db.sh` reconstruit la base de Sparklog localement pour relever la structure exacte.

**V0.4.0 :** décision D4 : hébergement par **Supabase auto-hébergé sur un serveur au Québec** (`PLAN.md`, étape 2bis ; `OFFICIEL.md`, section 0 et 11). Documentation seulement.

**V0.4.0 :** grille de comparaison des fournisseurs d'infrastructure (`docs/grille-fournisseurs.md`, `.csv`), liée à `PLAN.md` 2bis.1. Documentation seulement.

**V0.4.0 :** étape 2bis du plan complétée avec la documentation officielle de Supabase (auto-hébergement) ; première lecture des sites publics de quatre fournisseurs dans la grille. Documentation seulement.

**V0.4.0 :** question 7 de l'étape 0.1 inscrite (réponse verbale du 2026-11-14 : le certificat du fournisseur suffit ; à confirmer par écrit). Documentation seulement.

**V0.4.0 :** `supabase/next/0005_job_writes` : fonctions d'écriture des fiches (`save_own_job`, `return_job_for_correction`, `approve_jobs`, feuille d'urgence), `audit_log` sans nom et non modifiable, `employee_notices` (avis à l'employé), avec test SQL.

Commandes : `npm ci`, `npm run dev`, `npm run build`, `npm test`, `npm run lint`.
