# Rapport : capture des empreintes par caméra (phase 3)

> Prototype non officiel. Les mesures ont été faites sur **une seule personne** (le porteur du projet, consentant), avec **un seul téléphone**. Ce ne sont pas des résultats de fiabilité : ceux-ci viendront de la phase 4 (volontaires) et de la phase 9.

## Matériel

| | |
|---|---|
| Téléphone | Samsung Galaxy S23 Ultra (SM-S918U), Android 16 (haut de gamme : résultats optimistes) |
| Photo | 4080×3060 (12,5 Mpx), disponible en même temps que l'analyse en direct |
| Mise au point minimale | 10 cm (valeur annoncée par le téléphone, « approximative ») |
| Analyse en direct | 640×480, environ 8,4 images analysées par seconde, 21 à 34 ms par image (GPU) |

## Fonctionnement

1. **Analyse en direct** (MediaPipe, 21 points de la main) : guidage selon plusieurs critères :
   - bonne main, paume visible ;
   - doigts dans le cadre et écartés ;
   - distance, exprimée par la résolution estimée en dpi ;
   - lumière ;
   - immobilité pendant 0,5 s.
2. **Rafale de 3 photos** pleine résolution, avec la mise au point verrouillée sur les bouts des doigts.
3. **Sur chaque photo** :
   - nouvelle détection de la main ;
   - découpe redressée de chaque bout de doigt, à l'échelle 1:1 ;
   - mesure de la **netteté des crêtes**.
4. **Doigt sous le seuil** : jusqu'à 2 rafales supplémentaires, avec la mise au point **sur ce doigt**.

### Mesure de netteté des crêtes (`QualiteCretes`)

La mesure repose sur l'espacement attendu des crêtes (0,45 mm), converti en pixels grâce au dpi estimé. Pour chaque bloc de la pulpe du doigt, elle calcule :
- l'énergie dans cette bande de fréquence, rapportée au contraste du bloc ;
- multipliée par la cohérence d'orientation.

Le score du doigt est la médiane des blocs, entre 0 et 1.

L'ancienne mesure (variance du Laplacien) réagissait à la peau sèche et au bruit : un index très net obtenait 7, un autre 60, et un doigt flou 4. La nouvelle mesure place les découpes floues en bas du classement.

**Seuil retenu : 0,04.** Calibrage sur 28 découpes (9 examinées à l'œil), puis 2 sessions de validation. La zone 0,03 à 0,04 mélange encore des découpes médiocres et floues.

## Résultats (2 sessions de validation complètes, 01/10/2026)

| Critère | Résultat |
|---|---|
| Déclenchement automatique | 8 étapes sur 8 réussies |
| Durée, étape 4 doigts | environ 3 s (une seule rafale) |
| Durée, étape pouce | 2,6 à 5,3 s (parfois 2 rafales) |
| Résolution estimée des découpes | 360 à 700 dpi, autour de 500 en général |
| Crêtes visibles à l'œil nu | oui sur index, majeur et annulaire ; **auriculaire gauche limite** |
| Pouces | pli de l'articulation exclu de la zone utile ; pulpe vue un peu de biais |

## Limites constatées

- **Auriculaire** : c'est le doigt le moins net, car il est plus court et plus loin que les autres. Les rafales ciblées aident, mais ne suffisent pas toujours.
- **Chauffe** : le téléphone atteint le niveau « sévère » (3 sur 6) après quelques captures. La cause : flash allumé en continu, caméra, GPU et photos de 12 Mpx. Pour une campagne de 50 à 100 personnes, il faudra couper le flash sans main détectée et ralentir l'analyse.
- **Main qui bouge pendant les rafales ciblées** : les photos où la main s'est éloignée (moins de 350 dpi) sont maintenant écartées. La personne doit rester immobile jusqu'à 5 s.
- **Résolution estimée** : elle suppose un doigt large de 18 mm. La phase 4 la mesurera sur l'image.
- **Une seule personne, un seul téléphone haut de gamme** : rien ne permet encore de conclure pour un téléphone d'entrée de gamme.
