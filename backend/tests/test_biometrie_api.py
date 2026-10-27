"""Routes biométriques, avec un FAUX matcher et des doigts SYNTHÉTIQUES
(aucune vraie empreinte, aucune donnée personnelle réelle)."""

import base64
import hashlib

import cv2
import numpy as np
import pytest
from sqlalchemy import select

from app.biometrie.client_matcher import Candidat, ErreurMatcher
from app.main import app
from app.models import Empreinte, JournalAction
from app.routers.biometrie import get_client_matcher
from tests.conftest import connecter, entetes_de


class FauxMatcher:
    """Imite le matcher : le « modèle » est l'empreinte numérique de l'image
    prétraitée ; deux modèles identiques → score 60 (même doigt), sinon 5.
    `score` peut être remplacé pour fabriquer des cas limites."""

    VERSION = "faux-1"

    def __init__(self):
        self.galerie: dict[str, dict[int, bytes]] = {}
        self.panne = False
        self.score = lambda sonde, candidat, id_, iso: 60.0 if sonde == candidat else 5.0

    def _verifier(self):
        if self.panne:
            raise ErreurMatcher("Matcher injoignable : panne simulée")

    def modele(self, image_png: bytes, dpi: float):
        self._verifier()
        return hashlib.sha256(image_png).digest()[:16], self.VERSION

    def identifier(self, doigts, fusion="SOMME", limite=5):
        self._verifier()
        candidats = []
        for id_, modeles in self.galerie.items():
            scores = {iso: self.score(m, modeles[iso], id_, iso) for iso, m in doigts.items() if iso in modeles}
            if scores:
                candidats.append(Candidat(id_, sum(scores.values()), scores))
        return sorted(candidats, key=lambda c: c.score, reverse=True)[:limite]

    def ajouter(self, identifiant, doigts):
        self._verifier()
        self.galerie[identifiant] = dict(doigts)

    def retirer(self, identifiant):
        self.galerie.pop(identifiant, None)


@pytest.fixture
def faux(client):
    matcher = FauxMatcher()
    app.dependency_overrides[get_client_matcher] = lambda: matcher
    yield matcher
    app.dependency_overrides.pop(get_client_matcher, None)


def decoupe(graine: int) -> str:
    """Fausse découpe de doigt (crêtes synthétiques), différente pour chaque graine."""
    rng = np.random.default_rng(graine)
    periode, angle = rng.uniform(9, 13), rng.uniform(0, np.pi)
    yy, xx = np.indices((400, 300))
    t = (xx * np.cos(angle) + yy * np.sin(angle)) * 2 * np.pi / periode
    gris = 140 + 35 * np.sin(t) + rng.normal(0, 4, t.shape)
    ok, png = cv2.imencode(".png", np.clip(gris, 0, 255).astype(np.uint8))
    assert ok
    return base64.b64encode(png.tobytes()).decode()


def main(personne: int, doigts=(2, 3, 4, 5)) -> list[dict]:
    """Les doigts fictifs d'une personne fictive (mêmes images à chaque appel)."""
    return [{"doigt": d, "image": decoupe(personne * 100 + d), "dpi_estime": 550} for d in doigts]


@pytest.fixture
def enroler(client, entetes, faux):
    def _enroler(numero, personne, **options):
        return client.put(f"/citoyens/{numero}/empreintes", json={"doigts": main(personne), **options}, headers=entetes)

    return _enroler


# --- Enregistrement des empreintes ---


def test_enregistrement_stocke_les_modeles_pas_les_images(enroler, creer_citoyen, db, faux):
    fiche = creer_citoyen()
    reponse = enroler(fiche["numero"], personne=1)
    assert reponse.status_code == 200, reponse.text
    corps = reponse.json()
    assert corps["doigts_enregistres"] == [2, 3, 4, 5]
    assert corps["controle_doublon"]["verdict"] == "aucun_doublon"

    empreintes = db.scalars(select(Empreinte)).all()
    assert len(empreintes) == 4
    assert all(len(e.modele) == 16 and e.version_moteur == "faux-1" for e in empreintes)
    assert fiche["id"] in faux.galerie  # ajoutée au matcher


