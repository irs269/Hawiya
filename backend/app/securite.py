"""Mots de passe (Argon2) et jetons d'accès (JWT).

Authentification PROVISOIRE de la phase 1 : le système complet (téléphones
approuvés, jetons de renouvellement, blocage après échecs) arrive en phase 1 bis.
"""

import uuid
from datetime import datetime, timedelta, timezone

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError

from app.config import parametres

_hacheur = PasswordHasher()

# Hash d'un mot de passe jetable : on le vérifie quand le matricule n'existe pas,
# pour que la réponse prenne le même temps (ne révèle pas quels matricules existent).
HASH_FACTICE = _hacheur.hash(uuid.uuid4().hex)


def hacher_mot_de_passe(mot_de_passe: str) -> str:
    return _hacheur.hash(mot_de_passe)


def verifier_mot_de_passe(mot_de_passe: str, hash_enregistre: str) -> bool:
    try:
        return _hacheur.verify(hash_enregistre, mot_de_passe)
    except (VerificationError, InvalidHashError):
        return False


def creer_jeton(agent_id: uuid.UUID) -> str:
    maintenant = datetime.now(timezone.utc)
    charge = {
        "sub": str(agent_id),
        "iat": maintenant,
        "exp": maintenant + timedelta(minutes=parametres.jwt_duree_minutes),
    }
    return jwt.encode(charge, parametres.jwt_secret, algorithm=parametres.jwt_algorithme)


def lire_jeton(jeton: str) -> uuid.UUID | None:
    """Renvoie l'identifiant de l'agent, ou None si le jeton est invalide ou expiré."""
    try:
        charge = jwt.decode(
            jeton,
            parametres.jwt_secret,
            algorithms=[parametres.jwt_algorithme],
            options={"require": ["sub", "exp"]},
        )
        return uuid.UUID(charge["sub"])
    except (jwt.PyJWTError, ValueError):
        return None
