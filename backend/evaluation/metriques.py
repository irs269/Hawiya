"""Mesures de fiabilité d'un système biométrique, à partir de scores.

Vocabulaire :
  - paire authentique : deux captures du MÊME doigt (de la même personne) ;
  - paire imposteur   : deux doigts DIFFÉRENTS (autre doigt ou autre personne) ;
  - FMR (taux de fausses correspondances) : part des paires imposteur acceptées ;
  - FNMR (taux de refus à tort)            : part des paires authentiques refusées ;
  - EER (taux d'égale erreur)              : point où FMR = FNMR.
Une paire est « acceptée » si son score est ≥ au seuil.
"""

from dataclasses import dataclass

import numpy as np


def fmr(imposteurs: np.ndarray, seuil: float) -> float:
    return float(np.mean(imposteurs >= seuil)) if len(imposteurs) else float("nan")


def fnmr(authentiques: np.ndarray, seuil: float) -> float:
    return float(np.mean(authentiques < seuil)) if len(authentiques) else float("nan")


def seuils_candidats(authentiques: np.ndarray, imposteurs: np.ndarray) -> np.ndarray:
    """Tous les seuils où l'une des deux courbes change, plus un seuil au-dessus de tout."""
    valeurs = np.unique(np.concatenate([authentiques, imposteurs]))
    return np.concatenate([valeurs, [valeurs.max() + 1 if len(valeurs) else 1.0]])


def eer(authentiques: np.ndarray, imposteurs: np.ndarray) -> tuple[float, float]:
    """(EER, seuil correspondant). Au seuil où |FMR − FNMR| est minimal."""
    meilleur = (float("inf"), 0.0, 0.0)
    for s in seuils_candidats(authentiques, imposteurs):
        a, b = fmr(imposteurs, s), fnmr(authentiques, s)
        if abs(a - b) < meilleur[0]:
            meilleur = (abs(a - b), (a + b) / 2, float(s))
    return meilleur[1], meilleur[2]


def seuil_pour_fmr(authentiques: np.ndarray, imposteurs: np.ndarray, fmr_cible: float) -> tuple[float, float, float]:
    """Plus petit seuil dont le FMR ≤ cible → (seuil, FMR obtenu, FNMR à ce seuil)."""
    for s in seuils_candidats(authentiques, imposteurs):
        taux = fmr(imposteurs, s)
        if taux <= fmr_cible:
            return float(s), taux, fnmr(authentiques, s)
    raise ValueError("Aucun seuil possible")


def courbe_det(authentiques: np.ndarray, imposteurs: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """(seuils, FMR, FNMR) pour tracer la courbe DET."""
    seuils = seuils_candidats(authentiques, imposteurs)
    return (
        seuils,
        np.array([fmr(imposteurs, s) for s in seuils]),
        np.array([fnmr(authentiques, s) for s in seuils]),
    )


def plus_petit_fmr_mesurable(nb_imposteurs: int) -> float:
    """Avec N paires imposteur, on ne peut pas affirmer un FMR inférieur à ≈ 3/N
    (règle des 3, intervalle de confiance à 95 % quand aucune erreur n'est vue)."""
    return 3.0 / nb_imposteurs if nb_imposteurs else float("nan")


@dataclass
class Synthese:
    nb_authentiques: int
    nb_imposteurs: int
    eer: float
    seuil_eer: float
    authentique_mediane: float
    imposteur_max: float
    imposteur_p99: float
    separation_d_prime: float
    seuil_fmr_1pc: float | None
    fnmr_a_fmr_1pc: float | None
    fmr_mesurable_min: float


def synthese(authentiques, imposteurs) -> Synthese:
    a = np.asarray(authentiques, dtype=float)
    i = np.asarray(imposteurs, dtype=float)
    taux, seuil = eer(a, i)
    # d' : écart des moyennes rapporté à la dispersion (> 3 = bien séparés).
    d_prime = abs(a.mean() - i.mean()) / np.sqrt((a.var() + i.var()) / 2) if len(a) and len(i) else float("nan")
    try:
        s1, _, f1 = seuil_pour_fmr(a, i, 0.01)
    except ValueError:
        s1, f1 = None, None
    return Synthese(
        nb_authentiques=len(a),
        nb_imposteurs=len(i),
        eer=taux,
        seuil_eer=seuil,
        authentique_mediane=float(np.median(a)) if len(a) else float("nan"),
        imposteur_max=float(i.max()) if len(i) else float("nan"),
        imposteur_p99=float(np.percentile(i, 99)) if len(i) else float("nan"),
        separation_d_prime=float(d_prime),
        seuil_fmr_1pc=s1,
        fnmr_a_fmr_1pc=f1,
        fmr_mesurable_min=plus_petit_fmr_mesurable(len(i)),
    )


def rang1(sondes: list[tuple[str, dict[str, float]]]) -> float:
    """Identification en ensemble fermé : pour chaque sonde, (identité vraie,
    {identité candidate: score}). Part des sondes dont le meilleur candidat est la vraie identité."""
    if not sondes:
        return float("nan")
    bons = sum(1 for vraie, scores in sondes if scores and max(scores, key=scores.get) == vraie)
    return bons / len(sondes)