def test_enregistrement_fiche_inconnue(client, entetes, faux):
    reponse = client.put("/citoyens/KM-2026-999999/empreintes", json={"doigts": main(1)}, headers=entetes)
    assert reponse.status_code == 404


def test_reenregistrement_de_la_meme_personne_accepte(enroler, creer_citoyen, db):
    fiche = creer_citoyen()
    assert enroler(fiche["numero"], personne=1).status_code == 200
    # Elle ne doit pas être prise pour son propre doublon.
    assert enroler(fiche["numero"], personne=1).status_code == 200
    assert len(db.scalars(select(Empreinte)).all()) == 4


def test_doublon_certain_refuse(enroler, creer_citoyen, db):
    a = creer_citoyen()
    b = creer_citoyen(numero_acte_naissance="FICTIF-1990-0002")
    enroler(a["numero"], personne=1)
    reponse = enroler(b["numero"], personne=1)  # mêmes doigts que A
    assert reponse.status_code == 409
    detail = reponse.json()["detail"]
    assert detail["verdict"] == "doublon_certain"
    assert detail["numeros"] == [a["numero"]]
    assert len(db.scalars(select(Empreinte)).all()) == 4  # rien d'ajouté pour B
    assert db.scalar(select(JournalAction).where(JournalAction.action == "empreintes_refus_doublon"))


def test_doublon_possible_valide_par_un_superviseur(client, enroler, creer_citoyen, creer_agent, faux):
    a = creer_citoyen()
    b = creer_citoyen(numero_acte_naissance="FICTIF-1990-0002")
    enroler(a["numero"], personne=1)
    # Un doigt de B ressemble fortement à un doigt de A : doublon possible.
    faux.score = lambda s, c, id_, iso: 60.0 if s == c else (38.0 if iso == 3 else 5.0)
    assert enroler(b["numero"], personne=2).json()["detail"]["verdict"] == "doublon_possible"

    # Un simple agent ne peut pas passer outre.
    assert enroler(b["numero"], personne=2, validation_superviseur=True).status_code == 403

    superviseur = creer_agent(matricule="AG-SUP", role="superviseur")
    entetes_sup = entetes_de(connecter(client, superviseur.matricule))
    reponse = client.put(
        f"/citoyens/{b['numero']}/empreintes",
        json={"doigts": main(2), "validation_superviseur": True},
        headers=entetes_sup,
    )
    assert reponse.status_code == 200, reponse.text
    assert reponse.json()["controle_doublon"]["verdict"] == "doublon_possible"


def test_controle_doublon_avant_creation(client, entetes, enroler, creer_citoyen):
    a = creer_citoyen()
    enroler(a["numero"], personne=1)
    meme = client.post("/doublons", json={"doigts": main(1)}, headers=entetes).json()
    assert meme["verdict"] == "doublon_certain" and meme["numeros"] == [a["numero"]]
    autre = client.post("/doublons", json={"doigts": main(2)}, headers=entetes).json()
    assert autre["verdict"] == "aucun_doublon"


# --- Identification ---


def test_identification_de_la_bonne_personne(client, entetes, enroler, creer_citoyen, db):
    a = creer_citoyen()
    b = creer_citoyen(nom="TEST", numero_acte_naissance="FICTIF-1990-0002")
    enroler(a["numero"], personne=1)
    enroler(b["numero"], personne=2)

    reponse = client.post("/identification", json={"scans": [{"doigts": main(2)}]}, headers=entetes)
    assert reponse.status_code == 200, reponse.text
    corps = reponse.json()
    assert corps["verdict"] == "identifie"
    assert corps["citoyen"]["numero"] == b["numero"]
    assert corps["doigts_concordants"] == 4
    trace = db.scalar(select(JournalAction).where(JournalAction.action == "identification"))
    assert trace.cible == b["numero"] and trace.details["verdict"] == "identifie"


