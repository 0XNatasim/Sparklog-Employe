# Sparklog-Employés (côté 1 : pointage) — V0.21.0

Application de **pointage** de Sparklog, version « en deux côtés ». Elle remplace, à terme, le dépôt `Sparklog` (mis de côté).
Le **côté 2** (noms, courriels, téléphones, paie, NAS) est dans `Sparklog-Gestion` (privé).

**État (V0.21.0, étape 1bis de `PLAN.md`) :** squelette copié de Sparklog V2.4.258, sans les écrans de gestion et de paie. Il compile (`npm run build`) et ses tests
passent, mais il utilise encore la base et les noms de Sparklog : **il n'est pas encore branché sur une nouvelle base** et ne doit pas être utilisé en production.
Ce qui reste à faire est dans `PLAN.md` (étapes 2 et suivantes) et la liste des écarts dans `OFFICIEL.md`.

- Ce que fait l'app : saisie du temps par l'employé (Départ / Arrivée / Fin), preuve de temps supplémentaire, repas, stationnement, inventaire, feuille d'urgence, révision des fiches par les gestionnaires, notes, notifications.
- Ce qu'elle ne fait plus : paie, talons, DAS, relevé d'emploi, cumul, taux, barèmes, accidents, annonces, formulaires, dossier d'employé (tout cela est dans `Sparklog-Gestion`).
- Provenance et liste des fichiers retirés : `COPIE-DEPUIS-SPARKLOG.md`.

**V0.11.0 :** schéma neuf du côté 1 commencé dans `supabase/next/` (migration `0001_identity` : profil minimal par numéro d'employé, codes d'activation) ; décisions table par table dans `docs/schema-cote1.md` ; banc d'essai SQL : `scripts/test-next-schema.sh` (PostgreSQL local jetable, non branché sur la CI).

**V0.11.0 :** décisions de répartition inscrites (temps libre et notes de gestionnaires → côté 2 ; groupes → côté 1 par numéro) ; migration `0002_roles` (rôles, aal2, lecture des profils) ajoutée à `supabase/next/`.

**V0.11.0 :** `supabase/next/` : migrations `0003_company_settings` et `0004_jobs` (fiche de temps, instants de Montréal, contrat de soumission de base, fenêtre de saisie, RLS), chacune avec son test SQL ; `scripts/rebuild-legacy-db.sh` reconstruit la base de Sparklog localement pour relever la structure exacte.

**V0.11.0 :** décision D4 : hébergement par **Supabase auto-hébergé sur un serveur au Québec** (`PLAN.md`, étape 2bis ; `OFFICIEL.md`, section 0 et 11). Documentation seulement.

**V0.11.0 :** grille de comparaison des fournisseurs d'infrastructure (`docs/grille-fournisseurs.md`, `.csv`), liée à `PLAN.md` 2bis.1. Documentation seulement.

**V0.11.0 :** étape 2bis du plan complétée avec la documentation officielle de Supabase (auto-hébergement) ; première lecture des sites publics de quatre fournisseurs dans la grille. Documentation seulement.

**V0.11.0 :** question 7 de l'étape 0.1 inscrite (réponse verbale du 2026-11-14 : le certificat du fournisseur suffit ; à confirmer par écrit). Documentation seulement.

