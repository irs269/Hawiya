"""Administration : agents (administrateurs) et appareils (superviseurs).

En attendant le tableau de bord, ces routes s'utilisent depuis /docs.
"""

from datetime import datetime, timezone
from typing import Literal

from fastapi import APIRouter, HTTPException, status
from sqlalchemy import select

from app.dependances import Administrateur, SessionDb, Superviseur
from app.journal import journaliser
from app.models import Agent, Appareil
from app.schemas import AgentAvecMotDePasse, AgentCreation, AgentLecture, AgentModification, AppareilLecture
from app.securite import generer_mot_de_passe_provisoire, hacher_mot_de_passe
from app.sessions import revoquer_sessions_agent, revoquer_sessions_appareil

router = APIRouter(tags=["Administration"])


def _agent(db, matricule: str) -> Agent:
    agent = db.scalar(select(Agent).where(Agent.matricule == matricule.strip().upper()))
    if agent is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Agent introuvable")
    return agent


# ------------------------------------------------------------------- agents


@router.get("/agents", response_model=list[AgentLecture])
def lister_agents(admin: Administrateur, db: SessionDb):
    return db.scalars(select(Agent).order_by(Agent.matricule)).all()


@router.post("/agents", response_model=AgentAvecMotDePasse, status_code=status.HTTP_201_CREATED)
def creer_agent(donnees: AgentCreation, admin: Administrateur, db: SessionDb):
    """Crée un agent avec un mot de passe PROVISOIRE (montré une seule fois),
    à changer à la première connexion."""
    if db.scalar(select(Agent.id).where(Agent.matricule == donnees.matricule)):
        raise HTTPException(status.HTTP_409_CONFLICT, "Ce matricule existe déjà")
    provisoire = generer_mot_de_passe_provisoire()
    agent = Agent(
        **donnees.model_dump(),
        mot_de_passe_hash=hacher_mot_de_passe(provisoire),
        doit_changer_mot_de_passe=True,
    )
    db.add(agent)
    db.flush()
    journaliser(db, "agent_creation", agent_id=admin.id, cible=agent.matricule, details={"role": agent.role})
    db.commit()
    db.refresh(agent)
    return AgentAvecMotDePasse(**AgentLecture.model_validate(agent).model_dump(), mot_de_passe_provisoire=provisoire)


@router.patch("/agents/{matricule}", response_model=AgentLecture)
def modifier_agent(matricule: str, donnees: AgentModification, admin: Administrateur, db: SessionDb):
    """Rôle, statut, île… Suspendre ou désactiver coupe immédiatement ses sessions."""
    agent = _agent(db, matricule)
    changements = donnees.model_dump(exclude_unset=True)
    if agent.id == admin.id and (
        changements.get("statut", "actif") != "actif" or changements.get("role", "administrateur") != "administrateur"
    ):
        # Évite qu'un administrateur se retire lui-même l'accès par erreur.
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Vous ne pouvez pas retirer vos propres droits")
    for champ, valeur in changements.items():
        setattr(agent, champ, valeur)
    if agent.statut != "actif":
        revoquer_sessions_agent(db, agent.id)
    journaliser(db, "agent_modification", agent_id=admin.id, cible=agent.matricule, details=changements)
    db.commit()
    return agent


@router.post("/agents/{matricule}/reinitialiser", response_model=AgentAvecMotDePasse)
def reinitialiser_mot_de_passe(matricule: str, admin: Administrateur, db: SessionDb):
    """Nouveau mot de passe provisoire (montré une seule fois) ; débloque le
    compte et coupe ses sessions."""
    agent = _agent(db, matricule)
    provisoire = generer_mot_de_passe_provisoire()
    agent.mot_de_passe_hash = hacher_mot_de_passe(provisoire)
    agent.doit_changer_mot_de_passe = True
    agent.echecs_connexion = 0
    agent.bloque_jusqu_a = None
    revoquer_sessions_agent(db, agent.id)
    journaliser(db, "mot_de_passe_reinitialise", agent_id=admin.id, cible=agent.matricule)
    db.commit()
    return AgentAvecMotDePasse(**AgentLecture.model_validate(agent).model_dump(), mot_de_passe_provisoire=provisoire)


# ----------------------------------------------------------------- appareils


def _lecture(db, appareil: Appareil) -> AppareilLecture:
    demandeur = db.get(Agent, appareil.agent_id) if appareil.agent_id else None
    return AppareilLecture(
        code=appareil.code,
        nom=appareil.nom,
        statut=appareil.statut,
        demande_par=demandeur.matricule if demandeur else None,
        approuve_le=appareil.approuve_le,
        derniere_connexion=appareil.derniere_connexion,
        cree_le=appareil.cree_le,
    )


def _appareil(db, code: str) -> Appareil:
    """Retrouve un appareil par son code court (8 premiers caractères de son identifiant)."""
    code = code.strip().lower()
    if len(code) < 8:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Code d'appareil : 8 caractères")
    trouves = db.scalars(select(Appareil).where(Appareil.identifiant.ilike(f"{code}%"))).all()
    if not trouves:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Appareil introuvable")
    if len(trouves) > 1:
        raise HTTPException(status.HTTP_409_CONFLICT, "Code ambigu : plusieurs appareils correspondent")
    return trouves[0]


@router.get("/appareils", response_model=list[AppareilLecture])
def lister_appareils(
    superviseur: Superviseur, db: SessionDb, statut: Literal["en_attente", "approuve", "revoque"] | None = None
):
    requete = select(Appareil).order_by(Appareil.cree_le.desc())
    if statut:
        requete = requete.where(Appareil.statut == statut)
    return [_lecture(db, a) for a in db.scalars(requete).all()]


@router.post("/appareils/{code}/approuver", response_model=AppareilLecture)
def approuver_appareil(code: str, superviseur: Superviseur, db: SessionDb):
    appareil = _appareil(db, code)
    if appareil.statut == "revoque":
        # Un appareil révoqué (perdu, volé) ne revient pas : l'application en génère un nouveau.
        raise HTTPException(status.HTTP_409_CONFLICT, "Appareil révoqué : il ne peut pas être réapprouvé")
    appareil.statut = "approuve"
    appareil.approuve_par = superviseur.id
    appareil.approuve_le = datetime.now(timezone.utc)
    journaliser(db, "appareil_approuve", agent_id=superviseur.id, cible=appareil.code)
    db.commit()
    return _lecture(db, appareil)


@router.post("/appareils/{code}/revoquer", response_model=AppareilLecture)
def revoquer_appareil(code: str, superviseur: Superviseur, db: SessionDb):
    """Appareil perdu ou volé : plus aucune connexion, sessions coupées immédiatement."""
    appareil = _appareil(db, code)
    appareil.statut = "revoque"
    revoquer_sessions_appareil(db, appareil.id)
    journaliser(db, "appareil_revoque", agent_id=superviseur.id, cible=appareil.code)
    db.commit()
    return _lecture(db, appareil)
