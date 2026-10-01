# Simulation : plusieurs captures par doigt à l'enregistrement

> Généré le 01/10/2026. Prototype non officiel. Une seule personne : indicatif seulement.

- Découpes : 61 (7 sessions)
- Variante de prétraitement : `simple_inverse` ; comparaison multi-échelle
- Filtre : aucun

Chaque session joue la nouvelle capture ; k autres sessions jouent l'enregistrement ; on garde le meilleur score des k.

## Doigt par doigt

| Captures à l'enregistrement | Authentiques | Imposteurs | EER | d' | Médiane authentique | Max imposteur | FNMR à FMR 1 % |
|---|---|---|---|---|---|---|---|
| 1 | 320 | 2840 | 42.6 % | 0.68 | 8.6 | 30.7 | 75.6 % |
| 2 | 702 | 6138 | 34.4 % | 0.95 | 15.4 | 30.7 | 59.8 % |
| 3 | 824 | 7096 | 29.1 % | 1.13 | 26.0 | 30.7 | 49.4 % |
| 4 | 545 | 4625 | 27.1 % | 1.26 | 30.3 | 30.7 | 49.0 % |

## Main entière (4 doigts, meilleur des k par doigt, puis somme)

| Captures à l'enregistrement | Authentiques | Imposteurs | EER | d' | Médiane authentique | Max imposteur | FNMR à FMR 1 % |
|---|---|---|---|---|---|---|---|
| 1 | 72 | 72 | 27.8 % | 1.14 | 55.3 | 57.6 | 55.6 % |
| 2 | 165 | 165 | 14.5 % | 1.67 | 102.1 | 70.7 | 30.3 % |
| 3 | 200 | 200 | 11.0 % | 2.03 | 116.2 | 72.7 | 19.5 % |
| 4 | 135 | 135 | 8.1 % | 2.27 | 144.9 | 72.7 | 12.6 % |

Les paires d'une simulation à k captures ne sont pas indépendantes (combinaisons) : les effectifs surestiment la précision.
