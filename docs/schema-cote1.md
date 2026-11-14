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
3. `0003_company_settings` — réglages et jours fériés.
4. `0004_jobs` — fiches, validation de soumission, chevauchement, fuseau (reprendre 0062 à 0064, 0116, 0135 en une version consolidée, **un test par règle déjà verrouillée dans Sparklog**).
5. `0005_evidence_meals_parking` — preuves, repas, stationnement, tampons de nettoyage.
6. `0006_notes_review_audit` — notes, notifications, audit sans donnée nominative, historique des corrections.
7. `0007_inventory` (avec `employee_groups`), `0008_push`, `0009_announcements`, `0010_sync_api` (clients, actions, `action_key` unique, `expected_version`).

Chaque migration : fichier SQL + test SQL (`next/test-NNNN.sql`) exécuté par `scripts/test-next-schema.sh` sur un PostgreSQL jetable, avec ses fausses fonctions Supabase (`auth.uid()`, rôles). Ce banc d'essai ne remplace pas un essai sur une vraie base Supabase.
