"""Prétraitement, sur des crêtes SYNTHÉTIQUES (aucune vraie empreinte dans le dépôt)."""

import numpy as np
import pytest

from app.biometrie.pretraitement import (
    DPI_SORTIE,
    PERIODE_SORTIE_PX,
    VARIANTES,
    Variante,
    bords_par_ligne,
    decoder_image,
    derouler,
    encoder_png,
    masque_doigt,
    mesurer_periode,
    niveaux_de_gris,
    pretraiter,
    silhouette_doigt,
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


# --- Levier 3 : déroulage cylindrique (doigt SYNTHÉTIQUE) ---


def doigt_cylindrique(periode=10.0, rayon=110, largeur=300, hauteur=400, inclinaison=0.0) -> np.ndarray:
    """Fausse découpe : crêtes verticales régulières (espacement `periode` sur la
    peau à plat) enroulées sur un cylindre vu de dessus, doigt clair sur fond
    sombre comme sous le flash. `inclinaison` : décalage horizontal de l'axe
    (pixels par ligne)."""
    yy, xx = np.indices((hauteur, largeur)).astype(np.float64)
    centre = largeur / 2 + inclinaison * (yy - hauteur / 2)
    sinus = (xx - centre) / rayon
    dedans = np.abs(sinus) < 1
    arc = rayon * np.arcsin(np.clip(sinus, -1, 1))  # position sur la peau à plat
    gris = np.where(dedans, 150 + 35 * np.sin(2 * np.pi * arc / periode), 40)
    image = np.stack([gris * 0.8, gris * 0.9, gris], axis=-1)
    return np.clip(image, 0, 255).astype(np.uint8)


def periode_locale(ligne: np.ndarray) -> float:
    """Espacement moyen des crêtes sur un bout de ligne (passages par la moyenne)."""
    signe = np.sign(ligne - ligne.mean())
    passages = np.flatnonzero(np.diff(signe) != 0)
    return float(2 * (passages[-1] - passages[0]) / (len(passages) - 1))


def test_silhouette_trouvee_sur_un_doigt_clair():
    image = doigt_cylindrique(rayon=120)
    contour = silhouette_doigt(niveaux_de_gris(image, "luminance"))
    assert contour is not None
    _, demi = bords_par_ligne(contour)
    assert np.median(demi) == pytest.approx(120, rel=0.08)


def test_pas_de_silhouette_si_le_doigt_remplit_la_decoupe():
    assert silhouette_doigt(niveaux_de_gris(cretes(10.0), "luminance")) is None


def test_le_deroulage_rend_l_espacement_homogene():
    """Sur la photo, à 50° du sommet, les crêtes sont comprimées (× cos 50° ≈ 0,64) ;
    après déroulage, elles retrouvent l'espacement du centre."""
    periode, rayon = 10.0, 110
    gris = niveaux_de_gris(doigt_cylindrique(periode, rayon), "luminance")
    contour = silhouette_doigt(gris)
    deroule, masque = derouler(gris, contour, contour)
    ligne_photo, ligne_deroulee = gris[300], deroule[300]

    bord_photo = 150 + int(rayon * np.sin(np.deg2rad(50)))
    assert periode_locale(ligne_photo[bord_photo - 10 : bord_photo + 10]) < 0.75 * periode

    marge = (deroule.shape[1] - gris.shape[1]) // 2
    centre = 150 + marge
    bord_deroule = centre + int(rayon * np.deg2rad(50))
    assert periode_locale(ligne_deroulee[centre - 20 : centre + 20]) == pytest.approx(periode, rel=0.1)
    assert periode_locale(ligne_deroulee[bord_deroule - 20 : bord_deroule + 20]) == pytest.approx(periode, rel=0.1)
    # Au-delà de 65°, la peau est masquée.
    assert not masque[300, centre + int(rayon * np.deg2rad(75))]
    assert masque[300, bord_deroule]


def test_deroulage_d_un_doigt_incline():
    image = doigt_cylindrique(inclinaison=0.05)
    resultat = pretraiter(image, dpi_estime=550, variante=Variante("d", deroulage=True))
    assert resultat.deroulage == "silhouette"
    h, w = resultat.image.shape
    pulpe = resultat.image[int(h * 0.4) : int(h * 0.6), int(w * 0.4) : int(w * 0.6)]
    assert pulpe.std() > 40


def test_deroulage_sans_silhouette_utilise_la_largeur_supposee():
    resultat = pretraiter(cretes(10.0), dpi_estime=550, variante=Variante("d", deroulage=True))
    assert resultat.deroulage == "supposee"
    # La sortie est plus large que sans déroulage (bords « dépliés »).
    sans = pretraiter(cretes(10.0), dpi_estime=550, variante=Variante("s"))
    assert resultat.image.shape[1] > sans.image.shape[1]
    assert resultat.image.shape[0] == sans.image.shape[0]


def test_deroulage_sans_contour_ne_change_rien():
    gris = np.full((100, 80), 128, np.float32)
    vide = np.zeros((100, 80), bool)
    sortie, masque = derouler(gris, vide, vide)
    assert sortie.shape == gris.shape and not masque.any()


def test_variante_sans_deroulage_inchangee():
    assert pretraiter(cretes(10.0), dpi_estime=550).deroulage is None
