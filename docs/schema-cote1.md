# Schéma du côté 1 (pointage) — décisions table par table

Source : les 57 tables créées par les migrations de Sparklog V2.4.258 (`supabase/migrations/`). Le schéma neuf s'écrit dans **`supabase/next/`** (nouvelle base, `PLAN.md` étapes 2, 5, 9, 10).
`supabase/migrations/` (copie de Sparklog) reste en place tant que les tests de contrat la lisent ; elle sera retirée quand `next/` la remplace.
Légende : **Garder** = reste au côté 1 ; **Gestion** = va au côté 2 (`Sparklog-Gestion`) ; **Modifier** = reste, mais sans donnée nominative ; **À trancher** = décision de la propriétaire.

## Profil

| Table | Décision | Note |
|-------|----------|------|
| `profiles` | **Modifier** → profil minimal | Reste : `id`, `employee_number`, `role`, `is_paused`, `first_activated_at` (fait : `next/0001`). À ajouter par migration, après vérification dans le moteur d'heures : options qui changent **le temps** (`first_trip_unpaid`, `ten_hour_days`, `km_apart_from_capture`, `return_with_benefits_to_8h`, `overtime_first_hour_double`), interrupteurs d'écran (`inventory_screenshots_enabled`, `parking_receipts_enabled`, `show_on_boards`, `overtime_evidence_required`, `evidence_retention_days`), `admin_sections`. **Retirés (Gestion) :** nom, courriel, téléphone, date de naissance, NAS, numéro et carte CCQ, taux horaire, primes, indemnités, syndicat, dates d'embauche / départ, notes de départ |
| `activation_codes` | **Nouveau** (fait : `next/0001`) | Codes à usage unique, hachés |
| `employee_sensitive` (NAS, coffre) | **Gestion** | Jamais au côté 1 |
| `employee_tax_profiles`, `payroll_period_ledger`, `payroll_ytd`, `roe_history` | **Gestion** | Paie |

## Temps (le cœur du côté 1)

| Table | Décision | Note |
|-------|----------|------|
| `jobs` | **Garder** | `user_id` → profil par numéro ; colonnes d'approbation / d'export à revoir avec l'API (`PLAN.md` 3.3) |
| `job_entry_unlocks`, `job_entry_sources` | **Garder** | |
| `overtime_evidence`, `meal_claims`, `parking_receipts`, `evidence_downloads` | **Garder** | Photos à durée courte ; aucun nom |
| `company_time_settings`, `company_holidays`, `company_capture_settings`, `overtime_settings`, `preset_work_orders` | **Garder** | Réglages communs |
| `employee_time_off` | **Gestion** (décidé le 2026-11-14) | Absences et congés : c'est de la gestion (paie, congés), pas du pointage |

## Notes, révision, journaux

