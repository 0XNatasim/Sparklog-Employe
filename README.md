# Sparklog-Employés (côté 1 : pointage) — V0.15.0

Application de **pointage** de Sparklog, version « en deux côtés ». Elle remplace, à terme, le dépôt `Sparklog` (mis de côté).
Le **côté 2** (noms, courriels, téléphones, paie, NAS) est dans `Sparklog-Gestion` (privé).

**État (V0.15.0, étape 1bis de `PLAN.md`) :** squelette copié de Sparklog V2.4.258, sans les écrans de gestion et de paie. Il compile (`npm run build`) et ses tests
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
