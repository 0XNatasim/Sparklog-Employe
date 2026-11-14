# Copie depuis Sparklog (lecture seule)

Source : dépôt `Sparklog` (mis de côté), branche `main`, commit `57005cc` (V2.4.258), extraite avec `git archive` : **Sparklog n'a pas été modifié**.

## Conservé (pointage)

Écrans de l'employé (`EmployeeForm`, `History`, `Week`, `Profile`, `Login`, `ResetPassword`), `employee-form/`, saisie d'urgence, preuves de temps supp., repas, stationnement,
inventaire, notes et notes de contremaître, notifications push et cloche, `WeekSnapshot`, `JobCard`, `TodoInbox`, `UnlockDayManager`, `LiveCrew`, `AuditLog`, `EmployeeActivityLog`, `InfraHealthCard`,
`TwoFactor`, composants communs et `ui/`, moteur d'heures (`supabase/functions/_shared/payroll_engine.js`, `classify_week`), fonctions Edge de pointage (`process_*`, `cleanup_overtime_evidence`,
`delete_inventory_screenshots`, `send_push`, `infra_metrics`), toutes les migrations (voir `CLAUDE.md`), docs `adr/`, `security/`, `ops/`, `governance/`, `rules/compensation-rules.md`.

## Retiré (va dans `Sparklog-Gestion`)

Paie, talons, DAS, relevé d'emploi, Calcul, Coûts, Rapports, export CCQ, taux et barèmes, trajets et frais, dossier d'employé (`components/employees/`), employés / absences / formulaires / références / contacts / groupes,
paramètres, annonces (`Broadcast*Manager`, `ManagerAnnouncePanel`), registre d'accidents, import de talons, NAS, `src/payroll/` (sauf `ccq-benefits.js` et `rules/2026.js`, encore lus par `payroll-rates.js`),
fonctions Edge `push_approved_batch`, `ccq_rates*`, `send_announcement`, `create_employee`, `reset_employee_password`, `delete_user`, et les tests qui les concernaient.

## Adaptations faites ici (V0.1.0)

`App.jsx`, `pages/manager/ManagerPages.jsx`, `lib/manager-nav.js` : routes et onglets de gestion retirés. Tests de ces écrans supprimés ; tests de `manager-nav`, `mfa`, `push-*`, `authorization-matrix` réduits.
`version.js` : `0.1.0`. `README.md`, `NOOB.md`, `CLAUDE.md` : nouveaux.
