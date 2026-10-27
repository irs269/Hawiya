"""Outils d'administration en ligne de commande, À LANCER SUR LE SERVEUR (qui
y a accès est déjà de confiance). Sert surtout au premier démarrage :
approuver le tout premier appareil de l'administrateur.

Utilisation (dans le conteneur backend) :
    python -m app.outils appareils             # appareils en attente
    python -m app.outils approuver AB12CD34    # approuver par son code
    python -m app.outils revoquer AB12CD34
    python -m app.outils reinitialiser AG-0001 # nouveau mot de passe provisoire
"""

import argparse
import sys
from datetime import datetime, timezone

from sqlalchemy import select

from app.db import SessionLocale
from app.journal import journaliser
from app.models import Agent, Appareil
from app.securite import generer_mot_de_passe_provisoire, hacher_mot_de_passe
from app.sessions import revoquer_sessions_agent, revoquer_sessions_appareil


def _appareil(db, code: str) -> Appareil:
    trouves = db.scalars(select(Appareil).where(Appareil.identifiant.ilike(f"{code.strip().lower()}%"))).all()
    if len(trouves) != 1:
        sys.exit(f"Code « {code} » : {len(trouves)} appareil(s) correspondant(s), il en faut exactement 1.")
    return trouves[0]


def main(arguments: list[str] | None = None) -> None:
    analyseur = argparse.ArgumentParser(description="Outils d'administration Hawiya (serveur)")
    commandes = analyseur.add_subparsers(dest="commande", required=True)
    commandes.add_parser("appareils", help="lister les appareils en attente")
    for nom in ("approuver", "revoquer"):
        commandes.add_parser(nom).add_argument("code")
    commandes.add_parser("reinitialiser").add_argument("matricule")
    args = analyseur.parse_args(arguments)

    with SessionLocale() as db:
        if args.commande == "appareils":
            en_attente = db.scalars(select(Appareil).where(Appareil.statut == "en_attente")).all()
            if not en_attente:
                print("Aucun appareil en attente.")
            for a in en_attente:
                demandeur = db.get(Agent, a.agent_id) if a.agent_id else None
                print(f"{a.code}  {a.nom or '(sans nom)'}  demandé par {demandeur.matricule if demandeur else '?'}  le {a.cree_le:%d/%m/%Y %H:%M}")
        elif args.commande == "approuver":
            appareil = _appareil(db, args.code)
            appareil.statut = "approuve"
            appareil.approuve_le = datetime.now(timezone.utc)
            journaliser(db, "appareil_approuve", cible=appareil.code, details={"par": "ligne_de_commande"})
            print(f"Appareil {appareil.code} approuvé.")
        elif args.commande == "revoquer":
            appareil = _appareil(db, args.code)
            appareil.statut = "revoque"
            revoquer_sessions_appareil(db, appareil.id)
            journaliser(db, "appareil_revoque", cible=appareil.code, details={"par": "ligne_de_commande"})
            print(f"Appareil {appareil.code} révoqué.")
        elif args.commande == "reinitialiser":
            agent = db.scalar(select(Agent).where(Agent.matricule == args.matricule.strip().upper()))
            if agent is None:
                sys.exit("Agent introuvable.")
            provisoire = generer_mot_de_passe_provisoire()
            agent.mot_de_passe_hash = hacher_mot_de_passe(provisoire)
            agent.doit_changer_mot_de_passe = True
            agent.echecs_connexion = 0
            agent.bloque_jusqu_a = None
            revoquer_sessions_agent(db, agent.id)
            journaliser(db, "mot_de_passe_reinitialise", cible=agent.matricule, details={"par": "ligne_de_commande"})
            print(f"Mot de passe provisoire de {agent.matricule} : {provisoire}  (à changer à la connexion)")
        db.commit()


if __name__ == "__main__":
    main()
