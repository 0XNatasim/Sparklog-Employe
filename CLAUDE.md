# CLAUDE.md — Sparklog-Employés (côté 1 : pointage)

**Stack :** React 18 + Vite PWA, Supabase (Postgres + RLS + Edge Functions). Même pile que `Sparklog` (mis de côté).

**Rôle :** pointage par **numéro d'employé**. Aucun nom, courriel, téléphone, NAS ni montant de paie ne doit être recueilli ni stocké ici (invariant I1 de `PLAN.md`).
Le côté 2 est `Sparklog-Gestion` (privé). Plan : `PLAN.md`. Conformité : `OFFICIEL.md`.

**Release rule:** à chaque PR, incrémenter `APP_VERSION` dans `src/lib/version.js` et le mentionner dans le titre du commit / de la PR.

**Docs rule:** `README.md`, `NOOB.md` et `CLAUDE.md` sont mis à jour **ensemble, dans la même PR**, et nomment chacun la version courante (`src/lib/docs-sync.test.js` échoue sinon).
Jamais de valeur personnelle (nom, NAS, salaire, montant de paie) dans le dépôt : il est **public**.

**Règle de sécurité des tables :** pour toute nouvelle table, `revoke all … from anon, public, authenticated` **avant** les `grant` voulus (Supabase donne des droits par défaut).

## État (V0.29.4)

**V0.29.4 :** ajout de `--yes` à `functions deploy` (échec du 1er essai : confirmation interactive). `.github/workflows/deploy-functions.yml` (`workflow_dispatch` seulement ; `--no-verify-jwt` pour `pointage_api` et `activate_account` ; `ALLOWED_ORIGIN` posé si le secret GitHub existe). Jamais essayé.

Squelette copié de Sparklog V2.4.258 (étape 1bis de `PLAN.md`) : voir `COPIE-DEPUIS-SPARKLOG.md`. Écrans de gestion et de paie retirés ; `App.jsx`, `ManagerPages.jsx` et
`manager-nav.js` réduits au temps (Aujourd'hui, En direct, Notes, Feuilles de temps, Inventaire, Journal, État du service, Feuille d'urgence).
Les migrations de Sparklog (`supabase/migrations/`) sont encore **toutes** là (les tests de contrat les lisent) ; elles seront remplacées par des migrations neuves à l'étape 10.

## Hébergement (V0.29.4)

D4 tranchée le 2026-11-14 : **Supabase auto-hébergé, serveur au Québec**, fournisseur d'infrastructure canadien (`PLAN.md` étape 2bis). Le code reste compatible `supabase-js` : ne rien introduire qui dépende de l'infonuagique de Supabase (plan B = hébergé en région canadienne). Aucune mise en production sans personne responsable de l'exploitation nommée. Question 7 (exploitant certifié ?) : réponse verbale du 2026-11-14, « le certificat du fournisseur suffit » ; **l'obtenir par écrit avant la production**.

Choix du fournisseur : `docs/grille-fournisseurs.md` (éliminatoires G1 à G6, notes N1 à N10, courriel type). **Ne jamais remplir une case sans preuve rangée ; aucune preuve ni coordonnée de contact dans ce dépôt public.**

## Schéma neuf (V0.29.4)

