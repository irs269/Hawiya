"""Enchaînement biométrique : découpes de doigts → modèles → matcher → décision.

Les photos des doigts ne servent qu'à calculer les modèles : elles ne sont
JAMAIS enregistrées (seuls les modèles le sont, voir models.Empreinte).
"""

import cv2

from app.biometrie.client_matcher import Candidat
from app.biometrie.decision import (
    Decision,
    DecisionDoublon,
    Seuils,
    combiner_scans,
    decider_apres_plusieurs_scans,
    decider_doublon,
)
from app.biometrie.pretraitement import VARIANTES, decoder_image, encoder_png, pretraiter

# Variante retenue sur les mesures du 01/10/2026 (meilleur EER, comparaison
# multi-échelle). Le déroulage (levier 3) n'est pas activé tant qu'il n'est pas mesuré.
VARIANTE_PRODUCTION = next(v for v in VARIANTES if v.nom == "simple_inverse")

# SourceAFIS perd la correspondance dès ~10 % d'erreur d'échelle : la sonde est
# comparée à plusieurs échelles, on garde le meilleur score par doigt (comme
# l'outil d'évaluation, dont viennent les seuils de décision). 1.0 en premier :
# c'est le modèle enregistré à l'enrôlement.
ECHELLES_SONDE = [1.0, 0.85, 0.9, 0.95, 1.05, 1.1, 1.15]

# Nombre de candidats demandés au matcher à chaque comparaison : assez pour que
# la décision voie si un autre candidat s'approche.
LIMITE_CANDIDATS = 10


class DoigtIllisible(ValueError):
    """Une découpe n'a pas pu être transformée en modèle."""


def modeles_multi_echelle(client, image: bytes, dpi: float, echelles=ECHELLES_SONDE) -> tuple[list[bytes], str]:
    """Une découpe → un modèle par échelle (le premier à l'échelle 1) et la version du moteur."""
    try:
        resultat = pretraiter(decoder_image(image), dpi, VARIANTE_PRODUCTION)
    except Exception as erreur:
        raise DoigtIllisible(str(erreur)) from erreur
    modeles, version = [], ""
    h, w = resultat.image.shape
    for facteur in echelles:
        img = resultat.image
        if facteur != 1.0:
            img = cv2.resize(img, (round(w * facteur), round(h * facteur)), interpolation=cv2.INTER_LINEAR)
        modele, version = client.modele(encoder_png(img), resultat.dpi)
        modeles.append(modele)
    return modeles, version


def extraire(client, doigts: dict[int, tuple[bytes, float]], echelles=ECHELLES_SONDE) -> tuple[dict[int, list[bytes]], str, list[int]]:
    """Toutes les découpes d'un scan → (modèles par doigt, version, doigts illisibles).
    Un doigt illisible est écarté : la décision en tient compte (doigts exploitables)."""
    modeles: dict[int, list[bytes]] = {}
    illisibles: list[int] = []
    version = ""
    for iso, (image, dpi) in sorted(doigts.items()):
        try:
            modeles[iso], version = modeles_multi_echelle(client, image, dpi, echelles)
        except DoigtIllisible:
            illisibles.append(iso)
    return modeles, version, illisibles


def rechercher(client, modeles: dict[int, list[bytes]], exclure: str | None = None) -> list[Candidat]:
    """Compare un scan à toute la base, à chaque échelle, et garde le meilleur
    score de chaque doigt pour chaque candidat. `exclure` : identifiant à ignorer
    (la personne elle-même quand on remplace ses empreintes)."""
    if not modeles:
        return []
    nb_echelles = len(next(iter(modeles.values())))
    par_echelle = []
    for k in range(nb_echelles):
        candidats = client.identifier({iso: m[k] for iso, m in modeles.items()}, limite=LIMITE_CANDIDATS)
        par_echelle.append([c for c in candidats if c.id != exclure])
    return combiner_scans(par_echelle)


def identifier(client, scans: list[dict[int, list[bytes]]], seuils: Seuils = Seuils()) -> Decision:
    """Décision sur un ou plusieurs scans de la même main (modèles déjà extraits)."""
    resultats = [rechercher(client, modeles) for modeles in scans]
    doigts = len({iso for modeles in scans for iso in modeles})
    return decider_apres_plusieurs_scans(resultats, doigts, seuils)


def controler_doublon(
    client, modeles: dict[int, list[bytes]], exclure: str | None = None, seuils: Seuils = Seuils()
) -> DecisionDoublon:
    return decider_doublon(rechercher(client, modeles, exclure), len(modeles), seuils)
