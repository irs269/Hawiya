"""Statistiques simples pour l'accueil de l'application."""

from datetime import datetime, time
from zoneinfo import ZoneInfo

from fastapi import APIRouter
from sqlalchemy import func, select

from app.config import parametres
from app.dependances import AgentCourant, SessionDb
from app.models import Citoyen
from app.referentiels import ILES, SEXES
from app.schemas import Statistiques

router = APIRouter(tags=["Statistiques"])


def _compter_par(db, colonne, valeurs: tuple[str, ...]) -> dict[str, int]:
    """Compte par valeur, en incluant les valeurs à zéro."""
    lignes = db.execute(select(colonne, func.count()).group_by(colonne)).all()
    comptes = dict.fromkeys(valeurs, 0)
    comptes.update({valeur: nombre for valeur, nombre in lignes})
    return comptes


@router.get("/statistiques", response_model=Statistiques)
def statistiques(agent: AgentCourant, db: SessionDb):
    fuseau = ZoneInfo(parametres.fuseau_horaire)
    debut_du_jour = datetime.combine(datetime.now(fuseau).date(), time.min, tzinfo=fuseau)

    return Statistiques(
        total_citoyens=db.scalar(select(func.count()).select_from(Citoyen)),
        enregistres_aujourdhui=db.scalar(
            select(func.count()).select_from(Citoyen).where(Citoyen.enregistre_le >= debut_du_jour)
        ),
        par_ile=_compter_par(db, Citoyen.ile, ILES),
        par_sexe=_compter_par(db, Citoyen.sexe, SEXES),
    )
