"""Numéro d'identification Hawiya.

FORMAT PROVISOIRE : KM-AAAA-NNNNNN-L
  - KM     : préfixe pays
  - AAAA   : année d'enregistrement
  - NNNNNN : séquence de l'année (000001 à 999999)
  - L      : lettre de contrôle = (AAAANNNNNN modulo 23) dans LETTRES_CONTROLE

C'est le SEUL endroit du code qui connaît ce format : quand l'État donnera le
format officiel, il suffira de modifier ce fichier (et ses tests).

La lettre de contrôle détecte toute erreur sur un seul chiffre et toute
inversion de deux chiffres voisins (23 est premier et ne divise ni 10^k ni 9·10^k).
"""

import re
from datetime import datetime
from zoneinfo import ZoneInfo

from sqlalchemy import text
from sqlalchemy.orm import Session

from app.config import parametres

PREFIXE = "KM"
LETTRES_CONTROLE = "TRWAGMYFPDXBNJZSQVHLCKE"  # 23 lettres
SEQUENCE_MAX = 999_999
LONGUEUR_MAX = 20  # doit tenir dans citoyens.numero

_MOTIF = re.compile(rf"^{PREFIXE}-(\d{{4}})-(\d{{6}})-([A-Z])$")


def lettre_controle(annee: int, sequence: int) -> str:
    return LETTRES_CONTROLE[int(f"{annee:04d}{sequence:06d}") % 23]


def formater_numero(annee: int, sequence: int) -> str:
    if not 1 <= sequence <= SEQUENCE_MAX:
        raise ValueError(f"Séquence hors limites pour l'année {annee} : {sequence}")
    return f"{PREFIXE}-{annee:04d}-{sequence:06d}-{lettre_controle(annee, sequence)}"


def est_numero_valide(numero: str) -> bool:
    """Vérifie le format ET la lettre de contrôle."""
    correspondance = _MOTIF.match(numero)
    if not correspondance:
        return False
    annee, sequence, lettre = correspondance.groups()
    return int(sequence) >= 1 and lettre == lettre_controle(int(annee), int(sequence))


def normaliser_numero(saisie: str) -> str:
    """Majuscules et suppression des espaces (saisie manuelle par un agent)."""
    return saisie.strip().upper().replace(" ", "")


def annee_courante() -> int:
    return datetime.now(ZoneInfo(parametres.fuseau_horaire)).year


def prochaine_sequence(db: Session, annee: int) -> int:
    """Réserve la séquence suivante de l'année, de façon atomique.

    L'UPSERT verrouille la ligne de l'année jusqu'à la fin de la transaction :
    deux créations simultanées obtiennent forcément deux séquences différentes.
    Si la transaction est annulée, la séquence est libérée (pas de trou).
    """
    return db.execute(
        text(
            """
            INSERT INTO compteurs_numero (annee, dernier) VALUES (:annee, 1)
            ON CONFLICT (annee) DO UPDATE SET dernier = compteurs_numero.dernier + 1
            RETURNING dernier
            """
        ),
        {"annee": annee},
    ).scalar_one()


def attribuer_numero(db: Session, annee: int | None = None) -> str:
    """Attribue un nouveau numéro dans la transaction en cours (à valider par commit)."""
    annee = annee or annee_courante()
    return formater_numero(annee, prochaine_sequence(db, annee))
