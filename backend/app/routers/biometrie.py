"""Identification par les empreintes, contrôle anti-doublon et enregistrement
des modèles d'empreintes d'une fiche.

Règle : ne jamais afficher la fiche d'une autre personne. Voir
app/biometrie/decision.py pour les conditions de chaque réponse.
"""

import base64
import binascii
import uuid
from functools import lru_cache
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import delete, select

from app.biometrie import service
from app.biometrie.client_matcher import ClientMatcher, ErreurMatcher
from app.biometrie.decision import Verdict, VerdictDoublon
from app.dependances import AgentCourant, SessionDb
from app.journal import journaliser
from app.models import Citoyen, Empreinte
from app.numero import normaliser_numero
from app.schemas import (
    DemandeEmpreintes,
    DemandeIdentification,
    DoigtImage,
    ReponseDoublon,
    ReponseEmpreintes,
    ReponseIdentification,
    ScanMain,
)

router = APIRouter(tags=["Biométrie"])

ROLES_VALIDATION = ("superviseur", "administrateur")


@lru_cache
def _client_partage() -> ClientMatcher:
    return ClientMatcher()


def get_client_matcher() -> ClientMatcher:
    """Client du matcher (remplacé par un faux matcher dans les tests)."""
    try:
        return _client_partage()
    except ErreurMatcher as erreur:
        raise _indisponible(erreur) from erreur


ClientDep = Annotated[ClientMatcher, Depends(get_client_matcher)]


def _indisponible(erreur: Exception) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        detail=f"Service de comparaison indisponible : {erreur}",
    )


def _decoder(doigts: list[DoigtImage]) -> dict[int, tuple[bytes, float]]:
    try:
        return {d.doigt: (base64.b64decode(d.image, validate=True), d.dpi_estime) for d in doigts}
    except (binascii.Error, ValueError) as erreur:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Image base64 invalide") from erreur


def _numeros(db, identifiants: list[str]) -> dict[str, str]:
    """Identifiants du matcher (UUID des fiches) → numéros d'identification."""
    ids = []
    for i in identifiants:
        try:
            ids.append(uuid.UUID(i))
        except ValueError:
            continue
    lignes = db.execute(select(Citoyen.id, Citoyen.numero).where(Citoyen.id.in_(ids))).all() if ids else []
    return {str(id_): numero for id_, numero in lignes}


def _controle(db, client, modeles, illisibles, exclure=None) -> ReponseDoublon:
    decision = service.controler_doublon(client, modeles, exclure=exclure)
    numeros = _numeros(db, decision.candidats)
    return ReponseDoublon(
        verdict=decision.verdict.value,
        motif=decision.motif,
        # Une fiche du matcher absente de la base est quand même signalée.
        numeros=[numeros.get(c, f"inconnu:{c[:8]}") for c in decision.candidats],
        doigts_illisibles=illisibles,
    )


@router.post("/identification", response_model=ReponseIdentification)
def identifier(demande: DemandeIdentification, agent: AgentCourant, db: SessionDb, client: ClientDep):
    """Identifie une personne à partir d'un ou plusieurs scans de sa main.

    Trois réponses : « identifie » (avec la fiche), « non_enregistre », ou
    « non_concluant » (recommencer le scan ; après deux échecs, vérification
    manuelle sur pièce d'identité)."""
    try:
        extraits = [service.extraire(client, _decoder(scan.doigts)) for scan in demande.scans]
        illisibles = sorted({iso for _, _, ill in extraits for iso in ill})
        decision = service.identifier(client, [modeles for modeles, _, _ in extraits])
    except ErreurMatcher as erreur:
        raise _indisponible(erreur) from erreur

    citoyen = None
    verdict, motif = decision.verdict, decision.motif
    if verdict == Verdict.IDENTIFIE:
        try:
            citoyen = db.get(Citoyen, uuid.UUID(decision.candidat))
        except ValueError:
            citoyen = None
        if citoyen is None:
            # Le matcher connaît une personne que la base ignore : on ne conclut pas.
            verdict, motif = Verdict.NON_CONCLUANT, "Fiche introuvable dans la base : vérification manuelle."

    journaliser(
        db,
        "identification",
        agent_id=agent.id,
        cible=citoyen.numero if citoyen else None,
        details={
            "verdict": verdict.value,
            "scans": len(demande.scans),
            "doigts_compares": decision.doigts_compares,
            "doigts_concordants": decision.doigts_concordants,
        },
    )
    db.commit()
    return ReponseIdentification(
        verdict=verdict.value,
        motif=motif,
        doigts_compares=decision.doigts_compares,
        doigts_concordants=decision.doigts_concordants,
        doigts_illisibles=illisibles,
        citoyen=citoyen,
    )


