# Lecture des captures : OCR.space (gardé pour l'instant) et Tesseract (prêt si on change)

## Décision (propriétaire, 2026-11-14)
**On garde OCR.space pour l'instant.** Tesseract est noté ici au cas où la propriétaire décide de changer. Rien dans le code n'a été modifié pour Tesseract.

**À savoir en gardant OCR.space** (service hors Québec, `OFFICIEL.md` écart « OCR ») : les captures et photos lues par OCR transitent par ce fournisseur. À inscrire dans l'ÉFVP, la politique de confidentialité et le consentement ; à revoir avec l'avis juridique (PLAN étape 0). Où ça se passe : navigateur (`src/lib/ocr.js`, `src/lib/work-order-ocr.js`, clé `VITE_OCR_SPACE_API_KEY`, visible dans la page) et fonctions Edge `process_overtime_evidence` et `process_inventory_screenshot` (secret `OCR_SPACE_API_KEY`, sinon clé publique de démonstration « helloworld » : à vérifier avant la mise en service).

## Résultat de l'essai Tesseract (V0.24.1, 14 captures réelles)
Tesseract 5.3 (eng + fra, modèles « fast » d'Ubuntu), avec l'analyseur de l'application (`src/lib/work-order-parse.js`), par `scripts/ocr-bench.mjs`.
- **`--psm 11` (texte épars), image brute : 14/14 captures entièrement justes** (OT, date, départ, arrivée, fin, km, miles).
- `--psm 6` / `4` / `3` : tout juste sauf les « miles » (le contrôle de cohérence km / miles ne marcherait pas).
- Agrandir ×2 ou ×3 : pas mieux (1 à 2 OT mal lus de plus). La réduction actuelle de l'app (1600 px, JPEG 70) ne nuit pas.
- Photo sans rapport (panneau électrique) : aucun champ lu (0 faux positif).
- Vitesse : environ 10 s par image (4 cœurs, eng + fra, 1080 × 2340) ; à réduire (anglais seul, image réduite).
- **Limites :** environ 7 fiches distinctes (plusieurs captures sont la même fiche), un seul téléphone, **aucune comparaison avec OCR.space**.

## Avant de décider : compléter l'essai
15 à 20 captures de plus, masquées si besoin, d'**autres téléphones** et **autres écrans** : écran en français, fiche sans km, fiche avec « --- », capture coupée, reçu de stationnement, liste d'inventaire (le banc d'essai actuel ne couvre que l'écran Durée de Field Service). Relancer : `node scripts/ocr-bench.mjs verite.json --variants raw-psm11,up2-psm11 --details` (ne jamais commiter les images ni `verite.json`).

## Si on change : plan de travail
1. **Service OCR au Québec** : conteneur Tesseract (eng + fra) à côté de Supabase (même Docker Compose, même serveur), petit service HTTP interne (image → texte), sans accès Internet sortant, sans journal du contenu. (Variante : `tesseract.js` dans le téléphone, 10 Mo environ à télécharger une fois, plus lent sur un vieil appareil, l'image ne quitte pas l'appareil.)
2. **Réglage** : `--psm 11`, image brute (ou réduite), langues `eng+fra`.
3. **Code** : remplacer l'appel OCR.space dans `ocr.js`, `work-order-ocr.js` et les fonctions Edge `process_*` par ce service ; l'analyseur `work-order-parse.js` ne change pas. Le contrat de sortie reste « texte brut ».
4. **Tests** : fixtures de texte réel de Tesseract pour l'analyseur ; test qui échoue si `ocr.space` réapparaît dans `src/` ou `supabase/functions/` ; essai de charge (plusieurs captures en même temps).
5. **Retrait** : supprimer `VITE_OCR_SPACE_API_KEY` et le secret `OCR_SPACE_API_KEY` ; retirer OCR.space de la politique de confidentialité et de l'ÉFVP.
6. **Repli** : la saisie manuelle reste toujours possible si la lecture échoue.
