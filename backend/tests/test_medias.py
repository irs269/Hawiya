"""Photo du visage et signature (images FICTIVES générées par le test)."""

import base64

import cv2
import numpy as np
from sqlalchemy import select

from app.models import CitoyenMedia, JournalAction


def image(format_: str, taille=(60, 40)) -> bytes:
    """Petite image synthétique (dégradé), sans aucun visage réel."""
    ok, tampon = cv2.imencode(format_, np.tile(np.arange(taille[1], dtype=np.uint8), (taille[0], 1)))
    assert ok
    return tampon.tobytes()


def b64(octets: bytes) -> str:
    return base64.b64encode(octets).decode()


def test_photo_et_signature_enregistrees_et_relues(client, entetes, creer_citoyen, db):
    numero = creer_citoyen()["numero"]
    photo, signature = image(".jpg"), image(".png")
    reponse = client.put(f"/citoyens/{numero}/medias", json={"photo": b64(photo), "signature": b64(signature)}, headers=entetes)
    assert reponse.status_code == 200, reponse.text
    assert reponse.json() == {"photo": True, "signature": True}

    lue = client.get(f"/citoyens/{numero}/photo", headers=entetes)
    assert lue.status_code == 200
    assert lue.headers["content-type"] == "image/jpeg"
    assert lue.content == photo
    assert client.get(f"/citoyens/{numero}/signature", headers=entetes).content == signature
    assert db.scalar(select(JournalAction).where(JournalAction.action == "citoyen_medias"))


def test_envoi_partiel_garde_l_autre_media(client, entetes, creer_citoyen, db):
    numero = creer_citoyen()["numero"]
    client.put(f"/citoyens/{numero}/medias", json={"signature": b64(image(".png"))}, headers=entetes)
    reponse = client.put(f"/citoyens/{numero}/medias", json={"photo": b64(image(".png"))}, headers=entetes)
    assert reponse.json() == {"photo": True, "signature": True}
    assert client.get(f"/citoyens/{numero}/photo", headers=entetes).headers["content-type"] == "image/png"
    assert len(db.scalars(select(CitoyenMedia)).all()) == 1


def test_pas_de_photo(client, entetes, creer_citoyen):
    numero = creer_citoyen()["numero"]
    assert client.get(f"/citoyens/{numero}/photo", headers=entetes).status_code == 404
    assert client.get(f"/citoyens/{numero}/signature", headers=entetes).status_code == 404


def test_fiche_inconnue(client, entetes):
    reponse = client.put("/citoyens/KM-2026-999999-A/medias", json={"photo": b64(image(".jpg"))}, headers=entetes)
    assert reponse.status_code == 404


def test_formats_refuses(client, entetes, creer_citoyen):
    numero = creer_citoyen()["numero"]
    pas_une_image = b64(b"GIF89a fausse image")
    assert client.put(f"/citoyens/{numero}/medias", json={"photo": pas_une_image}, headers=entetes).status_code == 422
    # La signature doit être un PNG (dessin), pas un JPEG.
    jpeg = b64(image(".jpg"))
    assert client.put(f"/citoyens/{numero}/medias", json={"signature": jpeg}, headers=entetes).status_code == 422
    assert client.put(f"/citoyens/{numero}/medias", json={"photo": "%%%"}, headers=entetes).status_code == 422


def test_image_trop_lourde(client, entetes, creer_citoyen):
    numero = creer_citoyen()["numero"]
    lourde = b"\xff\xd8\xff" + bytes(2 * 1024 * 1024)
    assert client.put(f"/citoyens/{numero}/medias", json={"photo": b64(lourde)}, headers=entetes).status_code == 422


def test_authentification_obligatoire(client, creer_citoyen):
    numero = creer_citoyen()["numero"]
    assert client.get(f"/citoyens/{numero}/photo").status_code == 401
