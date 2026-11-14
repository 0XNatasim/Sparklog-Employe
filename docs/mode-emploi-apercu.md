# Mode d'emploi — voir le côté 1 (aperçu de test)

But : **regarder et essayer** Sparklog-Employés (côté 1) sur un petit environnement de **test**, avec des **données inventées seulement**. Ce n'est **pas** la mise en service : le vrai serveur au Québec viendra plus tard (`PLAN.md`, étape 2bis).

> **Règle d'or : aucune vraie donnée.** Pas de vrai employé, pas de vrai numéro, pas de vraie photo. Un projet Supabase infonuagique n'est pas hébergé au Québec ; il sert ici uniquement à regarder l'application. Supprimez-le quand vous avez fini (étape 12).
> **N'utilisez pas votre projet Supabase actuel de Sparklog** : créez-en un **nouveau, vide**.

**Durée :** environ 1 h. **Il vous faut :** un compte Supabase (gratuit), votre compte Canner (déjà lié au dépôt), une application d'authentification sur votre téléphone (Google Authenticator, Microsoft Authenticator, Authy…), et un ordinateur avec **Node.js 20** pour 3 commandes (étape 6).

Ce qui est vérifié et ce qui ne l'est pas : les scripts SQL de ce dossier ont été **essayés sur un PostgreSQL local** ; les réglages de Supabase et de Canner ci-dessous viennent de mes lectures et de la documentation, **pas d'un essai sur vos comptes** : si un menu n'a pas exactement ce nom, cherchez le mot-clé, et dites-moi ce que vous voyez.

---

## Étape 1 — Créer le projet de test (Supabase)
1. Sur supabase.com : **New project**. Nom : `sparklog-employes-apercu`. Choisissez un mot de passe de base de données (rangez-le dans votre gestionnaire de mots de passe). Région : n'importe laquelle (c'est un test).
2. Attendez que le projet soit prêt (1 à 2 minutes).
3. Notez deux choses (menu **Project Settings › API**) : l'**adresse du projet** (`https://xxxx.supabase.co`) et la clé **anon / publique**. La clé **service_role** reste secrète : ne la copiez nulle part pour l'instant.

