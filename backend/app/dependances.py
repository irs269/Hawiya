"""Dépendances FastAPI partagées : session de base et agent connecté."""

from typing import Annotated

from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from sqlalchemy.orm import Session

from app.db import get_db
from app.models import Agent
from app.securite import lire_jeton

# tokenUrl permet au bouton « Authorize » de /docs de se connecter directement.
schema_oauth2 = OAuth2PasswordBearer(tokenUrl="/auth/connexion")

SessionDb = Annotated[Session, Depends(get_db)]


def get_agent_courant(jeton: Annotated[str, Depends(schema_oauth2)], db: SessionDb) -> Agent:
    """Vérifie le jeton et que l'agent est toujours actif (à chaque requête)."""
    refus = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Session invalide ou expirée",
        headers={"WWW-Authenticate": "Bearer"},
    )
    agent_id = lire_jeton(jeton)
    if agent_id is None:
        raise refus
    agent = db.get(Agent, agent_id)
    if agent is None or agent.statut != "actif":
        raise refus
    return agent


AgentCourant = Annotated[Agent, Depends(get_agent_courant)]
