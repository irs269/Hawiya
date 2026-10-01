"""Prétraitement, sur des crêtes SYNTHÉTIQUES (aucune vraie empreinte dans le dépôt)."""

import numpy as np
import pytest

from app.biometrie.pretraitement import (
    DPI_SORTIE,
    PERIODE_SORTIE_PX,
    VARIANTES,
    Variante,
    decoder_image,
    encoder_png,
    masque_doigt,
    mesurer_periode,
    pretraiter,
)


def cretes(periode: float, largeur=300, hauteur=400, angle=0.4, claires=True) -> np.ndarray:
    """Fausse découpe couleur : crêtes sinusoïdales sur un fond « peau »."""
    yy, xx = np.indices((hauteur, largeur))
    t = (xx * np.cos(angle) + yy * np.sin(angle)) * 2 * np.pi / periode
    signe = 1 if claires else -1
    gris = 140 + signe * 35 * np.sin(t)
    image = np.stack([gris * 0.8, gris * 0.9, gris], axis=-1)
    return np.clip(image, 0, 255).astype(np.uint8)


@pytest.mark.parametrize("periode", [7.5, 10.0, 12.5])
def test_mesure_de_l_espacement_des_cretes(periode):
    gris = cretes(periode)[:, :, 1].astype(np.float32)
    mesure = mesurer_periode(gris, periode_attendue=10.0)
    assert mesure == pytest.approx(periode, rel=0.12)


def test_mesure_non_trompee_par_une_basse_frequence():
    """Cas réel (S23 Ultra) : un pli ou la courbure du doigt, très contrasté,
    faisait mesurer 12,8 px au lieu d'environ 8."""
    yy, xx = np.indices((400, 300))
    cretes_fines = 15 * np.sin(2 * np.pi * (xx * 0.9 + yy * 0.4) / 8.0)
    pli = 60 * np.sin(2 * np.pi * yy / 13.0)
    mesure = mesurer_periode((128 + cretes_fines + pli).astype(np.float32), periode_attendue=8.5)
    assert mesure == pytest.approx(8.0, rel=0.12)


def test_pas_de_pic_sur_une_image_uniforme():
    assert mesurer_periode(np.full((300, 300), 128, np.float32), 10.0) is None


def test_mise_a_l_echelle_par_les_cretes():
    # Crêtes de 12 px dans la découpe → ramenées à ≈ 8,9 px (500 dpi).
    resultat = pretraiter(cretes(12.0), dpi_estime=600)
    assert resultat.dpi == DPI_SORTIE
    assert resultat.periode_mesuree_px == pytest.approx(12.0, rel=0.12)
    assert resultat.facteur_echelle == pytest.approx(PERIODE_SORTIE_PX / 12.0, rel=0.12)
    assert resultat.image.dtype == np.uint8
    assert resultat.image.shape[1] == round(300 * resultat.facteur_echelle)


def test_mise_a_l_echelle_par_la_largeur_supposee():
    variante = Variante("largeur", echelle="largeur")
    resultat = pretraiter(cretes(12.0), dpi_estime=1000, variante=variante)
    assert resultat.facteur_echelle == pytest.approx(0.5)


def test_fond_blanc_hors_du_doigt():
    image = pretraiter(cretes(10.0), dpi_estime=550).image
    assert image[0, 0] == 255  # coin supérieur gauche : hors du doigt
    assert image[-1, 0] == 255


@pytest.mark.parametrize("variante", VARIANTES, ids=lambda v: v.nom)
def test_toutes_les_variantes_produisent_des_cretes(variante):
    image = pretraiter(cretes(10.0), dpi_estime=550, variante=variante).image
    h, w = image.shape
    pulpe = image[int(h * 0.35) : int(h * 0.6), int(w * 0.35) : int(w * 0.65)]
    assert pulpe.std() > 40  # crêtes bien contrastées


def test_polarite_inversee():
    """Crêtes claires sur la photo → sombres après inversion (au même endroit)."""
    source = cretes(10.0, claires=True)
    direct = pretraiter(source, 550, Variante("d", gabor=False, inverser=False)).image.astype(int)
    inverse = pretraiter(source, 550, Variante("i", gabor=False, inverser=True)).image.astype(int)
    h, w = direct.shape
    zone = (slice(int(h * 0.4), int(h * 0.6)), slice(int(w * 0.4), int(w * 0.6)))
    correlation = np.corrcoef(direct[zone].ravel(), inverse[zone].ravel())[0, 1]
    assert correlation < -0.9


def test_masque_en_forme_de_doigt():
    m = masque_doigt(400, 300)
    assert m[200, 150] and not m[0, 0] and not m[200, 5]


def test_png_aller_retour():
    image = cretes(10.0)
    assert decoder_image(encoder_png(image)).shape == image.shape
    with pytest.raises(ValueError):
        decoder_image(b"pas une image")
