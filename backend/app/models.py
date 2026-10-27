"""Tables de la base de données.

Toute modification ici doit s'accompagner d'une migration Alembic
(backend/alembic/versions/).
"""

import uuid
from datetime import date, datetime

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    Integer,
    LargeBinary,
    SmallInteger,
    String,
    UniqueConstraint,
    Uuid,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.referentiels import (
    COULEURS_CHEVEUX,
    COULEURS_YEUX,
    ILES,
    ROLES_AGENT,
    SEXES,
    STATUTS_APPAREIL,
    STATUTS_AGENT,
    TAILLE_MAX_CM,
    TAILLE_MIN_CM,
    condition_sql_in,
)


class Agent(Base):
    """Agent qui enregistre et identifie des citoyens.

    Rôles : agent (enregistre, identifie), superviseur (valide les doublons,
    approuve les téléphones), administrateur (gère aussi les agents).
    """

    __tablename__ = "agents"

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    matricule: Mapped[str] = mapped_column(String(20), unique=True)
    nom: Mapped[str] = mapped_column(String(150))
    mot_de_passe_hash: Mapped[str] = mapped_column(String(255))
    role: Mapped[str] = mapped_column(String(20), default="agent", server_default="agent")
    ile: Mapped[str | None] = mapped_column(String(20))
    commune: Mapped[str | None] = mapped_column(String(100))
    statut: Mapped[str] = mapped_column(String(20), default="actif", server_default="actif")
    cree_le: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    # Blocage après des échecs de connexion consécutifs.
    echecs_connexion: Mapped[int] = mapped_column(SmallInteger, default=0, server_default="0")
    bloque_jusqu_a: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # Mot de passe provisoire (création, réinitialisation) : à changer avant toute action.
    doit_changer_mot_de_passe: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")
    mot_de_passe_change_le: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    __table_args__ = (
        CheckConstraint(condition_sql_in("role", ROLES_AGENT), name="role"),
        CheckConstraint(condition_sql_in("statut", STATUTS_AGENT), name="statut"),
        CheckConstraint("ile IS NULL OR " + condition_sql_in("ile", ILES), name="ile"),
    )


class Appareil(Base):
    """Téléphone (ou poste) autorisé à se connecter. Un nouvel appareil reste
    « en_attente » tant qu'un superviseur ne l'a pas approuvé ; un appareil
    perdu est « revoque » (ses sessions sont coupées)."""

    __tablename__ = "appareils"

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    # Identifiant aléatoire généré par l'appareil lui-même (gardé dans son coffre).
    identifiant: Mapped[str] = mapped_column(String(64), unique=True)
    nom: Mapped[str | None] = mapped_column(String(100))
    statut: Mapped[str] = mapped_column(String(20), default="en_attente", server_default="en_attente")
    # Agent qui a fait la première demande de connexion depuis cet appareil.
    agent_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("agents.id", ondelete="SET NULL"), index=True)
    approuve_par: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("agents.id", ondelete="SET NULL"))
    approuve_le: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    derniere_connexion: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    cree_le: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (CheckConstraint(condition_sql_in("statut", STATUTS_APPAREIL), name="statut"),)

    @property
    def code(self) -> str:
        """Code court lu à voix haute ou recopié par le superviseur."""
        return self.identifiant[:8].upper()


