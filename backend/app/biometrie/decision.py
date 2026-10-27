"""Décision d'identification à partir des candidats renvoyés par le matcher.

Principe : NE JAMAIS AFFICHER LA FICHE D'UNE AUTRE PERSONNE. Aucun système
biométrique n'est exact à 100 % ; on préfère donc répondre « non concluant »
(nouveau scan, puis vérification manuelle) plutôt que deviner.

Trois réponses possibles pour une identification :
  - IDENTIFIE : plusieurs preuves indépendantes concordent (score de la main,
    doigts pris un par un, écart net avec le deuxième candidat) ;
  - NON_ENREGISTRE : personne ne s'approche, même de loin, sur aucun doigt ;
  - NON_CONCLUANT : tout le reste.

Pour l'anti-doublon à l'enregistrement, la prudence est inversée : au moindre
doute, on signale un doublon possible, à vérifier par un superviseur.

Les seuils par défaut sont prudents et provisoires : ils viennent d'un premier
signal sur UNE personne (main entière : authentiques 130 à 213, imposteurs
≤ 55 ; doigt seul : imposteur max ≈ 31). Ils devront être recalés sur une
évaluation avec plusieurs personnes. Ils sont exprimés PAR DOIGT comparé,
pour s'appliquer aussi bien à 4 doigts qu'à 10.
"""

from dataclasses import dataclass, field
from enum import Enum

from app.biometrie.client_matcher import Candidat


class Verdict(str, Enum):
    IDENTIFIE = "identifie"
    NON_ENREGISTRE = "non_enregistre"
    NON_CONCLUANT = "non_concluant"


class VerdictDoublon(str, Enum):
    DOUBLON_CERTAIN = "doublon_certain"
    DOUBLON_POSSIBLE = "doublon_possible"  # enregistrement bloqué, à vérifier par un superviseur
    AUCUN_DOUBLON = "aucun_doublon"


@dataclass(frozen=True)
class Seuils:
    # Nombre minimal de doigts exploitables dans la sonde : en dessous, on ne
    # conclut rien (ni identité, ni absence).
    doigts_min: int = 3
    # IDENTIFIE : score moyen par doigt du 1er candidat (4 doigts → 120).
    moyenne_identifie: float = 30.0
    # IDENTIFIE : un doigt « concordant » est le meilleur de tous les candidats
    # pour ce doigt, avec au moins ce score…
    doigt_concordant: float = 25.0
    # … et il en faut au moins cette proportion (4 doigts → 3).
    part_concordants: float = 0.75
    # IDENTIFIE : écart avec le 2e candidat, par doigt (4 doigts → 50) ET en rapport.
    ecart_par_doigt: float = 12.5
    rapport_min: float = 1.8
    # NON_ENREGISTRE : le 1er candidat reste sous cette moyenne par doigt
    # (4 doigts → 60)…
    moyenne_absent: float = 15.0
    # … et aucun doigt, chez aucun candidat, n'atteint ce score.
    doigt_suspect: float = 35.0
    # Anti-doublon : nombre de doigts moyennement ressemblants qui suffit à
    # rendre un doublon possible.
    doigts_suspects_doublon: int = 2
    doigt_moyen_doublon: float = 25.0


@dataclass
class Decision:
    verdict: Verdict
    candidat: str | None  # identifiant de la personne, seulement si IDENTIFIE
    motif: str  # explication courte en français, pour l'agent et le journal
    doigts_compares: int
    doigts_concordants: int = 0
    score: float = 0.0
    second_score: float = 0.0


@dataclass
class DecisionDoublon:
    verdict: VerdictDoublon
    candidats: list[str] = field(default_factory=list)  # personnes à vérifier
    motif: str = ""


def _doigts_concordants(candidats: list[Candidat], seuils: Seuils) -> int:
    """Doigts pour lesquels le 1er candidat est le meilleur de tous, avec un score suffisant."""
    premier = candidats[0]
    nombre = 0
    for doigt, score in premier.scores_doigts.items():
        if score < seuils.doigt_concordant:
            continue
        autres = [c.scores_doigts.get(doigt, 0.0) for c in candidats[1:]]
        if all(score > autre for autre in autres):
            nombre += 1
    return nombre


def _max_doigt(candidats: list[Candidat]) -> float:
    return max((s for c in candidats for s in c.scores_doigts.values()), default=0.0)


