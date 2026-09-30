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
