# PLAN.md — Construire Sparklog-Gestion (côté 2) et séparer le pointage (côté 1)

> Plan d'exécution détaillé, étape par étape. Il découle de `OFFICIEL.md` du dépôt **Sparklog** (plan de conformité : exigences,
> écarts, phases P0–P6) et le précise pour la partie « deux côtés ». Si les deux documents divergent, `OFFICIEL.md` donne les
> **exigences**, ce fichier donne l'**ordre de travail**.
>
> **Dépôt privé.** Il décrit où sont les données sensibles, mais ne contient **aucune** donnée réelle : ni nom, ni NAS, ni montant de
> paie d'une personne, ni table numéro ↔ personne. Ces données ne vivent que dans la base du côté 2.
>
> Tout ce qui est juridique est **[À VALIDER]** à l'étape 0 : ce plan n'est pas un avis juridique.

> ## Révision du 2026-11-14 (2) — trois dépôts, et Sparklog est mis de côté
>
> Décision de la propriétaire : le dépôt **`Sparklog` est mis de côté** (il n'est plus modifié, il reste la référence et le plan B). On construit **uniquement** :
>
> | Dépôt | Rôle | Visibilité |
> |-------|------|------------|
> | **`Sparklog-Employés`** (`Sparklog-Employ-s` sur GitHub : l'accent est remplacé par un tiret) | **Côté 1 = pointage.** Une copie, ou presque, de Sparklog, sans la gestion ni la paie. C'est là que se font les étapes marquées « dépôt Sparklog / côté 1 » | public |
> | **`Sparklog-Gestion`** | **Côté 2 = gestion et paie** (noms, courriels, téléphones, paie, NAS, relevés d'emploi) | privé |
>
> **Comment lire ce plan :** partout où il dit « dépôt Sparklog », « côté 1 » ou « Sparklog (côté 1) », lire **`Sparklog-Employés`**. Comme c'est un **nouveau** dépôt avec sa **nouvelle** base, rien de ce qui est
> demandé n'est « interdit » : on ne touche pas à la production actuelle de Sparklog, on construit à côté, puis on bascule (étape 13).
>
> | Étape | Où | Précision |
> |-------|----|-----------|
> | 0, 1, 2 | Gestion | Inchangées |
> | 3 (API d'échange) | **Employés** | Se construit dans le nouveau dépôt ; plus de « ajout seulement à Sparklog » |
> | 4, 5, 6, 7, 8 | Gestion | Inchangées. Au début, la source des heures est la production de Sparklog (lecture seule) ; après la bascule, c'est Employés |
> | 9 (actions vers le côté 1) | Employés + Gestion | Inchangée |
> | 10 (côté 1 sans noms) | **Employés** | Plus simple : on **ne copie pas** les colonnes et écrans nominatifs au lieu de les retirer ; la connexion par numéro se construit dès le départ |
> | 11 (hébergement au Québec) | Employés (et Gestion selon D4) | Le nouveau projet de base est créé **directement** dans la région choisie : plus de migration d'hébergement |
> | 12, 14 | Les deux | Inchangées |
> | 13 (parallèle et bascule) | Les deux | Les employés passent de Sparklog à Employés ; 13.3 (retrait de l'ancien chemin) devient **l'abandon de Sparklog**, après la période parallèle |
>
> **Nouvelle étape intercalaire, 1bis — Squelette de `Sparklog-Employés`** (avant l'étape 3) : copier de Sparklog le pointage (écrans de l'employé, saisie, preuves de temps supp., repas, stationnement,
> inventaire, notifications, OCR, saisie d'urgence, notes de contremaître, révision des fiches), **sans** les écrans de paie ni les données nominatives ; nouvelle base (région décidée à l'étape 0) ;
> CI, version, tests et documentation comme à l'étape 1. Livrable : le pointage fonctionne de bout en bout avec des numéros d'employé et des adresses factices.
>
> **Invariants :** les sept invariants (I1 à I7) s'appliquent à `Sparklog-Employés`. Ils sont atteignables puisque le dépôt est nouveau.
>
> ## Révision du 2026-11-14 (3) — cinq idées retenues d'une proposition externe
>
> Une proposition d'architecture (rédigée par un autre assistant) a été comparée à ce plan. On **garde ce plan** (il couvre tout le domaine : fiches par OT, kilométrage, preuves, repas, stationnement,
> inventaire, règles CCQ, approbation, paie) et on **y ajoute** cinq idées :
>
> | # | Idée retenue | Où dans ce plan |
> |---|--------------|-----------------|
> | 1 | **Codes d'activation** à usage unique (hachés, durée limitée, essais limités) à la place d'un NIP temporaire ; le numéro d'employé n'est **jamais** un mot de passe | 5.7, 9.4 |
> | 2 | **Journaux minimaux** : pas d'IP complète, ni nom, ni courriel, ni numéro RH, ni jeton dans les métadonnées ; vérifier ce que l'hébergeur garde de son côté | 3.6, 10.8 |
> | 3 | **CSV d'abord**, automatisation ensuite pour l'échange des heures | 4.0 |
> | 4 | **Couche d'authentification séparée** de la logique de pointage (changer de méthode de connexion sans tout refaire) ; passkeys possibles **plus tard**, pas au départ | 10.1 |
> | 5 | **Les corrections n'écrasent jamais l'original** : piste d'audit prouvée par un test | 10.9 |
>
> ## Révision du 2026-11-14 (4) — D4 tranchée : Supabase auto-hébergé sur un serveur au Québec
>
> Décision de la propriétaire : on **quitte l'infonuagique de Supabase** et on fait tourner le **logiciel libre Supabase** sur un **serveur situé au Québec**, chez un fournisseur d'infrastructure **canadien**. Raisons : les données ne sont pas
> chez une société américaine (pas d'exposition au CLOUD Act pour l'hébergement), et **aucune réécriture de l'app** (`supabase-js`, RLS, schéma `supabase/next/`, fonctions Edge restent).
> Le prix : **nous devenons l'équipe d'exploitation** (sécurité, sauvegardes, mises à jour, pannes). Nouvelle étape **2bis** (infrastructure) avant toute mise en service ; l'étape 11 la **réutilise**.
> Le **front** (fichiers statiques) peut être hébergé chez Canner (Montréal) ou sur le même serveur. **D4b** (à confirmer) : le côté 1 et le côté 2 sont sur **deux piles séparées** (jamais la même base) ; elles peuvent partager un serveur au tout début, à séparer ensuite.
> **Plan B** si l'exploitation devient trop lourde : Supabase infonuagique en région canadienne (même schéma, même code, migration par sauvegarde et restauration) — avec l'exposition américaine à documenter dans l'évaluation (Loi 25).
>
> **Idées écartées, et pourquoi :** remplacer les fiches par des « sessions de travail » et des pauses (Sparklog n'a pas de boutons de pointage et le domaine est plus large) ; ajouter un UUID en plus du numéro d'employé
> (la convention prévoit un numéro d'employé ; le numéro aléatoire du côté 2 joue ce rôle, **à confirmer à l'étape 0**) ; supposer un système RH existant (c'est le côté 2) ; imposer les passkeys (support jugé
> expérimental chez Supabase, **non vérifié**, et charge de soutien pour environ 150 employés).

---

## 0. Le modèle en une page

```
 Employés ──────► CÔTÉ 1 « Sparklog » (public, Québec) ◄──── appels authentifiés ──── CÔTÉ 2 « Sparklog-Gestion » (privé, Québec)
                  numéro d'employé, fiches de temps,                                    noms, courriels, téléphones, taux, paie,
                  preuves, inventaire, notes par numéro                                 talons, DAS, RE, TD1, NAS, accidents, annonces
                  AUCUN nom / courriel / téléphone / montant                            table numéro ↔ personne (seul endroit)
                          │                                                                   ▲
                          └──────────── jamais d'appel du côté 1 vers le côté 2 ──────────────┘
```

### Règles qui ne changent jamais (invariants)

| # | Invariant | Comment on le prouve |
|---|-----------|----------------------|
| I1 | Le côté 1 ne reçoit ni ne stocke un nom, un courriel, un téléphone, un NAS, un taux ni un montant de paie. | Requête SQL de contrôle (étape 10) sur la base du côté 1 : 0 ligne. |
| I2 | Tous les appels entre les deux côtés partent du **côté 2**. Le côté 1 n'a ni URL ni secret du côté 2. | Revue du code et des secrets du côté 1 ; test qui échoue si une fonction du côté 1 appelle un hôte du côté 2. |
| I3 | Chaque action qui traverse la frontière a une **clé d'idempotence** : rejouée, elle produit un seul effet métier et une seule ligne d'audit. | Tests de rejeu (étapes 4 et 9). |
| I4 | Le lien numéro ↔ personne n'existe que dans la base du côté 2. | Contrôle des tables du côté 1 ; export de la base du côté 1 sans lien. |
| I5 | La paie du côté 2 est identique, au centime, à celle de Sparklog actuel, semaine par semaine, avant de retirer l'ancien chemin. | Tests de parité (étape 6) et période parallèle (étape 13). |
| I6 | Aucune étape n'est mise en production sans plan de retour arrière écrit. | Section « Retour arrière » de chaque étape. |
| I7 | Les journaux (audit) des deux côtés désignent les gens **par numéro** côté 1 et par personne côté 2. | Étape 10. |

### Vocabulaire

- **Numéro d'employé** (`employee_number`) : entier attribué par le côté 2, jamais réutilisé, jamais dérivé d'un nom, d'une date ou du NAS.
- **Fiche** : une ligne de la table `jobs` du côté 1 (un intervalle de travail d'un jour).
- **Miroir** : copie des fiches du côté 1 dans la base du côté 2, indexée par numéro.
- **Curseur** : repère (`updated_at`, `id`) qui dit au côté 2 où il s'est arrêté dans la lecture.
- **Boîte d'envoi** (*outbox*) : file des actions du côté 2 vers le côté 1 (approuver, retourner, créer un compte…), rejouables.

---

## Vue d'ensemble des étapes

| Étape | Titre | Durée estimée | Dépend de | Point de non-retour ? |
|-------|-------|---------------|-----------|------------------------|
| 0 | Décisions et prérequis (avis juridique, hébergeur, responsable) | 1–2 sem. (attente de tiers) | — | Non |
| 1 | Squelette du dépôt côté 2 | 2–3 jours | 0 (hébergeur) | Non |
| 2 | Base de données du côté 2 (schéma, sécurité) | 1 sem. | 1 | Non |
| 2bis | **Infrastructure : Supabase auto-hébergé sur un serveur québécois** (sécurité, sauvegardes, surveillance, mises à jour) | 2–3 sem. | 0 (hébergeur) | Non |
| 3 | Contrat d'échange : l'API du côté 1 (dépôt Sparklog) | 1 sem. | 0 | Non |
| 4 | Synchronisation en lecture (côté 2 lit le côté 1) | 1 sem. | 2, 3 | Non |
| 5 | Numérotation des employés et table numéro ↔ personne | 3–4 jours | 2, 3 | Non |
| 6 | Moteur de paie du côté 2 et parité | 2 sem. | 4, 5 | Non |
| 7 | Migration des données de paie vers le côté 2 | 1 sem. | 2, 6 | Non (l'ancien chemin reste) |
| 8 | Écrans de gestion du côté 2 (avec noms) | 3–4 sem. | 6, 7 | Non |
| 9 | Actions du côté 2 vers le côté 1 (approuver, retourner, comptes) | 1–2 sem. | 3, 4, 8 | Non |
| 10 | Côté 1 sans noms (retrait des colonnes, journaux, écrans) | 2–3 sem. | 9 | **Oui** (voir 10.6) |
| 11 | Hébergement du côté 1 au Québec | 1–2 sem. | 10 | **Oui** (bascule) |
| 12 | Services externes (courriel, notifications, OCR, export Google) | 1–2 sem. | 8 | Non |
| 13 | Période parallèle, bascule finale, retrait de l'ancien chemin | 2 sem. de paie | 8–12 | **Oui** |
| 14 | Exploitation et maintien | continu | 13 | — |

Les étapes 1 à 7 ne changent **rien** pour les employés ni pour les gestionnaires : Sparklog continue de fonctionner comme aujourd'hui.
Le premier changement visible apparaît à l'étape 8 (nouvel écran de gestion), et le premier changement qui ne se défait pas facilement
à l'étape 10. **Si l'avis de l'étape 0 dit que la séparation n'est pas exigée, on s'arrête après l'étape 8 ou 9 et on garde un seul côté
renforcé.**

---

## Étape 0 — Décisions et prérequis

**Objectif.** Ne rien construire de lourd avant d'avoir les réponses qui peuvent raccourcir le plan.

**À faire (la propriétaire, avec de l'aide pour la rédaction des questions) :**
- [ ] **0.1** Avis écrit de l'AECQ ou d'un avocat sur ces questions précises :
  1. Sparklog est-il un « système de pointage » au sens de l'art. 18.01 2) b) ? **[D1]**
  2. Un numéro d'employé lié à des heures, sans nom, suffit-il comme renseignement dépersonnalisé côté pointage ? **[OFFICIEL 5.1]**
  3. Le côté 2 (noms, courriels, téléphones, paie) doit-il aussi être hébergé au Québec ? (la convention vise le pointage ; la Loi 25 vise le transfert hors Québec, avec évaluation et entente écrite)
  4. L'approbation par un gestionnaire peut-elle se faire dans un système distinct du pointage ?
  5. Un gestionnaire peut-il afficher un nom dans son navigateur si le serveur de pointage ne le stocke pas ?
  6. Durée de conservation des fiches de temps et des preuves.
  7. **Exploitation par nous-mêmes :** si nous faisons tourner le logiciel sur l'infrastructure d'un fournisseur québécois certifié (ISO 27001 / SOC 2 Type 2), l'exigence de **fournisseur certifié** de la convention est-elle satisfaite, ou faut-il que **l'exploitant** du système soit lui-même certifié ? (D4) **Réponse reçue le 2026-11-14 (de la propriétaire, verbalement) : oui, le certificat du fournisseur d'infrastructure suffit ; l'exploitant n'a pas à être certifié lui-même.** **À obtenir par écrit** (courriel de l'AECQ ou de l'avocat, rangé dans le dossier privé de preuves) avant la mise en production.
- [ ] **0.2** Nommer la **personne responsable de la protection des renseignements personnels** (obligation Loi 25) et publier ses coordonnées.
- [ ] **0.3** **D4 tranchée (2026-11-14) : Supabase auto-hébergé.** Reste à choisir le **fournisseur d'infrastructure** québécois (voir 2bis.1) et à nommer la personne responsable de l'exploitation (2bis.9).
  Vérifier la région disponible chez Supabase **[À VÉRIFIER : région `ca-central-1` (Montréal) ou équivalent]**.
- [ ] **0.4** Décider **D2** (écran de gestion servi par le côté 2 — *recommandé et supposé par ce plan*) et **D3** (moteur d'heures : copie versionnée avec parité, ou appel du côté 1).
- [ ] **0.5** Décider **D5** (l'export Google Sheet : retiré ou reproduit côté 2) et **D7** (date de naissance, photo de la carte CCQ : supprimer ou garder côté 2).
- [ ] **0.6** Créer un **nouveau projet** de base de données pour le côté 2 (voir étape 2) et noter la région **dans OFFICIEL.md** (section 10, Sparklog).

**Livrable testable.** Un document « Décisions D1 à D7 » signé (date, qui a décidé, sur quelle base) dans `OFFICIEL.md` du dépôt Sparklog.

**Critère de sortie.** 0.1, 0.2, 0.3 répondus. Les autres décisions peuvent attendre l'étape où elles servent (D3 avant l'étape 6, D7 avant l'étape 7).

**Retour arrière.** Sans objet (aucun changement de système).

---

## Étape 1 — Squelette du dépôt côté 2

**Objectif.** Un dépôt qui construit, se teste et se déploie à vide, avec les mêmes garde-fous que Sparklog.

**Tâches précises :**
- [ ] **1.1** Branche par défaut protégée : pas de poussée directe, revue obligatoire, état de CI vert obligatoire. Dépôt **privé** (déjà fait).
- [ ] **1.2** Pile identique au côté 1 (pour réutiliser les compétences et le code) : React 18 + Vite, Tailwind, Vitest, ESLint (`--max-warnings=0`).
  `package.json` avec les scripts `dev`, `build`, `test`, `lint`. Node verrouillé (`.nvmrc`).
- [ ] **1.3** `CLAUDE.md` du côté 2 : stack, règles (nouveau fichier de migration à chaque changement de base, jamais de donnée réelle dans le dépôt),
  règle de version (`src/lib/version.js` incrémenté à chaque PR), règle de documentation (README, NOOB, CLAUDE ensemble — test de synchronisation
  repris de `docs-sync.test.js`).
- [ ] **1.4** `README.md` (ce que fait le côté 2), `NOOB.md` (ce que la propriétaire voit ou doit faire, en français simple), `OFFICIEL.md` ou renvoi vers celui de Sparklog.
- [ ] **1.5** Dossiers : `src/` (app), `src/lib/`, `src/payroll/` (étape 6), `supabase/migrations/`, `supabase/functions/`, `supabase/functions/_shared/`, `docs/`.
- [ ] **1.6** CI (GitHub Actions) : `npm ci`, `lint`, `test`, `build`. Analyse des secrets (`gitleaks` ou équivalent) bloquante.
  Test d'**interdit** : échoue si un fichier du dépôt contient un motif de NAS, de courriel réel ou de numéro de téléphone (liste de motifs dans `scripts/forbidden-patterns.js`).
- [ ] **1.7** Gestion des secrets : aucune clé dans le dépôt ; fichier `.env.example` avec noms seulement ; secrets réels dans l'hébergeur (fonctions) et dans un gestionnaire de mots de passe (copie de secours).
- [ ] **1.8** Déploiement du front sur un hébergeur **au Québec ou au Canada** (décision D4) ; domaine propre (ex. un sous-domaine réservé à la gestion).

**Livrable testable.** Une PR vide qui passe la CI ; l'URL de déploiement affiche « Sparklog-Gestion » derrière une page de connexion.

**Critère de sortie.** CI verte, déploiement automatique depuis la branche par défaut, test d'interdit qui échoue volontairement sur un faux NAS puis passe.

**Retour arrière.** Supprimer le dépôt ou le projet d'hébergement ; rien d'autre n'en dépend.

---

## Étape 2 — Base de données du côté 2

**Objectif.** Le schéma qui contiendra personnes, paie et miroir des fiches, avec la sécurité dès le premier jour.

**Règles de conception (leçons de Sparklog) :**
- Chaque nouvelle table : `revoke all on <table> from anon, public, authenticated;` **avant** tout `grant` (Supabase donne trop de droits par défaut ; voir la migration 0134 de Sparklog).
- RLS activée partout. Un gestionnaire n'accède qu'avec une session à double authentification (`aal2`) : mêmes fonctions `get_my_role()` / `is_privileged()` que le côté 1.
- Les fonctions `security definer` fixent `search_path`.
- Chaque table sensible a un trigger d'audit.

**Tâches précises :**
- [ ] **2.1** Projet de base au Québec (étape 0.3). Une migration par sujet dans `supabase/migrations/`, nommée `AAAAMMJJHHMMSS_NNNN_sujet.sql`.
- [ ] **2.2** Migration `0001_people` : table `people` (`id uuid`, `employee_number integer unique not null`, `full_name`, `email`, `phone`, `role`, `is_paused`, `start_date`, `rehire_date`, `notes`) ; séquence `employee_number_seq` ; **aucune** réutilisation de numéro (pas de `delete`, seulement `is_paused` / `left_on`).
- [ ] **2.3** Migration `0002_managers_auth` : comptes de gestion (courriel + mot de passe + **TOTP obligatoire**), rôles `owner` / `manager` / `admin` / `payroll`. `get_my_role()` renvoie un niveau manager seulement avec `aal2`.
- [ ] **2.4** Migration `0003_jobs_mirror` : table `jobs_mirror` (voir 4.2), `sync_state`, `sync_runs`.
- [ ] **2.5** Migration `0004_audit` : `audit_log` (acteur = personne du côté 2, cible = numéro) ; trigger d'audit générique ; **aucun** droit `update` / `delete`.
- [ ] **2.6** Migration `0005_incidents` : registre des incidents de confidentialité (date, nature, personnes touchées par numéro, mesures, avis donné ou non).
- [ ] **2.7** Migration `0006_consents` : registre des consentements (numéro, version du texte, date, refus / retrait) — copie des consentements reçus du côté 1 par numéro.
- [ ] **2.8** Sauvegardes automatiques activées, restauration **testée** (voir étape 14.4).

**Livrable testable.** `supabase/tests/rls.test.sql` (ou test Vitest sur la base de test) : un employé fictif, un gestionnaire sans `aal2`, un gestionnaire avec `aal2` ; chaque rôle × chaque table = résultat attendu (lecture refusée / permise).

**Critère de sortie.** La matrice rôle × table passe ; `\dp` ne montre aucun droit pour `anon` ; les triggers d'audit écrivent.

**Retour arrière.** Chaque migration a son script d'annulation documenté ; base vide à ce stade, on peut la recréer.

---

## Étape 2bis — Infrastructure : Supabase auto-hébergé sur un serveur québécois

**Objectif.** Une pile Supabase qui tourne chez nous, au Québec, sécurisée, sauvegardée et surveillée, **avant** d'y mettre une seule vraie donnée.

> **Lu dans la documentation officielle (supabase.com, « Self-Hosting », mise à jour le 2026-11-05, lue le 2026-11-14) :**
> - **Ressources :** minimum 4 Go de mémoire / 2 cœurs / 40 Go SSD ; **recommandé 8 Go et plus / 4 cœurs et plus / 80 Go et plus**. Notre point de départ (4 vCPU, 8 Go, 100 Go) est dans la zone recommandée.
> - **Installation officielle :** Docker Compose ; un script d'installation existe (`setup.sh`), mais on installe **à la main** avec une **étiquette de version épinglée** (ex. `self-hosted/vX.Y.Z`) plutôt que d'exécuter un script téléchargé. Le projet générait des secrets avec `utils/generate-keys.sh`. L'interface d'administration (Studio) n'est protégée que par un **mot de passe HTTP de base** : ne jamais l'exposer.
> - **Télémétrie :** la documentation dit que le Supabase **auto-hébergé n'envoie aucune télémétrie** ; seul l'outil en ligne de commande (CLI), distinct, en collecte. **À confirmer par un relevé des connexions sortantes du serveur.**
> - **Ce qui n'existe PAS en auto-hébergé :** sauvegardes gérées et restauration à un instant précis (PITR), branches, métriques avancées, analyses, API de gestion. **Les sauvegardes sont donc entièrement à notre charge** (2bis.5).
> - **Fonctions Edge :** supportées (dossier `volumes/functions`, redémarrage du service pour les prendre en compte). **Stockage S3 :** un guide de configuration existe. **Cron :** à vérifier pour l'auto-hébergé.
> - **Soutien :** le logiciel auto-hébergé est **soutenu par la communauté** (forums, GitHub), **sans engagement de service**. Un contact « entreprise » existe. Voir le risque ci-dessous.
> - **Mise à jour :** un guide « Update your deployment » et un script `update.sh` existent ; le guide précise que l'exploitant est responsable du serveur, de la sécurité, des sauvegardes, de la surveillance et de la haute disponibilité.
> Les autres points marqués **[À VÉRIFIER]** n'ont pas été relus.

**Tâches précises :**
- [ ] **2bis.1 Fournisseur d'infrastructure.** Serveur privé virtuel ou dédié, **centre de données au Québec**, fournisseur **à propriété canadienne**, certifications ISO 27001 et/ou SOC 2 Type 2 **du fournisseur**, entente écrite (art. 18.3), console hors bande, instantanés (*snapshots*), stockage de sauvegarde **au Québec** distinct du serveur. Comparer au moins deux offres. Question 7 de l'étape 0.1 : **réponse verbale reçue** (le certificat du fournisseur suffit) ; l'avoir **par écrit** avant la production, pas avant de commander un serveur d'essai. **Grille et modèle de courriel : `docs/grille-fournisseurs.md` (et `docs/grille-fournisseurs.csv` à importer dans Google Sheets).**
- [ ] **2bis.2 Dimensionnement.** Point de départ : 4 vCPU, 8 Go de mémoire, 100 Go de disque SSD (zone **recommandée** par la documentation officielle) pour environ 150 employés avec photos de courte durée ; à valider par un essai de charge, pas une garantie. Prévoir la croissance du stockage des photos (durée de conservation réglable : 30 jours par défaut).
- [ ] **2bis.3 Installation.** Docker Compose du projet Supabase, **versions épinglées** (jamais `latest`), **tous** les secrets de l'exemple remplacés : mot de passe Postgres, secret JWT, clés `anon` et `service_role` (dérivées du secret JWT), clé de chiffrement du coffre, mots de passe de l'interface d'administration. Secrets dans un gestionnaire de mots de passe d'équipe (copie de secours hors serveur), **jamais dans un dépôt**. Installation **à la main** sur une étiquette de version épinglée (la documentation la décrit : copie du dossier `docker/`, `.env` à partir de l'exemple, génération des clés) ; **ne pas exécuter à l'aveugle un script téléchargé** : le lire d'abord.
- [ ] **2bis.4 Durcissement.** Pare-feu : seuls 443 (et SSH par clés, depuis des adresses autorisées) ouverts ; Postgres, l'interface d'administration (Studio) et les services internes **jamais exposés** à Internet ; reverse proxy avec TLS automatique ; SSH par clés seulement, pas de connexion root ; mises à jour de sécurité du système automatiques ; limitation des essais de connexion ; journaux sans donnée personnelle. **Télémétrie :** la documentation dit qu'il n'y en a pas en auto-hébergé ; **le confirmer** par un test réseau qui liste les hôtes sortants du serveur.
- [ ] **2bis.5 Sauvegardes** (**confirmé : ni sauvegarde gérée ni restauration à un instant précis en auto-hébergé, tout est à nous**). Sauvegarde logique quotidienne **et** archivage continu pour restaurer à un instant précis (outil à choisir : `pgBackRest` ou équivalent) vers un stockage **au Québec, hors du serveur**, chiffré ; sauvegarde du stockage d'objets (photos) ; rétention écrite ; **restauration complète testée** sur un serveur neuf, avec le temps mesuré.
- [ ] **2bis.6 Surveillance.** Sonde externe (le site répond), espace disque, mémoire, expiration du certificat, dernière sauvegarde réussie, erreurs des services ; alertes à la propriétaire **et** à la personne d'exploitation (2bis.9), **sans** donnée personnelle dans les messages.
- [ ] **2bis.7 Mises à jour.** Calendrier écrit : système chaque mois, pile Supabase chaque trimestre (ou plus tôt pour une faille de sécurité) ; chaque mise à jour **d'abord** sur la pile d'essai ; retour arrière par instantané.
- [ ] **2bis.8 Deux environnements.** Production et **essai** (mêmes versions, données **fictives** seulement). Le côté 2 est sur une **pile séparée** (D4b) ; jamais de base partagée.
- [ ] **2bis.9 Personne responsable de l'exploitation** nommée (employé, prestataire ou contrat de soutien), avec un **runbook** : panne, restauration, rotation des secrets, incident de sécurité (lien avec 14.3), renouvellement du certificat, remplacement du serveur. **Pas de mise en production sans cette personne.**
- [ ] **2bis.10 Fonctions Edge et tâches planifiées.** Les fonctions Edge sont supportées en auto-hébergé (dossier `volumes/functions`) ; vérifier que `classify_week`, `process_*`, `cleanup_overtime_evidence`, `delete_inventory_screenshots`, `send_push`, `infra_metrics` y tournent ; planifier les tâches (extension `pg_cron` de l'image Postgres, ou un cron système qui appelle une fonction) **[À VÉRIFIER]**.
- [ ] **2bis.11 Stockage des photos.** Volume local du serveur, ou stockage compatible S3 au Québec (un guide « Configure S3 Storage » existe dans la documentation) ; dans les deux cas, règles d'accès équivalentes à celles de Sparklog (aucune lecture par un employé des photos d'un autre).
- [ ] **2bis.12 Front.** Fichiers statiques hébergés chez Canner (Montréal) ou sur le même serveur ; variables `VITE_SUPABASE_URL` et `VITE_SUPABASE_ANON_KEY` propres à chaque environnement.
- [ ] **2bis.13 Évaluation des risques de l'exploitation propre** (à joindre à l'évaluation Loi 25) : ce qu'on gagne (pas de société américaine, données au Québec) et ce qu'on prend en charge (sécurité, disponibilité, personne clé).

**Livrable testable.**
1. `scripts/test-next-schema.sh` rejoué **sur la pile d'essai réelle** (pas seulement la base jetable locale) : les migrations 0001 à 0004 s'appliquent et leurs tests passent.
2. Restauration complète depuis une sauvegarde sur un serveur neuf, **temps mesuré et noté** (objectif à fixer avec la propriétaire).
3. Balayage de ports depuis l'extérieur : seuls 443 (et SSH depuis les adresses autorisées) répondent.
4. Une mise à jour de la pile réussie sur l'essai, avec retour arrière essayé.

**Critère de sortie.** Les quatre livrables passent, la personne responsable (2bis.9) a signé le runbook, et la réponse **écrite** à la question 7 de l'étape 0.1 est rangée (réponse verbale reçue le 2026-11-14 : le certificat du fournisseur suffit).

**Risques et parades.**
- *Panne ou mauvaise manipulation sans personne pour réparer* → 2bis.9, sondes, instantanés avant chaque changement.
- *Faille non corrigée* → mises à jour planifiées, pare-feu strict, rien d'exposé sauf 443.
- *Perte de données* → sauvegardes hors serveur et **restauration réellement testée**.
- *Aucun soutien contractuel du logiciel* (soutien par la communauté seulement) → personne d'exploitation compétente (2bis.9), version épinglée, essai de chaque mise à jour, ou contrat de soutien auprès d'un prestataire ; plan B.
- *Charge de travail trop lourde* → **plan B** : Supabase infonuagique en région canadienne, sans changement de code.

**Retour arrière.** Détruire la pile d'essai ; rien n'est en production à ce stade.

---

## Étape 3 — Contrat d'échange : l'API du côté 1 (dans le dépôt Sparklog)

**Objectif.** Offrir au côté 2 une porte d'entrée **unique, étroite, protégée**, sans aucun nom.

> Cette étape se fait dans le dépôt **Sparklog**, pas ici. Elle ajoute des choses ; elle n'en retire aucune.

**3.1 Authentification du côté 2.**
- [ ] Table `sync_clients` (`id`, `label`, `secret_hash`, `created_at`, `revoked_at`, `last_used_at`) : le secret n'est jamais stocké en clair (condensat `argon2` ou `sha-256` + sel). Un seul client actif : « gestion ».
- [ ] Fonction Edge `pointage_api` (`verify_jwt = false` car elle valide sa propre clé) : vérifie `Authorization: Bearer <secret>` contre `sync_clients`, limite de débit (60 appels/min), écrit une ligne d'audit par appel (client, route, nombre de lignes, durée).
- [ ] **Rotation** : deux secrets valides en même temps pendant la rotation ; procédure écrite (étape 14.2).

**3.2 Routes (toutes en HTTPS, JSON) :**

| Route | Sens | Effet | Idempotence |
|-------|------|-------|-------------|
| `GET /jobs/changed?after=<updated_at>,<id>&limit=500` | lecture | Fiches modifiées après le curseur, ordre `(updated_at, id)` | naturelle |
| `GET /jobs/ids?from=<date>&to=<date>` | lecture | Liste des identifiants et versions d'une période (sert à détecter les trous) | naturelle |
| `GET /employees/changed?after=…` | lecture | Profils minimaux (numéro, rôle, pause, options de temps) | naturelle |
| `GET /evidence/changed?after=…` | lecture | Preuves de temps supp., repas, stationnement : **indicateurs seulement** (existe / chemin opaque), jamais le contenu des photos | naturelle |
| `POST /actions` | écriture | Une action de la boîte d'envoi (voir 3.4) | `action_key` unique |
| `GET /health` | lecture | Version du contrat, version du moteur, heure du serveur | naturelle |

**3.3 Forme exacte d'une fiche (contrat v1).** Les noms de champs sont **[À CONFIRMER contre `\d jobs`]** avant de figer le contrat :

```json
{
  "id": "uuid",
  "employee_number": 1042,
  "job_date": "2026-11-12",
  "depart": "06:30", "fin": "15:00",
  "started_at": "2026-11-12T11:30:00Z", "ended_at": "2026-11-12T20:00:00Z",
  "depart_fold": 0, "fin_fold": 0,
  "km_aller": 0, "km_retour": 0, "km_total": 0,
  "return_time_minutes": 0,
  "ot": "texte libre sans nom",
  "status": "submitted",
  "submission_key": "uuid",
  "overtime_evidence_captured": true,
  "meal_claim": {"state": "none|requested|approved"},
  "updated_at": "2026-11-12T21:03:44.120Z",
  "approved_at": null
}
```

Règles du contrat :
- `employee_number` remplace `user_id` : **le côté 1 expose le numéro, jamais l'UUID de compte** (l'UUID relierait à `auth.users`).
- Le champ `ot` est du texte libre : le côté 2 ne le traite pas comme sûr (voir 3.5).
- Le contrat porte un `contract_version` ; le côté 2 refuse une version inconnue plutôt que de deviner.
- Les curseurs sont **opaques** pour le côté 2 (il les renvoie tels quels).

**3.4 Actions (`POST /actions`).** Chaque action : `{ "action_key": "uuid", "type": "...", "payload": {…}, "expected_version": "<updated_at>" }`.
- `approve_jobs` — approuve une liste de fiches (même contrôle serveur que `push_approved_batch` aujourd'hui : claim atomique, résultat typé par fiche).
- `return_job` — retourne une fiche pour correction avec `reason` (≤ 500 caractères, voir 3.5) ; même logique que `return_job_for_correction`.
- `return_foreman_note_sheet` — idem pour les fiches de contremaître (0140).
- `set_pause` — mettre en pause / réactiver un numéro.
- `create_account` — créer le compte « numéro » côté 1, sans nom, avec un code d'activation (étape 9.4).
- `reissue_activation_code` — nouveau code d'activation pour un numéro (étape 9.4).
- `unlock_day` — rouvrir une journée pour un numéro ou pour tous (reprend `UnlockDayManager`).
- Table `sync_actions` (`action_key` **unique**, `type`, `result`, `created_at`) : un rejeu renvoie le **résultat enregistré**, sans refaire l'action.
- `expected_version` : si la fiche a changé depuis, la réponse est `conflict` avec la version actuelle (ceci règle aussi le point ouvert **S-4** de Sparklog).

**3.5 Texte libre et noms.** Le côté 1 ne peut pas savoir qu'un texte contient un nom. Parades :
- côté 2, **avant l'envoi** : le champ `reason` passe par un filtre qui bloque les noms et courriels connus du côté 2 (liste générée depuis `people`) ;
- côté 1 : avertissement affiché à l'employé sous les champs libres (« n'écrivez pas de nom »).

**3.6 Journalisation minimale (idée 2).**
- Les lignes d'audit de l'API (3.1) contiennent : client, route, nombre de lignes, durée, code de résultat. **Pas** d'IP complète (au besoin, un préfixe tronqué), **pas** d'empreinte d'appareil, **pas** de nom, courriel, numéro RH ni jeton.
- Les champs `metadata` (JSON) de tous les journaux passent par une liste de clés **permises** ; toute autre clé est rejetée par un trigger.
- **À vérifier avant de promettre :** ce que l'hébergeur garde lui-même (journaux d'authentification, d'API et de base : IP, appareils, durée de conservation) et ce qui peut être réduit ; le noter dans `OFFICIEL.md`.

**Livrable testable (dans Employés).** Tests Vitest qui lisent le SQL (même style que `manager-entry.test.js`) : la route n'expose aucun champ de la liste interdite ; un rejeu d'`approve_jobs` renvoie le même résultat ; une version périmée renvoie `conflict` ; un secret révoqué renvoie 401.

**Critère de sortie.** Une requête `curl` avec le secret renvoie des fiches pour un numéro de test ; sans secret ou avec un secret révoqué, 401 ; l'audit montre chaque appel.

**Retour arrière.** Révoquer `sync_clients`, retirer la fonction Edge. Aucune donnée existante n'est touchée.

---

## Étape 4 — Synchronisation en lecture (le côté 2 lit le côté 1)

**Objectif.** Un miroir des fiches du côté 1 dans la base du côté 2, à jour en quelques minutes, sans doublon, sans trou.

**4.0 Démarrage par CSV (idée 3).** Avant toute lecture automatique :
1. Le côté 1 offre un **export CSV des fiches approuvées** (`employee_number, job_date, depart, fin, km_aller, km_retour, km_total, return_time_minutes, ot, status, job_id, updated_at`), protégé contre les formules (`=`, `+`, `-`, `@`), téléchargé par un gestionnaire.
2. Le côté 2 importe ce fichier avec **la même logique** que la lecture automatique (upsert conditionnel sur `job_id` et `updated_at`, rapport de l'import : lignes reçues / changées / ignorées / rejetées).
3. Le fichier est **supprimé** après l'import ; aucun CSV n'est conservé dans un dépôt, un courriel ou un dossier partagé.
4. Quand l'import manuel est fiable (deux semaines sans écart), **brancher** la lecture automatique (4.1 à 4.4) sur le même code d'import. Le CSV reste le plan de secours.
Livrable : un CSV de test importé deux fois = aucun doublon ; une ligne invalide est rejetée avec son motif, sans arrêter le reste.

**4.1 Tâche planifiée.** Fonction `sync_jobs` (Edge Function planifiée, toutes les **10 minutes**, plus un passage complet **chaque nuit**) :
1. lire `sync_state.cursor` (début : `null`) ;
2. appeler `GET /jobs/changed?after=<curseur>&limit=500` ;
3. dans **une transaction** : `upsert` dans `jobs_mirror` sur `id`, mais **seulement si** `updated_at` reçu > `updated_at` stocké ;
4. avancer le curseur à la dernière ligne reçue, **dans la même transaction** ;
5. répéter jusqu'à une page vide (plafond de 20 pages par passage) ;
6. écrire une ligne dans `sync_runs` (début, fin, lignes reçues, lignes changées, curseur final, erreur éventuelle).

**4.2 Table `jobs_mirror`.** Même colonnes que le contrat (3.3) + `received_at`, `raw_hash`. Clé primaire : `id`. Index : `(employee_number, job_date)`, `(status, job_date)`, `(updated_at, id)`.

**4.3 Pièges à traiter explicitement :**
- **Fenêtre de chevauchement** : relire à partir de `curseur − 5 minutes` pour couvrir les écritures validées en retard (deux fiches de même `updated_at`, transactions longues). L'upsert conditionnel rend la relecture sans danger.
- **Trous** : chaque nuit, comparer `GET /jobs/ids` sur les 45 derniers jours à `jobs_mirror` ; toute fiche manquante ou de version différente est relue. Écrire l'écart dans `sync_runs.gap_count`.
- **Fiche supprimée côté 1** : le contrat expose `deleted_at` (suppression logique) ; ne jamais perdre silencieusement une fiche du miroir.
- **Panne** : si le passage échoue, le curseur n'avance pas ; le passage suivant reprend. Alerte (courriel à la propriétaire, sans donnée personnelle) si aucun passage réussi depuis **60 minutes**.
- **Horloge** : ne jamais comparer l'heure du côté 2 à celle du côté 1 ; seul `updated_at` du côté 1 compte.
- **Rattrapage initial** (*backfill*) : premier passage avec curseur `null`, par blocs, pendant une plage creuse ; mesurer la durée sur la production réelle avant de promettre quoi que ce soit.

**4.4 Écran de santé.** Page « Synchronisation » (propriétaire) : dernier passage, retard en minutes, nombre de fiches, écarts, erreurs. Bouton « Relancer maintenant » (idempotent).

**Livrable testable.** Tests Vitest avec un faux côté 1 : (a) la même page reçue deux fois = aucun changement ; (b) un passage interrompu au milieu reprend sans trou ; (c) une fiche modifiée est remplacée, une fiche plus ancienne n'écrase pas une plus récente ; (d) un `contract_version` inconnu arrête la synchronisation avec une erreur claire.

**Critère de sortie.** Sur la production : après un backfill complet, `count(*)` et somme des minutes par semaine du miroir = celles du côté 1 (comparaison par agrégats, sans afficher de ligne).

**Retour arrière.** Désactiver la tâche planifiée ; le miroir est jetable (reconstruit par un nouveau backfill).

---

## Étape 5 — Numérotation et table numéro ↔ personne

**Objectif.** Chaque employé actuel reçoit un numéro, et seul le côté 2 sait qui est qui.

**Tâches précises :**
- [ ] **5.1** (Sparklog) Migration : `profiles.employee_number integer unique` **nullable** au départ (pas de rupture). Index unique partiel.
- [ ] **5.2** (côté 2) Script `scripts/assign-numbers.js` exécuté **par la propriétaire sur son poste**, jamais committé avec ses résultats : lit la liste des profils (via le côté 1, hors dépôt), attribue des numéros **aléatoires non séquentiels de 4 chiffres** (pas d'ordre d'embauche, pas de date), écrit `people` dans la base du côté 2, puis écrit `profiles.employee_number` dans le côté 1 par une action `set_employee_number` (étape 9).
- [ ] **5.3** Contrôle : aucun numéro en double ; tous les profils actifs ont un numéro ; les 5 anciens employés « …@…invalid » aussi.
- [ ] **5.4** Décision sur les nouveaux employés : le numéro est attribué **dans le côté 2** à la création de la personne (étape 9.4).
- [ ] **5.5** Le contrat de l'étape 3 expose maintenant le vrai `employee_number` (avant : `null` toléré).
- [ ] **5.6** Document interne (hors dépôt) : où est la sauvegarde de la table numéro ↔ personne, qui y a accès, comment elle est chiffrée.

- [ ] **5.7** Le numéro d'employé **n'est jamais** un secret ni un mot de passe : il identifie, il n'authentifie pas. Il ne sert qu'avec un code d'activation (9.4) puis un mot de passe choisi par l'employé (ou plus tard une passkey, 10.1).

**Livrable testable.** Test : la fonction qui crée une personne attribue un numéro unique et refuse d'en réutiliser un ; une requête sur le côté 1 ne montre que des numéros.

**Critère de sortie.** 100 % des profils actifs ont un numéro des deux côtés ; le miroir associe chaque fiche à une ligne de `people`.

**Retour arrière.** Remettre `profiles.employee_number` à `null` ; la colonne est ajoutive.

---

## Étape 6 — Moteur de paie du côté 2 et parité

**Objectif.** Le côté 2 calcule heures, avantages, retenues et talons exactement comme Sparklog aujourd'hui.

**Décision D3 (à fermer au début de l'étape) :**
- **Option A (recommandée par OFFICIEL.md)** : le côté 2 appelle `classify_week` du côté 1 pour le **classement des heures** et calcule les **montants** lui-même. Une seule source pour les règles d'heures.
- **Option B** : copie versionnée de `payroll_engine.js` avec les mêmes fixtures. Plus autonome (marche si le côté 1 est tombé), plus risquée (divergence).

Ce plan suppose l'**option B pour les montants** (qui n'ont jamais été dans le côté 1 après l'étape 10) et l'**option A ou B pour les heures**, selon D3.

**Tâches précises :**
- [ ] **6.1** Copier dans `src/payroll/` les modules de montants : `ccq-benefits.js`, `earnings.js`, `employee-week.js`, `ytd.js`, `money.js`, `employer/`, `statutory/`, `rules/` (barèmes), `payroll-rates` — **avec leurs tests**.
- [ ] **6.2** Copier le moteur d'heures `supabase/functions/_shared/payroll_engine.js` (version actuelle **2.10.0**) et ses fixtures de parité. Ajouter un test qui **échoue si les numéros de version diffèrent** entre le côté 1 et le côté 2.
- [ ] **6.3** Remplacer `user_id` par `employee_number` dans les entrées du moteur ; les profils viennent de `people` + options de paie du côté 2.
- [ ] **6.4** Fixtures de parité : exporter depuis Sparklog (hors dépôt, agrégats anonymes) les semaines **42 à 46** (couvrant semaine avec temps supp., repas, stationnement, chef d'équipe, contremaître, 4×10 h, férié, samedi / dimanche, minuit, changement d'heure). Comparer **au centime** : heures régulières, 1,5×, 2×, souper, retour, avantages CCQ, retenues, net.
- [ ] **6.5** Les sources de taux (`payroll_rates`, `statutory_rate_sets`, `ccq_rate_snapshots`, `travel_pay_rules`, `conges_indemnity_rate`) deviennent des tables du côté 2 (migration), avec leurs RPC d'écriture (`is_privileged()`) et leur audit.
- [ ] **6.6** Reproduire les règles « règle non signée par un spécialiste (ADR 0001) » : `RULE_VERSION.status` reste `draft` / `requires_review` ; la signature du spécialiste (§6.1 C de Sparklog) reste un prérequis de la paie finale, **indépendant** de cette migration.

**Livrable testable.** `npm test` du côté 2 : tous les tests copiés passent ; le test de parité compare, pour chaque semaine de référence, le résultat du côté 2 à la valeur de référence figée (JSON de fixtures sans nom).

**Critère de sortie.** 0 écart (0,00 $) sur les semaines 42 à 46 ; test de version actif.

**Retour arrière.** Rien n'est encore utilisé en production : le côté 2 calcule en parallèle, l'ancien chemin reste la paie officielle.

---

## Étape 7 — Migration des données de paie vers le côté 2

**Objectif.** Copier les tables de gestion vers le côté 2 sans rien retirer du côté 1.

**Inventaire (d'après OFFICIEL.md 5.3 ; confirmer par `list_tables`) :**

| Table du côté 1 | Destination côté 2 | Remarque |
|-----------------|--------------------|----------|
| `profiles` (partie identité, CCQ, syndicat, taux, options de paie) | `people` + `person_pay_options` | Couper en deux : options qui changent le **temps** restent côté 1 (étape 10) |
| `employee_sensitive` (NAS, coffre) | `people_sensitive` | Voir 7.3 : les secrets du coffre ne se copient pas tels quels |
| `employee_tax_profiles` | idem | TD1 / TP-1015.3 |
| `payroll_period_ledger`, `payroll_ytd`, `employer_contributions`, `roe_history` | idem | Cumuls : vérifier par totaux |
| `payroll_rates`, `statutory_rate_sets`, `ccq_rate_snapshots`, `travel_pay_rules`, `conges_indemnity_rate`, `payroll_employer_settings` | idem | Étape 6.5 |
| `employee_forms`, `employee_form_access`, `profile_references`, cartes CCQ (bucket) | idem | Décision D7 sur la carte CCQ et la date de naissance |
| `employee_time_off` | idem | **Décidé : gestion** (2026-11-14) |
| `messages`, `message_recipients`, `manager_broadcasts`, `broadcast_recipients`, `broadcast_revisions` | idem | Annonces (courriels) |
| `accident_log`, `accident_files` (bucket) | idem | Noms, CNESST |
| `employee_groups`, `employee_group_members` | **Reste au côté 1, par numéro** (décidé 2026-11-14) | Le côté 2 les gère par une action de l'API et s'en sert pour cibler les annonces |

**Tâches précises :**
- [ ] **7.1** Gel de lecture de 2 h (nuit) ; instantané du côté 1 (sauvegarde nommée).
- [ ] **7.2** Scripts `scripts/migrate/NN-<table>.sql|js`, **un par table**, exécutés dans l'ordre des clés étrangères, chacun **idempotent** (`insert … on conflict do nothing` / `update` conditionnel) et journalisé dans `migration_runs`.
- [ ] **7.3** **NAS** : les secrets du coffre (Vault) ne sont pas portables entre projets. Marche à suivre : procédure du propriétaire seul (`reveal_nas` → `set_nas` dans le côté 2), chaque lecture auditée, **jamais** écrite dans un fichier, un journal ou le dépôt ; contrôle du chiffre de Luhn à la réécriture. Alternative : ressaisie par l'employé dans le formulaire.
- [ ] **7.4** **Photos** (cartes CCQ, accidents) : copie d'objet à objet entre buckets, sans passer par un disque partagé ; hachage avant / après.
- [ ] **7.5** Contrôles **par agrégats seulement** : nombre de lignes par table, somme des montants des cumuls par employé (comparée par numéro, sans afficher les noms), nombre d'objets et taille des buckets.
- [ ] **7.6** Rejouer l'étape 6.4 **sur les données migrées** : le talon d'une semaine de référence calculé depuis le côté 2 = celui de l'ancien chemin.

**Livrable testable.** Rapport `migration_report` (agrégats uniquement) : 0 écart sur toutes les tables ; test de parité de paie vert sur les données migrées.

**Critère de sortie.** Les deux côtés contiennent les mêmes données ; l'ancien chemin reste la paie officielle jusqu'à l'étape 13.

**Retour arrière.** Vider les tables du côté 2 et relancer (scripts idempotents). Le côté 1 n'a pas bougé.

---

## Étape 8 — Écrans de gestion du côté 2 (avec noms)

**Objectif.** Que la propriétaire et les gestionnaires fassent leur travail de gestion **depuis le côté 2**, avec les noms.

**Écrans à déplacer (liste tirée du code actuel ; chacun avec ses tests) :**

| Groupe | Écrans |
|--------|--------|
| Équipe | Employés (fiche guidée, onglets, Impôts, CCQ, accidents), Registre d'accidents, Notes, Annonces, Formulaires |
| Paie | Paie de la semaine (`PayrollWeek`), Calcul, Talons, DAS, Relevé d'emploi, Export CCQ (JSON mensuel), Rapports, Coûts, Cumuls |
| Configuration | Taux et barèmes, Trajets et frais, Règles de paie (fiche de référence), Paramètres de paie, Minimums d'inventaire (si les groupes passent côté 2) |
| Révision | **À traiter / approbation des fiches** (écran clé) |

**Tâches précises :**
- [ ] **8.1** Pour chaque écran : copier le composant, remplacer chaque lecture `supabase.from("…")` sur une table déplacée par la lecture du côté 2 ; les **fiches** viennent de `jobs_mirror` (jointure avec `people` par numéro, **dans le côté 2**).
- [ ] **8.2** Écran **« À traiter »** du côté 2 : fiches `submitted` du miroir, noms, anomalies (`detectJobAnomalies`), bouton « J'ai vu », approbation par jour / par semaine. **Pour l'instant, l'approbation fait l'appel de l'étape 9** ; avant l'étape 9, l'écran est en lecture seule.
- [ ] **8.3** Navigation : menu du côté 2 sur le modèle de `manager-nav.js` ; chaque entrée garde sa règle d'accès (gestionnaire, propriétaire seul pour les écritures de taux).
- [ ] **8.4** Retirer les écrans **uniquement** quand leur équivalent est vérifié (étape 13). Ici on **ajoute**.
- [ ] **8.5** Test d'accessibilité et de contraste repris de `theme-contrast.test.js`.
- [ ] **8.6** Budgets de requêtes (leçon « Database load regression ») : chaque écran déclare son plafond de lignes ; pagination par clé.

**Livrable testable.** Pour chaque écran déplacé : un test d'écran + une comparaison de ses chiffres (mêmes totaux que l'écran du côté 1 pour une semaine de référence).

**Critère de sortie.** La propriétaire peut, depuis le côté 2 seul, préparer la paie d'une semaine jusqu'au talon (en lecture seule pour les approbations).

**Retour arrière.** Les écrans du côté 1 existent toujours ; on retourne simplement les utiliser.

---

## Étape 9 — Actions du côté 2 vers le côté 1

**Objectif.** Les décisions prises dans le côté 2 (approuver, retourner, comptes) arrivent côté 1 **une seule fois**, même si le réseau flanche.

**9.1 Boîte d'envoi (côté 2).** Table `outbox` : `action_key uuid unique`, `type`, `payload`, `expected_version`, `state` (`pending` / `sent` / `done` / `conflict` / `failed`), `attempts`, `next_try_at`, `result`, `created_by`, `created_at`.
- Le clic d'un gestionnaire **écrit dans `outbox` dans la même transaction** que son changement local (patron *transactional outbox*), puis un envoyeur la vide.
- Reprise : l'envoyeur réessaie avec délais croissants (30 s, 2 min, 10 min, 1 h) jusqu'à 10 essais ; au-delà, `failed` + alerte.
- **Perte de la réponse après validation** : le rejeu avec la même `action_key` renvoie le résultat enregistré côté 1 (étape 3.4) ; on ne refait jamais l'effet.

**9.2 Approuver.** L'écran « À traiter » écrit `approve_jobs` avec les fiches et leurs `expected_version`. Réponse typée **par fiche** (comme `push_approved_batch`) : `approved`, `already_approved`, `conflict`, `not_found`. Une fiche en conflit reste affichée avec le message « modifiée depuis, à revoir ».
- **Export vers l'ancienne feuille Google** : selon D5 ; tant qu'il existe, il part du côté 2 (étape 12.4).

**9.3 Retourner.** `return_job` / `return_foreman_note_sheet` avec la raison filtrée (étape 3.5). L'employé voit la fiche retournée dans le côté 1 (par numéro) ; la raison est visible des autres gestionnaires dans le côté 2 (pas de nom dans le texte).

**9.4 Comptes et codes d'activation (idée 1).**
- `create_account` : le côté 2 crée la personne (`people`) et attribue le numéro (5.2). Il appelle le côté 1, qui crée le compte « numéro » avec une adresse factice `<numéro>@pointage.invalid` **sans mot de passe utilisable**, et génère un **code d'activation**.
- **Code d'activation :** aléatoire (au moins 10 caractères, sans caractères ambigus), généré côté 1 ; seul son **condensat** (`argon2` ou équivalent) est stocké, avec `expires_at` (72 h), `used_at`, `attempts`. **Usage unique** ; après 5 essais ratés, le code est bloqué ; blocage par numéro et par appareil (limite de débit).
- Le code clair est affiché **une seule fois** au gestionnaire (côté 2), qui le remet à l'employé **hors système** (en personne ou par un canal déjà utilisé par l'entreprise). Le côté 1 ne l'envoie à personne et ne le journalise pas.
- **Activation :** l'employé entre son numéro et le code ; il **choisit son mot de passe** (règles du projet : minuscule, majuscule, chiffre, symbole, mot de passe divulgué refusé) ; le code est consommé ; une ligne d'audit « compte activé » (par numéro).
- `reissue_activation_code` (ex-`reset_pin`) : même chemin, l'ancien code et l'ancien mot de passe sont invalidés ; **aucun** « mot de passe oublié » par courriel.
- `set_pause` : met un numéro en pause (comportement actuel de `is_paused`) ; les sessions ouvertes sont révoquées.
Livrable : tests de rejeu (un code ne marche qu'une fois), d'expiration, de blocage après essais, et de non-journalisation du code clair.

**9.5 Journal.** Chaque action écrit une ligne d'audit **dans les deux côtés** (côté 1 : numéro et type ; côté 2 : personne, numéro, type, résultat).

**Livrable testable.** Tests : (a) l'envoyeur rejoue après un échec réseau simulé → un seul effet côté 1 ; (b) réponse perdue après succès → rejeu = même résultat ; (c) conflit de version → fiche non approuvée, message clair ; (d) deux gestionnaires approuvent la même fiche → un seul `approved`, l'autre `already_approved` ; (e) `reason` contenant le nom d'un employé est refusée.

**Critère de sortie.** Un gestionnaire approuve une journée depuis le côté 2 ; la fiche est `approved` côté 1 ; l'export part ; un second clic ne change rien.

**Retour arrière.** Désactiver l'envoyeur ; les gestionnaires reprennent l'approbation dans le côté 1 (qui existe encore).

---

## Étape 10 — Côté 1 sans noms

**Objectif.** Rendre vrai l'invariant I1 : plus aucun nom, courriel, téléphone ni montant côté 1.

> Étape dans le dépôt **Sparklog**. C'est la plus risquée : elle retire des données. Elle ne commence qu'après un **instantané vérifié** et après que les étapes 8 et 9 ont tourné **au moins deux semaines** en production sans écart.

**10.1 Connexion (idée 4).** Identifiant = numéro + mot de passe choisi à l'activation (9.4) ; adresses factices dans `auth.users` ; écran `Login.jsx` demande « numéro d'employé » ; `ResetPassword.jsx` remplacé par « demandez un nouveau NIP à la gestion ». Gestionnaires : numéro + mot de passe + TOTP (`MfaGate` inchangé). **Couche d'authentification séparée :** un module `src/lib/auth-adapter.js` est le **seul** endroit qui parle au fournisseur d'authentification (connexion, session, déconnexion, activation) ; les écrans n'appellent plus `supabase.auth` directement. Ainsi, une passkey (WebAuthn) pourra être ajoutée **plus tard** comme méthode de plus sans toucher au pointage. Prérequis avant de l'envisager : vérifier l'état de son support chez l'hébergeur, prévoir la perte ou le changement de téléphone, et un chemin de repli par code d'activation.

**10.2 Colonnes à retirer ou vider** (liste de départ, à confirmer par inventaire) : `profiles.full_name`, `email`, `phone`, `birth_date`, taux horaires, options de **paie** ; `push_subscriptions.user_agent`.
  Les options qui changent **le temps** (`first_trip_unpaid`, `ten_hour_days`, `km_apart_from_capture`, `team_leader_*`, `overtime_first_hour_double`) **restent**.
  Méthode : (1) ajouter les valeurs de remplacement ; (2) cesser d'écrire les colonnes ; (3) cesser de les lire (écrans) ; (4) **vider** les valeurs ; (5) **supprimer** les colonnes dans une migration séparée, plus tard.

**10.3 Journaux.** `audit_log`, `employee_activity_log`, `manager_notifications` : réécrire acteur et cible **par numéro** (migration de données + triggers modifiés) ; les nouveaux triggers n'écrivent plus de nom.

**10.4 Textes nominatifs.** `foreman_reports.audited_name` → numéro de l'employé audité (liste déroulante de numéros) ; `manager_notes` : **déplacées au côté 2** (décidé 2026-11-14), plus de filtre de noms côté 1.

**10.5 Écrans du côté 1.** `ManagerDashboard`, `TodoInbox`, `WeekSnapshot`, `JobCard`, `History` en mode gestionnaire : affichent « Employé 1042 ». **Les écrans de gestion du côté 1 sont retirés** quand leur équivalent est dans le côté 2 (étape 13) ; d'ici là ils affichent des numéros.
  Employés : leur propre nom n'est plus affiché ; l'écran affiche leur numéro.

**10.6 Point de non-retour.** Après 10.2 (5), le retour à l'état précédent demande la restauration d'une sauvegarde. **Avant** : instantané vérifié ; restauration répétée **sur une copie** ; accord écrit de la propriétaire.

**10.7 Contrôle d'interdit (livrable central).** Script `scripts/forbidden-scan.sql` exécuté sur la base du côté 1 :
- aucune colonne texte ne contient un `@`, sauf les adresses factices `@pointage.invalid` ;
- aucune colonne texte ne contient 9 chiffres de NAS valides (Luhn) ;
- aucune colonne ne porte un nom de personne présent dans `people` (comparaison faite côté 2 avec une liste de noms exportée à usage unique, **supprimée après**) ;
- aucune table de paie ou de taux ;
- `auth.users` : uniquement des adresses factices.

**10.8 Journaux sans données inutiles (idée 2).** Réécrire les triggers d'audit pour n'enregistrer que les clés permises (3.6) ; purger les IP et empreintes déjà présentes dans les journaux copiés ; fixer une durée de conservation des journaux (D6).

**10.9 Corrections sans écrasement (idée 5).** Une fiche déjà soumise, approuvée ou exportée ne se réécrit jamais en place : toute modification (par l'employé après un retour, ou par un gestionnaire) crée une **ligne d'historique** (ancienne valeur, nouvelle valeur, auteur par numéro, motif standardisé, heure du serveur) que le navigateur ne peut ni modifier ni supprimer. **Test :** modifier une fiche approuvée par une requête directe échoue ; une correction légitime laisse la valeur d'origine retrouvable. À vérifier d'abord ce que `audit_log` et `return_job_for_correction` couvrent déjà, et ne combler que l'écart.

**Critère de sortie.** Le scan renvoie 0 ligne ; les tests d'écran affichent des numéros ; la connexion par numéro fonctionne pour employés et gestionnaires ; l'employé retrouve ses fiches.

**Retour arrière.** Restauration de l'instantané (voir 10.6). C'est pourquoi on vide d'abord, on supprime ensuite.

---

## Étape 11 — Mise en service du côté 1 sur l'infrastructure québécoise (2bis)

**Objectif.** Les fiches de temps (côté 1) sont hébergées au Québec (exigence C-hébergement, OFFICIEL 6.2).

**Tâches précises :**
- [ ] **11.1** Utiliser la **pile de production** préparée à l'étape 2bis (Supabase auto-hébergé, Québec) ; mêmes migrations rejouées dans l'ordre ; extensions identiques ; secrets des fonctions recréés ; **rien ne se met en production avant que les critères de sortie de 2bis soient atteints**.
- [ ] **11.2** Copie des données (fiches, preuves, inventaire) par agrégats vérifiés ; copie des **objets** de stockage (preuves de temps supp., reçus, captures d'inventaire) ; recalcul des chemins si nécessaire.
- [ ] **11.3** Jetons d'accès : les comptes factices se recréent avec un code d'activation (9.4) **ou** la table `auth.users` est migrée avec ses condensats (selon la capacité de l'hébergeur ; vérifier avant de promettre).
- [ ] **11.4** Variables d'environnement du front (`VITE_SUPABASE_URL`, clé publique) changent à la bascule ; la PWA se met à jour (`UpdateBanner`) ; les anciens abonnements push sont recréés.
- [ ] **11.5** Le côté 2 change l'URL de l'API du côté 1 **à un seul endroit** (`SYNC_BASE_URL`) et le secret est roté.
- [ ] **11.6** Fenêtre de bascule un **dimanche** (aucune saisie), annonce aux employés 48 h avant ; la période de nuit change d'heure ne doit pas tomber dans la fenêtre.
- [ ] **11.7** L'ancien projet est conservé **en lecture seule 30 jours**, puis supprimé (avec un certificat de suppression ou une confirmation de l'hébergeur).
- [ ] **11.8** Mettre à jour `OFFICIEL.md` (section 3.1 : région, hébergeur) et la politique de confidentialité.

**Livrable testable.** Même suite de tests de parité sur la nouvelle base ; un employé de test pointe et soumet une fiche ; le côté 2 la lit.

**Critère de sortie.** 48 h sans erreur de synchronisation ; l'ancien projet n'est plus appelé (journal de l'ancien projet : 0 requête).

**Retour arrière.** Avant 11.7 : repointer le front et `SYNC_BASE_URL` vers l'ancien projet (gardé à jour jusqu'à la bascule, puis figé).

---

## Étape 12 — Services externes

**Objectif.** Sortir les renseignements personnels de services qui ne conviennent pas (OFFICIEL 6.4).

- [ ] **12.1** **Courriels** (annonces) : l'envoi part du côté 2 (il connaît les adresses) ; fournisseur au Canada, avec entente ; les courriels n'embarquent jamais de fiche de temps.
- [ ] **12.2** **Notifications push** : abonnement lié au **numéro** côté 1 ; le contenu n'a pas de nom (« Une de vos fiches a été retournée »). Retrait de `user_agent`.
- [ ] **12.3** **OCR des captures** (OCR.space aujourd'hui, depuis le navigateur) : remplacer par un service au Canada ou un traitement local ; tant que ce n'est pas fait, avertir l'employé et ne jamais envoyer de capture contenant un nom.
- [ ] **12.4** **Export Google Sheet** (décision D5) : retiré ou reproduit côté 2. Si conservé : le côté 2 appelle le `doPost` avec les **noms** (c'est un outil de gestion) ; le côté 1 ne parle plus à Google.
- [ ] **12.5** **CCQ** (export JSON mensuel) : généré côté 2 (il connaît les NAS) ; le côté 1 ne contient aucun NAS.
- [ ] **12.6** Mettre à jour la liste des sous-traitants dans la politique de confidentialité et dans l'évaluation (ÉFVP).

**Livrable testable.** Test réseau : la liste des hôtes appelés par le côté 1 en production ne contient plus ni OCR.space ni Google ni service de courriel ; le côté 2 liste les siens, tous documentés.

**Critère de sortie.** Chaque fournisseur est dans le registre avec : données reçues, pays, entente, certification.

**Retour arrière.** Réactiver le service précédent tant qu'il n'est pas retiré (12.3, 12.4).

---

## Étape 13 — Période parallèle, bascule finale, retrait de l'ancien chemin

**Objectif.** Passer à la nouvelle façon de faire sans casser la paie, puis retirer l'ancienne.

**13.1 Période parallèle : 2 semaines de paie complètes.**
- [ ] Chaque semaine : calculer la paie **aux deux endroits** (ancien chemin = officiel ; côté 2 = vérification).
- [ ] Comparer au centime : heures, avantages, retenues, net, cumuls. **Tout écart = on corrige avant de continuer**, la semaine ne compte pas.
- [ ] Au moins **un vrai talon** par type (apprenti, temps supp., repas / stationnement, chef d'équipe, contremaître) comparé à un calcul externe (WebRAS / PDOC) — rejoint le point ouvert « 3 à 5 vrais talons » de Sparklog §6.1 C.

**13.2 Bascule.** La semaine suivante, le côté 2 devient la **paie officielle**. Sparklog (côté 1) ne calcule plus de montants.

**13.3 Retrait de l'ancien chemin.** Dans Sparklog : retirer les écrans de gestion et de paie, les tables de paie, les fonctions (`push_approved_batch` côté montants, `classify_week` selon D3), les droits RLS correspondants, les tests devenus sans objet. **Une PR par groupe d'écrans**, version incrémentée à chaque fois, documentation mise à jour.

**13.4 Nettoyage.** Retirer `profiles.return_overtime_no_benefits` et les autres colonnes mortes ; revue de toutes les fonctions Edge (point « Ménage des fonctions Edge » de Sparklog §6.3).

**Livrable testable.** Rapport de 2 semaines : 0 écart ; liste des tables de Sparklog = liste attendue du côté 1 ; `forbidden-scan` toujours à 0.

**Critère de sortie.** La paie d'au moins une semaine complète est sortie **uniquement** du côté 2 et approuvée par la propriétaire ou le comptable.

**Retour arrière.** Pendant 13.1 et jusqu'à 13.3 : revenir à l'ancien chemin (il existe encore). Après 13.3 : restauration depuis l'instantané conservé (30 jours).

---

## Étape 14 — Exploitation et maintien

- [ ] **14.1** **Surveillance** : alerte si aucune synchronisation réussie depuis 60 min, si la boîte d'envoi a des actions `failed`, si le taux d'erreur de l'API dépasse 2 % sur 15 min. Alertes **sans donnée personnelle**.
- [ ] **14.2** **Rotation des secrets** : le secret du lien côté 2 → côté 1 tous les **90 jours** et à chaque départ d'une personne qui y avait accès ; procédure à deux secrets valides en parallèle.
- [ ] **14.3** **Registre des incidents** (table de l'étape 2.6) : procédure de 72 h, modèle d'avis à la Commission d'accès à l'information et aux personnes touchées **[À VALIDER]** ; exercice annuel.
- [ ] **14.4** **Sauvegardes et restauration** : sauvegarde quotidienne des deux bases ; **test de restauration trimestriel** sur une copie, avec le temps mesuré.
- [ ] **14.5** **Revue des accès** (trimestrielle) : qui est gestionnaire, qui a le secret, qui accède à la table numéro ↔ personne.
- [ ] **14.6** **Destruction automatique** : preuves en photo (durée réglable déjà dans `overtime_settings`), fiches selon D6, anciens employés selon la durée décidée.
- [ ] **14.7** **Demandes d'accès / rectification** : export « Mes renseignements » (côté 2 assemble ce que les deux côtés ont sur un numéro) ; délai de réponse de 30 jours.
- [ ] **14.8** **Mise à jour annuelle** : barèmes (avant le 1er janvier), cotisation AECQ, taux MÉDIC, calendrier CCQ — comme aujourd'hui, mais dans le côté 2.
- [ ] **14.9** **Vérification de conformité** (P6) : repasser la matrice de traçabilité d'`OFFICIEL.md` (section 10) ; chaque exigence a un changement et une preuve.

---

## Annexe A — Ordre recommandé des PR (côté 2)

1. `V0.1.0` squelette + CI + test d'interdit (étape 1)
2. `V0.2.0` schéma `people`, auth manager + TOTP, audit (étape 2)
3. `V0.3.0` miroir + `sync_jobs` + écran de santé (étape 4, après l'étape 3 côté Sparklog)
4. `V0.4.0` numérotation (étape 5)
5. `V0.5.0` moteur et parité (étape 6)
6. `V0.6.0` scripts de migration (étape 7)
7. `V0.7.x` un écran de gestion par PR (étape 8)
8. `V0.8.0` boîte d'envoi + actions (étape 9)
9. `V1.0.0` bascule (étape 13)

## Annexe B — Ordre recommandé des PR (côté 1, dépôt Sparklog)

1. API d'échange (étape 3) — **ajout seulement**
2. `profiles.employee_number` (étape 5.1)
3. Connexion par numéro, adresses factices (10.1)
4. Journaux et textes par numéro (10.3, 10.4)
5. Écrans par numéro (10.5)
6. Vidage puis suppression des colonnes (10.2, 10.6)
7. Retrait de l'ancien chemin (13.3)
8. Nouveau projet au Québec (étape 11)

## Annexe C — Ce qui reste incertain (à ne pas tenir pour acquis)

- Si la séparation est **exigée** : réponse de l'étape 0.1. Sinon, l'étape 10 peut être réduite.
- Les **noms exacts des colonnes** du contrat (étape 3.3) : à confirmer contre la base.
- La **région canadienne** disponible chez l'hébergeur et la possibilité de **migrer `auth.users` avec les condensats** (étape 11.3).
- La façon de déplacer les **secrets du coffre** (NAS) entre projets (étape 7.3).
- (Tranché le 2026-11-14 : temps libre et notes de gestionnaires → côté 2 ; groupes / entrepôts → côté 1, par numéro, gérés par l'API.)
- **Exploitation propre (D4) :** la réponse « le certificat du fournisseur suffit » (question 7) est **verbale** : à obtenir **par écrit** ; la **disponibilité de `pg_cron`** dans la pile auto-hébergée ; les ressources réellement nécessaires (essai de charge). (Lu le 2026-11-14 dans la documentation de Supabase : pas de télémétrie en auto-hébergé, fonctions Edge et stockage S3 supportés, sauvegardes et restauration à un instant précis non fournies, soutien par la communauté.)
- Ce que l'**hébergeur garde dans ses propres journaux** (IP, appareils, durée) et ce qu'on peut en réduire (3.6).
- L'état du **support des passkeys** chez l'hébergeur (jugé expérimental dans une source externe, non vérifié ici).
- Si la **convention** accepte le numéro d'employé tel quel comme identifiant (hypothèse de ce plan) ou exige une couche d'identifiant technique de plus : question 2 de l'étape 0.1.
- La **charge réelle** : les durées sont des estimations, à revoir après l'étape 4 (mesure du backfill) et l'étape 6 (écarts de parité).

## Annexe D — Définition de « terminé » pour chaque étape

Une étape est terminée quand : (1) son livrable testable passe ; (2) son critère de sortie est constaté **sur la production** et non seulement en test ; (3) le retour arrière a été relu ; (4) la documentation du dépôt concerné (README, NOOB, CLAUDE, et `OFFICIEL.md` pour la conformité) est à jour ; (5) la version est incrémentée ; (6) la propriétaire a vu et accepté le résultat.
