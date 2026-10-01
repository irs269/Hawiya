# Simulation : plusieurs captures par doigt à l'enregistrement

> Généré le 01/10/2026. Prototype non officiel. Une seule personne : indicatif seulement.

- Découpes : 27 (4 sessions)
- Variante de prétraitement : `simple_inverse` ; comparaison multi-échelle
- Filtre : netteté ≥ 0.04

Chaque session joue la nouvelle capture ; k autres sessions jouent l'enregistrement ; on garde le meilleur score des k.

## Doigt par doigt

| Captures à l'enregistrement | Authentiques | Imposteurs | EER | d' | Médiane authentique | Max imposteur | FNMR à FMR 1 % |
|---|---|---|---|---|---|---|---|
| 1 | 64 | 472 | 31.3 % | 1.07 | 20.9 | 30.7 | 50.0 % |
| 2 | 54 | 363 | 27.7 % | 1.47 | 38.6 | 30.7 | 31.5 % |
| 3 | 16 | 100 | 31.1 % | 1.50 | 44.5 | 22.0 | 31.2 % |

## Main entière (4 doigts, meilleur des k par doigt, puis somme)

| Captures à l'enregistrement | Authentiques | Imposteurs | EER | d' | Médiane authentique | Max imposteur | FNMR à FMR 1 % |
|---|---|---|---|---|---|---|---|
| 1 | 14 | 12 | 0.0 % | 2.11 | 129.8 | 40.6 | 0.0 % |
| 2 | 14 | 12 | 0.0 % | 3.48 | 192.8 | 54.7 | 0.0 % |
| 3 | 4 | 3 | 0.0 % | 3.65 | 212.9 | 54.7 | 0.0 % |

Les paires d'une simulation à k captures ne sont pas indépendantes (combinaisons) : les effectifs surestiment la précision.
