"""Authentification des agents : appareil approuvé, blocage, jetons
renouvelables, déconnexion, mot de passe provisoire."""

from datetime import datetime, timedelta, timezone

import jwt
from sqlalchemy import select

from app.config import parametres
from app.models import Agent, Appareil, JournalAction, SessionAgent
from tests.conftest import APPAREIL_TEST, MOT_DE_PASSE_TEST, connecter, entetes_de


def _actions(db):
    return [(j.action, (j.details or {}).get("raison")) for j in db.scalars(select(JournalAction))]


# --- Connexion ---


def test_connexion_reussie(client, agent, appareil, db):
    reponse = connecter(client, agent.matricule)
    assert reponse.status_code == 200
    corps = reponse.json()
    assert corps["token_type"] == "bearer"
    assert corps["refresh_token"] and corps["expires_in"] == parametres.jwt_duree_minutes * 60
    assert corps["doit_changer_mot_de_passe"] is False
    assert ("connexion_reussie", None) in _actions(db)
    # Le jeton de renouvellement n'est jamais stocké en clair.
    session = db.scalar(select(SessionAgent))
    assert session.hash_jeton != corps["refresh_token"] and len(session.hash_jeton) == 64


def test_matricule_insensible_a_la_casse(client, agent, appareil):
    assert connecter(client, "  ag-test ").status_code == 200


def test_mauvais_mot_de_passe(client, agent, appareil, db):
    reponse = connecter(client, agent.matricule, "faux")
    assert reponse.status_code == 401
    assert ("connexion_echouee", "mot_de_passe_incorrect") in _actions(db)


def test_matricule_inconnu_meme_message(client, agent, appareil, db):
    inconnu = connecter(client, "AG-9999")
    mauvais = connecter(client, agent.matricule, "faux")
    assert inconnu.status_code == mauvais.status_code == 401
    assert inconnu.json() == mauvais.json()
    assert ("connexion_echouee", "matricule_inconnu") in _actions(db)


def test_agent_suspendu_refuse(client, creer_agent, appareil, db):
    creer_agent(matricule="AG-SUSP", statut="suspendu")
    assert connecter(client, "AG-SUSP").status_code == 401
    assert ("connexion_echouee", "agent_suspendu") in _actions(db)


# --- Blocage après échecs ---


def test_blocage_apres_5_echecs_meme_avec_le_bon_mot_de_passe(client, agent, appareil, db):
    for _ in range(parametres.connexion_echecs_max):
        assert connecter(client, agent.matricule, "faux").status_code == 401
    bloque = connecter(client, agent.matricule)
    assert bloque.status_code == 401
    assert bloque.json() == connecter(client, agent.matricule, "faux").json()  # rien ne trahit le blocage
    assert ("compte_bloque", None) in _actions(db)
    assert ("connexion_echouee", "compte_bloque") in _actions(db)

    # Fin du blocage : le bon mot de passe passe de nouveau.
    db.expire_all()
    a = db.get(Agent, agent.id)
    a.bloque_jusqu_a = datetime.now(timezone.utc) - timedelta(seconds=1)
    db.commit()
    assert connecter(client, agent.matricule).status_code == 200


def test_succes_remet_le_compteur_a_zero(client, agent, appareil, db):
    for _ in range(parametres.connexion_echecs_max - 1):
        connecter(client, agent.matricule, "faux")
    assert connecter(client, agent.matricule).status_code == 200
    for _ in range(parametres.connexion_echecs_max - 1):
        connecter(client, agent.matricule, "faux")
    assert connecter(client, agent.matricule).status_code == 200


# --- Appareils ---


def test_nouvel_appareil_en_attente(client, agent, db):
    reponse = client.post(
        "/auth/connexion",
        data={"username": agent.matricule, "password": MOT_DE_PASSE_TEST, "client_id": "a1b2c3d4e5f6a7b8", "appareil_nom": "Galaxy fictif"},
    )
    assert reponse.status_code == 403
    detail = reponse.json()["detail"]
    assert detail["code"] == "appareil_en_attente"
    assert detail["code_appareil"] == "A1B2C3D4"
    appareil = db.scalar(select(Appareil))
    assert (appareil.statut, appareil.nom, appareil.agent_id) == ("en_attente", "Galaxy fictif", agent.id)
    # Deuxième essai : toujours en attente, pas de doublon d'appareil.
    assert connecter(client, agent.matricule, appareil="a1b2c3d4e5f6a7b8").status_code == 403
    assert len(db.scalars(select(Appareil)).all()) == 1