## Étape 2 — Installer le schéma (la base de données du côté 1)
1. Menu **SQL Editor › New query**.
2. Ouvrez le fichier `docs/apercu/schema-apercu.sql` de ce dépôt, copiez **tout** son contenu, collez-le, puis **Run**.
3. Résultat attendu : « Success. No rows returned ». Si une erreur apparaît, **ne relancez pas** : copiez le message et dites-le-moi (le projet doit être vierge ; en cas de doute, supprimez le projet et recommencez à l'étape 1).

## Étape 3 — Réglages de connexion (Authentication)
Dans **Authentication** (les noms exacts peuvent varier un peu) :
1. **Inscriptions publiques : désactivées** (« Allow new users to sign up » à OFF). Seuls les comptes créés par le côté 2 (ou par vous, à l'étape 5) doivent exister.
2. **Mot de passe : longueur minimale 12**, **aucune exigence** de majuscule / chiffre / symbole (sinon l'activation échoue avec « activation_failed »).
3. **Authentification à deux facteurs (MFA) : TOTP activé** (c'est normalement le cas). Elle est obligatoire pour le propriétaire.

## Étape 4 — Mettre en ligne les deux fonctions (Edge Functions)
C'est ce qui permet la **création des comptes** et **l'activation par code**. Sur votre ordinateur, dans le dossier du dépôt `sparklog-employ-s` (3 commandes ; la 1re ouvre le navigateur pour vous connecter) :
```
npx supabase@latest login
npx supabase@latest link --project-ref xxxx          # xxxx = la partie de l'adresse avant .supabase.co
npx supabase@latest functions deploy pointage_api --no-verify-jwt
npx supabase@latest functions deploy activate_account --no-verify-jwt
```
`--no-verify-jwt` est voulu : ces fonctions vérifient elles-mêmes leur secret ou leur code. (Alternative : je peux le faire pour vous avec la connexion Supabase de la session si vous me désignez **explicitement** le nouveau projet de test ; je ne toucherai à aucun autre projet.)

## Étape 5 — Créer le compte propriétaire de test
1. Menu **Authentication › Users › Add user › Create new user**. Courriel : `1000@pointage.invalid`. Mot de passe : une **phrase de 12 caractères ou plus** (rangez-la). Cochez « Auto confirm user ».
2. Menu **SQL Editor** : copiez et lancez `docs/apercu/1-proprietaire.sql`. Résultat attendu : **une ligne** `1000 | owner`.

## Étape 6 — Mettre la page en ligne (Canner)
1. Dans Canner, projet lié au dépôt `Sparklog-Employés` : choisissez la **branche** `ccr-75902f75-y912bl` (ou `main` une fois fusionné).
2. Commande de compilation : `npm run build`. Dossier publié : `dist`. Version de Node : 20.
3. **Variables d'environnement** (elles sont lues à la compilation, ajoutez-les **avant** de compiler) :
   - `VITE_SUPABASE_URL` = l'adresse du projet (étape 1)
   - `VITE_SUPABASE_ANON_KEY` = la clé **anon** (étape 1)
4. Lancez le déploiement et notez l'adresse de la page (`https://….canner…`).
5. Dites à la fonction d'activation quelle page a le droit de l'appeler (sur votre ordinateur) :
   `npx supabase@latest secrets set ALLOWED_ORIGIN=https://l-adresse-de-votre-page`
   (sans `/` à la fin, exactement l'adresse affichée par Canner).

## Étape 7 — Première connexion du propriétaire
1. Ouvrez la page. Entrez le numéro **1000** et le mot de passe de l'étape 5.
2. L'écran de **double authentification** s'affiche : scannez le code QR avec votre application, entrez le code à 6 chiffres. Vous arrivez dans le menu de **gestion** (Aujourd'hui, En direct, Notes, Feuilles de temps, Inventaire, Journal, Feuille d'urgence).

## Étape 8 — Créer des employés de test (comme le fera le côté 2)
1. SQL Editor : lancez `docs/apercu/2-client-api.sql`. **Copiez le secret `skc_…` tout de suite** (il ne s'affiche qu'une fois) dans un endroit privé.
2. Sur votre ordinateur (remplacez `ADRESSE_PROJET` et `SECRET`) :
```
curl -s -X POST "ADRESSE_PROJET/functions/v1/pointage_api/actions" \
  -H "Authorization: Bearer SECRET" -H "Content-Type: application/json" \
  -d "{\"action_key\":\"$(uuidgen)\",\"type\":\"register_account\",\"payload\":{\"employee_number\":1001,\"role\":\"employee\"}}"
```
(Sous Windows, remplacez `$(uuidgen)` par n'importe quel identifiant au format UUID, par exemple `11111111-1111-4111-8111-111111111111`, différent à chaque appel.)
Réponse attendue : `{"ok":true,"result":{"employee_number":1001,"role":"employee","code":"XXXXXXXXXX"}}`. Le **code** de 10 caractères n'est montré qu'**une fois**. Refaites avec `1002`, `1003` (et `"role":"foreman"` pour un contremaître).
3. Vérification : `curl -s "ADRESSE_PROJET/functions/v1/pointage_api/health" -H "Authorization: Bearer SECRET"` doit répondre `{"ok":true,…}`.

## Étape 9 — Activer un employé (ce que vivra l'employé)
1. Dans une **fenêtre privée** (ou un autre navigateur), ouvrez la page. Appuyez sur **« Première fois ? Activer mon compte »**.
2. Numéro `1001`, le **code** reçu, puis choisissez un mot de passe (12 caractères ou plus, sans le numéro ni le code). Vous êtes connecté·e.
3. Essayez : **Profil** (le numéro seulement), une **fiche de temps** (date, OT, départ, fin, km), enregistrer, puis soumettre.

## Étape 10 — Voir le côté gestion
Retour dans la fenêtre du propriétaire (1000) : **En direct**, **Feuilles de temps**, **Aujourd'hui** (la fiche soumise doit apparaître), **Feuille d'urgence** (créer une saisie pour l'employé 1001).
Note : **approuver** une fiche est une action du côté 2 (`approve_jobs`, via l'API) : ce n'est pas un bouton ici.

## Étape 11 — Ce qui peut ne pas marcher (connu, pas un oubli de votre part)
- **Notifications téléphone** et **annonces** : `send_push` n'est pas adapté, et seul le côté 2 publie les annonces.
- **Lecture automatique des captures** (OCR) et nettoyage des preuves : ces fonctions Edge (`process_*`, `cleanup_*`) ne sont pas déployées dans l'aperçu.
- **Mise à jour en direct** de la cloche d'annonces : demande de l'activer dans Supabase (« Realtime » sur la table `announcement_recipients`) ; sans cela la cloche se met à jour au rechargement.
- Certains textes ou écrans de gestion hérités de Sparklog peuvent encore afficher une erreur : **notez l'écran et le message**, c'est exactement ce que cet aperçu sert à trouver.
- **Réémettre un code** ne déconnecte pas les téléphones déjà connectés (point ouvert).

## Étape 12 — Quand vous avez fini
Supprimez le projet Supabase de test (**Project Settings › General › Delete project**) et, si vous voulez, la variable et le déploiement Canner. Rien de vrai ne s'y trouvait.

---

## Si quelque chose bloque, envoyez-moi
Le **numéro de l'étape**, ce que vous voyez à l'écran (capture ou texte du message d'erreur) et l'adresse de la page. **Jamais** : un mot de passe, le secret `skc_…`, un code d'activation, la clé `service_role`.
