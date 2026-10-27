"""Fixtures de test : base PostgreSQL dédiée (TEST_DATABASE_URL), vidée avant chaque test."""

from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.orm import sessionmaker

from app.config import parametres
from app.db import get_db
from app.main import app
from app.models import Agent, Appareil
from app.securite import hacher_mot_de_passe

DOSSIER_BACKEND = Path(__file__).resolve().parents[1]
MOT_DE_PASSE_TEST = "mot-de-passe-de-test"  # valeur de test, sans rapport avec .env
APPAREIL_TEST = "appareil-de-test-0001"  # identifiant d'un appareil approuvé par la fixture


def connecter(client, matricule, mot_de_passe=MOT_DE_PASSE_TEST, appareil=APPAREIL_TEST):
    """POST /auth/connexion comme le fait l'application (client_id = appareil)."""
    donnees = {"username": matricule, "password": mot_de_passe}
    if appareil is not None:
        donnees["client_id"] = appareil
    return client.post("/auth/connexion", data=donnees)


def entetes_de(reponse) -> dict:
    assert reponse.status_code == 200, reponse.text
    return {"Authorization": f"Bearer {reponse.json()['access_token']}"}

# Données FICTIVES réutilisées par les tests.
CITOYEN_FICTIF = {
    "nom": "MSA",
    "prenoms": "Ahmed Nassur",
    "sexe": "M",
    "date_naissance": "1990-05-14",
    "lieu_naissance": "Moroni",
    "nationalite": "Comorienne",
    "numero_acte_naissance": "FICTIF-1990-0001",
    "telephone": "+269 321 00 00",
    "ile": "Ngazidja",
    "ville": "Moroni",
    "quartier": "Magoudjou",
    "adresse": "Rue fictive n° 1",
    "taille_cm": 172,
    "couleur_yeux": "marron",
    "couleur_cheveux": "noirs",
}


def _creer_base_si_absente(url: str) -> None:
    url_obj = make_url(url)
    admin = create_engine(url_obj.set(database="postgres"), isolation_level="AUTOCOMMIT")
    with admin.connect() as connexion:
        existe = connexion.scalar(
            text("SELECT 1 FROM pg_database WHERE datname = :nom"), {"nom": url_obj.database}
        )
        if not existe:
            connexion.execute(text(f'CREATE DATABASE "{url_obj.database}"'))
    admin.dispose()


@pytest.fixture(scope="session")
def moteur():
    url = parametres.test_database_url
    if not url:
        pytest.exit("TEST_DATABASE_URL manquant : les tests exigent une base dédiée.")
    if url == parametres.database_url:
        pytest.exit("TEST_DATABASE_URL doit être différent de DATABASE_URL.")
    _creer_base_si_absente(url)

    # Repart de zéro et teste au passage la migration dans les deux sens.
    config = Config(str(DOSSIER_BACKEND / "alembic.ini"))
    config.set_main_option("script_location", str(DOSSIER_BACKEND / "alembic"))
    config.set_main_option("sqlalchemy.url", url.replace("%", "%%"))
    command.downgrade(config, "base")
    command.upgrade(config, "head")

    moteur = create_engine(url)
    yield moteur
    moteur.dispose()


@pytest.fixture
def fabrique_sessions(moteur):
    with moteur.begin() as connexion:
        connexion.execute(
            text(
                "TRUNCATE journal_actions, sessions_agents, appareils, empreintes, citoyens_medias, citoyens, "
                "agents, compteurs_numero RESTART IDENTITY CASCADE"
            )
        )
    return sessionmaker(bind=moteur, autoflush=False, expire_on_commit=False)


@pytest.fixture
def db(fabrique_sessions):
    with fabrique_sessions() as session:
        yield session


@pytest.fixture
def client(fabrique_sessions):
    def get_db_test():
        with fabrique_sessions() as session:
            yield session

    app.dependency_overrides[get_db] = get_db_test
    with TestClient(app) as client:
        yield client
    app.dependency_overrides.clear()


@pytest.fixture
def creer_agent(db):
    def _creer(matricule="AG-TEST", statut="actif", role="agent"):
        agent = Agent(
            matricule=matricule,
            nom="Agent fictif",
            mot_de_passe_hash=hacher_mot_de_passe(MOT_DE_PASSE_TEST),
            role=role,
            statut=statut,
            ile="Ngazidja",
        )
        db.add(agent)
        db.commit()
        return agent

    return _creer


@pytest.fixture
def agent(creer_agent):
    return creer_agent()


@pytest.fixture
def appareil(db):
    """Appareil déjà approuvé (APPAREIL_TEST)."""
    appareil = Appareil(identifiant=APPAREIL_TEST, nom="Téléphone de test", statut="approuve")
    db.add(appareil)
    db.commit()
    return appareil


@pytest.fixture
def entetes(client, agent, appareil):
    """En-têtes HTTP d'un agent connecté depuis l'appareil approuvé."""
    return entetes_de(connecter(client, agent.matricule))


@pytest.fixture
def creer_citoyen(client, entetes):
    def _creer(**modifications):
        reponse = client.post("/citoyens", json={**CITOYEN_FICTIF, **modifications}, headers=entetes)
        assert reponse.status_code == 201, reponse.text
        return reponse.json()

    return _creer