class SessionAgent(Base):
    """Jeton de renouvellement (enregistré HACHÉ). À chaque renouvellement, le
    jeton est marqué « utilisé » et un nouveau est créé dans la même famille.
    Un jeton déjà utilisé qui revient = vol probable : toute la famille est révoquée."""

    __tablename__ = "sessions_agents"

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    agent_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("agents.id", ondelete="CASCADE"), index=True)
    appareil_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("appareils.id", ondelete="CASCADE"), index=True)
    famille: Mapped[uuid.UUID] = mapped_column(Uuid, index=True)
    hash_jeton: Mapped[str] = mapped_column(String(64), unique=True)
    cree_le: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    expire_le: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    utilise_le: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoque_le: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Citoyen(Base):
    """Fiche d'identité d'un citoyen (sans photo, signature ni empreintes)."""

    __tablename__ = "citoyens"

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    numero: Mapped[str] = mapped_column(String(20), unique=True)

    # Identité
    nom: Mapped[str] = mapped_column(String(100))
    prenoms: Mapped[str] = mapped_column(String(150))
    sexe: Mapped[str] = mapped_column(String(1))
    date_naissance: Mapped[date] = mapped_column(Date)
    lieu_naissance: Mapped[str] = mapped_column(String(150))
    nationalite: Mapped[str] = mapped_column(String(100))
    numero_acte_naissance: Mapped[str] = mapped_column(String(50))
    telephone: Mapped[str | None] = mapped_column(String(20))

    # Domicile
    ile: Mapped[str] = mapped_column(String(20), index=True)
    ville: Mapped[str] = mapped_column(String(100))
    quartier: Mapped[str] = mapped_column(String(100))
    adresse: Mapped[str] = mapped_column(String(255))

    # Signalement
    taille_cm: Mapped[int] = mapped_column(SmallInteger)
    couleur_yeux: Mapped[str] = mapped_column(String(20))
    couleur_cheveux: Mapped[str] = mapped_column(String(20))

    # Traçabilité
    agent_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("agents.id", ondelete="RESTRICT"), index=True
    )
    enregistre_le: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), index=True
    )

    __table_args__ = (
        CheckConstraint(condition_sql_in("sexe", SEXES), name="sexe"),
        CheckConstraint(condition_sql_in("ile", ILES), name="ile"),
        CheckConstraint(condition_sql_in("couleur_yeux", COULEURS_YEUX), name="couleur_yeux"),
        CheckConstraint(
            condition_sql_in("couleur_cheveux", COULEURS_CHEVEUX), name="couleur_cheveux"
        ),
        CheckConstraint(
            f"taille_cm BETWEEN {TAILLE_MIN_CM} AND {TAILLE_MAX_CM}", name="taille_cm"
        ),
    )


class CitoyenMedia(Base):
    """Photo du visage et signature, séparées pour garder la table citoyens légère.

    Le chiffrement au repos sera ajouté à la phase 7.
    """

    __tablename__ = "citoyens_medias"

    citoyen_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("citoyens.id", ondelete="CASCADE"), primary_key=True
    )
    photo: Mapped[bytes | None] = mapped_column(LargeBinary)
    photo_type_mime: Mapped[str | None] = mapped_column(String(50))
    signature: Mapped[bytes | None] = mapped_column(LargeBinary)
    mis_a_jour_le: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )


class Empreinte(Base):
    """Modèle (template) d'empreinte d'un doigt — jamais la photo du doigt.

    Numérotation ISO/IEC 19794 : 1 = pouce droit … 5 = auriculaire droit,
    6 = pouce gauche … 10 = auriculaire gauche.
    """

    __tablename__ = "empreintes"

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    citoyen_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("citoyens.id", ondelete="CASCADE"), index=True
    )
    doigt: Mapped[int] = mapped_column(SmallInteger)
    modele: Mapped[bytes] = mapped_column(LargeBinary)
    qualite: Mapped[int | None] = mapped_column(SmallInteger)
    # Version du moteur de comparaison : un changement de version impose de recalculer les modèles.
    version_moteur: Mapped[str] = mapped_column(String(50))
    cree_le: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (
        UniqueConstraint("citoyen_id", "doigt", name="uq_empreintes_citoyen_doigt"),
        CheckConstraint("doigt BETWEEN 1 AND 10", name="doigt"),
        CheckConstraint("qualite IS NULL OR qualite BETWEEN 0 AND 100", name="qualite"),
    )


class JournalAction(Base):
    """Journal de toutes les actions : qui, quoi, sur quoi, quand."""

    __tablename__ = "journal_actions"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    agent_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("agents.id", ondelete="SET NULL"), index=True
    )
    action: Mapped[str] = mapped_column(String(50))
    cible: Mapped[str | None] = mapped_column(String(100))
    details: Mapped[dict | None] = mapped_column(JSONB)
    horodatage: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), index=True
    )


class CompteurNumero(Base):
    """Dernière séquence attribuée pour chaque année (voir app/numero.py)."""

    __tablename__ = "compteurs_numero"

    annee: Mapped[int] = mapped_column(SmallInteger, primary_key=True, autoincrement=False)
    dernier: Mapped[int] = mapped_column(Integer)
