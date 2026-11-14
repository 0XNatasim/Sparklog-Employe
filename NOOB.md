# NOOB — Sparklog-Employés (V0.3.1)

**Ce que c'est :** la moitié « pointage » de Sparklog, en train d'être construite dans un nouveau dépôt. L'autre moitié (noms, paie) est dans `Sparklog-Gestion`.

**Ce que vous voyez maintenant :** rien de nouveau pour les employés. Ce dépôt n'est **pas** utilisé en production : Sparklog (l'ancien dépôt) tourne toujours.

**Ce qui a été fait (V0.3.1) :** le code du pointage a été copié de Sparklog, et les écrans de gestion et de paie ont été retirés (ils sont dans Sparklog-Gestion).

**V0.3.1 :** documentation seulement — `PLAN.md` complété (codes d'activation, journaux minimaux, CSV d'abord, couche d'authentification séparée, corrections sans écrasement). Aucun code changé.

**À faire ensuite (par vous) :**
- Décider de l'hébergement au Québec et du projet de base de données de ce côté (étape 0 du `PLAN.md`).
- Obtenir l'avis de l'AECQ ou d'un avocat (questions listées dans `PLAN.md`, étape 0).

**À faire ensuite (par moi, sur votre demande) :** nouvelle base, connexion par numéro d'employé, retrait des noms (`PLAN.md`, étapes 2 à 10).

**V0.3.1 :** premier morceau du **schéma neuf du côté 1** (dans `supabase/next/`, pas encore appliqué à une base) : le profil minimal (numéro d'employé, rôle, pause) et les **codes d'activation** (code à usage unique, valable 72 h, bloqué après 5 essais ratés, jamais stocké en clair). Testé sur un PostgreSQL local jetable (`scripts/test-next-schema.sh`). Le tableau de ce qui reste au côté 1 et de ce qui va au côté 2, table par table, est dans `docs/schema-cote1.md`. **Rien ne change pour les employés.** Les trois points laissés ouverts sont tranchés (voir V0.3.1).

**V0.3.1 :** vos trois décisions sont inscrites. Le **temps libre** (absences, congés) et les **notes entre gestionnaires** vont dans Sparklog-Gestion (côté 2). Les **groupes d'employés** (un groupe = un entrepôt ou une équipe, avec des numéros, jamais des noms) restent au côté 1 ; le côté 2 les gère et s'en sert pour cibler les annonces, qu'il publie vers le côté 1 sans noms de destinataires. Nouvelle migration `0002_roles` du schéma neuf : rôles, double authentification obligatoire pour les gestionnaires, propriétaire seul « privilégié », lecture des profils (chacun voit le sien ; un gestionnaire avec double authentification voit les numéros et rôles). Testée sur un PostgreSQL local. **Rien ne change pour les employés.**

**V0.3.1 :** deux morceaux de plus du schéma neuf du côté 1, **testés** sur un PostgreSQL local. (1) **Réglages** : fuseau, échéance quotidienne, seuils d'alerte, conservation des preuves (30 jours), jours fériés de la convention, OT prédéfinis. Le côté 1 ne lit plus la carte CCQ, la date de naissance ni le syndicat. (2) **La fiche de temps** : heures de Montréal (hiver, été, nuit, heure qui n'existe pas au printemps, heure répétée à l'automne), refus de saisie un jour férié ou après l'échéance (sauf journée rouverte), vérification d'une fiche soumise (durée de 0 à 16 h, pas de chevauchement, retour et kilomètres cohérents). Les montants (taux, primes) ne sont plus sur la fiche : ils sont au côté 2. **Une chose à savoir :** l'ancienne liste d'OT prédéfinis contenait un libellé avec un prénom ; je ne l'ai pas repris dans le nouveau schéma. Il reste dans les anciennes migrations copiées de Sparklog, qui seront retirées plus tard. **Rien ne change pour les employés.**

**V0.3.1 :** **décision d'hébergement prise : Supabase auto-hébergé sur un serveur au Québec** (le logiciel libre, qui tourne sur un serveur chez un fournisseur canadien ; plus besoin de réécrire l'app). Le plan a une nouvelle **étape 2bis** (installer, sécuriser, sauvegarder et surveiller ce serveur) avant toute mise en service. **Ce que vous avez à faire :** (1) **nommer la personne qui sera responsable du serveur** (vous, un employé ou un prestataire) : sans elle, pas de mise en production ; (2) **choisir le fournisseur du serveur** (au Québec, propriété canadienne, certifié ISO 27001 ou SOC 2 Type 2) : je peux préparer une grille de comparaison ; (3) poser à l'AECQ ou à l'avocat la question 7 de l'étape 0.1 : « si nous exploitons nous-mêmes le logiciel sur l'infrastructure d'un fournisseur certifié, est-ce que l'exigence de fournisseur certifié est satisfaite ? ». **Plan B** si l'exploitation devient trop lourde : Supabase infonuagique en région canadienne, sans changer le code. **Rien ne change pour les employés.**
