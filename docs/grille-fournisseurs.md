# Grille de comparaison des fournisseurs d'infrastructure (D4 : Supabase auto-hébergé, serveur au Québec)

Utilisée à l'étape **2bis.1** de `PLAN.md`. Le but : choisir **où** installer le serveur Supabase du côté 1 (et, plus tard, celui du côté 2), sur des critères écrits, avec des **preuves** gardées.
Ce n'est **pas un avis juridique** ; les critères marqués **[À VALIDER]** dépendent de la réponse de l'AECQ ou de l'avocat (`PLAN.md`, étape 0.1, questions 2, 3 et 7).

> **État des données : rien n'est vérifié.** Les fournisseurs listés plus bas sont des **pistes à investiguer**, pas des recommandations. Je n'ai pu lire que le site de Canner (le 2026-11-14) ; pour tous les autres, chaque case est vide
> jusqu'à ce qu'une preuve (certificat, contrat, courriel du fournisseur) soit rangée dans le dossier « Preuves » de la propriétaire. **Ne jamais remplir une case de mémoire.**

## 1. Besoin à couvrir (point de départ, à valider par un essai de charge)

| Élément | Valeur de départ |
|---------|------------------|
| Serveur | privé virtuel ou dédié, **accès root complet**, **Docker** autorisé |
| Taille | 4 vCPU, 8 Go de mémoire, 100 Go de disque SSD (≈ 150 employés, photos de courte durée) |
| Emplacement | **centre de données au Québec** (production **et** sauvegardes) |
| Réseau | adresse IPv4 publique fixe, pare-feu configurable, accès console hors bande |
| Sauvegardes | instantanés du serveur + stockage de sauvegarde **au Québec**, distinct du serveur |
| Environnements | production + essai (deux serveurs ou un serveur plus un petit) ; le côté 2 plus tard sur une pile séparée |
| Durée | contrat mensuel (sans longue période d'engagement au départ) |

## 2. Critères éliminatoires (une seule réponse « non » ou « inconnue » = écarté tant que ce n'est pas prouvé)

| # | Critère | Preuve à exiger |
|---|---------|-----------------|
| G1 | **Centre de données au Québec**, adresse précise ; sauvegardes et reprise après sinistre aussi **au Québec** | Courriel signé du fournisseur ou annexe du contrat |
| G2 | **Propriété et contrôle canadiens** : pas de société mère étrangère, ni de filiale soumise à une loi étrangère d'accès aux données (CLOUD Act pour les États-Unis) | Registre des entreprises (Québec ou fédéral), structure de propriété écrite par le fournisseur |
| G3 | **ISO 27001 et/ou SOC 2 Type 2** pour **le site et le service loués** (portée écrite), certificat ou rapport **en cours de validité** **Question 7 : réponse verbale reçue le 2026-11-14 — le certificat du fournisseur suffit, l'exploitant n'a pas à être certifié ; à confirmer par écrit** | Certificat daté, organisme émetteur, portée |
| G4 | **Entente écrite de traitement** (art. 18.3 de la Loi 25) acceptant : pas de transfert hors Québec, notification d'incident dans un délai précis, destruction des données à la fin du contrat avec attestation | Contrat ou addenda signé |
| G5 | **Machine virtuelle ou dédiée avec accès root et Docker** (pas seulement de l'hébergement d'applications) | Fiche de l'offre |
| G6 | **Support, journaux et personnel d'administration** dans un pays acceptable (au minimum au Canada, de préférence au Québec) ; aucune ouverture de la machine par le fournisseur sans trace | Réponse écrite |

## 3. Critères notés (0 à 5, multipliés par le poids)

| # | Critère | Poids | Ce qu'on regarde |
|---|---------|:----:|------------------|
| N1 | Sécurité de l'offre | 3 | pare-feu réseau, protection contre les attaques par saturation, console hors bande, chiffrement des disques, journal des accès physiques |
| N2 | Sauvegardes et instantanés au Québec | 3 | fréquence, rétention, prix, **restauration testée**, copie hors site **au Québec** |
| N3 | Disponibilité contractuelle | 2 | pourcentage garanti, crédits en cas de panne, historique public des incidents |
| N4 | Réversibilité | 2 | export facile, pas de blocage propriétaire, sortie sans frais, délai de destruction |
| N5 | Services gérés optionnels | 2 | le fournisseur peut-il prendre en charge système, mises à jour, surveillance, sauvegardes (allège la charge d'exploitation, `PLAN.md` 2bis.9) ? |
| N6 | Support | 2 | français, heures, délai de réponse, accès à une personne compétente |
| N7 | Prix total mensuel | 2 | serveur + stockage + sauvegardes + bande passante + IP + soutien ; **comparer sur le besoin de la section 1** |
| N8 | Flexibilité | 1 | redimensionner sans reconstruire, second serveur, réseau privé entre les deux piles |
| N9 | Contrat et facturation en français | 1 | langue, devise (CAD), facture conforme |
| N10 | Solidité du fournisseur | 1 | ancienneté, taille, références vérifiables |

Total maximal : somme des poids × 5 = **95**. Un fournisseur qui passe tous les éliminatoires et dépasse **60** est une candidate sérieuse ; sous 60, à écarter sauf raison particulière écrite.

## 4. Pistes à investiguer (aucune donnée vérifiée)

| Piste | Type d'offre probable | Observation |
|-------|-----------------------|-------------|
| **Canner** | Plateforme d'hébergement d'applications (Node, Python, Go, etc.), base PostgreSQL gérée, stockage S3 | Selon son site (lu le 2026-11-14) : entreprise canadienne basée au Québec, serveurs à Montréal. **Probablement écartée par G5** : ses pages ne parlent pas de machine virtuelle ni de Docker ; **à confirmer** auprès d'elle. Reste utile pour le **front** statique |
| **OVHcloud** | serveurs privés virtuels et dédiés | À investiguer : emplacement exact, structure de propriété et filiale canadienne (G1, G2) |
| **Hypertec** | infonuagique | À investiguer (G1 à G6) |
| **eStruxture** | colocation / hébergement de serveurs à Montréal | À investiguer : offre de serveurs, structure de propriété (G2) |
| **Cologix** | colocation / hébergement à Montréal | À investiguer : structure de propriété (G2) |
| **Une entreprise locale québécoise** de serveurs privés | selon l'offre | À chercher, par recommandation de l'AECQ ou de votre comptable |
| **Références américaines** : AWS (Montréal), Azure (Québec), Google Cloud (Montréal) | infonuagique | **Exposition américaine** (G2 « non ») ; gardées seulement comme **point de comparaison** de prix et de fonctions, ou pour le plan B (Supabase infonuagique) |

### Première lecture des sites publics (2026-11-14)

Lu sur les **pages publiques** des fournisseurs (aucun contact, aucun contrat). **Ce sont des affirmations des fournisseurs, pas des preuves** : tout est à confirmer par écrit (section 6) avant de remplir la grille.

| Fournisseur | Ce que la page dit | Ce qui manque ou inquiète |
|-------------|--------------------|---------------------------|
| **Cologix** | Siège à **Denver (Colorado)**. Certifié **ISO 27001** (par Schellman) pour tous ses centres de données ; évaluations tierces **SOC 1, SOC 2**, HIPAA, PCI-DSS dans toutes ses installations. Centres à **Montréal** (MTL1 à MTL12), aussi Toronto, Calgary, Vancouver et plusieurs sites américains. Offre : colocation et interconnexion | **G2 probablement « non »** : siège aux États-Unis (à confirmer : structure de propriété et filiale canadienne). Colocation : on loue de l'espace pour son propre serveur, pas un serveur clé en main (**G5** à confirmer) |
| **eStruxture** | Centres à **Montréal** (MTL-1 à MTL-5), aussi Toronto, Vancouver, Calgary. « Cloud et colocation neutre quant aux fournisseurs de réseau » | Propriété, certifications et type d'offre (serveur loué ou colocation) **non indiqués** sur la page d'accueil (G2, G3, G5) |
| **Hypertec** | Fondée en **1984** ; activités : calcul haute performance, centres de données hyperéchelle, refroidissement. Siège certifié BOMA BEST Or | Emplacement des centres de données, propriété, certifications et offre de serveurs **non lus** (G1, G2, G3, G5) |
| **OVHcloud** (pages canadiennes) | Politique de certification : **ISO 27001 / 27017 / 27018**, **ISO 27701**, **HDS**, **SecNumCloud**… Met de l'avant la « souveraineté des données ». Offre de serveurs privés virtuels et dédiés | **Emplacement des centres canadiens et propriété non lus** (G1, G2) : à demander par écrit ; vérifier que la certification couvre le site canadien (portée, G3) |
| **Canner** | Voir ci-dessus (lu le 2026-11-14) | Probablement écarté par G5 |

La liste est un point de départ, **pas** une présélection : ni ownership ni certification n'ont été confirmés pour aucune de ces entreprises.

## 5. Grille à remplir

Le fichier `docs/grille-fournisseurs.csv` (à importer dans Google Sheets) reprend les critères ci-dessus, une colonne par fournisseur. Remplir **seulement** avec une preuve rangée. Pour les éliminatoires : `Oui` / `Non` / `Inconnu`. Pour les notés : 0 à 5 et le **montant** réel pour le prix (N7).
Total d'un fournisseur : somme des (note × poids) ; dans Google Sheets : `=SOMMEPROD(poids; notes)`.

## 6. Questions à envoyer aux fournisseurs (modèle de courriel)

> **Objet : Demande d'information — serveur privé au Québec pour une application de feuilles de temps**
>
> Bonjour,
>
> Nous évaluons un hébergement pour une application de feuilles de temps (environ 150 utilisateurs) qui doit respecter la Loi 25. Pourriez-vous répondre **par écrit** aux questions suivantes ?
>
> 1. **Où** (adresse ou municipalité) se trouvent les serveurs que vous nous loueriez ? Et les **sauvegardes** et copies de reprise après sinistre ?
> 2. Qui **détient** l'entreprise (actionnaires majoritaires, société mère) ? Une société ou une filiale **étrangère** a-t-elle un accès ou une obligation de divulgation envers un État étranger ?
> 3. Quelles **certifications** détenez-vous (ISO 27001, SOC 2 Type 2) ? Quelle est la **portée** (sites et services visés) et la date de validité ? Pouvez-vous nous transmettre les certificats ou rapports ?
> 4. Offrez-vous un **serveur privé virtuel ou dédié** avec accès **root** et **Docker** ? Quelle configuration pour 4 vCPU, 8 Go de mémoire, 100 Go SSD, et à quel prix mensuel (sauvegardes, IP, bande passante comprises) ?
> 5. Acceptez-vous une **entente écrite de traitement des renseignements personnels** (article 18.3 de la Loi 25) incluant : aucune sortie hors Québec, **avis d'incident** dans un délai de ___ heures, **destruction attestée** à la fin du contrat ?
> 6. Où se trouvent votre **support** et votre **personnel d'administration** ? Vos **journaux** ? Quels accès avez-vous à nos machines, et laissent-ils des traces que nous pouvons consulter ?
> 7. Quels **instantanés et sauvegardes** offrez-vous (fréquence, rétention, prix) ? Peut-on **restaurer** sur un serveur neuf, et en combien de temps ?
> 8. Quel **engagement de disponibilité** (pourcentage, crédits) et quel **historique d'incidents** public ?
> 9. Offrez-vous des **services gérés** (mises à jour système, surveillance, sauvegardes) ? À quel prix ?
> 10. Quelles sont les **conditions de sortie** : export, délai de destruction, frais ?
> 11. Le contrat et la facturation sont-ils disponibles **en français** et en **dollars canadiens** ?
>
> Merci,
> [nom, titre, entreprise]

## 7. Déroulement

1. **Présélectionner 3 à 4 fournisseurs** parmi la section 4 (et les recommandations de votre entourage).
2. **Envoyer le courriel de la section 6** ; ranger **chaque réponse** (courriel complet, certificats, contrats) dans le dossier « Preuves ».
3. **Remplir la grille** ; passer d'abord les éliminatoires, noter ensuite.
4. **Faire valider** par l'avocat ou l'AECQ ce qui dépend d'eux (G3, G6) et **obtenir par écrit** la réponse à la question 7 (reçue verbalement le 2026-11-14).
5. **Décider** et inscrire dans `OFFICIEL.md` (section 11, D4) : fournisseur retenu, date, points faibles connus, preuves rangées, plan B.
6. **Ensuite seulement** commander le serveur d'essai (2bis.3) ; le serveur de production quand 2bis est complet.

## 8. Pour les prochaines révisions

- Je peux **lire les pages publiques** des fournisseurs retenus (certifications annoncées, régions, tarifs) si vous autorisez leur domaine dans le réseau de la session ; ce sera une **première lecture**, toujours à confirmer par écrit auprès du fournisseur.
- Les preuves (certificats, contrats, courriels) **ne vont pas dans ce dépôt** (il est public) : dossier privé de la propriétaire.
