"""Connexion des agents : mot de passe + appareil approuvé, jetons courts
renouvelables, blocage après échecs, changement de mot de passe."""

from datetime import datetime, timedelta, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, Form, HTTPException, status
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy import select

from app.config import parametres
from app.dependances import ContexteProvisoire, SessionDb
from app.journal import journaliser
from app.models import Agent, Appareil
from app.schemas import AgentMoi, DemandeMotDePasse, DemandeRenouvellement, Jeton
from app.securite import HASH_FACTICE, hacher_mot_de_passe, probleme_mot_de_passe, verifier_mot_de_passe
from app.sessions import (
    Jetons,
    RenouvellementRefuse,
    ouvrir_session,
    renouveler,
    revoquer_famille,
    revoquer_sessions_agent,
)

router = APIRouter(prefix="/auth", tags=["Authentification"])

# Même message pour toutes les causes : ne révèle ni les matricules existants,
# ni les comptes bloqués.
MESSAGE_REFUS = (
    "Matricule ou mot de passe incorrect. Après "
    f"{parametres.connexion_echecs_max} essais ratés, le compte est bloqué "
    f"{parametres.connexion_blocage_minutes} minutes."
)


def _refus() -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=MESSAGE_REFUS,
        headers={"WWW-Authenticate": "Bearer"},
    )


def _reponse(jetons: Jetons, agent: Agent) -> Jeton:
    return Jeton(
        access_token=jetons.acces,
        refresh_token=jetons.renouvellement,
        expires_in=parametres.jwt_duree_minutes * 60,
        doit_changer_mot_de_passe=agent.doit_changer_mot_de_passe,
    )


def _appareil_refuse(appareil: Appareil, code: str, message: str) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail={"code": code, "message": message, "code_appareil": appareil.code},
    )


@router.post("/connexion", response_model=Jeton)
def connexion(
    formulaire: Annotated[OAuth2PasswordRequestForm, Depends()],
    db: SessionDb,
    appareil_nom: Annotated[str | None, Form(max_length=100)] = None,
):
    """Connexion par matricule (« username »), mot de passe et identifiant de
    l'appareil (« client_id », généré par l'application). Un appareil inconnu
    est enregistré « en attente » : un superviseur doit l'approuver."""
    maintenant = datetime.now(timezone.utc)
    matricule = formulaire.username.strip().upper()
    agent = db.scalar(select(Agent).where(Agent.matricule == matricule))

    # Même travail (vérification Argon2) que le matricule existe ou non.
    mot_de_passe_ok = verifier_mot_de_passe(
        formulaire.password, agent.mot_de_passe_hash if agent else HASH_FACTICE
    )
    bloque = agent is not None and agent.bloque_jusqu_a is not None and agent.bloque_jusqu_a > maintenant

    if agent is None or bloque or not mot_de_passe_ok or agent.statut != "actif":
        if agent is None:
            raison = "matricule_inconnu"
        elif bloque:
            raison = "compte_bloque"
        elif not mot_de_passe_ok:
            raison = "mot_de_passe_incorrect"
            agent.echecs_connexion += 1
            if agent.echecs_connexion >= parametres.connexion_echecs_max:
                agent.bloque_jusqu_a = maintenant + timedelta(minutes=parametres.connexion_blocage_minutes)
                agent.echecs_connexion = 0
                journaliser(db, "compte_bloque", agent_id=agent.id, cible=agent.matricule)
        else:
            raison = f"agent_{agent.statut}"
        journaliser(
            db,
            "connexion_echouee",
            agent_id=agent.id if agent else None,
            cible=matricule[:100],
            details={"raison": raison},
        )
        db.commit()
        raise _refus()

    # Mot de passe correct : les échecs précédents sont oubliés.
    agent.echecs_connexion = 0
    agent.bloque_jusqu_a = None

    identifiant = (formulaire.client_id or "").strip()
    if not 8 <= len(identifiant) <= 64:
        db.commit()
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            "Identifiant de l'appareil manquant (champ client_id, 8 à 64 caractères)",
        )
    appareil = db.scalar(select(Appareil).where(Appareil.identifiant == identifiant))
    if appareil is None:
        appareil = Appareil(identifiant=identifiant, nom=appareil_nom, agent_id=agent.id)
        db.add(appareil)
        db.flush()
        journaliser(db, "appareil_demande", agent_id=agent.id, cible=appareil.code, details={"nom": appareil_nom})
    if appareil.statut != "approuve":
        db.commit()
        if appareil.statut == "revoque":
            raise _appareil_refuse(appareil, "appareil_revoque", "Cet appareil a été révoqué : il ne peut plus se connecter.")
        raise _appareil_refuse(
            appareil,
            "appareil_en_attente",
            f"Appareil en attente d'approbation. Donnez ce code à votre superviseur : {appareil.code}",
        )

    jetons = ouvrir_session(db, agent, appareil)
    journaliser(db, "connexion_reussie", agent_id=agent.id, cible=agent.matricule, details={"appareil": appareil.code})
    db.commit()
    return _reponse(jetons, agent)


@router.post("/renouveler", response_model=Jeton)
def renouveler_jetons(demande: DemandeRenouvellement, db: SessionDb):
    """Nouveau jeton d'accès (et nouveau jeton de renouvellement : l'ancien
    devient inutilisable ; s'il est présenté de nouveau, la session est coupée)."""
    try:
        agent, jetons = renouveler(db, demande.refresh_token)
    except RenouvellementRefuse as refus:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"code": str(refus), "message": "Session expirée : reconnectez-vous."},
        ) from refus
    return _reponse(jetons, agent)


@router.post("/deconnexion", status_code=status.HTTP_204_NO_CONTENT)
def deconnexion(contexte: ContexteProvisoire, db: SessionDb):
    """Révoque la session : jeton d'accès et jeton de renouvellement deviennent inutilisables."""
    revoquer_famille(db, contexte.famille)
    journaliser(db, "deconnexion", agent_id=contexte.agent.id, cible=contexte.agent.matricule)
    db.commit()


@router.get("/moi", response_model=AgentMoi)
def moi(contexte: ContexteProvisoire):
    """Agent connecté : l'application adapte ses écrans à son rôle et affiche
    le changement de mot de passe obligatoire (le serveur vérifie de toute
    façon les droits à chaque action)."""
    return contexte.agent


@router.post("/mot-de-passe", status_code=status.HTTP_204_NO_CONTENT)
def changer_mot_de_passe(demande: DemandeMotDePasse, contexte: ContexteProvisoire, db: SessionDb):
    """Change le mot de passe (obligatoire après un mot de passe provisoire).
    Les autres sessions de l'agent sont coupées ; celle-ci continue."""
    agent = contexte.agent
    if not verifier_mot_de_passe(demande.ancien, agent.mot_de_passe_hash):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Mot de passe actuel incorrect")
    if demande.nouveau == demande.ancien:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Le nouveau mot de passe doit être différent de l'actuel")
    probleme = probleme_mot_de_passe(demande.nouveau, agent.matricule)
    if probleme:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, probleme)
    agent.mot_de_passe_hash = hacher_mot_de_passe(demande.nouveau)
    agent.doit_changer_mot_de_passe = False
    agent.mot_de_passe_change_le = datetime.now(timezone.utc)
    revoquer_sessions_agent(db, agent.id, sauf_famille=contexte.famille)
    journaliser(db, "mot_de_passe_change", agent_id=agent.id, cible=agent.matricule)
    db.commit()
