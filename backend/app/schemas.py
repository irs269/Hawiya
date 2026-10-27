"""Schémas Pydantic : validation des données reçues et forme des réponses."""

import re
import uuid
from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.referentiels import (
    COULEURS_CHEVEUX,
    COULEURS_YEUX,
    ILES,
    SEXES,
    TAILLE_MAX_CM,
    TAILLE_MIN_CM,
)

Ile = Literal[ILES]
Sexe = Literal[SEXES]
CouleurYeux = Literal[COULEURS_YEUX]
CouleurCheveux = Literal[COULEURS_CHEVEUX]

# Numéro comorien : +269 suivi de 7 chiffres.
_MOTIF_TELEPHONE = re.compile(r"^\+269\d{7}$")
DATE_NAISSANCE_MIN = date(1900, 1, 1)


class Jeton(BaseModel):
    access_token: str
    token_type: str = "bearer"


class CitoyenChamps(BaseModel):
    """Champs d'une fiche, communs à la création et à la lecture."""

    model_config = ConfigDict(str_strip_whitespace=True)

    # Identité
    nom: str = Field(min_length=1, max_length=100)
    prenoms: str = Field(min_length=1, max_length=150)
    sexe: Sexe
    date_naissance: date
    lieu_naissance: str = Field(min_length=1, max_length=150)
    nationalite: str = Field(default="Comorienne", min_length=1, max_length=100)
    numero_acte_naissance: str = Field(min_length=1, max_length=50)
    telephone: str | None = Field(default=None, examples=["+2693210000"])

    # Domicile
    ile: Ile
    ville: str = Field(min_length=1, max_length=100)
    quartier: str = Field(min_length=1, max_length=100)
    adresse: str = Field(min_length=1, max_length=255)

    # Signalement
    taille_cm: int = Field(ge=TAILLE_MIN_CM, le=TAILLE_MAX_CM)
    couleur_yeux: CouleurYeux
    couleur_cheveux: CouleurCheveux


class CitoyenCreation(CitoyenChamps):
    @field_validator("telephone")
    @classmethod
    def valider_telephone(cls, valeur: str | None) -> str | None:
        """Accepte « +269 321 00 00 », « 321-00-00 »… et stocke « +2693210000 »."""
        if valeur is None:
            return None
        nettoye = re.sub(r"[\s.\-()]", "", valeur)
        if not nettoye:
            return None
        if re.fullmatch(r"\d{7}", nettoye):
            nettoye = "+269" + nettoye
        elif nettoye.startswith("00269"):
            nettoye = "+" + nettoye[2:]
        if not _MOTIF_TELEPHONE.match(nettoye):
            raise ValueError("Téléphone invalide : attendu +269 suivi de 7 chiffres")
        return nettoye

    @field_validator("date_naissance")
    @classmethod
    def valider_date_naissance(cls, valeur: date) -> date:
        if valeur > date.today():
            raise ValueError("La date de naissance ne peut pas être dans le futur")
        if valeur < DATE_NAISSANCE_MIN:
            raise ValueError("Date de naissance trop ancienne")
        return valeur


class CitoyenLecture(CitoyenChamps):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    numero: str
    agent_id: uuid.UUID
    enregistre_le: datetime


class CitoyenResume(BaseModel):
    """Ligne d'une liste de résultats."""

    model_config = ConfigDict(from_attributes=True)

    numero: str
    nom: str
    prenoms: str
    sexe: Sexe
    date_naissance: date
    ile: Ile
    ville: str


class PageCitoyens(BaseModel):
    total: int
    page: int
    taille_page: int
    resultats: list[CitoyenResume]


class Statistiques(BaseModel):
    total_citoyens: int
    enregistres_aujourdhui: int
    par_ile: dict[str, int]
    par_sexe: dict[str, int]


# --- Biométrie ---

# Une découpe de doigt encodée en base64 (PNG ou JPEG) : ~2 Mo au plus.
TAILLE_MAX_IMAGE_B64 = 2_800_000


class DoigtImage(BaseModel):
    """Découpe d'un bout de doigt prise par le téléphone. Elle sert à calculer le
    modèle puis est oubliée : elle n'est jamais enregistrée."""

    doigt: int = Field(ge=1, le=10, description="ISO 19794 : 1 = pouce droit … 10 = auriculaire gauche")
    image: str = Field(min_length=16, max_length=TAILLE_MAX_IMAGE_B64, description="PNG ou JPEG en base64")
    dpi_estime: float = Field(ge=200, le=2000)


def _doigts_uniques(doigts: list[DoigtImage]) -> list[DoigtImage]:
    if len({d.doigt for d in doigts}) != len(doigts):
        raise ValueError("Un même doigt est présent deux fois")
    return doigts


class ScanMain(BaseModel):
    doigts: list[DoigtImage] = Field(min_length=1, max_length=10)

    _unicite = field_validator("doigts")(_doigts_uniques)


class DemandeIdentification(BaseModel):
    """Un scan, ou plusieurs scans de la même main (après un « non concluant »)."""

    scans: list[ScanMain] = Field(min_length=1, max_length=3)


class ReponseIdentification(BaseModel):
    verdict: Literal["identifie", "non_enregistre", "non_concluant"]
    motif: str
    doigts_compares: int
    doigts_concordants: int
    doigts_illisibles: list[int]
    citoyen: CitoyenLecture | None = None


class DemandeEmpreintes(BaseModel):
    doigts: list[DoigtImage] = Field(min_length=1, max_length=10)
    # Un superviseur peut passer outre un « doublon possible » après vérification.
    validation_superviseur: bool = False

    _unicite = field_validator("doigts")(_doigts_uniques)


class ReponseDoublon(BaseModel):
    verdict: Literal["doublon_certain", "doublon_possible", "aucun_doublon"]
    motif: str
    numeros: list[str] = []  # fiches à vérifier
    doigts_illisibles: list[int] = []


class ReponseEmpreintes(BaseModel):
    numero: str
    doigts_enregistres: list[int]
    doigts_illisibles: list[int]
    controle_doublon: ReponseDoublon
