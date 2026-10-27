# Diagnostic phase 4 : premier signal (01/10/2026)

> Prototype non officiel. **Une seule personne**, Galaxy S23 Ultra, 7 sessions de capture (61 découpes, dont 27 nettes). Ces chiffres sont des indices, pas des résultats de fiabilité. Aucune image d'empreinte ici.

## Constat

Doigt par doigt, d'une session à l'autre, SourceAFIS reconnaît **mal** le même doigt :
- score médian des paires authentiques : **2 à 6** (sur des empreintes de scanner, il dépasse en général 40) ;
- taux d'égale erreur (EER) : **31 à 44 %**.

Rapports détaillés :
- [premier-signal/](premier-signal/rapport.md) : toutes les découpes ;
- [premier-signal-nettes/](premier-signal-nettes/rapport.md) : découpes nettes seulement ;
- [premier-signal-multi-echelle/](premier-signal-multi-echelle/rapport.md) : découpes nettes, comparaison multi-échelle.

## Expériences pour isoler la cause

| Expérience | Résultat | Conclusion |
|---|---|---|
| **Même instant** : 3 photos d'une même rafale (même pose, même échelle), 111 paires | score médian **67**, souvent 100 à 250 ; 0 seulement pour l'auriculaire flou | la chaîne (découpe, prétraitement, SourceAFIS) **fonctionne** |
| **Échelle faussée** : une découpe comparée à elle-même | 0 % : 300 à 665 · 5 % : 34 à 143 · 10 % : 22 à 110 · 15 % : 7 à 46 · 20 % : 2 à 12 | SourceAFIS est **très sensible à l'échelle** ; l'échelle estimée varie de 10 à 20 % d'une session à l'autre |
| **Comparaison multi-échelle** (±15 %) | EER doigt **≈ 31 %** (au lieu de 31 à 40 %), d' jusqu'à 1,06 | gain réel mais **insuffisant** : l'échelle n'est pas la seule cause |

Défauts de prétraitement corrigés pendant ce diagnostic :
- **mesure de l'espacement des crêtes trompée par les plis** : le spectre est maintenant blanchi, et la recherche limitée à ±35 % de l'espacement attendu ;
- **bord du doigt resté dans l'image** : le masque est maintenant calculé d'après l'énergie des crêtes.

## Causes restantes probables

1. **Pose** : doigts tournés sur eux-mêmes ou inclinés d'une session à l'autre. Ce n'est pas la même partie de la pulpe qui est vue.
2. **Déformation** : un doigt rond photographié à plat comprime les bords. Avec un scanner, le doigt est aplati.
3. **Échelle résiduelle** : l'estimation de la largeur du doigt, ou de l'espacement des crêtes, reste imprécise.

## Pistes, de la moins chère à la plus chère

1. **Plusieurs captures à l'enregistrement** (3 par doigt) : on compare à la plus proche. Peu coûteux, gain souvent important en sans-contact.
2. **Guidage de pose plus strict** : contrôle « main à plat » activé, fenêtre de distance plus étroite, d'où moins de variation d'échelle et de pose.
3. **Correction de la courbure du doigt** (modèle cylindrique) avant SourceAFIS.
4. **Moteur conçu pour le sans-contact** (SDK commercial) : à évaluer avec le même outil.
5. **Recentrer l'usage** : vérification 1:1 (« est-ce bien cette personne ? ») plutôt qu'identification 1:N.

## Levier 3 : déroulage cylindrique du doigt (code prêt, gain NON mesuré)

> Codé et testé sur des doigts synthétiques uniquement (27/10/2026). Les captures réelles ne sont pas dans le dépôt : le gain doit être mesuré sur le poste qui les détient.

**Principe.** Le doigt est vu comme un cylindre d'axe vertical. Sur la photo, un point de la peau situé à l'angle θ du sommet apparaît à `x = centre + R·sin θ`. Les bords sont donc comprimés : à 50°, l'espacement des crêtes vaut 0,64 fois celui du centre. Le déroulage reconstruit la peau « à plat » : la colonne de sortie correspond à la longueur d'arc `R·θ`. Le centre de la pulpe garde son échelle, donc la mise à l'échelle 500 dpi reste valable.

- **Centre et rayon, ligne par ligne**, d'après la silhouette du doigt sur la photo brute : sous le flash, le doigt est clair et le fond sombre. Vers le bout, le rayon diminue, ce qui approche un bout arrondi.
- **Repli** si la silhouette n'est pas crédible (pas de fond visible, contraste faible, largeur aberrante) : on suppose que le doigt occupe la découpe moins la marge de 15 %.
- Au-delà de **65°**, la peau est vue trop en biais : elle est masquée.
- Variantes ajoutées : `gabor_inverse_deroule` et `simple_inverse_deroule`. L'outil affiche combien de découpes ont utilisé la silhouette ou la largeur supposée.

**Mesure à faire** (matcher démarré, captures dans `./captures/s23ultra`) :

```
docker compose run --rm -v ./captures:/captures:ro -v ./docs:/docs backend \
    python -m evaluation.evaluer --captures /captures/s23ultra --multi-echelle \
    --nettete-min 0.04 --variantes simple_inverse,simple_inverse_deroule,gabor_inverse,gabor_inverse_deroule \
    --sortie /docs/evaluation/deroulage-nettes --titre "Levier 3 : déroulage"

docker compose run --rm -v ./captures:/captures:ro -v ./docs:/docs backend \
    python -m evaluation.simulation_enrolement --captures /captures/s23ultra --multi-echelle \
    --nettete-min 0.04 --variante simple_inverse_deroule --sortie /docs/evaluation/simulation-deroulage-nettes
```

**Critère de décision** : garder le déroulage si l'EER doigt et le d' s'améliorent par rapport à la même variante sans déroulage, et si la majorité des découpes utilise la silhouette (sinon, revoir la détection des bords avant de conclure).
