"""Listes de valeurs autorisées, partagées par les modèles et les schémas.

Les valeurs sont des codes sans accents ; les libellés affichés seront gérés
par les fichiers de traduction de l'application.
"""

ILES = ("Ngazidja", "Ndzuani", "Mwali")
SEXES = ("M", "F")
COULEURS_YEUX = ("noirs", "marron_fonce", "marron", "noisette", "verts", "bleus", "gris", "autre")
COULEURS_CHEVEUX = ("noirs", "bruns", "chatains", "blonds", "roux", "gris", "blancs", "chauve", "autre")

ROLES_AGENT = ("agent", "superviseur", "administrateur")
STATUTS_AGENT = ("actif", "suspendu", "desactive")

TAILLE_MIN_CM = 50
TAILLE_MAX_CM = 250


def condition_sql_in(colonne: str, valeurs: tuple[str, ...]) -> str:
    """Construit « colonne IN ('a', 'b') » pour une contrainte CHECK."""
    liste = ", ".join(f"'{v}'" for v in valeurs)
    return f"{colonne} IN ({liste})"
