# NOOB — Sparklog-Employés (V0.2.0)

**Ce que c'est :** la moitié « pointage » de Sparklog, en train d'être construite dans un nouveau dépôt. L'autre moitié (noms, paie) est dans `Sparklog-Gestion`.

**Ce que vous voyez maintenant :** rien de nouveau pour les employés. Ce dépôt n'est **pas** utilisé en production : Sparklog (l'ancien dépôt) tourne toujours.

**Ce qui a été fait (V0.2.0) :** le code du pointage a été copié de Sparklog, et les écrans de gestion et de paie ont été retirés (ils sont dans Sparklog-Gestion).

**V0.2.0 :** documentation seulement — `PLAN.md` complété (codes d'activation, journaux minimaux, CSV d'abord, couche d'authentification séparée, corrections sans écrasement). Aucun code changé.

**À faire ensuite (par vous) :**
- Décider de l'hébergement au Québec et du projet de base de données de ce côté (étape 0 du `PLAN.md`).
- Obtenir l'avis de l'AECQ ou d'un avocat (questions listées dans `PLAN.md`, étape 0).

**À faire ensuite (par moi, sur votre demande) :** nouvelle base, connexion par numéro d'employé, retrait des noms (`PLAN.md`, étapes 2 à 10).

**V0.2.0 :** premier morceau du **schéma neuf du côté 1** (dans `supabase/next/`, pas encore appliqué à une base) : le profil minimal (numéro d'employé, rôle, pause) et les **codes d'activation** (code à usage unique, valable 72 h, bloqué après 5 essais ratés, jamais stocké en clair). Testé sur un PostgreSQL local jetable (`scripts/test-next-schema.sh`). Le tableau de ce qui reste au côté 1 et de ce qui va au côté 2, table par table, est dans `docs/schema-cote1.md`. **Rien ne change pour les employés.** Vous avez trois choses à trancher dans ce tableau : l'absence de temps libre (`employee_time_off`), les notes de gestionnaires, et les groupes d'employés (inventaire et annonces).
