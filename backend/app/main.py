"""Point d'entrée de l'API Hawiya."""

from fastapi import FastAPI
from sqlalchemy import text

from app.dependances import SessionDb
from app.routers import administration, auth, biometrie, citoyens, statistiques

app = FastAPI(
    title="Hawiya — API (prototype)",
    description=(
        "Prototype de démonstration d'identification biométrique. "
        "**Système non officiel** — données fictives uniquement.\n\n"
        "Pour tester : bouton **Authorize**, saisir le matricule, le mot de passe de "
        "l'agent de démonstration (voir .env) et, dans **client_id**, l'identifiant de "
        "l'appareil (8 caractères au moins). Un nouvel appareil doit être approuvé : "
        "`python -m app.outils approuver <code>` dans le conteneur backend."
    ),
    version="0.1.0",
)

app.include_router(auth.router)
app.include_router(citoyens.router)
app.include_router(statistiques.router)
app.include_router(biometrie.router)
app.include_router(administration.router)


@app.get("/sante", tags=["Supervision"])
def sante(db: SessionDb):
    """Vérifie que l'API et la base de données répondent."""
    db.execute(text("SELECT 1"))
    return {"statut": "ok"}
