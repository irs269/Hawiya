"""Simulation : enregistrer PLUSIEURS captures par doigt (levier 1, phase 4).

Chaque session joue tour à tour la « nouvelle capture » (sonde). On l'oppose à
k AUTRES sessions jouant l'enregistrement (galerie) et l'on garde le meilleur
score parmi ces k captures. Toutes les combinaisons de k sessions sont essayées.

  - authentique : même doigt (et même personne) que la sonde ;
  - imposteur   : autre doigt (ou autre personne).

Main entière : pour chaque doigt, meilleur score parmi les k captures, puis
somme des 4 doigts.

  python -m evaluation.simulation_enrolement --captures /captures/s23ultra \
         --sortie /docs/evaluation/simulation-enrolement [--nettete-min 0.04]
"""

import argparse
from collections import defaultdict
from datetime import date
from itertools import combinations
from pathlib import Path

import numpy as np

from app.biometrie.client_matcher import ClientMatcher
from app.biometrie.pretraitement import VARIANTES
from evaluation.evaluer import Echantillon, collecter, evaluer_variante
from evaluation.metriques import Synthese, synthese

MAX_COMBINAISONS = 30  # par sonde et par identité, pour limiter le calcul


def simuler(scores: np.ndarray, gardes: list[Echantillon], k: int):
    # Index des découpes par (personne, iso) et par session.
    par_doigt: dict[tuple[str, int], dict[str, int]] = defaultdict(dict)
    for i, e in enumerate(gardes):
        par_doigt[(e.personne, e.iso)][e.session] = i

    auth_doigt, imp_doigt = [], []
    for i, sonde in enumerate(gardes):
        for (personne, iso), sessions in par_doigt.items():
            autres = [j for s, j in sessions.items() if s != sonde.session]
            if len(autres) < k:
                continue
            authentique = personne == sonde.personne and iso == sonde.iso
            for combo in list(combinations(autres, k))[:MAX_COMBINAISONS]:
                meilleur = max(scores[i, j] for j in combo)
                (auth_doigt if authentique else imp_doigt).append(meilleur)

    # Main entière : sonde = 4 doigts d'une main d'une session.
    mains_sondes: dict[tuple[str, str, str], dict[int, int]] = defaultdict(dict)
    for i, e in enumerate(gardes):
        if e.doigt != 0:
            mains_sondes[(e.personne, e.session, e.main)][e.doigt] = i
    identites = {(e.personne, e.main) for e in gardes if e.doigt != 0}
    auth_main, imp_main = [], []
    for (personne, session, main), doigts_sonde in mains_sondes.items():
        for (personne_g, main_g) in identites:
            sessions_g = sorted(
                {e.session for e in gardes if e.personne == personne_g and e.main == main_g and e.session != session}
            )
            if len(sessions_g) < k:
                continue
            authentique = personne_g == personne and main_g == main
            for combo in list(combinations(sessions_g, k))[:MAX_COMBINAISONS]:
                total, communs = 0.0, 0
                for position, i in doigts_sonde.items():
                    iso_g = (1 if main_g == "droite" else 6) + position
                    candidats = [par_doigt[(personne_g, iso_g)].get(s) for s in combo]
                    candidats = [j for j in candidats if j is not None]
                    if candidats:
                        total += max(scores[i, j] for j in candidats)
                        communs += 1
                if communs >= 3:
                    (auth_main if authentique else imp_main).append(total)
    return (auth_doigt, imp_doigt), (auth_main, imp_main)


def _pc(x):
    return "—" if x is None or x != x else f"{x * 100:.1f} %"


def _n(x, c=1):
    return "—" if x is None or x != x else f"{x:.{c}f}"


def ligne(k: int, s: Synthese | None) -> str:
    if s is None:
        return f"| {k} | — | — | — | — | — | — | — |"
    return (
        f"| {k} | {s.nb_authentiques} | {s.nb_imposteurs} | {_pc(s.eer)} | {_n(s.separation_d_prime, 2)} | "
        f"{_n(s.authentique_mediane)} | {_n(s.imposteur_max)} | {_pc(s.fnmr_a_fmr_1pc)} |"
    )


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--captures", type=Path, required=True)
    p.add_argument("--sortie", type=Path, required=True)
    p.add_argument("--variante", default="simple_inverse")
    p.add_argument("--nettete-min", type=float, default=None)
    p.add_argument("--multi-echelle", action="store_true")
    p.add_argument("--kmax", type=int, default=3)
    args = p.parse_args()

    echantillons = collecter(args.captures, {}, "P01")
    if args.nettete_min is not None:
        echantillons = [e for e in echantillons if e.nettete is not None and e.nettete >= args.nettete_min]
    variante = next(v for v in VARIANTES if v.nom == args.variante)
    print(f"{len(echantillons)} découpes, {len({e.session for e in echantillons})} sessions, variante {variante.nom}")
    r = evaluer_variante(echantillons, variante, ClientMatcher(), multi_echelle=args.multi_echelle)

    lignes_doigt, lignes_main = [], []
    for k in range(1, args.kmax + 1):
        (ad, idoigt), (am, im) = simuler(r.matrice, r.gardes, k)
        sd = synthese(ad, idoigt) if ad and idoigt else None
        sm = synthese(am, im) if am and im else None
        lignes_doigt.append(ligne(k, sd))
        lignes_main.append(ligne(k, sm))
        print(f"k={k} : doigt EER {_pc(sd.eer if sd else None)} d' {_n(sd.separation_d_prime if sd else None, 2)}"
              f" | main EER {_pc(sm.eer if sm else None)} d' {_n(sm.separation_d_prime if sm else None, 2)}")

    entete = "| Captures à l'enregistrement | Authentiques | Imposteurs | EER | d' | Médiane authentique | Max imposteur | FNMR à FMR 1 % |\n|---|---|---|---|---|---|---|---|"
    texte = "\n".join([
        "# Simulation : plusieurs captures par doigt à l'enregistrement",
        "",
        f"> Généré le {date.today():%d/%m/%Y}. Prototype non officiel. Une seule personne : indicatif seulement.",
        "",
        f"- Découpes : {len(r.gardes)} ({len({e.session for e in r.gardes})} sessions)",
        f"- Variante de prétraitement : `{variante.nom}`" + (" ; comparaison multi-échelle" if args.multi_echelle else ""),
        "- Filtre : " + (f"netteté ≥ {args.nettete_min}" if args.nettete_min is not None else "aucun"),
        "",
        "Chaque session joue la nouvelle capture ; k autres sessions jouent l'enregistrement ; "
        "on garde le meilleur score des k.",
        "",
        "## Doigt par doigt",
        "",
        entete,
        *lignes_doigt,
        "",
        "## Main entière (4 doigts, meilleur des k par doigt, puis somme)",
        "",
        entete,
        *lignes_main,
        "",
        "Les paires d'une simulation à k captures ne sont pas indépendantes (combinaisons) : "
        "les effectifs surestiment la précision.",
    ])
    args.sortie.mkdir(parents=True, exist_ok=True)
    (args.sortie / "rapport.md").write_text(texte + "\n", encoding="utf-8")
    print(f"Rapport : {args.sortie / 'rapport.md'}")


if __name__ == "__main__":
    main()
