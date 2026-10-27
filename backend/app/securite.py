"""Mots de passe (Argon2), jetons d'accès (JWT courts) et jetons de
renouvellement (aléatoires, enregistrés hachés en base).

Un jeton d'accès porte l'agent (`sub`), l'appareil (`app`) et la famille de
session (`fam`) : à chaque requête, on vérifie que l'agent est actif, que
l'appareil est toujours approuvé et que la session n'a pas été révoquée.
"""

import hashlib
import secrets
import uuid
from dataclasses import dataclass
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


def probleme_mot_de_passe(mot_de_passe: str, matricule: str) -> str | None:
    """Règles du mot de passe ; renvoie le problème, ou None s'il est acceptable."""
    minimum = parametres.mot_de_passe_longueur_min
    if len(mot_de_passe) < minimum:
        return f"Le mot de passe doit contenir au moins {minimum} caractères"
    if matricule.strip().lower() in mot_de_passe.lower():
        return "Le mot de passe ne doit pas contenir le matricule"
    if len(set(mot_de_passe)) < 4:
        return "Le mot de passe est trop simple"
    return None


def generer_mot_de_passe_provisoire() -> str:
    """12 caractères faciles à recopier (sans 0/O, 1/l/I), à changer à la première connexion."""
    alphabet = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    return "".join(secrets.choice(alphabet) for _ in range(12))


@dataclass(frozen=True)
class ChargeJeton:
    agent_id: uuid.UUID
    appareil_id: uuid.UUID
    famille: uuid.UUID


def creer_jeton(agent_id: uuid.UUID, appareil_id: uuid.UUID, famille: uuid.UUID) -> str:
    maintenant = datetime.now(timezone.utc)
    charge = {
        "sub": str(agent_id),
        "app": str(appareil_id),
        "fam": str(famille),
        "iat": maintenant,
        "exp": maintenant + timedelta(minutes=parametres.jwt_duree_minutes),
    }
    return jwt.encode(charge, parametres.jwt_secret, algorithm=parametres.jwt_algorithme)


def lire_jeton(jeton: str) -> ChargeJeton | None:
    """Contenu du jeton d'accès, ou None s'il est invalide, incomplet ou expiré."""
    try:
        charge = jwt.decode(
            jeton,
            parametres.jwt_secret,
            algorithms=[parametres.jwt_algorithme],
            options={"require": ["sub", "app", "fam", "exp"]},
        )
        return ChargeJeton(uuid.UUID(charge["sub"]), uuid.UUID(charge["app"]), uuid.UUID(charge["fam"]))
    except (jwt.PyJWTError, ValueError, KeyError):
        return None


def nouveau_jeton_renouvellement() -> tuple[str, str]:
    """(jeton remis à l'appareil, empreinte SHA-256 enregistrée en base)."""
    jeton = secrets.token_urlsafe(32)
    return jeton, hacher_jeton(jeton)


def hacher_jeton(jeton: str) -> str:
    # SHA-256 suffit : le jeton est aléatoire (256 bits), pas un mot de passe.
    return hashlib.sha256(jeton.encode()).hexdigest()
