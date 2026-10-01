"""Transforme une photo de bout de doigt (découpe du téléphone) en image
comparable à une empreinte de scanner, pour SourceAFIS :
niveaux de gris, crêtes SOMBRES sur fond clair, environ 500 dpi.

Chaque étape est réglable par une « variante » : l'outil d'évaluation compare
les variantes et retient la meilleure SUR LES MESURES, pas au jugé.

Étapes :
  1. niveaux de gris (luminance ou canal vert) ;
  2. masque du doigt (le fond est neutralisé) ;
  3. correction de l'éclairage + CLAHE ;
  4. mesure de l'espacement réel des crêtes (spectre de Fourier) et mise à
     l'échelle pour qu'il vaille celui d'une empreinte à 500 dpi ;
  5. renforcement des crêtes (filtres de Gabor orientés), facultatif ;
  6. polarité : crêtes sombres. Sur une photo au flash, le haut des crêtes
     brille : il faut en général inverser.
"""

from dataclasses import dataclass

import cv2
import numpy as np

DPI_SORTIE = 500
ECART_CRETES_MM = 0.45
# Espacement des crêtes attendu dans l'image de sortie (≈ 8,9 px).
PERIODE_SORTIE_PX = ECART_CRETES_MM / 25.4 * DPI_SORTIE


@dataclass(frozen=True)
class Variante:
    nom: str
    canal: str = "luminance"  # « luminance » ou « vert »
    clahe: bool = True
    gabor: bool = True
    inverser: bool = True  # vrai = les crêtes claires de la photo deviennent sombres
    echelle: str = "cretes"  # « cretes » (espacement mesuré) ou « largeur » (doigt de 18 mm)


# Variantes évaluées par défaut (la première est la référence).
VARIANTES = [
    Variante("gabor_inverse"),
    Variante("gabor_direct", inverser=False),
    Variante("simple_inverse", gabor=False),
    Variante("simple_direct", gabor=False, inverser=False),
    Variante("gabor_inverse_vert", canal="vert"),
    Variante("gabor_inverse_largeur", echelle="largeur"),
]


@dataclass
class Resultat:
    image: np.ndarray  # uint8, crêtes sombres, ≈ 500 dpi
    dpi: int
    periode_mesuree_px: float | None  # dans la découpe d'origine
    facteur_echelle: float


def niveaux_de_gris(image_bgr: np.ndarray, canal: str) -> np.ndarray:
    if image_bgr.ndim == 2:
        return image_bgr.astype(np.float32)
    if canal == "vert":
        return image_bgr[:, :, 1].astype(np.float32)
    return cv2.cvtColor(image_bgr, cv2.COLOR_BGR2GRAY).astype(np.float32)


def masque_doigt(hauteur: int, largeur: int) -> np.ndarray:
    """Masque géométrique : la découpe du téléphone centre le doigt (bout en haut),
    avec 15 % de marge. On garde un « U » renversé : rectangle + demi-ellipse en haut."""
    masque = np.zeros((hauteur, largeur), np.uint8)
    demi_largeur = int(largeur * 0.41)
    cx = largeur // 2
    haut_arrondi = int(hauteur * 0.08) + demi_largeur
    cv2.rectangle(masque, (cx - demi_largeur, haut_arrondi), (cx + demi_largeur, hauteur - 1), 255, -1)
    cv2.ellipse(masque, (cx, haut_arrondi), (demi_largeur, demi_largeur), 0, 180, 360, 255, -1)
    return masque > 0


