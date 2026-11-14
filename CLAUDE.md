# CLAUDE.md — Sparklog-Employés (côté 1 : pointage)

**Stack :** React 18 + Vite PWA, Supabase (Postgres + RLS + Edge Functions). Même pile que `Sparklog` (mis de côté).

**Rôle :** pointage par **numéro d'employé**. Aucun nom, courriel, téléphone, NAS ni montant de paie ne doit être recueilli ni stocké ici (invariant I1 de `PLAN.md`).
Le côté 2 est `Sparklog-Gestion` (privé). Plan : `PLAN.md`. Conformité : `OFFICIEL.md`.

**Release rule:** à chaque PR, incrémenter `APP_VERSION` dans `src/lib/version.js` et le mentionner dans le titre du commit / de la PR.

**Docs rule:** `README.md`, `NOOB.md` et `CLAUDE.md` sont mis à jour **ensemble, dans la même PR**, et nomment chacun la version courante (`src/lib/docs-sync.test.js` échoue sinon).
Jamais de valeur personnelle (nom, NAS, salaire, montant de paie) dans le dépôt : il est **public**.

**Règle de sécurité des tables :** pour toute nouvelle table, `revoke all … from anon, public, authenticated` **avant** les `grant` voulus (Supabase donne des droits par défaut).

## État (V0.3.1)

Squelette copié de Sparklog V2.4.258 (étape 1bis de `PLAN.md`) : voir `COPIE-DEPUIS-SPARKLOG.md`. Écrans de gestion et de paie retirés ; `App.jsx`, `ManagerPages.jsx` et
`manager-nav.js` réduits au temps (Aujourd'hui, En direct, Notes, Feuilles de temps, Inventaire, Journal, État du service, Feuille d'urgence).
Les migrations de Sparklog (`supabase/migrations/`) sont encore **toutes** là (les tests de contrat les lisent) ; elles seront remplacées par des migrations neuves à l'étape 10.

## Hébergement (V0.3.1)

D4 tranchée le 2026-11-14 : **Supabase auto-hébergé, serveur au Québec**, fournisseur d'infrastructure canadien (`PLAN.md` étape 2bis). Le code reste compatible `supabase-js` : ne rien introduire qui dépende de l'infonuagique de Supabase (plan B = hébergé en région canadienne). Aucune mise en production sans personne responsable de l'exploitation nommée.

## Schéma neuf (V0.3.1)

`supabase/next/` contient le schéma neuf (migrations `NNNN_*.sql` + `test-NNNN.sql`), **séparé** de `supabase/migrations/` (copie de Sparklog, encore lue par des tests). `scripts/test-next-schema.sh` (en root, PostgreSQL 16 local)
applique `next/` sur une base jetable avec de faux schémas Supabase puis lance les tests SQL ; à lancer avant chaque PR qui touche `next/`. Décisions table par table et ordre des migrations : `docs/schema-cote1.md`. Fait : `0001_identity`, `0002_roles`, `0003_company_settings`, `0004_jobs` (fiche de base ; `validate_job_submission_contract` sera remplacée par 0005 puis 0007). Pour relever la structure d'une table de Sparklog : `scripts/rebuild-legacy-db.sh` puis `pg_dump -s -t …` sur `/tmp/legacydb` (port 54330). Chaque migration neuve a son `test-NNNN.sql` ; vérifier au moins une mutation (casser une règle, constater l'échec, rétablir). Décisions du 2026-11-14 : `employee_time_off` et notes de gestionnaires → côté 2 ; groupes d'employés → côté 1 (par numéro).

## Ouvert (voir `PLAN.md`)

- [ ] Étape 2bis : serveur québécois (fournisseur, pile Supabase, sécurité, sauvegardes, surveillance, personne responsable) ; étape 3 : API d'échange pour le côté 2.
- [ ] Étape 10 : connexion par numéro + adresses factices, retrait des colonnes et textes nominatifs, journaux par numéro.
- [ ] Nettoyage : `authorization-matrix.js` et ses tests, `manager-nav.test.js`, textes `i18n.js` et fonctions Edge à revoir pour ne garder que le pointage.
- [ ] À trancher : `CcqCardCapture` et `ReferenceContent` (utilisés par `Profile.jsx`). À retirer du côté 1 : `NotesPanel` et le code des notes de gestionnaires (décidé : côté 2).
