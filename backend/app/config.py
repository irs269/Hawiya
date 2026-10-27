"""Paramètres de l'application, lus depuis les variables d'environnement (.env)."""

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Parametres(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str
    test_database_url: str | None = None

    jwt_secret: str
    jwt_algorithme: str = "HS256"
    # Jeton d'accès court ; le jeton de renouvellement permet d'en obtenir un autre.
    jwt_duree_minutes: int = 15
    renouvellement_duree_jours: int = 30

    # Blocage après des mots de passe faux consécutifs.
    connexion_echecs_max: int = 5
    connexion_blocage_minutes: int = 15
    mot_de_passe_longueur_min: int = 10

    # Fuseau utilisé pour l'année du numéro et les statistiques « du jour ».
    fuseau_horaire: str = "Indian/Comoro"

    # Agent de démonstration créé par le script de données fictives.
    seed_agent_matricule: str = "AG-0001"
    seed_agent_mot_de_passe: str | None = None

    @field_validator("jwt_secret")
    @classmethod
    def secret_assez_long(cls, valeur: str) -> str:
        if len(valeur) < 32:
            raise ValueError("JWT_SECRET doit contenir au moins 32 caractères")
        return valeur


parametres = Parametres()
