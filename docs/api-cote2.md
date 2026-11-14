# Interface d'échange côté 1 → côté 2 (`pointage_api`, contrat v1)

Le côté 2 (Sparklog-Gestion) appelle le côté 1 ; le côté 1 n'appelle jamais le côté 2. Code : `supabase/functions/pointage_api/` (`handler.js` = logique pure, testée par `src/lib/pointage-api.test.js` ; `index.ts` = branchement Deno). Fonctions SQL appelées : migration `0012_sync_api`.

## Déploiement
- Déployer avec `verify_jwt = false` (la fonction valide son propre secret) ; variables `SUPABASE_URL` et `SUPABASE_SERVICE_ROLE_KEY` fournies par la plateforme.
- Aucun en-tête CORS : appel de serveur à serveur seulement. Réponses `cache-control: no-store`, `x-contract-version: 1`.
- Créer un client : `select * from sync_create_client('gestion')` (clé de service). Le secret `skc_` + 40 caractères n'est montré **qu'une fois** ; il est stocké haché. Rotation : créer un second client, basculer, révoquer le premier (`sync_revoke_client`).

## Authentification
`Authorization: Bearer skc_<40 caractères alphanumériques>`. Un secret mal formé est refusé (401) sans toucher à la base. Un secret faux : 401 `invalid_client`. Trop d'essais ratés (20/min en tout) ou d'appels (120/min par client) : 429 `rate_limited` avec `Retry-After: 60`.

## Routes
| Méthode | Route | Paramètres | Réponse |
|---|---|---|---|
| GET | `/health` | — | état et `contract_version` |
| GET | `/employees` | — | employés par numéro (jamais de nom) |
| GET | `/jobs/changed` | `after_ts`, `after_id`, `limit` (1–500, défaut 500) | fiches modifiées, curseur `(updated_at, id)` |
| GET | `/jobs/deleted` | idem | suppressions, curseur `(deleted_at, job_id)` |
| GET | `/jobs/ids` | `from`, `to` (AAAA-MM-JJ, 92 jours au plus) | identifiants, pour détecter les trous |
| GET | `/claims/changed` | `after_ts`, `after_id`, `limit` | demandes repas / stationnement, curseur `(changed_at, id)` |
| POST | `/actions` | corps JSON `{ action_key (uuid), type, payload (objet) }`, 256 Ko au plus | `{ ok: true, result }` |

Types d'action : `approve_jobs`, `return_job`, `set_pause`, `register_account`, `reissue_activation_code`, `unlock_day`, `upsert_group`, `set_group_members`.

Les pages sont `{ ok, data, has_more, next: { after_ts, after_id } | null }`. `after_ts` et `after_id` vont ensemble. Une page pleine annonce `has_more`.

## register_account (compte de connexion)
Charge : `{ employee_number (entier 1000–999999), role }` (`user_id` envoyé par l'appelant est ignoré). La fonction crée d'abord le compte d'authentification `<numéro>@pointage.invalid` (mot de passe aléatoire de 64 caractères hexadécimaux, jamais renvoyé ni conservé), puis appelle l'action avec son identifiant. Si l'action échoue, ou si c'est une relance reconnue, le compte qu'elle vient de créer est retiré. Si l'adresse existe déjà : relance reconnue = résultat enregistré ; sinon 409 `employee_number_taken`. Numéro hors plage : 422 `invalid_employee_number`. Un échec du retrait laisse un compte sans profil, sans effet ; à nettoyer au ménage.

## Erreurs
Corps `{ ok: false, error: "<code court>" }`, jamais de texte SQL. 400 `invalid_json` · 401 `invalid_client` · 403 `forbidden` · 404 · 405 (avec `Allow`) · 409 (version périmée, clé déjà utilisée, numéro pris) · 413 `payload_too_large` · 422 (paramètre ou charge invalide) · 429 `rate_limited` · 500 `internal_error`.

## Règles pour le côté 2
- Une action est **idempotente** par `action_key` : relancer la même clé renvoie le même résultat avec `replayed: true`. Réutiliser la clé pour un autre type est refusé.
- Le **code d'activation** (`register_account`, `reissue_activation_code`) n'est montré qu'une fois et n'est jamais conservé, pas même dans un résultat rejoué : le transmettre à l'employé tout de suite.
- Relire avec **5 minutes de chevauchement** sur le curseur (un enregistrement validé en retard peut porter une date antérieure) et faire un **passage complet chaque nuit** avec `/jobs/ids`.
- Le journal du côté 1 ne garde que la route et le code de réponse : ni secret, ni corps, ni IP.

## Activation par l'employé (`activate_account`, V0.14.0)
Fonction séparée, appelée par le navigateur de l'employé (pas par le côté 2) : `POST { employee_number, code, password }`. Le code (10 caractères, espaces et tirets tolérés) est vérifié et consommé par `consume_activation_code`, puis le mot de passe (12 à 72 caractères, sans le numéro ni le code) est posé sur le compte `<numéro>@pointage.invalid`. Réponses : 200 ; 422 (format, avant la base : ne compte pas comme un essai) ; 401 `invalid_code` (faux, inconnu, utilisé ou révoqué) ; 410 `code_expired` ; 429 `code_locked` (5 essais) ; 500 `activation_failed` (code consommé, mot de passe non posé : réémettre un code). `verify_jwt = false`, CORS limité à `ALLOWED_ORIGIN`.

**Réglages d'instance Auth requis (auto-hébergé) :** inscription publique désactivée (`GOTRUE_DISABLE_SIGNUP=true` : seuls les comptes créés par `pointage_api` existent), longueur minimale du mot de passe 12, aucune exigence de caractères (sinon l'activation échoue avec `activation_failed`), confirmation de courriel inutile (comptes créés confirmés).
