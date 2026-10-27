"""Authentification complète (phase 1 bis) : blocage, mot de passe provisoire,
appareils approuvés, sessions (jetons de renouvellement).

Révision : 0002
Précédente : 0001
Créée le : 2026-10-27
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0002"
down_revision: str | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("agents", sa.Column("echecs_connexion", sa.SmallInteger(), server_default="0", nullable=False))
    op.add_column("agents", sa.Column("bloque_jusqu_a", sa.DateTime(timezone=True), nullable=True))
    op.add_column(
        "agents", sa.Column("doit_changer_mot_de_passe", sa.Boolean(), server_default="false", nullable=False)
    )
    op.add_column("agents", sa.Column("mot_de_passe_change_le", sa.DateTime(timezone=True), nullable=True))

    op.create_table(
        "appareils",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("identifiant", sa.String(64), nullable=False),
        sa.Column("nom", sa.String(100), nullable=True),
        sa.Column("statut", sa.String(20), server_default="en_attente", nullable=False),
        sa.Column("agent_id", sa.Uuid(), nullable=True),
        sa.Column("approuve_par", sa.Uuid(), nullable=True),
        sa.Column("approuve_le", sa.DateTime(timezone=True), nullable=True),
        sa.Column("derniere_connexion", sa.DateTime(timezone=True), nullable=True),
        sa.Column("cree_le", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("id", name="pk_appareils"),
        sa.UniqueConstraint("identifiant", name="uq_appareils_identifiant"),
        sa.ForeignKeyConstraint(["agent_id"], ["agents.id"], name="fk_appareils_agent_id", ondelete="SET NULL"),
        sa.ForeignKeyConstraint(
            ["approuve_par"], ["agents.id"], name="fk_appareils_approuve_par", ondelete="SET NULL"
        ),
        sa.CheckConstraint("statut IN ('en_attente', 'approuve', 'revoque')", name="ck_appareils_statut"),
    )
    op.create_index("ix_appareils_agent_id", "appareils", ["agent_id"])

    op.create_table(
        "sessions_agents",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("agent_id", sa.Uuid(), nullable=False),
        sa.Column("appareil_id", sa.Uuid(), nullable=False),
        sa.Column("famille", sa.Uuid(), nullable=False),
        sa.Column("hash_jeton", sa.String(64), nullable=False),
        sa.Column("cree_le", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("expire_le", sa.DateTime(timezone=True), nullable=False),
        sa.Column("utilise_le", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoque_le", sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint("id", name="pk_sessions_agents"),
        sa.UniqueConstraint("hash_jeton", name="uq_sessions_agents_hash_jeton"),
        sa.ForeignKeyConstraint(
            ["agent_id"], ["agents.id"], name="fk_sessions_agents_agent_id", ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["appareil_id"], ["appareils.id"], name="fk_sessions_agents_appareil_id", ondelete="CASCADE"
        ),
    )
    op.create_index("ix_sessions_agents_agent_id", "sessions_agents", ["agent_id"])
    op.create_index("ix_sessions_agents_appareil_id", "sessions_agents", ["appareil_id"])
    op.create_index("ix_sessions_agents_famille", "sessions_agents", ["famille"])


def downgrade() -> None:
    op.drop_table("sessions_agents")
    op.drop_table("appareils")
    op.drop_column("agents", "mot_de_passe_change_le")
    op.drop_column("agents", "doit_changer_mot_de_passe")
    op.drop_column("agents", "bloque_jusqu_a")
    op.drop_column("agents", "echecs_connexion")