def decider_identification(
    candidats: list[Candidat], doigts_sonde: int, seuils: Seuils = Seuils()
) -> Decision:
    """`candidats` : sortie du matcher (triée ou non) ; demander au moins 5 candidats,
    pour que la comparaison avec les suivants ait un sens. `doigts_sonde` : nombre
    de doigts exploitables dans le scan."""
    if doigts_sonde < seuils.doigts_min:
        return Decision(
            Verdict.NON_CONCLUANT,
            None,
            f"Seulement {doigts_sonde} doigt(s) exploitable(s) : recommencer le scan.",
            doigts_sonde,
        )
    if not candidats:
        return Decision(Verdict.NON_ENREGISTRE, None, "Base vide : aucune personne à comparer.", doigts_sonde)

    candidats = sorted(candidats, key=lambda c: c.score, reverse=True)
    premier = candidats[0]
    second = candidats[1].score if len(candidats) > 1 else 0.0
    n = doigts_sonde
    concordants = _doigts_concordants(candidats, seuils)
    base = dict(doigts_compares=n, doigts_concordants=concordants, score=premier.score, second_score=second)

    # Toutes les conditions doivent être réunies : une seule preuve forte ne suffit pas.
    conditions = {
        "score de la main trop faible": premier.score >= seuils.moyenne_identifie * n,
        "pas assez de doigts concordants": concordants >= max(2, round(seuils.part_concordants * n + 1e-9)),
        "deuxième candidat trop proche": premier.score - second >= seuils.ecart_par_doigt * n
        and premier.score >= seuils.rapport_min * second,
    }
    if all(conditions.values()):
        return Decision(
            Verdict.IDENTIFIE,
            premier.id,
            f"{concordants} doigts sur {n} concordent ; écart net avec le candidat suivant.",
            **base,
        )

    if premier.score < seuils.moyenne_absent * n and _max_doigt(candidats) < seuils.doigt_suspect:
        return Decision(Verdict.NON_ENREGISTRE, None, "Aucune personne de la base ne ressemble à ce scan.", **base)

    manques = [motif for motif, ok in conditions.items() if not ok]
    return Decision(
        Verdict.NON_CONCLUANT,
        None,
        "Résultat incertain (" + ", ".join(manques) + ") : recommencer le scan.",
        **base,
    )


def combiner_scans(scans: list[list[Candidat]]) -> list[Candidat]:
    """Fusionne plusieurs scans de la même main : pour chaque candidat et chaque
    doigt, on garde le MEILLEUR score obtenu (une prise floue ne pénalise pas).
    Le score de la main est recalculé comme la somme des doigts."""
    meilleurs: dict[str, dict[int, float]] = {}
    for scan in scans:
        for c in scan:
            doigts = meilleurs.setdefault(c.id, {})
            for doigt, score in c.scores_doigts.items():
                doigts[doigt] = max(score, doigts.get(doigt, 0.0))
    fusion = [Candidat(id_, sum(d.values()), d) for id_, d in meilleurs.items()]
    return sorted(fusion, key=lambda c: c.score, reverse=True)


def decider_apres_plusieurs_scans(
    scans: list[list[Candidat]], doigts_sonde: int, seuils: Seuils = Seuils()
) -> Decision:
    """Décision sur plusieurs scans. Prudence supplémentaire : si deux scans
    désignent, chacun avec certitude, deux personnes différentes, on ne conclut pas."""
    identifies = {d.candidat for scan in scans if (d := decider_identification(scan, doigts_sonde, seuils)).candidat}
    if len(identifies) > 1:
        return Decision(
            Verdict.NON_CONCLUANT,
            None,
            "Les scans désignent des personnes différentes : vérification manuelle obligatoire.",
            doigts_sonde,
        )
    return decider_identification(combiner_scans(scans), doigts_sonde, seuils)


def decider_doublon(candidats: list[Candidat], doigts_sonde: int, seuils: Seuils = Seuils()) -> DecisionDoublon:
    """Anti-doublon à l'enregistrement (10 doigts en général). Au moindre doute :
    DOUBLON_POSSIBLE, l'enregistrement attend la validation d'un superviseur."""
    if not candidats:
        return DecisionDoublon(VerdictDoublon.AUCUN_DOUBLON, motif="Base vide.")
    candidats = sorted(candidats, key=lambda c: c.score, reverse=True)

    certain = decider_identification(candidats, doigts_sonde, seuils)
    if certain.verdict == Verdict.IDENTIFIE:
        return DecisionDoublon(
            VerdictDoublon.DOUBLON_CERTAIN, [certain.candidat], "Cette personne semble déjà enregistrée."
        )

    suspects = []
    for c in candidats:
        moyens = sum(1 for s in c.scores_doigts.values() if s >= seuils.doigt_moyen_doublon)
        if (
            c.score >= seuils.moyenne_absent * doigts_sonde
            or max(c.scores_doigts.values(), default=0.0) >= seuils.doigt_suspect
            or moyens >= seuils.doigts_suspects_doublon
        ):
            suspects.append(c.id)
    if suspects:
        return DecisionDoublon(
            VerdictDoublon.DOUBLON_POSSIBLE,
            suspects,
            f"{len(suspects)} fiche(s) ressemblante(s) : validation d'un superviseur requise.",
        )
    if doigts_sonde < seuils.doigts_min:
        # Trop peu de doigts pour affirmer l'absence de doublon.
        return DecisionDoublon(VerdictDoublon.DOUBLON_POSSIBLE, [], "Trop peu de doigts exploitables pour conclure.")
    return DecisionDoublon(VerdictDoublon.AUCUN_DOUBLON, motif="Aucune fiche ressemblante.")