def mesurer_periode(gris: np.ndarray, periode_attendue: float) -> float | None:
    """Espacement dominant des crêtes (pixels), par le pic du spectre de Fourier.

    - Le spectre d'une photo est dominé par les basses fréquences (courbure,
      plis, bords) : on le « blanchit » en multipliant la puissance par la
      fréquence au carré, sinon le pic tombe sur un pli (constaté : 12,8 px
      mesurés au lieu d'environ 8).
    - On ne cherche que dans ±35 % de l'espacement attendu d'après le dpi
      estimé : la mesure affine l'estimation, elle ne la remplace pas.
    None si aucun pic net.
    """
    h, w = gris.shape
    # Zone centrale de la pulpe, carrée, en puissance de 2 pour la FFT.
    cote = 1 << int(np.log2(min(h, w) * 0.6))
    if cote < 32:
        return None
    y0 = int(h * 0.45) - cote // 2
    x0 = w // 2 - cote // 2
    y0 = max(0, min(y0, h - cote))
    zone = gris[y0 : y0 + cote, x0 : x0 + cote]
    if zone.std() < 1.0:  # image quasi uniforme : aucune crête à mesurer
        return None
    zone = zone - zone.mean()
    fenetre = np.outer(np.hanning(cote), np.hanning(cote))
    spectre = np.abs(np.fft.fftshift(np.fft.fft2(zone * fenetre))) ** 2

    yy, xx = np.indices(spectre.shape)
    rayon = np.hypot(yy - cote / 2, xx - cote / 2)  # en cycles par « cote » pixels
    r_min = cote / (periode_attendue * 1.35)
    r_max = cote / (periode_attendue * 0.65)
    rayons_entiers = np.round(rayon).astype(int)
    puissance = np.bincount(rayons_entiers.ravel(), weights=spectre.ravel())
    nombre = np.bincount(rayons_entiers.ravel())
    profil = puissance / np.maximum(nombre, 1)
    profil = profil * np.arange(len(profil)) ** 2  # blanchiment (voir ci-dessus)
    bande = np.arange(int(np.ceil(r_min)), int(np.floor(r_max)) + 1)
    bande = bande[bande < len(profil)]
    if len(bande) < 2:
        return None
    pic = bande[np.argmax(profil[bande])]
    # Pic net : nettement au-dessus du reste du spectre (hors basses fréquences).
    reference = np.median(profil[int(cote / (periode_attendue * 3)) : cote // 2])
    if profil[pic] < 2.0 * reference:
        return None
    return float(cote / pic)


def masque_cretes(gris: np.ndarray, masque_geometrique: np.ndarray, periode: float) -> np.ndarray:
    """Zone où il y a réellement des crêtes : énergie d'un passe-bande réglé sur
    l'espacement des crêtes, lissée, seuillée (Otsu), dans le masque géométrique.
    Retire le fond resté dans la découpe et le bord du doigt (faux contour →
    fausses minuties)."""
    fin = cv2.GaussianBlur(gris, (0, 0), sigmaX=periode / 6)
    large = cv2.GaussianBlur(gris, (0, 0), sigmaX=periode / 3)
    energie = cv2.GaussianBlur((fin - large) ** 2, (0, 0), sigmaX=periode * 1.5)
    energie[~masque_geometrique] = 0
    valeurs = energie[masque_geometrique]
    if valeurs.size == 0 or valeurs.max() <= 0:
        return masque_geometrique
    echelle = np.clip(energie / np.percentile(valeurs, 99) * 255, 0, 255).astype(np.uint8)
    seuil, _ = cv2.threshold(echelle[masque_geometrique], 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    masque = (echelle > seuil * 0.6) & masque_geometrique
    # Plus grande zone d'un seul tenant, sans trous.
    nb, etiquettes, stats, _ = cv2.connectedComponentsWithStats(masque.astype(np.uint8))
    if nb <= 1:
        return masque_geometrique
    principale = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    masque = (etiquettes == principale).astype(np.uint8)
    noyau = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (int(periode * 3) | 1, int(periode * 3) | 1))
    masque = cv2.morphologyEx(masque, cv2.MORPH_CLOSE, noyau)
    return masque > 0


def champ_orientation(image: np.ndarray, bloc: int = 16) -> np.ndarray:
    """Orientation des crêtes en chaque pixel (radians), par le tenseur de structure."""
    gx = cv2.Sobel(image, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(image, cv2.CV_32F, 0, 1, ksize=3)
    gxx = cv2.boxFilter(gx * gx, -1, (bloc, bloc))
    gyy = cv2.boxFilter(gy * gy, -1, (bloc, bloc))
    gxy = cv2.boxFilter(gx * gy, -1, (bloc, bloc))
    # Direction du gradient dominant, puis + 90° : direction des crêtes.
    return 0.5 * np.arctan2(2 * gxy, gxx - gyy) + np.pi / 2


def renforcer_gabor(image: np.ndarray, periode: float, nb_orientations: int = 16) -> np.ndarray:
    """Filtre chaque pixel par le filtre de Gabor orienté comme les crêtes locales."""
    orientation = champ_orientation(image)
    indice = np.round((orientation % np.pi) / np.pi * nb_orientations).astype(int) % nb_orientations
    sigma = periode * 0.5
    taille = int(6 * sigma) | 1
    sortie = np.zeros_like(image)
    for k in range(nb_orientations):
        theta = k * np.pi / nb_orientations
        # OpenCV : theta = orientation de la normale aux bandes → normale aux crêtes.
        noyau = cv2.getGaborKernel((taille, taille), sigma, theta + np.pi / 2, periode, 1.0, 0, cv2.CV_32F)
        noyau -= noyau.mean()  # pas de réponse à une zone uniforme
        reponse = cv2.filter2D(image, cv2.CV_32F, noyau)
        sortie[indice == k] = reponse[indice == k]
    return sortie


def normaliser(image: np.ndarray, masque: np.ndarray) -> np.ndarray:
    """Étire les valeurs du doigt sur 0..255 (1er et 99e centiles)."""
    valeurs = image[masque]
    bas, haut = np.percentile(valeurs, [1, 99]) if valeurs.size else (0, 1)
    etire = (image - bas) / max(haut - bas, 1e-6) * 255
    return np.clip(etire, 0, 255)


def pretraiter(image_bgr: np.ndarray, dpi_estime: float, variante: Variante = VARIANTES[0]) -> Resultat:
    gris = niveaux_de_gris(image_bgr, variante.canal)
    h, w = gris.shape
    masque = masque_doigt(h, w)

    # 3. Éclairage : on retire les variations lentes (ombres, courbure du doigt).
    periode_estimee = ECART_CRETES_MM / 25.4 * dpi_estime
    fond = cv2.GaussianBlur(gris, (0, 0), sigmaX=max(2.0, 2 * periode_estimee))
    gris = gris - fond
    gris[~masque] = 0
    gris = normaliser(gris, masque)
    if variante.clahe:
        clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
        gris = clahe.apply(gris.astype(np.uint8)).astype(np.float32)

    # 4. Mise à l'échelle 500 dpi.
    periode = mesurer_periode(gris, periode_estimee)
    masque = masque_cretes(gris, masque, periode or periode_estimee)
    if variante.echelle == "cretes" and periode is not None:
        facteur = PERIODE_SORTIE_PX / periode
    else:
        facteur = DPI_SORTIE / dpi_estime
    taille = (max(16, round(w * facteur)), max(16, round(h * facteur)))
    gris = cv2.resize(gris, taille, interpolation=cv2.INTER_AREA if facteur < 1 else cv2.INTER_CUBIC)
    masque = cv2.resize(masque.astype(np.uint8), taille, interpolation=cv2.INTER_NEAREST) > 0
    # Le bord du masque crée un faux contour : on le rétrécit un peu.
    masque = cv2.erode(masque.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0

    # 5. Renforcement des crêtes.
    if variante.gabor:
        gris = renforcer_gabor(gris - gris[masque].mean(), PERIODE_SORTIE_PX)

    # 6. Polarité : crêtes sombres sur fond clair.
    gris = normaliser(gris, masque)
    if variante.inverser:
        gris = 255 - gris
    gris[~masque] = 255
    return Resultat(
        image=gris.astype(np.uint8),
        dpi=DPI_SORTIE,
        periode_mesuree_px=periode,
        facteur_echelle=facteur,
    )


def encoder_png(image: np.ndarray) -> bytes:
    ok, tampon = cv2.imencode(".png", image)
    if not ok:
        raise ValueError("Encodage PNG impossible")
    return tampon.tobytes()


def decoder_image(octets: bytes) -> np.ndarray:
    image = cv2.imdecode(np.frombuffer(octets, np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError("Image illisible")
    return image
