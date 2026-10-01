"""Mesures de fiabilité (valeurs calculables à la main)."""

import numpy as np
import pytest

from evaluation.metriques import eer, fmr, fnmr, plus_petit_fmr_mesurable, rang1, seuil_pour_fmr, synthese

AUTHENTIQUES = np.array([30.0, 50, 60, 80, 100])
IMPOSTEURS = np.array([2.0, 5, 8, 10, 12, 15, 20, 35, 3, 7])


def test_taux_a_un_seuil():
    assert fmr(IMPOSTEURS, 15) == pytest.approx(0.3)  # 15, 20, 35
    assert fnmr(AUTHENTIQUES, 15) == 0
    assert fnmr(AUTHENTIQUES, 55) == pytest.approx(0.4)  # 30, 50


def test_separation_parfaite():
    taux, seuil = eer(np.array([50.0, 60]), np.array([5.0, 10]))
    assert taux == 0
    assert 10 < seuil <= 50


def test_seuil_pour_un_fmr_cible():
    seuil, obtenu, refus = seuil_pour_fmr(AUTHENTIQUES, IMPOSTEURS, 0.10)
    assert seuil == 30  # plus petit seuil où seul l'imposteur à 35 passe → FMR 10 %
    assert obtenu == pytest.approx(0.1)
    assert refus == 0  # tous les authentiques (≥ 30) acceptés
    # FMR 0 % : il faut monter au-dessus de 35 → l'authentique à 30 est refusé.
    seuil0, _, refus0 = seuil_pour_fmr(AUTHENTIQUES, IMPOSTEURS, 0.0)
    assert seuil0 == 50
    assert refus0 == pytest.approx(0.2)


def test_synthese():
    s = synthese(AUTHENTIQUES, IMPOSTEURS)
    assert s.nb_authentiques == 5 and s.nb_imposteurs == 10
    assert s.imposteur_max == 35
    assert s.authentique_mediane == 60
    assert s.separation_d_prime > 2
    assert s.fmr_mesurable_min == pytest.approx(0.3)


def test_regle_des_trois():
    assert plus_petit_fmr_mesurable(3000) == pytest.approx(0.001)


def test_rang1():
    sondes = [
        ("A", {"A": 90, "B": 10}),
        ("B", {"A": 40, "B": 30}),  # erreur
        ("B", {"A": 5, "B": 70}),
    ]
    assert rang1(sondes) == pytest.approx(2 / 3)
