# Sparklog-Employés (côté 1 : pointage) — V0.29.5

Application de **pointage** de Sparklog, version « en deux côtés ». Elle remplace, à terme, le dépôt `Sparklog` (mis de côté).
Le **côté 2** (noms, courriels, téléphones, paie, NAS) est dans `Sparklog-Gestion` (privé).

**État (V0.25.0, étape 1bis de `PLAN.md`) :** squelette copié de Sparklog V2.4.258, sans les écrans de gestion et de paie. Il compile (`npm run build`) et ses tests
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

**V0.21.0 :** aperçu de test du côté 1 : `docs/mode-emploi-apercu.md` (12 étapes : projet Supabase de test, schéma, réglages d'authentification, fonctions Edge, propriétaire de test, page sur Canner, activation d'un employé de test), `docs/apercu/schema-apercu.sql` (les 14 migrations assemblées par `scripts/build-preview-sql.sh` ; `src/lib/preview-sql.test.js` échoue si le fichier n'est plus à jour), `docs/apercu/1-proprietaire.sql` et `2-client-api.sql`. `PREVIEW_SQL=… scripts/test-next-schema.sh` applique le fichier d'un seul coup et essaie les deux petits scripts (essai local seulement, pas sur Supabase).

**V0.22.0 :** nettoyage des fonctions Edge. `send_push` réécrite (`handler.js` testé par `src/lib/send-push.test.js`) : appelée par le **côté 2** avec sa clé d'échange (`skc_…`, comme `pointage_api`), `{ announcement_id, reread? }`, destinataires lus dans `announcement_recipients` (annonce non retirée ; `reread` = seulement ceux qui n'ont pas accusé réception), **texte toujours générique** (« Nouveau message » / « Message modifié »), jamais le contenu ni un nom, 429 / 401 / 503 sans texte technique ; le navigateur n'appelle plus `send_push` (`notifyBroadcastPush` et `pushOutcome` retirés). Migration `0014_orphan_cleanup` : `find_orphaned_evidence_objects` (photos téléversées sans ligne ; stationnement : photos supplémentaires incluses ; grâce minimale d'une heure ; clé de service seulement) pour `cleanup_overtime_evidence`, qui n'accepte plus que la clé de service (plus de `verify_cron_secret` ni de pg_cron / Vault : l'ordonnanceur du serveur l'appelle). `delete_inventory_screenshots` journalise par numéros. `classify_week` supprimée (elle lisait des colonnes de paie absentes du côté 1). Le contrôle app ↔ schéma lit maintenant aussi `supabase/functions/` : 0 écart.

**V0.23.0 :** nettoyage des textes et des droits. `src/lib/i18n.js` passe de 5 250 à 2 202 lignes : **1 524 clés inutilisées** retirées en français et en anglais (`scripts/unused-i18n-keys.mjs` les liste, `scripts/prune-i18n.mjs` les retire ; tient compte des clés construites comme `status.${x}` et du suffixe `.plain`). Nouveau test `src/lib/i18n-keys.test.js` : les deux langues ont les mêmes clés et toute clé citée dans le code existe. Matrice d'autorisation : plus de `canAccessSensitiveNas` ni `includedInCcqPayroll` (pas de NAS ni de paie CCQ au côté 1) ; retrait des tests qui lisaient les anciennes migrations du coffre NAS et de la paie.

**V0.24.0 :** `scripts/ocr-bench.mjs` : banc d'essai de lecture des captures Field Service avec Tesseract en ligne de commande et le vrai analyseur de l'application (`work-order-parse.js`), par champ et par variante de prétraitement. Les images et la vérité (numéros d'OT réels) ne sont jamais commitées.

**V0.24.1 :** résultat du banc d'essai Tesseract 5.3 (eng + fra, modèles « fast » d'Ubuntu) sur 14 captures Field Service réelles + 1 photo sans rapport : **mode `--psm 11` (texte épars), image brute : 14/14 captures lues sans aucune erreur** (OT, date, départ, arrivée, fin, km, miles) ; `--psm 6` / `4` / `3` : tous les champs sauf les « miles » (le contrôle de cohérence km / miles ne se ferait pas) ; agrandir ×2 ou ×3 ne sert à rien (1 à 2 OT mal lus de plus) ; la réduction à 1600 px / JPEG 70 de l'application ne nuit pas ; la photo sans rapport ne produit aucun champ (0 faux positif). Durée : environ 10 s par image sur 4 cœurs (eng + fra, 1080 × 2340) : à réduire (eng seul, image réduite) avant de décider. Limites : 14 captures dont plusieurs sont la même fiche (environ 7 fiches distinctes), un seul téléphone, aucune comparaison avec OCR.space.