| Table | Décision | Note |
|-------|----------|------|
| `foreman_reports`, `foreman_report_reads` | **Modifier** | `audited_name` (texte libre) → numéro de l'employé audité |
| `manager_notes`, `manager_note_replies`, `manager_note_reads` | **Gestion** (décidé le 2026-11-14) | Notes et rappels entre gestionnaires : elles parlent de personnes, donc côté 2 (le filtre de noms de `PLAN.md` 3.5 ne s'applique plus ici) |
| `manager_notifications`, `manager_notification_reads` | **Modifier** | Par numéro |
| `audit_log`, `employee_activity_log` | **Modifier** | Acteur et cible par numéro ; clés de métadonnées permises seulement (`PLAN.md` 3.6, 10.8, 10.9) |
| `push_subscriptions` | **Modifier** | Lié au numéro ; **retirer** `user_agent` |

## Inventaire

| Table | Décision |
|-------|----------|
| `inventory_screenshots`, `inventory_items`, `inventory_min_ratios`, `inventory_alert_dismissals`, `inventory_reading_log` | **Garder** (sans nom) |
| `employee_groups`, `employee_group_members` | **Garder au côté 1, par numéro** (décidé le 2026-11-14) : un groupe = un entrepôt ou une équipe (nom du groupe, jamais un nom de personne ; membres = numéros). Le côté 2 les gère par une action de l'API (`set_group`) et les utilise pour cibler les annonces |

## Va au côté 2 (`Sparklog-Gestion`)

`accident_log`, `accident_files`, `ccq_rate_snapshots`, `conges_indemnity_rate`, `employer_contributions`, `payroll_employer_settings`, `payroll_rates`, `payroll_rules`, `statutory_rate_sets`, `travel_pay_rules`,
`employee_forms`, `employee_form_access`, `profile_references`, `manager_broadcasts`, `broadcast_recipients`, `broadcast_revisions`, `messages`, `message_recipients`.

**Annonces :** les employés les lisent dans l'app (fenêtre et cloche). Retenu : le côté 2 **publie** le texte (sans destinataire nominatif) vers une table `announcements` du côté 1, ciblée par **groupe** ou par **numéro** (action de l'API, avec clé d'idempotence). Les courriels d'annonce partent du côté 2 (`PLAN.md` 12.1).

## Rôles et droits

`get_my_role()`, `is_privileged()`, `is_active_employee()` sont à réécrire pour la nouvelle table `profiles` (mêmes noms, même exigence `aal2` pour les gestionnaires). Règles qui ne changent pas : `security definer` avec `search_path` fixé,
`revoke all … from anon, public, authenticated` **avant** tout `grant` sur chaque table, écriture des champs privilégiés par RPC seulement.

## Ordre des migrations de `next/`

1. `0001_identity` — profil minimal, codes d'activation. **Fait et testé** (`scripts/test-next-schema.sh`).
2. `0002_roles` — `get_my_role()`, `is_privileged()` (aal2), `is_active_employee()`, lecture des profils. **Fait et testé.**
3. `0003_company_settings` — réglages du temps, conservation des preuves, 32 jours fériés (2026-2028, jours de la convention), OT prédéfinis. **Fait et testé.** Pas de `company_capture_settings` (le côté 1 ne lit ni carte CCQ, ni date de naissance, ni syndicat).
4. `0004_jobs` — fiche de temps, instants de Montréal (heure d'hiver / d'été, nuit, heure inexistante au printemps, heure répétée à l'automne avec choix 1 ou 2 réservé aux gestionnaires), déverrouillage de journée, fenêtre de saisie (férié, échéance), contrat de soumission de base (intervalle de 0 à 16 h exclu / inclus, chevauchement des fiches soumises, retour, kilomètres), options du profil qui changent le temps, droits et RLS. **Fait et testé** (quatre mutations vérifiées). Écarts voulus : pas de taux ni de montant sur la fiche, pas de `manager_entry_by_name`.
5. `0005_job_writes` — **fait et testé** (six mutations vérifiées). Fonctions serveur d'écriture : `save_own_job` (création idempotente par clé de soumission, verrou par employé, relance sans effet, confirmation d'une fiche créée par un gestionnaire), `return_job_for_correction` (gestionnaire avec double authentification, version attendue), `approve_jobs` (**clé de service seulement**, résultat typé par fiche : approuvée / déjà approuvée / conflit / non soumise / inconnue), `create_job_for_employee` et `submit_manager_entry_for_employee` (propriétaire seul). **Nouveau :** `audit_log` **sans nom** (numéros, clés de détail permises seulement, **non modifiable**) et `employee_notices` (**avis à l'employé** pour toute fiche créée, soumise ou retournée par un gestionnaire). Écarts voulus : une fiche soumise est toujours verrouillée (y compris par le propriétaire) ; le propriétaire qui **soumet** pour l'employé déclenche maintenant un avis (la convention l'exige ; Sparklog n'en envoyait pas) ; pas de « broadcast ». **Reste :** la preuve de temps supplémentaire n'est pas encore retenue par `save_own_job` (0006 la remplace) ; `save_own_job_with_overtime_evidence`, le test de concurrence réelle (deux transactions simultanées) et l'audit automatique des changements de statut.
6. `0006_overtime_evidence` — **fait et testé** (dix mutations vérifiées). Preuve de temps supplémentaire : table `overtime_evidence`, avis aux gestionnaires (`manager_notifications`, `manager_notification_reads`, sans nom), compartiment `overtime-evidence` (privé, 10 Mo, images) avec ses règles (l'employé téléverse dans son dossier seulement, les gestionnaires avec double authentification lisent), la preuve suit la **dernière fiche du jour**, elle est **retirée** si la journée redescend à 8 h, passe à une autre fiche si la sienne est supprimée ; **`validate_job_submission_contract` complète** (preuve au-delà de 8 h payées, 10 h pour « 4 jours de 10 h » sauf contremaître et sous-traitant, premier trajet non payé sauf 65 km ou plus, employé de bureau exempté, soumission par le propriétaire exemptée de la preuve seulement) ; `save_own_job` ne retient l'indicateur que si une preuve existe ; `save_own_job_with_overtime_evidence` (fiche + preuve + avis en une transaction, relance sans doublon, refus qui annule tout). Écart voulu : `overtime_day_minutes` n'est plus appelable par le navigateur. **Reste identique à Sparklog, volontairement :** le nettoyage de la preuve utilise 480 min même pour « 4 jours de 10 h », et une deuxième preuve le même jour échoue sur la contrainte d'unicité (l'app n'en téléverse qu'une par jour).
7. `0007_meals_parking` — **fait et testé** (quinze mutations vérifiées). **Repas :** table `meal_claims` ; le souper est dû un jour de semaine à partir de **615 minutes payées** (retour exclu, premier trajet non payé exclu sauf 65 km ou plus) et **jamais** pour « 4 jours de 10 h » (sauf contremaître et sous-traitant) ; **refusé à l'insertion** si la journée n'y donne pas droit, avec minutes **calculées par le serveur** ; retiré automatiquement si la journée raccourcit (sauf s'il est déjà révisé) ; révision par un gestionnaire (`review_meal_claim`). **Stationnement :** `parking_receipts` (plafond de 20 $ par jour, photos dans le dossier de l'employé, neuf photos de plus au maximum, échéance de conservation fixée par le serveur et non prolongeable), révision (`review_parking_claim`). **Avis aux gestionnaires :** `meal_claim`, `parking_receipt` (un employé ne peut créer que ces deux types, pour sa propre fiche) et `overtime_job_edited` (une seule notification par fiche, qui fusionne les modifications et disparaît si tout revient à l'origine). **Aussi :** `evidence_downloads` (auteur fixé par le serveur), compartiments privés `parking-receipts` et `meal-receipts`, audit des révisions par numéros. **Écarts voulus :** souper vérifié à l'insertion (Sparklog ne le faisait qu'à la modification d'une fiche) ; pas d'audit d'approbation par déclencheur (tout passe par `approve_jobs`). **À décider :** `payroll_treatment` (remboursement ou avantage imposable) et les montants de repas et de stationnement sont des notions de **paie** ; pour l'invariant « aucun montant de paie » au sens strict, ils passeraient au côté 2.
8. `0008_notes_review_audit` — notes de contremaître (par numéro), lecture par les gestionnaires, journal d'activité de l'employé sans nom.
9. `0009_inventory` (avec `employee_groups` ; **remplace** à nouveau `validate_job_submission_contract` pour l'inventaire de fin de quart).
10. `0010_push`, `0011_announcements`, `0012_sync_api` (clients, actions, `action_key` unique, `expected_version`).

Chaque migration : fichier SQL + test SQL (`next/test-NNNN.sql`) exécuté par `scripts/test-next-schema.sh` sur un PostgreSQL jetable, avec ses fausses fonctions et tables Supabase (`auth.uid()`, `auth.jwt()`, rôles, `storage.buckets` / `storage.objects`). **Chaque migration est appliquée, puis son test est lancé, avant la suivante** : un test décrit l'état de sa propre migration (une migration ultérieure peut remplacer une fonction, ce que son propre test vérifie). Ce banc d'essai ne remplace pas un essai sur une vraie base Supabase.

## Notes de relevé (V0.3.0)

- **Banc de référence :** `scripts/rebuild-legacy-db.sh` reconstruit les 150 migrations de Sparklog sur un PostgreSQL local (avec `check_function_bodies = off`, comme Supabase) : `ok=150 bad=0`. On y relève la structure exacte (`pg_dump -s -t …`, `pg_get_functiondef`) avant d'écrire une migration neuve.
- **Donnée nominative trouvée dans une liste de départ :** l'ancienne liste d'OT prédéfinis contient un libellé avec un prénom. Il n'est **pas** repris dans `next/0003`. Il reste dans les migrations copiées de Sparklog (`supabase/migrations/`, dépôt public), qui seront retirées quand `next/` les remplace.
- **Montants sur la fiche :** `jobs` portait trois « instantanés » de taux (`hourly_rate_snapshot`, `team_leader_premium_snapshot`, `km_rate_snapshot`). Le côté 2 les calcule : ils ne sont pas repris.
- **Jours fériés :** les dates sont celles de la convention (par exemple la Fête du Canada 2027 est le 2027-07-02, pas le 07-01).
