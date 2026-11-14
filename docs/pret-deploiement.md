# Le côté 1 est-il prêt à déployer ? (état au V0.25.0)

**Réponse courte : prêt pour l'APERÇU DE TEST (`docs/mode-emploi-apercu.md`), pas pour la mise en service.** Le côté 1 seul ne peut pas remplacer Sparklog : l'approbation, les noms, la paie et les annonces sont au côté 2, qui n'est pas construit.

## Ce qui est prêt
- Schéma neuf (14 migrations) : tests SQL, mutations, fichier d'aperçu assemblé. Application ↔ schéma : **0 écart** (`scripts/check-app-against-schema.mjs`, app + fonctions Edge). 793 tests, lint, build.
- Connexion par numéro, activation par code, comptes à adresse factice, API d'échange pour le côté 2 (`pointage_api`), notification générique (`send_push`), destruction automatique des photos (`cleanup_overtime_evidence` + 0014), plus aucune donnée nominative lue (test), limites du côté 1 testées (`src/lib/side-boundaries.test.js`).
- Trouvé en préparant ce document : la boîte « À traiter » et le tableau de bord appelaient encore `push_approved_batch` (approbation, fonction qui n'existe pas au côté 1). **Boutons d'approbation retirés** (V0.25.0) ; garde-fou ajouté : le code du côté 1 n'appelle plus rien du côté 2.

## Ce qui n'a JAMAIS été vérifié
- Le schéma sur un **vrai Supabase** (essayé seulement sur un PostgreSQL local avec de faux schémas Supabase).
- Les **fonctions Edge déployées** (`pointage_api`, `activate_account`, `send_push`, `cleanup_overtime_evidence`), l'activation et la connexion **de bout en bout**, la double authentification du propriétaire.
- La tâche CI `schema` sur GitHub ; la page sur Canner ; les réglages d'authentification de l'instance.
→ **Étape suivante utile : suivre le mode d'emploi de l'aperçu** et noter ce qui casse.

## Bloquants avant la mise en service
**Côté 1 (code)**
- Réémettre un code d'activation ne ferme pas les sessions déjà ouvertes (téléphone perdu).
- Tâche planifiée du serveur qui appelle `cleanup_overtime_evidence` chaque jour (sans elle, aucune photo n'est supprimée).
- `payroll_treatment` et montants de repas / stationnement encore au côté 1 (décision différée).
- Réglage d'instance : inscription publique désactivée, mot de passe ≥ 12 sans règle de caractères, CORS / `ALLOWED_ORIGIN`, CSP en application.
- OCR.space gardé (hors Québec) : à inscrire à l'ÉFVP / politique / consentement, clé OCR.space côté serveur à vérifier (`docs/ocr-tesseract.md`).

**Côté 2 (Sparklog-Gestion) : non construit** : approbation (`approve_jobs`), lecture / synchronisation (`/jobs/changed`…), noms et correspondance numéro ↔ personne, paie et talons, annonces (publication + `send_push`), création des comptes (`register_account`), export, CSV de secours. Tant qu'il manque, le côté 1 ne remplace pas l'ancienne application.

**Infrastructure et conformité** (`PLAN.md` 2bis, `OFFICIEL.md`)
- Fournisseur du serveur choisi (grille `docs/grille-fournisseurs.md`), Supabase auto-hébergé installé, sécurisé, sauvegardé, surveillé ; **personne responsable de l'exploitation nommée**.
- Réponse **écrite** à la question 7 (certificat du fournisseur) ; questions 2 et 3 (numéro comme identifiant ; côté 2 au Québec ?) à l'AECQ / avocat ; responsable de la protection des renseignements ; ÉFVP ; consentement W-1 ; politique de confidentialité ; registre des incidents.
- **Reprise des données** de l'ancienne base (noms → numéros, fiches, preuves) et **plan de bascule** (`PLAN.md` étape 13) ; essai à blanc ; plan de retour arrière.

## Ordre conseillé
1. Aperçu de test (vous, 1 h) → correctifs.  2. Choix du serveur + responsable.  3. Côté 2 minimal (approuver, lire, créer les comptes).  4. Essai à blanc avec de vraies fiches anonymisées.  5. Conformité écrite.  6. Bascule.
