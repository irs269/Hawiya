"""Création, lecture et recherche des fiches de citoyens."""

from typing import Annotated

from fastapi import APIRouter, HTTPException, Query, status
from sqlalchemy import func, or_, select

from app.dependances import AgentCourant, SessionDb
from app.journal import journaliser
from app.models import Citoyen
from app.numero import attribuer_numero, normaliser_numero
from app.schemas import CitoyenCreation, CitoyenLecture, Ile, PageCitoyens

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