@router.post("/doublons", response_model=ReponseDoublon)
def controler_doublon(scan: ScanMain, agent: AgentCourant, db: SessionDb, client: ClientDep):
    """Contrôle anti-doublon AVANT la création de la fiche (rien n'est enregistré).
    « doublon_possible » : l'enregistrement doit attendre un superviseur."""
    try:
        modeles, _, illisibles = service.extraire(client, _decoder(scan.doigts))
        if not modeles:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Aucun doigt exploitable : recommencer la capture")
        reponse = _controle(db, client, modeles, illisibles)
    except ErreurMatcher as erreur:
        raise _indisponible(erreur) from erreur
    journaliser(db, "controle_doublon", agent_id=agent.id, details={"verdict": reponse.verdict})
    db.commit()
    return reponse


@router.put("/citoyens/{numero}/empreintes", response_model=ReponseEmpreintes)
def enregistrer_empreintes(
    numero: str, demande: DemandeEmpreintes, agent: AgentCourant, db: SessionDb, client: ClientDep
):
    """Enregistre (ou remplace) les modèles d'empreintes d'une fiche.

    Le contrôle anti-doublon est refait ici : en cas de doublon certain ou
    possible, refus (409), sauf validation explicite d'un superviseur."""
    numero = normaliser_numero(numero)
    citoyen = db.scalar(select(Citoyen).where(Citoyen.numero == numero))
    if citoyen is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Fiche introuvable")
    if demande.validation_superviseur and agent.role not in ROLES_VALIDATION:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Seul un superviseur peut valider un doublon possible")

    identifiant = str(citoyen.id)
    try:
        modeles, version, illisibles = service.extraire(client, _decoder(demande.doigts))
        if not modeles:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Aucun doigt exploitable : recommencer la capture")
        controle = _controle(db, client, modeles, illisibles, exclure=identifiant)
        doute = controle.verdict != VerdictDoublon.AUCUN_DOUBLON.value
        if doute and not demande.validation_superviseur:
            journaliser(db, "empreintes_refus_doublon", agent_id=agent.id, cible=numero, details=controle.model_dump())
            db.commit()
            raise HTTPException(status.HTTP_409_CONFLICT, detail=controle.model_dump())

        # Seul le modèle à l'échelle 1 est conservé (jamais la photo du doigt).
        db.execute(delete(Empreinte).where(Empreinte.citoyen_id == citoyen.id))
        for iso, liste in modeles.items():
            db.add(Empreinte(citoyen_id=citoyen.id, doigt=iso, modele=liste[0], version_moteur=version))
        journaliser(
            db,
            "empreintes_enregistrement",
            agent_id=agent.id,
            cible=numero,
            details={
                "doigts": sorted(modeles),
                "controle_doublon": controle.verdict,
                "validation_superviseur": doute and demande.validation_superviseur,
            },
        )
        db.flush()
        client.ajouter(identifiant, {iso: liste[0] for iso, liste in modeles.items()})
    except ErreurMatcher as erreur:
        db.rollback()
        raise _indisponible(erreur) from erreur
    try:
        db.commit()
    except Exception:
        # La base a refusé : on retire la personne du matcher pour rester cohérent.
        try:
            client.retirer(identifiant)
        finally:
            raise
    return ReponseEmpreintes(
        numero=numero, doigts_enregistres=sorted(modeles), doigts_illisibles=illisibles, controle_doublon=controle
    )
