"""Données FICTIVES de démonstration : 1 agent + 30 citoyens inventés.

Aucune de ces personnes n'existe : noms combinés au hasard, numéros d'acte
marqués « FICTIF », téléphones fictifs.

Utilisation (dans le conteneur backend) :
    python -m app.seed            # ne fait rien si des citoyens existent déjà
    python -m app.seed --reset    # supprime toutes les fiches puis recrée les 30
"""

import argparse
import random
import sys
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session

from app.config import parametres
from app.db import SessionLocale
from app.journal import journaliser
from app.models import Agent, Citoyen
from app.numero import attribuer_numero
from app.referentiels import COULEURS_CHEVEUX, COULEURS_YEUX
from app.securite import hacher_mot_de_passe

NOMBRE_CITOYENS = 30

NOMS = [
    "Said", "Ahamada", "Msa", "Abdou", "Madi", "Hamidou", "Soilihi", "Youssouf",
    "Mbae", "Djoumoi", "Houmadi", "Oumouri", "Bacar", "Mouigni", "Chamsoudine",
    "Toiyfa", "Attoumane", "Zoubert", "Kassim", "Mdahoma",
]
PRENOMS_HOMMES = [
    "Ahmed", "Ibrahim", "Nassur", "Fahardine", "Anli", "Moussa", "Kamal", "Hachim",
    "Ismael", "Nadjim", "Soulaimana", "Farouk", "Mansour", "Djamal",
]
PRENOMS_FEMMES = [
    "Fatima", "Zaharia", "Echata", "Mariama", "Nadjma", "Anrifa", "Sitti", "Hadidja",
    "Moinaecha", "Zalhata", "Faouzia", "Roukia", "Soifiat", "Nourou",
]
# Villes et quartiers réels, adresses inventées.
LIEUX = {
    "Ngazidja": {
        "Moroni": ["Magoudjou", "Badjanani", "Coulée", "Hamramba"],
        "Mitsamiouli": ["Centre", "Ndzaouze"],
        "Foumbouni": ["Centre", "Mdjihari"],
        "Mbeni": ["Centre", "Hamahamet"],
    },
    "Ndzuani": {
        "Mutsamudu": ["Hampanga", "Mjimbiya", "Pagé"],
        "Domoni": ["Centre", "Hamtsaha"],
        "Ouani": ["Centre", "Mirontsy"],
        "Sima": ["Centre"],
    },
    "Mwali": {
        "Fomboni": ["Centre", "Boingoma"],
        "Nioumachoua": ["Centre"],
        "Djoiezi": ["Centre"],
    },
}


def _assurer_agent(db: Session) -> Agent:
    """Crée l'agent de démonstration s'il n'existe pas encore."""
    matricule = parametres.seed_agent_matricule.strip().upper()
    agent = db.scalar(select(Agent).where(Agent.matricule == matricule))
    if agent:
        return agent
    if not parametres.seed_agent_mot_de_passe:
        sys.exit("SEED_AGENT_MOT_DE_PASSE manquant dans .env : impossible de créer l'agent.")
    agent = Agent(
        matricule=matricule,
        nom="Agent de démonstration",
        mot_de_passe_hash=hacher_mot_de_passe(parametres.seed_agent_mot_de_passe),
        role="administrateur",
        ile="Ngazidja",
        commune="Moroni",
    )
    db.add(agent)
    db.flush()
    print(f"Agent de démonstration créé : {matricule}")
    return agent


def _citoyen_fictif(hasard: random.Random, index: int, agent: Agent, maintenant: datetime) -> Citoyen:
    sexe = hasard.choice(["M", "F"])
    prenoms_possibles = PRENOMS_HOMMES if sexe == "M" else PRENOMS_FEMMES
    ile = hasard.choice(list(LIEUX))
    ville = hasard.choice(list(LIEUX[ile]))
    naissance = date(1950, 1, 1) + timedelta(days=hasard.randint(0, 365 * 55))
    # Les 5 premiers « aujourd'hui », les autres sur les 30 derniers jours.
    decalage = timedelta(minutes=hasard.randint(0, 120)) if index < 5 else timedelta(
        days=hasard.randint(1, 30), minutes=hasard.randint(0, 600)
    )
    return Citoyen(
        nom=hasard.choice(NOMS).upper(),
        prenoms=" ".join(hasard.sample(prenoms_possibles, hasard.choice([1, 1, 2]))),
        sexe=sexe,
        date_naissance=naissance,
        lieu_naissance=hasard.choice(list(LIEUX[ile])),
        nationalite="Comorienne",
        numero_acte_naissance=f"FICTIF-{naissance.year}-{index + 1:04d}",
        telephone=hasard.choice([None, f"+26939{hasard.randint(0, 99999):05d}"]),
        ile=ile,
        ville=ville,
        quartier=hasard.choice(LIEUX[ile][ville]),
        adresse=f"Rue fictive n° {hasard.randint(1, 120)}",
        taille_cm=hasard.randint(150, 190) if sexe == "M" else hasard.randint(145, 178),
        couleur_yeux=hasard.choices(COULEURS_YEUX, weights=[6, 5, 3, 1, 0, 0, 0, 0])[0],
        couleur_cheveux=hasard.choices(COULEURS_CHEVEUX, weights=[8, 2, 0, 0, 0, 1, 1, 1, 0])[0],
        agent_id=agent.id,
        enregistre_le=maintenant - decalage,
    )


def charger(reset: bool = False) -> None:
    with SessionLocale() as db:
        agent = _assurer_agent(db)

        existants = db.scalar(select(func.count()).select_from(Citoyen))
        if existants and not reset:
            db.commit()
            print(f"{existants} citoyens déjà présents : rien à faire (utiliser --reset).")
            return
        if reset:
            db.execute(delete(Citoyen))
            print(f"{existants} fiches supprimées.")

        hasard = random.Random(42)  # toujours les mêmes données fictives
        maintenant = datetime.now(ZoneInfo(parametres.fuseau_horaire))
        for index in range(NOMBRE_CITOYENS):
            citoyen = _citoyen_fictif(hasard, index, agent, maintenant)
            citoyen.numero = attribuer_numero(db)
            db.add(citoyen)
        journaliser(db, "donnees_fictives_chargees", agent_id=agent.id, details={"nombre": NOMBRE_CITOYENS})
        db.commit()
        print(f"{NOMBRE_CITOYENS} citoyens fictifs créés.")


if __name__ == "__main__":
    analyseur = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    analyseur.add_argument("--reset", action="store_true", help="supprimer les fiches existantes")
    charger(reset=analyseur.parse_args().reset)