def test_appareil_obligatoire(client, agent, appareil):
    assert connecter(client, agent.matricule, appareil=None).status_code == 400
    assert connecter(client, agent.matricule, appareil="court").status_code == 400


def test_mauvais_mot_de_passe_ne_cree_pas_d_appareil(client, agent, db):
    connecter(client, agent.matricule, "faux", appareil="inconnu-0000-0000")
    assert db.scalars(select(Appareil)).all() == []


def test_appareil_revoque_coupe_les_sessions(client, agent, appareil, entetes, db):
    assert client.get("/citoyens", headers=entetes).status_code == 200
    a = db.get(Appareil, appareil.id)
    a.statut = "revoque"
    db.commit()
    assert client.get("/citoyens", headers=entetes).status_code == 401
    refus = connecter(client, agent.matricule)
    assert refus.status_code == 403 and refus.json()["detail"]["code"] == "appareil_revoque"


# --- Jetons ---


def test_agent_desactive_perd_l_acces_avec_un_jeton_deja_emis(client, agent, entetes, db):
    assert client.get("/statistiques", headers=entetes).status_code == 200
    agent.statut = "desactive"
    db.merge(agent)
    db.commit()
    assert client.get("/statistiques", headers=entetes).status_code == 401


def test_acces_sans_jeton_refuse(client):
    assert client.get("/citoyens").status_code == 401
    assert client.get("/statistiques").status_code == 401


def test_jeton_falsifie_refuse(client, agent, appareil):
    charge = {"sub": str(agent.id), "app": str(appareil.id), "fam": str(appareil.id),
              "exp": datetime.now(timezone.utc) + timedelta(hours=1)}
    faux = jwt.encode(charge, "x" * 40, algorithm="HS256")
    assert client.get("/citoyens", headers={"Authorization": f"Bearer {faux}"}).status_code == 401


def test_ancien_format_de_jeton_refuse(client, agent):
    """Jeton de la phase 1 (sans appareil ni session) : refusé."""
    ancien = jwt.encode({"sub": str(agent.id), "exp": datetime.now(timezone.utc) + timedelta(hours=1)},
                        parametres.jwt_secret, algorithm=parametres.jwt_algorithme)
    assert client.get("/citoyens", headers={"Authorization": f"Bearer {ancien}"}).status_code == 401


def test_jeton_expire_refuse(client, agent, appareil):
    expire = jwt.encode(
        {"sub": str(agent.id), "app": str(appareil.id), "fam": str(appareil.id),
         "exp": datetime.now(timezone.utc) - timedelta(minutes=1)},
        parametres.jwt_secret,
        algorithm=parametres.jwt_algorithme,
    )
    assert client.get("/citoyens", headers={"Authorization": f"Bearer {expire}"}).status_code == 401


def test_renouvellement_avec_rotation(client, agent, appareil, db):
    premier = connecter(client, agent.matricule).json()
    reponse = client.post("/auth/renouveler", json={"refresh_token": premier["refresh_token"]})
    assert reponse.status_code == 200
    second = reponse.json()
    assert second["refresh_token"] != premier["refresh_token"]
    assert client.get("/citoyens", headers={"Authorization": f"Bearer {second['access_token']}"}).status_code == 200
    # Le nouveau jeton de renouvellement fonctionne à son tour.
    assert client.post("/auth/renouveler", json={"refresh_token": second["refresh_token"]}).status_code == 200


def test_reutilisation_d_un_jeton_revoque_toute_la_session(client, agent, appareil, db):
    premier = connecter(client, agent.matricule).json()
    second = client.post("/auth/renouveler", json={"refresh_token": premier["refresh_token"]}).json()

    # L'ancien jeton revient (copié par quelqu'un) : refus, et la session entière tombe.
    vol = client.post("/auth/renouveler", json={"refresh_token": premier["refresh_token"]})
    assert vol.status_code == 401 and vol.json()["detail"]["code"] == "jeton_reutilise"
    assert client.post("/auth/renouveler", json={"refresh_token": second["refresh_token"]}).status_code == 401
    assert client.get("/citoyens", headers={"Authorization": f"Bearer {second['access_token']}"}).status_code == 401
    assert ("jeton_reutilise", None) in _actions(db)


