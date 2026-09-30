"""Numéro d'identification : format, lettre de contrôle, unicité."""

from concurrent.futures import ThreadPoolExecutor

import pytest
from sqlalchemy.exc import IntegrityError

from app.models import Citoyen
from app.numero import (
    LETTRES_CONTROLE,
    attribuer_numero,
    est_numero_valide,
    formater_numero,
    lettre_controle,
    normaliser_numero,
)
from app.schemas import CitoyenCreation
from tests.conftest import CITOYEN_FICTIF


def test_format_du_numero():
    numero = formater_numero(2026, 42)
    assert numero.startswith("KM-2026-000042-")
    assert len(numero) == 16
    assert est_numero_valide(numero)


def test_lettre_de_controle_calculee():
    assert lettre_controle(2026, 1) == LETTRES_CONTROLE[2026000001 % 23]


def test_un_chiffre_modifie_est_detecte():
    numero = formater_numero(2026, 123456)
    for position in range(3, 15):
        if not numero[position].isdigit():
            continue
        for chiffre in "0123456789":
            if chiffre == numero[position]:
                continue
            altere = numero[:position] + chiffre + numero[position + 1 :]
            assert not est_numero_valide(altere), altere


def test_inversion_de_deux_chiffres_voisins_est_detectee():
    numero = formater_numero(2026, 123456)  # KM-2026-123456-X
    altere = numero[:8] + "213456" + numero[14:]
    assert not est_numero_valide(altere)


@pytest.mark.parametrize(
    "saisie", ["", "KM-2026-000001", "XX-2026-000001-A", "KM-2026-000000-T", "km-2026-000001-r"]
)
def test_numeros_invalides(saisie):
    assert not est_numero_valide(saisie)


def test_normalisation_de_la_saisie():
    numero = formater_numero(2026, 7)
    assert normaliser_numero(f"  {numero.lower()} ") == numero


def test_sequence_hors_limites():
    with pytest.raises(ValueError):
        formater_numero(2026, 0)
    with pytest.raises(ValueError):
        formater_numero(2026, 1_000_000)


def test_sequences_successives(db):
    assert attribuer_numero(db, 2026) == formater_numero(2026, 1)
    assert attribuer_numero(db, 2026) == formater_numero(2026, 2)
    # Chaque année a son propre compteur.
    assert attribuer_numero(db, 2027) == formater_numero(2027, 1)
    db.commit()


def test_transaction_annulee_ne_consomme_pas_de_numero(db):
    attribuer_numero(db, 2026)
    db.rollback()
    assert attribuer_numero(db, 2026) == formater_numero(2026, 1)


def test_numeros_uniques_en_concurrence(fabrique_sessions):
    """50 attributions simultanées sur 10 connexions : 50 numéros différents."""

    def attribuer(_):
        with fabrique_sessions() as session:
            numero = attribuer_numero(session, 2026)
            session.commit()
            return numero

    with ThreadPoolExecutor(max_workers=10) as executeur:
        numeros = list(executeur.map(attribuer, range(50)))

    assert len(set(numeros)) == 50
    assert sorted(numeros) == [formater_numero(2026, s) for s in range(1, 51)]


def test_la_base_refuse_deux_fiches_avec_le_meme_numero(creer_citoyen, agent, db):
    """Filet de sécurité : même en contournant le compteur, la base refuse le doublon."""
    fiche = creer_citoyen()
    donnees = CitoyenCreation(**CITOYEN_FICTIF).model_dump()
    db.add(Citoyen(**donnees, numero=fiche["numero"], agent_id=agent.id))
    with pytest.raises(IntegrityError):
        db.commit()
