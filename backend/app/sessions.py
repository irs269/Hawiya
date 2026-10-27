"""Sessions des agents : ouverture, renouvellement (avec rotation) et révocation."""

import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.config import parametres
from app.journal import journaliser
from app.models import Agent, Appareil, SessionAgent
from app.securite import creer_jeton, hacher_jeton, nouveau_jeton_renouvellement


@dataclass
class Jetons:
    acces: str
    renouvellement: str
    famille: uuid.UUID


class RenouvellementRefuse(Exception):
    """Jeton de renouvellement inconnu, expiré, révoqué ou réutilisé."""


def _maintenant() -> datetime:
    return datetime.now(timezone.utc)


def _emettre(db: Session, agent: Agent, appareil: Appareil, famille: uuid.UUID) -> Jetons:
    jeton, empreinte = nouveau_jeton_renouvellement()
    db.add(
        SessionAgent(
            agent_id=agent.id,
            appareil_id=appareil.id,
            famille=famille,
            hash_jeton=empreinte,
            expire_le=_maintenant() + timedelta(days=parametres.renouvellement_duree_jours),
        )
    )
    return Jetons(creer_jeton(agent.id, appareil.id, famille), jeton, famille)


def ouvrir_session(db: Session, agent: Agent, appareil: Appareil) -> Jetons:
    """Nouvelle famille de session (connexion par mot de passe). L'appelant fait le commit."""
    appareil.derniere_connexion = _maintenant()
    return _emettre(db, agent, appareil, uuid.uuid4())


def renouveler(db: Session, jeton: str) -> tuple[Agent, Jetons]:
    """Échange un jeton de renouvellement contre une nouvelle paire de jetons.

    Le jeton présenté est marqué « utilisé ». S'il l'était déjà, quelqu'un
    d'autre l'a probablement copié : TOUTE la famille est révoquée (le
    titulaire légitime devra se reconnecter). Commit fait ici.
    """
    session = db.scalar(select(SessionAgent).where(SessionAgent.hash_jeton == hacher_jeton(jeton)))
    if session is None:
        raise RenouvellementRefuse("jeton_inconnu")
    if session.revoque_le is not None:
        raise RenouvellementRefuse("session_revoquee")
    if session.utilise_le is not None:
        revoquer_famille(db, session.famille)
        journaliser(db, "jeton_reutilise", agent_id=session.agent_id, details={"famille": str(session.famille)})
        db.commit()
        raise RenouvellementRefuse("jeton_reutilise")
    if session.expire_le <= _maintenant():
        raise RenouvellementRefuse("jeton_expire")

    agent = db.get(Agent, session.agent_id)
    appareil = db.get(Appareil, session.appareil_id)
    if agent is None or agent.statut != "actif" or appareil is None or appareil.statut != "approuve":
        revoquer_famille(db, session.famille)
        db.commit()
        raise RenouvellementRefuse("acces_retire")

    session.utilise_le = _maintenant()
    appareil.derniere_connexion = _maintenant()
    jetons = _emettre(db, agent, appareil, session.famille)
    db.commit()
    return agent, jetons


def famille_active(db: Session, famille: uuid.UUID) -> bool:
    return (
        db.scalar(
            select(SessionAgent.id)
            .where(SessionAgent.famille == famille, SessionAgent.revoque_le.is_(None))
            .limit(1)
        )
        is not None
    )


def revoquer_famille(db: Session, famille: uuid.UUID) -> None:
    db.execute(
        update(SessionAgent)
        .where(SessionAgent.famille == famille, SessionAgent.revoque_le.is_(None))
        .values(revoque_le=_maintenant())
    )


def revoquer_sessions_agent(db: Session, agent_id: uuid.UUID, sauf_famille: uuid.UUID | None = None) -> None:
    condition = [SessionAgent.agent_id == agent_id, SessionAgent.revoque_le.is_(None)]
    if sauf_famille is not None:
        condition.append(SessionAgent.famille != sauf_famille)
    db.execute(update(SessionAgent).where(*condition).values(revoque_le=_maintenant()))


def revoquer_sessions_appareil(db: Session, appareil_id: uuid.UUID) -> None:
    db.execute(
        update(SessionAgent)
        .where(SessionAgent.appareil_id == appareil_id, SessionAgent.revoque_le.is_(None))
        .values(revoque_le=_maintenant())
    )
