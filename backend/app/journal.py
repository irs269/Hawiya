"""Écriture dans le journal des actions."""

import uuid

from sqlalchemy.orm import Session

from app.models import JournalAction


def journaliser(
    db: Session,
    action: str,
    agent_id: uuid.UUID | None = None,
    cible: str | None = None,
    details: dict | None = None,
) -> None:
    """Ajoute une ligne au journal dans la transaction en cours.

    L'appelant fait le commit : l'action et sa trace sont enregistrées ensemble.
    """
    db.add(JournalAction(agent_id=agent_id, action=action, cible=cible, details=details))
