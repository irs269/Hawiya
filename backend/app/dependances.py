"""Dépendances FastAPI partagées : session de base, agent connecté, rôles."""

import uuid
from dataclasses import dataclass
from typing import Annotated

from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from sqlalchemy.orm import Session

from app.db import get_db
from app.models import Agent, Appareil
from app.securite import lire_jeton
from app.sessions import famille_active

# tokenUrl permet au bouton « Authorize » de /docs de se connecter directement
# (champ client_id = identifiant de l'appareil).
schema_oauth2 = OAuth2PasswordBearer(tokenUrl="/auth/connexion")

SessionDb = Annotated[Session, Depends(get_db)]


@dataclass
class Contexte:
    """Agent connecté, avec l'appareil et la famille de session du jeton."""

    agent: Agent
    appareil_id: uuid.UUID
    famille: uuid.UUID


def get_contexte_provisoire(jeton: Annotated[str, Depends(schema_oauth2)], db: SessionDb) -> Contexte:
    """Vérifie le jeton à CHAQUE requête : agent actif, appareil approuvé,
    session non révoquée. Accepte un agent qui doit encore changer son mot
    de passe (réservé aux routes de changement de mot de passe)."""
    refus = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Session invalide ou expirée",
        headers={"WWW-Authenticate": "Bearer"},
    )
    charge = lire_jeton(jeton)
    if charge is None:
        raise refus
    agent = db.get(Agent, charge.agent_id)
    appareil = db.get(Appareil, charge.appareil_id)
    if agent is None or agent.statut != "actif":
        raise refus
    if appareil is None or appareil.statut != "approuve" or not famille_active(db, charge.famille):
        raise refus
    return Contexte(agent, charge.appareil_id, charge.famille)


def get_contexte(contexte: Annotated[Contexte, Depends(get_contexte_provisoire)]) -> Contexte:
    """Comme ci-dessus, mais refuse tout tant que le mot de passe provisoire n'est pas changé."""
    if contexte.agent.doit_changer_mot_de_passe:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={
                "code": "changement_mot_de_passe_requis",
                "message": "Changez votre mot de passe provisoire avant de continuer.",
            },
        )
    return contexte


ContexteProvisoire = Annotated[Contexte, Depends(get_contexte_provisoire)]
ContexteAgent = Annotated[Contexte, Depends(get_contexte)]


def get_agent_courant(contexte: ContexteAgent) -> Agent:
    return contexte.agent


AgentCourant = Annotated[Agent, Depends(get_agent_courant)]


def exiger_roles(*roles: str):
    """Dépendance : l'agent connecté doit avoir l'un de ces rôles (sinon 403)."""

    def verifier(agent: AgentCourant) -> Agent:
        if agent.role not in roles:
            raise HTTPException(status.HTTP_403_FORBIDDEN, "Action non autorisée pour votre rôle")
        return agent

    return verifier


Superviseur = Annotated[Agent, Depends(exiger_roles("superviseur", "administrateur"))]
Administrateur = Annotated[Agent, Depends(exiger_roles("administrateur"))]
