"""Règle de décision, sur des scores FICTIFS (aucune donnée biométrique réelle)."""

from app.biometrie.client_matcher import Candidat
from app.biometrie.decision import (
    Seuils,
    Verdict,
    VerdictDoublon,
    combiner_scans,
    decider_apres_plusieurs_scans,
    decider_doublon,
    decider_identification,
)


def candidat(id_: str, *scores: float) -> Candidat:
    """Candidat fictif : scores des doigts 2, 3, 4, 5 (index → auriculaire), puis suivants."""
    doigts = {2 + i: float(s) for i, s in enumerate(scores)}
    return Candidat(id_, sum(doigts.values()), doigts)


def imposteurs(n=4) -> list[Candidat]:
    return [candidat(f"KM-FICTIF-{i:03d}", 8, 5, 12, 3) for i in range(n)]


# --- Identification ---


def test_cas_clair_identifie():
    candidats = [candidat("KM-FICTIF-100", 45, 60, 38, 20)] + imposteurs()
    d = decider_identification(candidats, doigts_sonde=4)
    assert d.verdict == Verdict.IDENTIFIE
    assert d.candidat == "KM-FICTIF-100"
    assert d.doigts_concordants == 3


def test_ordre_des_candidats_sans_importance():
    candidats = imposteurs() + [candidat("KM-FICTIF-100", 45, 60, 38, 20)]
    assert decider_identification(candidats, 4).candidat == "KM-FICTIF-100"


def test_un_seul_doigt_tres_fort_ne_suffit_pas():
    """Score de main élevé mais porté par un seul doigt : pas d'identification."""
    candidats = [candidat("KM-FICTIF-100", 150, 5, 4, 3)] + imposteurs()
    d = decider_identification(candidats, 4)
    assert d.verdict == Verdict.NON_CONCLUANT
    assert d.candidat is None
    assert "concordants" in d.motif


def test_deux_candidats_proches_non_concluant():
    """Deux personnes ressemblantes : on n'en choisit aucune."""
    candidats = [candidat("KM-FICTIF-100", 45, 50, 38, 20), candidat("KM-FICTIF-200", 40, 44, 30, 18)]
    d = decider_identification(candidats, 4)
    assert d.verdict == Verdict.NON_CONCLUANT
    assert d.candidat is None
    assert "deuxième candidat" in d.motif


def test_doigts_partages_entre_deux_candidats_non_concluant():
    """Chaque candidat gagne 2 doigts : aucun ne réunit 3 doigts concordants."""
    candidats = [candidat("KM-FICTIF-100", 70, 65, 10, 8), candidat("KM-FICTIF-200", 10, 9, 30, 28)]
    assert decider_identification(candidats, 4).verdict == Verdict.NON_CONCLUANT


def test_score_moyen_non_concluant():
    """Ni assez fort pour identifier, ni assez faible pour conclure à l'absence."""
    candidats = [candidat("KM-FICTIF-100", 28, 26, 25, 10)] + imposteurs()
    assert decider_identification(candidats, 4).verdict == Verdict.NON_CONCLUANT


def test_personne_absente():
    d = decider_identification(imposteurs(), 4)
    assert d.verdict == Verdict.NON_ENREGISTRE
    assert d.candidat is None


def test_un_doigt_suspect_empeche_de_conclure_a_l_absence():
    """Score de main faible mais un doigt très ressemblant : on ne dit pas « absent »."""
    candidats = [candidat("KM-FICTIF-100", 40, 3, 2, 1)] + imposteurs()
    assert decider_identification(candidats, 4).verdict == Verdict.NON_CONCLUANT


def test_trop_peu_de_doigts():
    candidats = [candidat("KM-FICTIF-100", 90, 80)]
    d = decider_identification(candidats, doigts_sonde=2)
    assert d.verdict == Verdict.NON_CONCLUANT
    assert "recommencer" in d.motif


def test_base_vide():
    assert decider_identification([], 4).verdict == Verdict.NON_ENREGISTRE


def test_seuils_proportionnels_au_nombre_de_doigts():
    """Avec 3 doigts exploitables, le seuil de la main est 90 (et non 120)."""
    candidats = [Candidat("KM-FICTIF-100", 105, {2: 40, 3: 35, 4: 30})] + [
        Candidat(f"KM-FICTIF-{i}", 15, {2: 5, 3: 5, 4: 5}) for i in range(3)
    ]
    assert decider_identification(candidats, 3).verdict == Verdict.IDENTIFIE


