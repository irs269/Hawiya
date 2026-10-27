"""Connexion provisoire des agents."""

from datetime import datetime, timedelta, timezone

import jwt
from sqlalchemy import select

from app.config import parametres
from app.models import JournalAction
from tests.conftest import MOT_DE_PASSE_TEST


def _connexion(client, matricule, mot_de_passe=MOT_DE_PASSE_TEST):
    return client.post("/auth/connexion", data={"username": matricule, "password": mot_de_passe})


def _actions(db):
    return [(j.action, (j.details or {}).get("raison")) for j in db.scalars(select(JournalAction))]


def test_connexion_reussie(client, agent, db):
    reponse = _connexion(client, agent.matricule)
    assert reponse.status_code == 200
    assert reponse.json()["token_type"] == "bearer"
    assert ("connexion_reussie", None) in _actions(db)


def test_matricule_insensible_a_la_casse(client, agent):
    assert _connexion(client, "  ag-test ").status_code == 200


def test_mauvais_mot_de_passe(client, agent, db):
    reponse = _connexion(client, agent.matricule, "faux")
    assert reponse.status_code == 401
    assert ("connexion_echouee", "mot_de_passe_incorrect") in _actions(db)


def test_matricule_inconnu_meme_message(client, agent, db):
    inconnu = _connexion(client, "AG-9999")
    mauvais = _connexion(client, agent.matricule, "faux")
    assert inconnu.status_code == mauvais.status_code == 401
    assert inconnu.json() == mauvais.json()
    assert ("connexion_echouee", "matricule_inconnu") in _actions(db)


def test_agent_suspendu_refuse(client, creer_agent, db):
    creer_agent(matricule="AG-SUSP", statut="suspendu")
    assert _connexion(client, "AG-SUSP").status_code == 401
    assert ("connexion_echouee", "agent_suspendu") in _actions(db)


def test_agent_desactive_perd_l_acces_avec_un_jeton_deja_emis(client, agent, entetes, db):
    assert client.get("/statistiques", headers=entetes).status_code == 200
    agent.statut = "desactive"
    db.merge(agent)
    db.commit()
    assert client.get("/statistiques", headers=entetes).status_code == 401


def test_acces_sans_jeton_refuse(client):
    assert client.get("/citoyens").status_code == 401
    assert client.get("/statistiques").status_code == 401


def test_jeton_falsifie_refuse(client, agent):
    faux = jwt.encode({"sub": str(agent.id), "exp": datetime.now(timezone.utc) + timedelta(hours=1)},
                      "x" * 40, algorithm="HS256")
    assert client.get("/citoyens", headers={"Authorization": f"Bearer {faux}"}).status_code == 401


def test_jeton_expire_refuse(client, agent):
    expire = jwt.encode(
        {"sub": str(agent.id), "exp": datetime.now(timezone.utc) - timedelta(minutes=1)},
        parametres.jwt_secret,
        algorithm=parametres.jwt_algorithme,
    )
    assert client.get("/citoyens", headers={"Authorization": f"Bearer {expire}"}).status_code == 401


def test_agent_connecte(client, entetes, agent):
    reponse = client.get("/auth/moi", headers=entetes)
    assert reponse.status_code == 200
    assert reponse.json() == {"matricule": agent.matricule, "nom": "Agent fictif", "role": "agent"}


def test_agent_connecte_sans_jeton(client):
    assert client.get("/auth/moi").status_code == 401
