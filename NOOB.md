# NOOB — Sparklog-Employés (V0.2.1)

**Ce que c'est :** la moitié « pointage » de Sparklog, en train d'être construite dans un nouveau dépôt. L'autre moitié (noms, paie) est dans `Sparklog-Gestion`.

**Ce que vous voyez maintenant :** rien de nouveau pour les employés. Ce dépôt n'est **pas** utilisé en production : Sparklog (l'ancien dépôt) tourne toujours.

**Ce qui a été fait (V0.2.1) :** le code du pointage a été copié de Sparklog, et les écrans de gestion et de paie ont été retirés (ils sont dans Sparklog-Gestion).

**V0.2.1 :** documentation seulement — `PLAN.md` complété (codes d'activation, journaux minimaux, CSV d'abord, couche d'authentification séparée, corrections sans écrasement). Aucun code changé.

**À faire ensuite (par vous) :**
- Décider de l'hébergement au Québec et du projet de base de données de ce côté (étape 0 du `PLAN.md`).
- Obtenir l'avis de l'AECQ ou d'un avocat (questions listées dans `PLAN.md`, étape 0).

**À faire ensuite (par moi, sur votre demande) :** nouvelle base, connexion par numéro d'employé, retrait des noms (`PLAN.md`, étapes 2 à 10).

**V0.2.1 :** premier morceau du **schéma neuf du côté 1** (dans `supabase/next/`, pas encore appliqué à une base) : le profil minimal (numéro d'employé, rôle, pause) et les **codes d'activation** (code à usage unique, valable 72 h, bloqué après 5 essais ratés, jamais stocké en clair). Testé sur un PostgreSQL local jetable (`scripts/test-next-schema.sh`). Le tableau de ce qui reste au côté 1 et de ce qui va au côté 2, table par table, est dans `docs/schema-cote1.md`. **Rien ne change pour les employés.** Les trois points laissés ouverts sont tranchés (voir V0.2.1).

**V0.2.1 :** vos trois décisions sont inscrites. Le **temps libre** (absences, congés) et les **notes entre gestionnaires** vont dans Sparklog-Gestion (côté 2). Les **groupes d'employés** (un groupe = un entrepôt ou une équipe, avec des numéros, jamais des noms) restent au côté 1 ; le côté 2 les gère et s'en sert pour cibler les annonces, qu'il publie vers le côté 1 sans noms de destinataires. Nouvelle migration `0002_roles` du schéma neuf : rôles, double authentification obligatoire pour les gestionnaires, propriétaire seul « privilégié », lecture des profils (chacun voit le sien ; un gestionnaire avec double authentification voit les numéros et rôles). Testée sur un PostgreSQL local. **Rien ne change pour les employés.**