def test_renouvellement_refuse(client, agent, appareil, db):
    assert client.post("/auth/renouveler", json={"refresh_token": "x" * 43}).status_code == 401
    jetons = connecter(client, agent.matricule).json()
    for s in db.scalars(select(SessionAgent)):
        s.expire_le = datetime.now(timezone.utc) - timedelta(seconds=1)
    db.commit()
    assert client.post("/auth/renouveler", json={"refresh_token": jetons["refresh_token"]}).status_code == 401


def test_renouvellement_refuse_si_agent_suspendu(client, agent, appareil, db):
    jetons = connecter(client, agent.matricule).json()
    a = db.get(Agent, agent.id)
    a.statut = "suspendu"
    db.commit()
    assert client.post("/auth/renouveler", json={"refresh_token": jetons["refresh_token"]}).status_code == 401


def test_deconnexion(client, agent, appareil):
    jetons = connecter(client, agent.matricule).json()
    entetes = {"Authorization": f"Bearer {jetons['access_token']}"}
    assert client.post("/auth/deconnexion", headers=entetes).status_code == 204
    assert client.get("/citoyens", headers=entetes).status_code == 401
    assert client.post("/auth/renouveler", json={"refresh_token": jetons["refresh_token"]}).status_code == 401


# --- Agent connecté et mot de passe ---


def test_agent_connecte(client, entetes, agent):
    reponse = client.get("/auth/moi", headers=entetes)
    assert reponse.status_code == 200
    assert reponse.json() == {
        "matricule": agent.matricule, "nom": "Agent fictif", "role": "agent", "doit_changer_mot_de_passe": False,
    }


def test_agent_connecte_sans_jeton(client):
    assert client.get("/auth/moi").status_code == 401


def test_mot_de_passe_provisoire_bloque_tout_sauf_le_changement(client, agent, appareil, db):
    a = db.get(Agent, agent.id)
    a.doit_changer_mot_de_passe = True
    db.commit()
    reponse = connecter(client, agent.matricule)
    assert reponse.json()["doit_changer_mot_de_passe"] is True
    entetes = entetes_de(reponse)

    refus = client.get("/citoyens", headers=entetes)
    assert refus.status_code == 403 and refus.json()["detail"]["code"] == "changement_mot_de_passe_requis"
    assert client.get("/auth/moi", headers=entetes).json()["doit_changer_mot_de_passe"] is True

    nouveau = "Nouveau-secret-2026"
    assert client.post("/auth/mot-de-passe", json={"ancien": MOT_DE_PASSE_TEST, "nouveau": nouveau}, headers=entetes).status_code == 204
    assert client.get("/citoyens", headers=entetes).status_code == 200  # même session, débloquée
    assert connecter(client, agent.matricule, nouveau).status_code == 200
    assert connecter(client, agent.matricule, MOT_DE_PASSE_TEST).status_code == 401


def test_regles_du_mot_de_passe(client, agent, entetes):
    def changer(ancien, nouveau):
        return client.post("/auth/mot-de-passe", json={"ancien": ancien, "nouveau": nouveau}, headers=entetes)

    assert changer("faux", "Nouveau-secret-2026").status_code == 400
    assert "10 caractères" in changer(MOT_DE_PASSE_TEST, "court").json()["detail"]
    assert "matricule" in changer(MOT_DE_PASSE_TEST, "xx-ag-test-xx").json()["detail"]
    assert changer(MOT_DE_PASSE_TEST, "aaaaaaaaaaaa").status_code == 400
    assert changer(MOT_DE_PASSE_TEST, MOT_DE_PASSE_TEST).status_code == 400


def test_changement_coupe_les_autres_sessions(client, agent, appareil, db):
    autre = Appareil(identifiant="autre-appareil-0002", statut="approuve")
    db.add(autre)
    db.commit()
    entetes_autre = entetes_de(connecter(client, agent.matricule, appareil="autre-appareil-0002"))
    entetes = entetes_de(connecter(client, agent.matricule, appareil=APPAREIL_TEST))
    client.post("/auth/mot-de-passe", json={"ancien": MOT_DE_PASSE_TEST, "nouveau": "Nouveau-secret-2026"}, headers=entetes)
    assert client.get("/citoyens", headers=entetes).status_code == 200
    assert client.get("/citoyens", headers=entetes_autre).status_code == 401