`supabase/next/` contient le schéma neuf (migrations `NNNN_*.sql` + `test-NNNN.sql`), **séparé** de `supabase/migrations/` (copie de Sparklog, encore lue par des tests). `scripts/test-next-schema.sh` (en root, PostgreSQL 16 local)
applique `next/` sur une base jetable avec de faux schémas Supabase puis lance les tests SQL ; à lancer avant chaque PR qui touche `next/`. Décisions table par table et ordre des migrations : `docs/schema-cote1.md`. Fait : `0001_identity`, `0002_roles`, `0003_company_settings`, `0004_jobs` (fiche de base ; `validate_job_submission_contract` remplacée par 0006), `0005_job_writes` (écriture des fiches, audit sans nom non modifiable, avis à l'employé), `0006_overtime_evidence` (preuve de temps supp., contrat de soumission complet ; `validate_job_submission_contract` complétée par 0009 pour l'inventaire), `0007_meals_parking` (souper, stationnement, avis, téléchargements), `0008_notes_activity` (notes du contremaître par numéro, journal d'activité sans nom ni appareil), `0009_inventory` (groupes, inventaire, stock minimum, inventaire de fin de quart dans `validate_job_submission_contract`, qui est maintenant COMPLÈTE), `0010_push` (abonnements sans appareil conservé, ménage), `0011_announcements` (annonces écrites par le côté 2 via la clé de service ; l'employé n'accuse réception qu'une fois ; `send_push` adapté en V0.22.0), `0014_orphan_cleanup` (V0.22.0 : `find_orphaned_evidence_objects`, clé de service seulement), `0013_manager_tools` (V0.18.0 : `job_entry_sources`, `manager_job_counts`, `ot_reuse_for_jobs` (numéro de l'autre employé), `evidence_download_alert`, `file_read_errors` + `log_file_read_error` (clés `size, age_s, attempts, type, step, error, reason` seulement), `delete_manager_entry` / `remind_manager_entry` (avis `manager_entry_reminder`) ; get_infra_stats abandonné), `0012_sync_api` (porte d'entrée du côté 2 : clé de service seulement, secrets hachés, actions idempotentes ; porte HTTP : fonction Edge `pointage_api` (V0.12.0, compte à adresse factice ajouté en V0.13.0, `docs/api-cote2.md`, `src/lib/pointage-api.test.js`, déployer avec `verify_jwt = false`)). **Un secret faux ne doit jamais lever d'erreur** (la ligne de journal de la tentative serait annulée avec la transaction). **Une notification doit avoir un texte générique** (jamais un nom, une heure ni un montant) : l'adresse d'un abonnement appartient à Google, Apple ou Mozilla. Question ouverte : `payroll_treatment` et les montants de repas / stationnement sont de la paie : à garder au côté 1 ou à déplacer au côté 2. Pour relever la structure d'une table de Sparklog : `scripts/rebuild-legacy-db.sh` puis `pg_dump -s -t …` sur `/tmp/legacydb` (port 54330). Chaque migration neuve a son `test-NNNN.sql` ; vérifier au moins une mutation (casser une règle, constater l'échec, rétablir). Décisions du 2026-11-14 : `employee_time_off` et notes de gestionnaires → côté 2 ; groupes d'employés → côté 1 (par numéro).

**V0.29.4 :** migration `0017_group_holiday_time_actions` (`delete_group`, `set_holiday`, `set_time_options` ; audit `group_deleted` / `holiday_changed` / `time_options_changed` avec les seules clés permises : `count`, `job_date`, `reason_code`) ; `pointage_api` à 15 types. Test : `supabase/next/test-0017.sql`.

**V0.27.0 :** migration `0016_group_ids` (`upsert_group` + `id` choisi par le côté 2, renommage, `group_name_taken`). Test : `supabase/next/test-0016.sql`.

**V0.26.0 :** migration `0015_sync_actions_export` (`apply_sync_action` + `set_role`, `publish_announcement`, `edit_announcement`, `withdraw_announcement` ; `export_jobs_for_import`, gestionnaire aal2, audit `jobs_exported`), `src/lib/jobs-csv.js`, `JobsCsvExport.jsx` (près de `EvidenceDownload` dans `ManagerDashboard`), `pointage_api` à 12 types. `set_employee_number` volontairement absent (numéro attribué par la gestion à `register_account`). Test : `supabase/next/test-0015.sql`.

## Ouvert (voir `PLAN.md`)

- [ ] Déploiement : **prêt pour l'aperçu, pas pour la production** (`docs/pret-deploiement.md`). Approbation retirée du côté 1 en V0.25.0 (côté 2 : `approve_jobs`) ; garde-fou `src/lib/side-boundaries.test.js`.

- [ ] Aperçu de test (V0.25.0) : `docs/mode-emploi-apercu.md` à suivre par la propriétaire ; réglages Supabase / Canner non vérifiés sur de vrais comptes ; ne jamais y mettre de vraies données ; `docs/apercu/schema-apercu.sql` se régénère avec `scripts/build-preview-sql.sh` à chaque nouvelle migration (test de dérive).

- [ ] Étape 2bis : serveur québécois (fournisseur, pile Supabase, sécurité, sauvegardes, surveillance, personne responsable) ; étape 3 : la partie SQL de l'API d'échange est faite (0012), `pointage_api` est écrite (V0.12.0), `activate_account` aussi (V0.14.0, `src/lib/activate-account.test.js`, `verify_jwt = false`, variable `ALLOWED_ORIGIN`, écran de connexion à brancher), compte à adresse factice créé par `pointage_api` avant `register_account` (V0.13.0, `deps.createAuthUser` / `deleteAuthUser`) ; reste à la déployer.
- [ ] Connexion par numéro faite (V0.15.0 : `Login.jsx`, `employee-login.js`). **Ouvert :** réémettre un code ne ferme pas les sessions déjà ouvertes (à faire côté serveur après `setPassword`) ; réglage Auth de l'instance : longueur minimale 12, aucune règle de caractères, inscription publique désactivée (`GOTRUE_DISABLE_SIGNUP=true`).
- [x] V0.16.0 : plus aucune lecture nominative dans `src/` (`employeeLabel()`, `AuthProvider.employeeNumber`, `Profile.jsx` réduit), garde-fou `src/lib/no-personal-data.test.js` (colonnes interdites : `full_name`, `work_region`, `union_association`, `birth_date`, `ccq_card*`, `ccq_number`, `employee_sensitive`, `employee|profile.phone|email`).
- [ ] Étape 10 (reste) : 0 écart app ↔ schéma en V0.20.0 (29 en V0.17.0, 22 en V0.18.0, 6 en V0.19.0 ; tâche CI `schema` à vérifier sur GitHub : `scripts/check-app-against-schema.mjs`, tri A/B/C dans `docs/ecarts-app-schema.md` ; à ramener à 0 puis à mettre en CI), textes `i18n.js` nominatifs, journaux par numéro.
- [ ] OCR : **décision du 2026-11-14 : on garde OCR.space pour l'instant** (hors Québec : à inscrire à l'ÉFVP, à la politique de confidentialité et au consentement ; `OFFICIEL.md`). Tesseract est noté dans `docs/ocr-tesseract.md` (essai V0.24.1 : `--psm 11`, image brute, 14/14 sur l'écran Durée de Field Service ; limites ; essai à compléter ; plan si on change). Nettoyage fait en V0.23.0 : `authorization-matrix` (sans NAS ni paie CCQ), 1 524 clés `i18n.js` inutilisées retirées (`scripts/prune-i18n.mjs`), test `src/lib/i18n-keys.test.js`. Fait en V0.22.0 : `send_push` (clé d'échange du côté 2, texte générique, `handler.js`), `cleanup_overtime_evidence` (clé de service seulement, `find_orphaned_evidence_objects` 0014 ; **tâche planifiée du serveur à prévoir**), `delete_inventory_screenshots` par numéros, `classify_week` supprimée. Fait en V0.19.0 : notes personnelles, taux de paie, inscriptions, État du service retirés (`infra_metrics` supprimée).
- [ ] Décidé et fait (V0.25.0) : `CcqCardCapture` et `ReferenceContent` retirés. À retirer du côté 1 : `NotesPanel` et le code des notes de gestionnaires (décidé : côté 2).

**V0.29.4 :** `--yes` aussi pour `secrets set`. 2e essai côté 1 : `list functions 404` = référence de projet ou jeton incorrect (secrets GitHub), pas le code.

**V0.29.4 :** étape « Vérifier et nettoyer les secrets » (regex `^sbp_[A-Za-z0-9]+$`, `^[a-z]{20}$`, masquage, `GITHUB_ENV`).

**V0.29.4 :** étape de diagnostic `supabase projects list -o json` + `jq` (compte, correspondance de la référence, région). Constat côté 1 : secrets bien formés mais `403` sur `list functions`.