**V0.11.0 :** `supabase/next/0005_job_writes` : fonctions d'écriture des fiches (`save_own_job`, `return_job_for_correction`, `approve_jobs`, feuille d'urgence), `audit_log` sans nom et non modifiable, `employee_notices` (avis à l'employé), avec test SQL.

**V0.11.0 :** `supabase/next/0006_overtime_evidence` : preuve de temps supplémentaire (table, avis aux gestionnaires, compartiment de stockage, contrat de soumission complet, `save_own_job_with_overtime_evidence`) avec test SQL ; `scripts/test-next-schema.sh` applique maintenant chaque migration puis son test, avec un faux stockage Supabase.

**V0.11.0 :** `supabase/next/0007_meals_parking` : souper (droit vérifié à l'insertion), stationnement (plafond, échéance, chemins), avis de modification d'une fiche à preuve, téléchargements de preuves, compartiments `parking-receipts` et `meal-receipts`, avec test SQL.

**V0.11.0 :** `supabase/next/0008_notes_activity` : notes du contremaître (numéro de l'employé audité, retour avec raison, faille « Retournée par » fermée) et journal d'activité sans nom ni appareil, avec test SQL.

**V0.11.0 :** `supabase/next/0009_inventory` : groupes d'employés (membres par numéro), captures et lignes d'inventaire, stock minimum par groupe, alertes de quantité négative par numéro, inventaire de fin de quart exigé à la soumission, compartiment `inventory-screenshots`, avec test SQL.

**V0.11.0 :** `supabase/next/0010_push` : abonnements aux notifications (enregistrement par fonction, appareil non conservé, liste des numéros abonnés pour les gestionnaires, ménage des abonnements anciens), avec test SQL.

**V0.11.0 :** `supabase/next/0011_announcements` : annonces publiées par le côté 2 (publication idempotente, modification avec version attendue, retrait), accusé de réception unique par l'employé, pièces jointes lisibles par les seuls destinataires, avec test SQL.

**V0.11.0 :** `supabase/next/0012_sync_api` : interface d'échange avec le côté 2 (clients à secret haché, blocage après échecs, lecture par curseur par numéro d'employé, suppressions, `apply_sync_action` idempotente avec codes d'activation jamais conservés), avec test SQL.

Commandes : `npm ci`, `npm run dev`, `npm run build`, `npm test`, `npm run lint`.

**V0.12.0 :** fonction Edge `pointage_api` (porte HTTP du côté 2 : authentification par secret, routes de lecture par curseur, `/actions` idempotente, erreurs sans texte SQL), `src/lib/pointage-api.test.js` (24 tests) et contrat dans `docs/api-cote2.md` ; `sync_jobs_deleted` passe à un curseur `(deleted_at, job_id)` (migration 0012 corrigée, pas encore appliquée à une base).

**V0.13.0 :** `pointage_api` crée le compte de connexion à adresse factice (`<numéro>@pointage.invalid`, mot de passe aléatoire jamais montré) avant l'action `register_account` ; numéro validé (1000 à 999999), relance sans compte orphelin, compte retiré si l'action échoue, 409 si le numéro existe. 9 tests de plus (33), contrat mis à jour dans `docs/api-cote2.md`.

**V0.14.0 :** fonction Edge `activate_account` (première connexion : numéro d'employé + code d'activation + mot de passe choisi de 12 à 72 caractères ; code vérifié et consommé par `consume_activation_code`, puis mot de passe posé sur le compte à adresse factice ; réponses 401 générique / 410 expiré / 429 bloqué ; CORS limité à `ALLOWED_ORIGIN`), `src/lib/activate-account.test.js` (10 tests). L'écran de connexion de l'app n'est pas encore branché dessus.

**V0.15.0 :** écran de connexion par numéro d'employé (`src/pages/Login.jsx`, `src/lib/employee-login.js`) : numéro + mot de passe (adresse factice `<numéro>@pointage.invalid` jamais affichée) ou, la première fois, numéro + code d'activation + mot de passe choisi via `activate_account`, puis connexion directe. Retirés : inscription libre, courriel, « mot de passe oublié » par courriel, page `ResetPassword` et sa route (un nouveau code vient de la gestion). Textes `login.*` (FR / EN). Tests : `Login.test.jsx` (7), `employee-login.test.js` (10).

**V0.16.0 :** l'application n'affiche ni ne lit plus aucune donnée nominative (invariant I1). `AuthProvider` fournit `employeeNumber` (plus `fullName`) ; `Profile.jsx` ne montre que le numéro ; les écrans de gestion (En direct, Boîte à faire, Paie de la semaine → `WeekSnapshot`, Inventaire, Feuille d'urgence, Notes, Journal d'activité, Justificatifs…) identifient chaque employé par `employeeLabel()` (`#1042`, `src/lib/employee-label.js`) ; les lectures de `profiles` ne demandent plus nom, courriel, téléphone, région, syndicat ni carte CCQ ; retirés : `RegionOnboarding`, `CcqCardCapture`, `ReferenceContent`, `reference-blocks`, `ccq-card`, `ccq-regions`, `union-associations`. Garde-fou : `src/lib/no-personal-data.test.js` lit le code et échoue si une colonne nominative revient.

**V0.17.0 :** outil de contrôle `scripts/check-app-against-schema.mjs` (compare les tables, colonnes et fonctions que l'app appelle à la structure de `supabase/next/`, relevée par `DUMP_SCHEMA=… scripts/test-next-schema.sh`) ; premier relevé : 29 écarts, triés dans `docs/ecarts-app-schema.md` (A à retirer, B à adapter, C à porter ou retirer). Aucun changement d'application.

**V0.18.0 :** `supabase/next/0013_manager_tools` : source de saisie (`job_entry_sources`, étoile « saisie manuelle »), compteurs `manager_job_counts`, `ot_reuse_for_jobs` (renvoie le numéro de l'autre employé), `evidence_download_alert`, diagnostic de lecture de photo (`file_read_errors` + `log_file_read_error`, sans navigateur ni appareil), feuille d'urgence (`delete_manager_entry`, `remind_manager_entry` par avis à l'employé), avec test SQL et 11 mutations vérifiées. « État du service » abandonné. App : `job-anomalies` lit `other_employee_number`, `file-read-report` n'envoie plus navigateur ni mode d'installation, le rappel de la feuille d'urgence n'envoie plus d'annonce. Écarts app ↔ schéma : 29 → 22.

**V0.19.0 :** retrait du côté 1 de ce qui appartient au côté 2 : notes personnelles des gestionnaires (`NotesPanel`, `NoteThread`, `lib/notes`), taux et barèmes de paie (`lib/payroll-rates`), inscriptions et dates d'embauche (`lib/signups`), carte « État du service » (`InfraHealthCard`, fonction `infra_metrics`, route `advanced/health`). Le temps libre n'est plus lu (`src/lib/no-time-off.js` renvoie une liste vide aux calculs) ; plus de `start_date`, `apprentice_level` ni `departure_status` dans les lectures ; l'entrée Notes du menu n'a plus que l'onglet Contremaître. Écarts app ↔ schéma : 22 → 6.

**V0.20.0 :** **0 écart entre l'application et le schéma neuf** (`scripts/check-app-against-schema.mjs`). Annonces : `announcement_recipients` / `announcements` lues par `src/lib/announcements.js` (les écrans gardent leur forme, une annonce retirée n'est jamais lue ; le bouton « Rappeler » de la boîte à faire, qui créait une annonce, est retiré : les annonces viennent du côté 2). Note du contremaître : l'employé audité est un **numéro** (`audited_employee_number`, 4 à 6 chiffres), plus de « retournée par … » ni de « saisie par … » nominatifs (`audit.management`). Nouvelle tâche CI `schema` (PostgreSQL 16 + contrôle des écarts, non encore vue tourner sur GitHub) ; `keep-warm.yml` (ping de l'ancienne base de Sparklog) supprimé.

**V0.21.0 :** aperçu de test du côté 1 : `docs/mode-emploi-apercu.md` (12 étapes : projet Supabase de test, schéma, réglages d'authentification, fonctions Edge, propriétaire de test, page sur Canner, activation d'un employé de test), `docs/apercu/schema-apercu.sql` (les 13 migrations assemblées par `scripts/build-preview-sql.sh` ; `src/lib/preview-sql.test.js` échoue si le fichier n'est plus à jour), `docs/apercu/1-proprietaire.sql` et `2-client-api.sql`. `PREVIEW_SQL=… scripts/test-next-schema.sh` applique le fichier d'un seul coup et essaie les deux petits scripts (essai local seulement, pas sur Supabase).
