"""Statistiques et santé de l'API."""

from datetime import datetime, timedelta, timezone

from sqlalchemy import update

from app.models import Citoyen


def test_statistiques_base_vide(client, entetes):
    stats = client.get("/statistiques", headers=entetes).json()
    assert stats == {
        "total_citoyens": 0,
        "enregistres_aujourdhui": 0,
        "par_ile": {"Ngazidja": 0, "Ndzuani": 0, "Mwali": 0},
        "par_sexe": {"M": 0, "F": 0},
    }


def test_statistiques(client, entetes, creer_citoyen, db):
    creer_citoyen(ile="Ngazidja")
    creer_citoyen(ile="Ngazidja", sexe="F")
    ancienne = creer_citoyen(ile="Mwali")
    # Une fiche enregistrée il y a 3 jours ne compte pas dans « aujourd'hui ».
    db.execute(
        update(Citoyen)
        .where(Citoyen.numero == ancienne["numero"])
        .values(enregistre_le=datetime.now(timezone.utc) - timedelta(days=3))
    )
    db.commit()

    stats = client.get("/statistiques", headers=entetes).json()
    assert stats["total_citoyens"] == 3
    assert stats["enregistres_aujourdhui"] == 2
    assert stats["par_ile"] == {"Ngazidja": 2, "Ndzuani": 0, "Mwali": 1}
    assert stats["par_sexe"] == {"M": 2, "F": 1}


def test_sante(client):
    assert client.get("/sante").json() == {"statut": "ok"}
