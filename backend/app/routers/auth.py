"""Connexion des agents (provisoire — système complet en phase 1 bis)."""

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy import select

from app.dependances import SessionDb
from app.journal import journaliser
from app.models import Agent
from app.schemas import Jeton
from app.securite import HASH_FACTICE, creer_jeton, verifier_mot_de_passe

router = APIRouter(prefix="/auth", tags=["Authentification"])


@router.post("/connexion", response_model=Jeton)
def connexion(formulaire: Annotated[OAuth2PasswordRequestForm, Depends()], db: SessionDb):
    """Connexion par matricule (champ « username ») et mot de passe."""
    matricule = formulaire.username.strip().upper()
    agent = db.scalar(select(Agent).where(Agent.matricule == matricule))

    # Même travail (vérification Argon2) que le matricule existe ou non.
    mot_de_passe_ok = verifier_mot_de_passe(
        formulaire.password, agent.mot_de_passe_hash if agent else HASH_FACTICE
    )

    if agent is None or not mot_de_passe_ok or agent.statut != "actif":
        raison = (
            "matricule_inconnu"
            if agent is None
            else "mot_de_passe_incorrect" if not mot_de_passe_ok else f"agent_{agent.statut}"
        )
        journaliser(
            db,
            "connexion_echouee",
            agent_id=agent.id if agent else None,
            cible=matricule[:100],
            details={"raison": raison},
        )
        db.commit()
        # Message volontairement identique dans tous les cas.
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Matricule ou mot de passe incorrect",
            headers={"WWW-Authenticate": "Bearer"},
        )

    journaliser(db, "connexion_reussie", agent_id=agent.id, cible=agent.matricule)
    db.commit()
    return Jeton(access_token=creer_jeton(agent.id))
