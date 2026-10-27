"""Création, lecture et recherche des fiches de citoyens, photo et signature."""

import base64
import binascii
from typing import Annotated

from fastapi import APIRouter, HTTPException, Query, Response, status
from sqlalchemy import func, or_, select

from app.dependances import AgentCourant, SessionDb
from app.journal import journaliser
from app.models import Citoyen, CitoyenMedia
from app.numero import attribuer_numero, normaliser_numero
from app.schemas import CitoyenCreation, CitoyenLecture, EtatMedias, Ile, MediasCitoyen, PageCitoyens

router = APIRouter(prefix="/citoyens", tags=["Citoyens"])


def _echapper_like(texte: str) -> str:
    """Empêche « % » et « _ » saisis par l'agent d'agir comme jokers SQL."""
    return texte.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


@router.post("", response_model=CitoyenLecture, status_code=status.HTTP_201_CREATED)
def creer_citoyen(donnees: CitoyenCreation, agent: AgentCourant, db: SessionDb):
    """Crée une fiche et lui attribue un numéro d'identification unique."""
    citoyen = Citoyen(
        **donnees.model_dump(),
        numero=attribuer_numero(db),
        agent_id=agent.id,
    )
    db.add(citoyen)
    journaliser(db, "citoyen_creation", agent_id=agent.id, cible=citoyen.numero)
    db.commit()
    db.refresh(citoyen)
    return citoyen


@router.get("", response_model=PageCitoyens)
def rechercher_citoyens(
    agent: AgentCourant,
    db: SessionDb,
    q: Annotated[
        str | None,
        Query(min_length=1, max_length=100, description="Nom, prénom(s) ou numéro"),
    ] = None,
    ile: Ile | None = None,
    page: Annotated[int, Query(ge=1)] = 1,
    taille_page: Annotated[int, Query(ge=1, le=100)] = 20,
):
    """Liste les fiches, les plus récentes d'abord, avec recherche et filtre par île."""
    filtres = []
    if q and q.strip():
        motif = f"%{_echapper_like(q.strip())}%"
        filtres.append(
            or_(
                Citoyen.nom.ilike(motif, escape="\\"),
                Citoyen.prenoms.ilike(motif, escape="\\"),
                Citoyen.numero.ilike(motif, escape="\\"),
                func.concat(Citoyen.prenoms, " ", Citoyen.nom).ilike(motif, escape="\\"),
                func.concat(Citoyen.nom, " ", Citoyen.prenoms).ilike(motif, escape="\\"),
            )
        )
    if ile:
        filtres.append(Citoyen.ile == ile)

    total = db.scalar(select(func.count()).select_from(Citoyen).where(*filtres))
    resultats = db.scalars(
        select(Citoyen)
        .where(*filtres)
        .order_by(Citoyen.enregistre_le.desc(), Citoyen.numero.desc())
        .offset((page - 1) * taille_page)
        .limit(taille_page)
    ).all()

    journaliser(
        db,
        "citoyen_recherche",
        agent_id=agent.id,
        details={"q": q, "ile": ile, "page": page, "total": total},
    )
    db.commit()
    return PageCitoyens(total=total, page=page, taille_page=taille_page, resultats=resultats)


@router.get("/{numero}", response_model=CitoyenLecture)
def lire_citoyen(numero: str, agent: AgentCourant, db: SessionDb):
    """Renvoie la fiche complète correspondant au numéro."""
    numero = normaliser_numero(numero)
    citoyen = db.scalar(select(Citoyen).where(Citoyen.numero == numero))
    journaliser(
        db,
        "citoyen_consultation",
        agent_id=agent.id,
        cible=numero[:100],
        details={"trouve": citoyen is not None},
    )
    db.commit()
    if citoyen is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Fiche introuvable")
    return citoyen


# --- Photo du visage et signature ---

# Signatures des formats acceptés (premiers octets du fichier).
_FORMATS = {b"\xff\xd8\xff": "image/jpeg", b"\x89PNG\r\n\x1a\n": "image/png"}
TAILLE_MAX_MEDIA = 2 * 1024 * 1024


def _decoder_media(contenu: str, champ: str, formats: tuple[str, ...]) -> tuple[bytes, str]:
    """base64 → (octets, type MIME) ; refuse ce qui n'est pas une vraie image JPEG/PNG."""
    try:
        octets = base64.b64decode(contenu, validate=True)
    except (binascii.Error, ValueError) as erreur:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, f"{champ} : base64 invalide") from erreur
    if len(octets) > TAILLE_MAX_MEDIA:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, f"{champ} : image trop lourde (2 Mo au plus)")
    for entete, mime in _FORMATS.items():
        if octets.startswith(entete) and mime in formats:
            return octets, mime
    raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, f"{champ} : format non accepté ({', '.join(formats)})")


def _fiche(db, numero: str) -> Citoyen:
    citoyen = db.scalar(select(Citoyen).where(Citoyen.numero == normaliser_numero(numero)))
    if citoyen is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Fiche introuvable")
    return citoyen


@router.put("/{numero}/medias", response_model=EtatMedias)
def enregistrer_medias(numero: str, donnees: MediasCitoyen, agent: AgentCourant, db: SessionDb):
    """Enregistre la photo du visage et/ou la signature d'une fiche.
    (Chiffrement au repos : phase 7.)"""
    citoyen = _fiche(db, numero)
    medias = db.get(CitoyenMedia, citoyen.id) or CitoyenMedia(citoyen_id=citoyen.id)
    if donnees.photo is not None:
        medias.photo, medias.photo_type_mime = _decoder_media(donnees.photo, "Photo", ("image/jpeg", "image/png"))
    if donnees.signature is not None:
        medias.signature, _ = _decoder_media(donnees.signature, "Signature", ("image/png",))
    medias.mis_a_jour_le = func.now()
    db.add(medias)
    journaliser(
        db,
        "citoyen_medias",
        agent_id=agent.id,
        cible=citoyen.numero,
        details={"photo": donnees.photo is not None, "signature": donnees.signature is not None},
    )
    db.commit()
    return EtatMedias(photo=medias.photo is not None, signature=medias.signature is not None)


@router.get("/{numero}/photo", response_class=Response, responses={200: {"content": {"image/jpeg": {}, "image/png": {}}}})
def lire_photo(numero: str, agent: AgentCourant, db: SessionDb):
    """Photo du visage de la fiche (404 si aucune)."""
    citoyen = _fiche(db, numero)
    medias = db.get(CitoyenMedia, citoyen.id)
    if medias is None or medias.photo is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Pas de photo")
    return Response(medias.photo, media_type=medias.photo_type_mime or "image/jpeg", headers={"Cache-Control": "no-store"})


@router.get("/{numero}/signature", response_class=Response, responses={200: {"content": {"image/png": {}}}})
def lire_signature(numero: str, agent: AgentCourant, db: SessionDb):
    """Signature de la fiche, en PNG (404 si aucune)."""
    citoyen = _fiche(db, numero)
    medias = db.get(CitoyenMedia, citoyen.id)
    if medias is None or medias.signature is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Pas de signature")
    return Response(medias.signature, media_type="image/png", headers={"Cache-Control": "no-store"})
