"""Connexion à PostgreSQL et session SQLAlchemy."""

from collections.abc import Iterator

from sqlalchemy import MetaData, create_engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from app.config import parametres

# Noms de contraintes prévisibles, identiques à ceux écrits dans les migrations Alembic.
CONVENTION_NOMS = {
    "ix": "ix_%(table_name)s_%(column_0_name)s",
    "uq": "uq_%(table_name)s_%(column_0_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s",
    "pk": "pk_%(table_name)s",
}


class Base(DeclarativeBase):
    metadata = MetaData(naming_convention=CONVENTION_NOMS)


moteur = create_engine(parametres.database_url, pool_pre_ping=True)
SessionLocale = sessionmaker(bind=moteur, autoflush=False, expire_on_commit=False)


def get_db() -> Iterator[Session]:
    """Fournit une session par requête HTTP, fermée à la fin."""
    db = SessionLocale()
    try:
        yield db
    finally:
        db.close()