def test_personne_non_enregistree(client, entetes, enroler, creer_citoyen):
    enroler(creer_citoyen()["numero"], personne=1)
    corps = client.post("/identification", json={"scans": [{"doigts": main(7)}]}, headers=entetes).json()
    assert corps["verdict"] == "non_enregistre"
    assert corps["citoyen"] is None


def test_resultat_incertain_aucune_fiche_affichee(client, entetes, enroler, creer_citoyen, faux):
    a = creer_citoyen()
    b = creer_citoyen(numero_acte_naissance="FICTIF-1990-0002")
    enroler(a["numero"], personne=1)
    enroler(b["numero"], personne=2)
    # B ressemble presque autant que A : aucune des deux fiches ne doit sortir.
    faux.score = lambda s, c, id_, iso: 60.0 if s == c else 50.0
    corps = client.post("/identification", json={"scans": [{"doigts": main(1)}]}, headers=entetes).json()
    assert corps["verdict"] == "non_concluant"
    assert corps["citoyen"] is None


def test_trop_peu_de_doigts(client, entetes, enroler, creer_citoyen):
    enroler(creer_citoyen()["numero"], personne=1)
    scan = {"doigts": main(1, doigts=(2, 3))}
    corps = client.post("/identification", json={"scans": [scan]}, headers=entetes).json()
    assert corps["verdict"] == "non_concluant"


def test_doigt_illisible_signale(client, entetes, enroler, creer_citoyen):
    a = creer_citoyen()
    enroler(a["numero"], personne=1)
    doigts = main(1)
    doigts[3]["image"] = base64.b64encode(b"ceci n'est pas une image").decode()
    corps = client.post("/identification", json={"scans": [{"doigts": doigts}]}, headers=entetes).json()
    assert corps["doigts_illisibles"] == [5]
    assert corps["doigts_compares"] == 3
    assert corps["verdict"] == "identifie"  # 3 doigts concordants sur 3


def test_deux_scans_combines(client, entetes, enroler, creer_citoyen):
    """Chaque scan n'a que 2 doigts lisibles ; ensemble, 4 : identification possible."""
    a = creer_citoyen()
    enroler(a["numero"], personne=1)
    scans = [{"doigts": main(1, doigts=(2, 3))}, {"doigts": main(1, doigts=(4, 5))}]
    corps = client.post("/identification", json={"scans": scans}, headers=entetes).json()
    assert corps["verdict"] == "identifie"
    assert corps["citoyen"]["numero"] == a["numero"]


# --- Erreurs ---


def test_matcher_indisponible(client, entetes, faux):
    faux.panne = True
    reponse = client.post("/identification", json={"scans": [{"doigts": main(1)}]}, headers=entetes)
    assert reponse.status_code == 503


def test_base64_invalide(client, entetes, faux):
    doigts = main(1)
    doigts[0]["image"] = "%%%% pas du base64 %%%%"
    reponse = client.post("/identification", json={"scans": [{"doigts": doigts}]}, headers=entetes)
    assert reponse.status_code == 422


def test_meme_doigt_deux_fois(client, entetes, faux):
    doigts = main(1)
    doigts[1]["doigt"] = doigts[0]["doigt"]
    reponse = client.post("/identification", json={"scans": [{"doigts": doigts}]}, headers=entetes)
    assert reponse.status_code == 422


def test_authentification_obligatoire(client, faux):
    assert client.post("/identification", json={"scans": [{"doigts": main(1)}]}).status_code == 401
    assert client.post("/doublons", json={"doigts": main(1)}).status_code == 401


def test_controle_doublon_sans_doigt_lisible(client, entetes, faux):
    illisibles = [{"doigt": d, "image": base64.b64encode(b"pas une image").decode(), "dpi_estime": 550} for d in (2, 3)]
    assert client.post("/doublons", json={"doigts": illisibles}, headers=entetes).status_code == 422
