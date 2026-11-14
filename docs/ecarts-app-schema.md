# Écarts entre l'application (`src/`) et le schéma neuf (`supabase/next/`)

Relevé automatique : `DUMP_SCHEMA=/tmp/schema.json scripts/test-next-schema.sh && node scripts/check-app-against-schema.mjs /tmp/schema.json` (analyse statique approximative : `.from()` + select / filtres / écritures, et `.rpc()`). État au **V0.18.0 : 22 écarts** (29 en V0.17.0 ; le groupe C est porté par la migration 0013, `get_infra_stats` abandonné). Objectif : 0, puis ajouter ce contrôle à la CI (il demande PostgreSQL 16).

## A. À retirer du côté 1 (données du côté 2 ou nominatives)
| Écart | Où | Pourquoi |
|---|---|---|
| `employee_time_off` (table) | LiveCrew, WeekSnapshot, InventoryScreenshotsPanel, TodoInbox, missing-days | décidé 2026-11-14 : temps libre → côté 2 |
| `manager_notes`, `manager_note_replies`, `manager_note_reads`, `my_note_unread_replies` | NotesPanel, lib/notes.js | décidé : notes de gestionnaires → côté 2 |
| `payroll_rates`, `statutory_rate_sets`, `set_/delete_payroll_rate`, `set_/delete_statutory_rate_set` | lib/payroll-rates.js | paie → côté 2 |
| `pending_signups` | lib/signups.js | plus d'inscription libre (V0.15.0) |
| `profiles.start_date`, `apprentice_level`, `departure_status` | LiveCrew, WeekSnapshot, TodoInbox, InventoryScreenshotsPanel, EmployeeActivityLog, MissingDaysPanel | dates d'embauche, niveau, départ : côté 2 |
| `employee_activity_log.user_name`, `jobs.manager_entry_by_name`, `foreman_reports.returned_by_name` | EmployeeActivityLog, EmergencyTimesheet, foreman-reports | noms : remplacés par le numéro (`employeeLabel`) |

## B. À adapter (existe sous un autre nom)
| Ancien | Nouveau (schéma neuf) |
|---|---|
| `foreman_reports.audited_name` (texte libre) | `audited_employee_number` (numéro) — saisie par numéro |
| `broadcast_recipients`, `manager_broadcasts` | `announcement_recipients`, `announcements` (0011 ; `employee_id`, `acknowledged_at` une seule fois) |

## C. Fonctions côté 1 — FAIT en V0.18.0 (migration 0013 ; `get_infra_stats` abandonné)
| Écart | Rôle dans l'app | Recommandation |
|---|---|---|
| `job_entry_sources` (table) | étoile rouge « saisie manuelle » (OCR ou à la main) | porter (petite table, RLS par employé) |
| `manager_job_counts` | compteurs de la page Feuilles de temps | porter (agrégat, évite de relire les fiches ; règle « Database load regression ») |
| `ot_reuse_for_jobs` | alerte « OT réutilisé » avant approbation | porter (travaille sur les numéros d'OT, pas de nom) |
| `evidence_download_alert` | bandeau « preuves à télécharger avant leur suppression » | porter (lit `evidence_downloads`, 0007) |
| `log_file_read_error` | journal des échecs de lecture de captures | porter ou retirer (compteurs seulement) |
| `delete_manager_entry`, `remind_manager_entry` | feuille d'urgence : supprimer un brouillon, rappeler l'employé | porter (0005 a `manager_entry_reminded_at`) |
| `get_infra_stats` | carte « État du service » | à revoir avec l'étape 2bis (serveur auto-hébergé : métriques d'infrastructure autres) |