def test_seuils_reglables():
    candidats = [candidat("KM-FICTIF-100", 45, 60, 38, 20)] + imposteurs()
    tres_strict = Seuils(moyenne_identifie=60)
    assert decider_identification(candidats, 4, tres_strict).verdict == Verdict.NON_CONCLUANT


# --- Plusieurs scans ---


def test_combinaison_garde_le_meilleur_score_par_doigt():
    a = [candidat("KM-FICTIF-100", 40, 10, 35, 5)]
    b = [candidat("KM-FICTIF-100", 12, 45, 20, 22)]
    fusion = combiner_scans([a, b])
    assert fusion[0].scores_doigts == {2: 40, 3: 45, 4: 35, 5: 22}
    assert fusion[0].score == 142


def test_deuxieme_scan_rend_l_identification_possible():
    """Chaque scan seul a un doigt flou ; ensemble, 4 doigts concordent."""
    scan1 = [candidat("KM-FICTIF-100", 45, 4, 40, 30)] + imposteurs()
    scan2 = [candidat("KM-FICTIF-100", 10, 50, 38, 28)] + imposteurs()
    assert decider_identification(scan1, 4).verdict == Verdict.NON_CONCLUANT
    d = decider_apres_plusieurs_scans([scan1, scan2], 4)
    assert d.verdict == Verdict.IDENTIFIE and d.candidat == "KM-FICTIF-100"


def test_scans_contradictoires_jamais_identifies():
    scan1 = [candidat("KM-FICTIF-100", 45, 60, 38, 20)] + imposteurs()
    scan2 = [candidat("KM-FICTIF-200", 50, 55, 40, 30)] + imposteurs()
    d = decider_apres_plusieurs_scans([scan1, scan2], 4)
    assert d.verdict == Verdict.NON_CONCLUANT
    assert "manuelle" in d.motif


# --- Anti-doublon (10 doigts) ---


def dix(id_: str, score: float, **forts: float) -> Candidat:
    doigts = {i: float(score) for i in range(1, 11)}
    doigts.update({int(k[1:]): float(v) for k, v in forts.items()})
    return Candidat(id_, sum(doigts.values()), doigts)


def test_doublon_certain():
    candidats = [dix("KM-FICTIF-100", 40)] + [dix(f"KM-FICTIF-{i}", 5) for i in range(3)]
    d = decider_doublon(candidats, 10)
    assert d.verdict == VerdictDoublon.DOUBLON_CERTAIN
    assert d.candidats == ["KM-FICTIF-100"]


def test_doublon_possible_sur_un_seul_doigt_fort():
    candidats = [dix("KM-FICTIF-100", 5, d7=38)] + [dix(f"KM-FICTIF-{i}", 4) for i in range(3)]
    d = decider_doublon(candidats, 10)
    assert d.verdict == VerdictDoublon.DOUBLON_POSSIBLE
    assert "KM-FICTIF-100" in d.candidats


def test_doublon_possible_sur_deux_doigts_moyens():
    candidats = [dix("KM-FICTIF-100", 5, d2=26, d8=27)] + [dix(f"KM-FICTIF-{i}", 4) for i in range(3)]
    assert decider_doublon(candidats, 10).verdict == VerdictDoublon.DOUBLON_POSSIBLE


def test_aucun_doublon():
    candidats = [dix(f"KM-FICTIF-{i}", 6) for i in range(5)]
    assert decider_doublon(candidats, 10).verdict == VerdictDoublon.AUCUN_DOUBLON


def test_aucun_doublon_impossible_a_affirmer_avec_trop_peu_de_doigts():
    candidats = [Candidat("KM-FICTIF-1", 6, {2: 3, 3: 3})]
    assert decider_doublon(candidats, 2).verdict == VerdictDoublon.DOUBLON_POSSIBLE


def test_doublon_base_vide():
    assert decider_doublon([], 10).verdict == VerdictDoublon.AUCUN_DOUBLON


def test_base_vide_mais_trop_peu_de_doigts():
    """Même sans personne en base, 2 doigts lisibles ne permettent pas d'affirmer « aucun doublon »."""
    assert decider_doublon([], 2).verdict == VerdictDoublon.DOUBLON_POSSIBLE
