"""Création, lecture et recherche des fiches."""

import pytest
from sqlalchemy import select

from app.models import JournalAction
from app.numero import est_numero_valide
from tests.conftest import CITOYEN_FICTIF


# --- Création ---

def test_creation_attribue_un_numero_valide(creer_citoyen, agent, db):
    fiche = creer_citoyen()
    assert est_numero_valide(fiche["numero"])
    assert fiche["agent_id"] == str(agent.id)
    assert fiche["nom"] == "MSA"
    journal = db.scalars(select(JournalAction).where(JournalAction.action == "citoyen_creation")).all()
    assert [j.cible for j in journal] == [fiche["numero"]]


def test_creations_successives_numeros_differents(creer_citoyen):
    numeros = {creer_citoyen()["numero"] for _ in range(5)}
    assert len(numeros) == 5


@pytest.mark.parametrize(
    "saisie,attendu",
    [("+269 321 00 00", "+2693210000"), ("321-00-00", "+2693210000"), ("00269 3210000", "+2693210000"),
     ("", None), (None, None)],
)
def test_telephone_normalise(creer_citoyen, saisie, attendu):
    assert creer_citoyen(telephone=saisie)["telephone"] == attendu


@pytest.mark.parametrize(
    "champ,valeur",
    [
        ("telephone", "+33612345678"),
        ("telephone", "+269 12"),
        ("taille_cm", 49),
        ("taille_cm", 251),
        ("date_naissance", "2999-01-01"),
        ("date_naissance", "1850-01-01"),
        ("date_naissance", "14/05/1990"),
        ("ile", "Mayotte"),
        ("sexe", "X"),
        ("couleur_yeux", "violets"),
        ("nom", "   "),
    ],
)
def test_validation_des_champs(client, entetes, champ, valeur):
    reponse = client.post("/citoyens", json={**CITOYEN_FICTIF, champ: valeur}, headers=entetes)
    assert reponse.status_code == 422, reponse.text


@pytest.mark.parametrize("champ", ["nom", "prenoms", "sexe", "date_naissance", "ile", "taille_cm"])
def test_champ_obligatoire(client, entetes, champ):
    donnees = {k: v for k, v in CITOYEN_FICTIF.items() if k != champ}
    assert client.post("/citoyens", json=donnees, headers=entetes).status_code == 422


def test_numero_impose_par_le_client_ignore(client, entetes, creer_citoyen):
    """Le client ne peut pas choisir le numéro : seul le serveur l'attribue."""
    existant = creer_citoyen()["numero"]
    nouvelle = creer_citoyen(numero=existant, agent_id="00000000-0000-0000-0000-000000000000")
    assert nouvelle["numero"] != existant
    assert est_numero_valide(nouvelle["numero"])
    assert nouvelle["agent_id"] != "00000000-0000-0000-0000-000000000000"


# --- Lecture ---

def test_lecture_par_numero(client, entetes, creer_citoyen):
    fiche = creer_citoyen()
    reponse = client.get(f"/citoyens/{fiche['numero']}", headers=entetes)
    assert reponse.status_code == 200
    assert reponse.json() == fiche


def test_lecture_numero_en_minuscules(client, entetes, creer_citoyen):
    fiche = creer_citoyen()
    assert client.get(f"/citoyens/{fiche['numero'].lower()}", headers=entetes).status_code == 200


def test_lecture_fiche_inexistante(client, entetes):
    assert client.get("/citoyens/KM-2026-999999-A", headers=entetes).status_code == 404


# --- Recherche ---

@pytest.fixture
def trois_fiches(creer_citoyen):
    return [
        creer_citoyen(nom="MSA", prenoms="Ahmed", ile="Ngazidja"),
        creer_citoyen(nom="SAID", prenoms="Fatima Zaharia", sexe="F", ile="Mwali", ville="Fomboni"),
        creer_citoyen(nom="MADI", prenoms="Moussa", ile="Ndzuani", ville="Mutsamudu"),
    ]


def _rechercher(client, entetes, **parametres):
    reponse = client.get("/citoyens", params=parametres, headers=entetes)
    assert reponse.status_code == 200, reponse.text
    return reponse.json()


def test_liste_complete_plus_recentes_d_abord(client, entetes, trois_fiches):
    page = _rechercher(client, entetes)
    assert page["total"] == 3
    assert [r["nom"] for r in page["resultats"]] == ["MADI", "SAID", "MSA"]


def test_recherche_par_nom_partiel_insensible_a_la_casse(client, entetes, trois_fiches):
    page = _rechercher(client, entetes, q="sai")
    assert [r["nom"] for r in page["resultats"]] == ["SAID"]


def test_recherche_par_prenom_et_nom_complet(client, entetes, trois_fiches):
    assert _rechercher(client, entetes, q="zaharia")["total"] == 1
    assert _rechercher(client, entetes, q="Fatima Zaharia SAID")["total"] == 1
    assert _rechercher(client, entetes, q="SAID Fatima")["total"] == 1


def test_recherche_par_numero(client, entetes, trois_fiches):
    numero = trois_fiches[1]["numero"]
    page = _rechercher(client, entetes, q=numero.lower())
    assert [r["numero"] for r in page["resultats"]] == [numero]


def test_filtre_par_ile(client, entetes, trois_fiches):
    page = _rechercher(client, entetes, ile="Mwali")
    assert [r["nom"] for r in page["resultats"]] == ["SAID"]


def test_jokers_sql_neutralises(client, entetes, trois_fiches):
    assert _rechercher(client, entetes, q="%")["total"] == 0
    assert _rechercher(client, entetes, q="_")["total"] == 0


def test_pagination(client, entetes, creer_citoyen):
    for _ in range(5):
        creer_citoyen()
    page2 = _rechercher(client, entetes, page=2, taille_page=2)
    assert page2["total"] == 5
    assert len(page2["resultats"]) == 2
    assert len(_rechercher(client, entetes, page=3, taille_page=2)["resultats"]) == 1


def test_parametres_de_recherche_invalides(client, entetes):
    assert client.get("/citoyens", params={"ile": "Mayotte"}, headers=entetes).status_code == 422
    assert client.get("/citoyens", params={"taille_page": 500}, headers=entetes).status_code == 422
    assert client.get("/citoyens", params={"page": 0}, headers=entetes).status_code == 422


def test_consultation_et_recherche_journalisees(client, entetes, creer_citoyen, db):
    fiche = creer_citoyen()
    client.get(f"/citoyens/{fiche['numero']}", headers=entetes)
    client.get("/citoyens", params={"q": "msa"}, headers=entetes)
    actions = [j.action for j in db.scalars(select(JournalAction))]
    assert "citoyen_consultation" in actions
    assert "citoyen_recherche" in actions
