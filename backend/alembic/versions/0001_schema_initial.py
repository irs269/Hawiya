"""Schéma initial : agents, citoyens, médias, empreintes, journal, compteurs.

Révision : 0001
Précédente :
Créée le : 2026-09-30

Les listes de valeurs des contraintes CHECK sont recopiées ici volontairement
(et non importées de app.referentiels) : une migration doit rester figée.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

ILES = "'Ngazidja', 'Ndzuani', 'Mwali'"


def upgrade() -> None:
    op.create_table(
        "agents",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("matricule", sa.String(20), nullable=False),
        sa.Column("nom", sa.String(150), nullable=False),
        sa.Column("mot_de_passe_hash", sa.String(255), nullable=False),
        sa.Column("role", sa.String(20), server_default="agent", nullable=False),
        sa.Column("ile", sa.String(20), nullable=True),
        sa.Column("commune", sa.String(100), nullable=True),
        sa.Column("statut", sa.String(20), server_default="actif", nullable=False),
        sa.Column("cree_le", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("id", name="pk_agents"),
        sa.UniqueConstraint("matricule", name="uq_agents_matricule"),
        sa.CheckConstraint(
            "role IN ('agent', 'superviseur', 'administrateur')", name="ck_agents_role"
        ),
        sa.CheckConstraint(
            "statut IN ('actif', 'suspendu', 'desactive')", name="ck_agents_statut"
        ),
        sa.CheckConstraint(f"ile IS NULL OR ile IN ({ILES})", name="ck_agents_ile"),
    )

    op.create_table(
        "citoyens",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("numero", sa.String(20), nullable=False),
        sa.Column("nom", sa.String(100), nullable=False),
        sa.Column("prenoms", sa.String(150), nullable=False),
        sa.Column("sexe", sa.String(1), nullable=False),
        sa.Column("date_naissance", sa.Date(), nullable=False),
        sa.Column("lieu_naissance", sa.String(150), nullable=False),
        sa.Column("nationalite", sa.String(100), nullable=False),
        sa.Column("numero_acte_naissance", sa.String(50), nullable=False),
        sa.Column("telephone", sa.String(20), nullable=True),
        sa.Column("ile", sa.String(20), nullable=False),
        sa.Column("ville", sa.String(100), nullable=False),
        sa.Column("quartier", sa.String(100), nullable=False),
        sa.Column("adresse", sa.String(255), nullable=False),
        sa.Column("taille_cm", sa.SmallInteger(), nullable=False),
        sa.Column("couleur_yeux", sa.String(20), nullable=False),
        sa.Column("couleur_cheveux", sa.String(20), nullable=False),
        sa.Column("agent_id", sa.Uuid(), nullable=False),
        sa.Column(
            "enregistre_le", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.PrimaryKeyConstraint("id", name="pk_citoyens"),
        sa.UniqueConstraint("numero", name="uq_citoyens_numero"),
        sa.ForeignKeyConstraint(
            ["agent_id"], ["agents.id"], name="fk_citoyens_agent_id", ondelete="RESTRICT"
        ),
        sa.CheckConstraint("sexe IN ('M', 'F')", name="ck_citoyens_sexe"),
        sa.CheckConstraint(f"ile IN ({ILES})", name="ck_citoyens_ile"),
        sa.CheckConstraint(
            "couleur_yeux IN ('noirs', 'marron_fonce', 'marron', 'noisette', 'verts', "
            "'bleus', 'gris', 'autre')",
            name="ck_citoyens_couleur_yeux",
        ),
        sa.CheckConstraint(
            "couleur_cheveux IN ('noirs', 'bruns', 'chatains', 'blonds', 'roux', 'gris', "
            "'blancs', 'chauve', 'autre')",
            name="ck_citoyens_couleur_cheveux",
        ),
        sa.CheckConstraint("taille_cm BETWEEN 50 AND 250", name="ck_citoyens_taille_cm"),
    )
    op.create_index("ix_citoyens_ile", "citoyens", ["ile"])
    op.create_index("ix_citoyens_agent_id", "citoyens", ["agent_id"])
    op.create_index("ix_citoyens_enregistre_le", "citoyens", ["enregistre_le"])

    op.create_table(
        "citoyens_medias",
        sa.Column("citoyen_id", sa.Uuid(), nullable=False),
        sa.Column("photo", sa.LargeBinary(), nullable=True),
        sa.Column("photo_type_mime", sa.String(50), nullable=True),
        sa.Column("signature", sa.LargeBinary(), nullable=True),
        sa.Column(
            "mis_a_jour_le", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.PrimaryKeyConstraint("citoyen_id", name="pk_citoyens_medias"),
        sa.ForeignKeyConstraint(
            ["citoyen_id"], ["citoyens.id"], name="fk_citoyens_medias_citoyen_id", ondelete="CASCADE"
        ),
    )

    op.create_table(
        "empreintes",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("citoyen_id", sa.Uuid(), nullable=False),
        sa.Column("doigt", sa.SmallInteger(), nullable=False),
        sa.Column("modele", sa.LargeBinary(), nullable=False),
        sa.Column("qualite", sa.SmallInteger(), nullable=True),
        sa.Column("version_moteur", sa.String(50), nullable=False),
        sa.Column("cree_le", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("id", name="pk_empreintes"),
        sa.ForeignKeyConstraint(
            ["citoyen_id"], ["citoyens.id"], name="fk_empreintes_citoyen_id", ondelete="CASCADE"
        ),
        sa.UniqueConstraint("citoyen_id", "doigt", name="uq_empreintes_citoyen_doigt"),
        sa.CheckConstraint("doigt BETWEEN 1 AND 10", name="ck_empreintes_doigt"),
        sa.CheckConstraint(
            "qualite IS NULL OR qualite BETWEEN 0 AND 100", name="ck_empreintes_qualite"
        ),
    )
    op.create_index("ix_empreintes_citoyen_id", "empreintes", ["citoyen_id"])

    op.create_table(
        "journal_actions",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("agent_id", sa.Uuid(), nullable=True),
        sa.Column("action", sa.String(50), nullable=False),
        sa.Column("cible", sa.String(100), nullable=True),
        sa.Column("details", postgresql.JSONB(), nullable=True),
        sa.Column(
            "horodatage", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.PrimaryKeyConstraint("id", name="pk_journal_actions"),
        sa.ForeignKeyConstraint(
            ["agent_id"], ["agents.id"], name="fk_journal_actions_agent_id", ondelete="SET NULL"
        ),
    )
    op.create_index("ix_journal_actions_agent_id", "journal_actions", ["agent_id"])
    op.create_index("ix_journal_actions_horodatage", "journal_actions", ["horodatage"])

    op.create_table(
        "compteurs_numero",
        sa.Column("annee", sa.SmallInteger(), autoincrement=False, nullable=False),
        sa.Column("dernier", sa.Integer(), nullable=False),
        sa.PrimaryKeyConstraint("annee", name="pk_compteurs_numero"),
    )


def downgrade() -> None:
    op.drop_table("compteurs_numero")
    op.drop_table("journal_actions")
    op.drop_table("empreintes")
    op.drop_table("citoyens_medias")
    op.drop_table("citoyens")
    op.drop_table("agents")
