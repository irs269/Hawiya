"""Administration : agents (administrateurs) et appareils (superviseurs)."""

from sqlalchemy import select

from app.models import Appareil, JournalAction
from app.outils import main as outils
from tests.conftest import connecter, entetes_de


def _entetes(client, creer_agent, role, matricule):
    creer_agent(matricule=matricule, role=role)
    return entetes_de(connecter(client, matricule))


# --- Agents ---


def test_creation_d_agent_avec_mot_de_passe_provisoire(client, creer_agent, appareil, db):
    admin = _entetes(client, creer_agent, "administrateur", "AG-ADMIN")
    reponse = client.post("/agents", json={"matricule": "ag-0100", "nom": "Agent fictif 100", "ile": "Mwali"}, headers=admin)
    assert reponse.status_code == 201, reponse.text
    corps = reponse.json()
    assert corps["matricule"] == "AG-0100" and corps["doit_changer_mot_de_passe"] is True
    provisoire = corps["mot_de_passe_provisoire"]
    assert len(provisoire) == 12

    connexion = connecter(client, "AG-0100", provisoire)
    assert connexion.json()["doit_changer_mot_de_passe"] is True
    assert [a["matricule"] for a in client.get("/agents", headers=admin).json()] == ["AG-0100", "AG-ADMIN"]
    # Le mot de passe provisoire n'apparaît jamais dans le journal.
    assert provisoire not in str([j.details for j in db.scalars(select(JournalAction))])


def test_matricule_existant_ou_invalide(client, creer_agent, appareil):
    admin = _entetes(client, creer_agent, "administrateur", "AG-ADMIN")
    assert client.post("/agents", json={"matricule": "AG-ADMIN", "nom": "x"}, headers=admin).status_code == 409
    assert client.post("/agents", json={"matricule": "a b", "nom": "x"}, headers=admin).status_code == 422


def test_seul_l_administrateur_gere_les_agents(client, creer_agent, appareil):
    for role, matricule in (("agent", "AG-SIMPLE"), ("superviseur", "AG-SUP")):
        entetes = _entetes(client, creer_agent, role, matricule)
        assert client.get("/agents", headers=entetes).status_code == 403
        assert client.post("/agents", json={"matricule": "AG-0101", "nom": "x"}, headers=entetes).status_code == 403


def test_suspension_coupe_les_sessions(client, creer_agent, appareil):
    admin = _entetes(client, creer_agent, "administrateur", "AG-ADMIN")
    agent = _entetes(client, creer_agent, "agent", "AG-SIMPLE")
    assert client.get("/citoyens", headers=agent).status_code == 200
    reponse = client.patch("/agents/ag-simple", json={"statut": "suspendu", "role": "superviseur"}, headers=admin)
    assert reponse.status_code == 200 and reponse.json()["statut"] == "suspendu"
    assert client.get("/citoyens", headers=agent).status_code == 401


def test_l_administrateur_ne_se_retire_pas_ses_droits(client, creer_agent, appareil):
    admin = _entetes(client, creer_agent, "administrateur", "AG-ADMIN")
    assert client.patch("/agents/AG-ADMIN", json={"statut": "suspendu"}, headers=admin).status_code == 400
    assert client.patch("/agents/AG-ADMIN", json={"role": "agent"}, headers=admin).status_code == 400
    assert client.patch("/agents/AG-ADMIN", json={"ile": "Ndzuani"}, headers=admin).status_code == 200


def test_reinitialisation(client, creer_agent, appareil):
    admin = _entetes(client, creer_agent, "administrateur", "AG-ADMIN")
    agent = _entetes(client, creer_agent, "agent", "AG-SIMPLE")
    reponse = client.post("/agents/AG-SIMPLE/reinitialiser", headers=admin)
    provisoire = reponse.json()["mot_de_passe_provisoire"]
    assert client.get("/citoyens", headers=agent).status_code == 401  # sessions coupées
    assert connecter(client, "AG-SIMPLE", provisoire).json()["doit_changer_mot_de_passe"] is True
    assert client.post("/agents/AG-INCONNU/reinitialiser", headers=admin).status_code == 404


# --- Appareils ---


def test_approbation_d_un_appareil_par_un_superviseur(client, creer_agent, appareil, db):
    superviseur = _entetes(client, creer_agent, "superviseur", "AG-SUP")
    creer_agent(matricule="AG-NOUVEAU")
    demande = connecter(client, "AG-NOUVEAU", appareil="f00dcafe12345678")
    code = demande.json()["detail"]["code_appareil"]

    en_attente = client.get("/appareils?statut=en_attente", headers=superviseur).json()
    assert [(a["code"], a["demande_par"]) for a in en_attente] == [(code, "AG-NOUVEAU")]
    reponse = client.post(f"/appareils/{code.lower()}/approuver", headers=superviseur)
    assert reponse.status_code == 200 and reponse.json()["statut"] == "approuve"
    assert connecter(client, "AG-NOUVEAU", appareil="f00dcafe12345678").status_code == 200


def test_revocation_definitive(client, creer_agent, appareil, db):
    superviseur = _entetes(client, creer_agent, "superviseur", "AG-SUP")
    assert client.post(f"/appareils/{appareil.code}/revoquer", headers=superviseur).status_code == 200
    assert client.get("/citoyens", headers=superviseur).status_code == 401  # c'était le sien aussi
    # Personne ne peut le réapprouver.
    autre = Appareil(identifiant="poste-superviseur-02", statut="approuve")
    db.add(autre)
    db.commit()
    entetes = entetes_de(connecter(client, "AG-SUP", appareil="poste-superviseur-02"))
    assert client.post(f"/appareils/{appareil.code}/approuver", headers=entetes).status_code == 409


def test_un_agent_n_approuve_pas_d_appareil(client, creer_agent, appareil):
    agent = _entetes(client, creer_agent, "agent", "AG-SIMPLE")
    assert client.get("/appareils", headers=agent).status_code == 403
    assert client.post(f"/appareils/{appareil.code}/approuver", headers=agent).status_code == 403


def test_code_inconnu_ou_trop_court(client, creer_agent, appareil):
    superviseur = _entetes(client, creer_agent, "superviseur", "AG-SUP")
    assert client.post("/appareils/00000000/approuver", headers=superviseur).status_code == 404
    assert client.post("/appareils/abc/approuver", headers=superviseur).status_code == 400


def test_outil_en_ligne_de_commande(client, agent, db, fabrique_sessions, monkeypatch, capsys):
    """Premier démarrage : approuver depuis le serveur, sans superviseur connecté."""
    monkeypatch.setattr("app.outils.SessionLocale", fabrique_sessions)
    code = connecter(client, agent.matricule, appareil="beefbeef00000001").json()["detail"]["code_appareil"]
    outils(["appareils"])
    assert code in capsys.readouterr().out
    outils(["approuver", code])
    assert connecter(client, agent.matricule, appareil="beefbeef00000001").status_code == 200
    outils(["reinitialiser", agent.matricule])
    assert "Mot de passe provisoire" in capsys.readouterr().out