**V0.24.2 :** décision de la propriétaire : **OCR.space est gardé pour l'instant** ; Tesseract est noté dans `docs/ocr-tesseract.md` (résultat de l'essai, limites, essai à compléter, plan de travail si on change). Aucun code changé.

**V0.29.5 :** migration `0017_group_holiday_time_actions` : trois actions de plus pour la gestion. `delete_group` (le groupe, ses membres et ses minimums de stock disparaissent ; rejouable), `set_holiday` (ajouter, renommer ou retirer un jour férié ou un congé de la construction : la gestion devient la source de la liste), `set_time_options` (les quatre options qui changent le temps : premier trajet non payé, « 4 jours de 10 h », retour avec avantages, 1re heure supplémentaire à 2× ; seules les options données changent, jamais un montant). `pointage_api` : 15 types d'actions.

**V0.27.0 :** migration `0016_group_ids` : l'action `upsert_group` accepte un identifiant (`id`) choisi par la gestion : le même groupe porte le même uuid des deux côtés (pas de table de correspondance), la création est rejouable, le renommage est permis, un nom déjà pris par un autre groupe est refusé. Les groupes se gèrent côté gestion ; ici ils ne servent plus qu'à l'inventaire et au stock minimum.

**V0.26.0 :** pour la gestion (côté 2). Migration `0015_sync_actions_export` : `apply_sync_action` accepte quatre actions de plus (`set_role` : changer le rôle d'un compte sauf gestionnaire ; `publish_announcement`, `edit_announcement` avec contrôle de version, `withdraw_announcement`), toutes rejouables et écrites au journal sans nom ; `export_jobs_for_import(du, au, statuts)` (gestionnaire avec double authentification, 366 jours et 50 000 fiches au plus, écrit au journal). Bouton « Exporter les fiches (CSV) » (`JobsCsvExport.jsx`, `src/lib/jobs-csv.js` : séparateur `;`, protection contre les formules) : plan de secours de la synchronisation. `pointage_api` : 12 types d'actions. Pas de `set_employee_number` : le numéro est attribué par la gestion à `register_account`. Aperçu SQL régénéré.
**V0.25.0 :** boutons d'**approbation retirés** de la boîte « À traiter » (`TodoInbox`) et du tableau de bord (`ManagerDashboard` : approuver une fiche, approuver la semaine) : ils appelaient `push_approved_batch`, qui n'existe pas au côté 1 (l'approbation vient du côté 2, `approve_jobs`). Message « L'approbation se fait dans la gestion » ; `approvalOutcome` et 48 textes devenus inutiles retirés. Garde-fou `src/lib/side-boundaries.test.js` : le code du côté 1 n'appelle ni approbation, ni paie, ni API d'échange, ni clé de service. `docs/pret-deploiement.md` : état de préparation (prêt pour l'aperçu, pas pour la mise en service) et bloquants.

**V0.29.5 :** `.github/workflows/deploy-functions.yml` : déploiement MANUEL de `pointage_api` et `activate_account` (sans vérification JWT, voulu) sur le projet de test, depuis l'onglet Actions ; secrets GitHub `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`, au besoin `ALLOWED_ORIGIN`.

**V0.29.5 :** le déploiement par GitHub ajoute `--yes` (le CLI Supabase demandait une confirmation impossible à poser dans Actions : « Deploy 1 Function », échec constaté au premier essai).

**V0.29.5 :** `--yes` aussi pour `supabase secrets set` du déploiement GitHub.

**V0.29.5 :** le déploiement GitHub nettoie les secrets (espaces, guillemets) et vérifie leur forme (`sbp_…`, 20 lettres) avec un message clair ; échec constaté côté 1 : « Invalid access token format ».

**V0.29.5 :** le déploiement GitHub affiche d'abord le nombre de projets visibles avec le jeton et la région du projet visé (aucun nom ni référence : le journal du côté 1 est public) ; il s'arrête avec un message clair si la référence n'est pas celle d'un projet du compte.

**V0.29.5 :** option `PWA_SW_MINIFY=0` (variable d'environnement de compilation) : saute la minification du service worker. Nécessaire chez Canner (Starter) où la compilation échouait avec « Unable to write the service worker file » (terser). Sans la variable, rien ne change.
