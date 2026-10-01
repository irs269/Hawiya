"""Évalue la reconnaissance sur des découpes de doigts capturées par le téléphone.

Pour chaque variante de prétraitement : prétraitement → modèles (matcher) →
scores de toutes les paires → mesures de fiabilité, doigt par doigt et main
entière (4 doigts fusionnés). Le rapport ne contient que des chiffres et des
graphiques, JAMAIS d'images d'empreintes.

Utilisation (matcher démarré) :
  docker compose run --rm -v ./captures:/captures:ro -v ./docs:/docs backend \
      python -m evaluation.evaluer --captures /captures/s23ultra \
             --sortie /docs/evaluation/premier-signal

Organisation attendue : un sous-dossier par session de capture (mode débogage
de l'application), avec ses fichiers JSON et PNG. Par défaut toutes les
sessions appartiennent à la même personne (--personne) ; sinon fournir un
fichier CSV « session;personne » (--personnes).
"""

import argparse
import json
import sys
from collections import defaultdict
from dataclasses import dataclass
from datetime import date
from pathlib import Path

import cv2
import numpy as np

from app.biometrie.client_matcher import ClientMatcher
from app.biometrie.pretraitement import VARIANTES, Variante, decoder_image, encoder_png, pretraiter
from evaluation.metriques import Synthese, courbe_det, rang1, synthese


@dataclass(frozen=True)
class Echantillon:
    personne: str
    session: str
    iso: int  # 1 = pouce droit … 10 = auriculaire gauche
    fichier: Path
    dpi: float
    nettete: float | None  # netteté des crêtes (0..1) ; None pour les sessions d'avant l'étape 3c

    @property
    def main(self) -> str:
        return "droite" if self.iso <= 5 else "gauche"

    @property
    def doigt(self) -> int:
        """0 = pouce … 4 = auriculaire."""
        return (self.iso - 1) % 5


def collecter(dossier: Path, personnes: dict[str, str], defaut: str) -> list[Echantillon]:
    trouves: dict[tuple[str, int], Echantillon] = {}
    for session in sorted(p for p in dossier.iterdir() if p.is_dir()):
        for fichier_json in sorted(session.glob("*.json")):
            donnees = json.loads(fichier_json.read_text(encoding="utf-8"))
            resultats = donnees.get("resultats", [])
            nouveau_format = any("acceptee" in r for r in resultats)
            for r in resultats:
                fichier = session / Path(r["chemin"]).name
                if not fichier.exists():
                    continue
                trouves[(session.name, int(r["iso"]))] = Echantillon(
                    personne=personnes.get(session.name, defaut),
                    session=session.name,
                    iso=int(r["iso"]),
                    fichier=fichier,
                    dpi=float(r["dpiEstime"]),
                    nettete=float(r["nettete"]) if nouveau_format else None,
                )
    return sorted(trouves.values(), key=lambda e: (e.session, e.iso))


@dataclass
class ResultatVariante:
    variante: Variante
    doigt: Synthese
    main_somme: Synthese | None
    main_meilleurs3: Synthese | None
    rang1_somme: float
    echecs: int
    scores_doigt: tuple[list[float], list[float]]
    scores_main: tuple[list[float], list[float]]


# Comparaison multi-échelle : SourceAFIS perd la correspondance dès ~10 % d'erreur
# d'échelle (diagnostic du 01/10/2026), or l'échelle estimée varie d'une session
# à l'autre. On compare donc chaque doigt à plusieurs échelles et on garde le meilleur score.
ECHELLES = [0.85, 0.9, 0.95, 1.05, 1.1, 1.15]


def evaluer_variante(
    echantillons: list[Echantillon], variante: Variante, client: ClientMatcher, multi_echelle: bool = False
) -> ResultatVariante:
    modeles: list[bytes] = []
    variantes_echelle: list[list[bytes]] = []
    gardes: list[Echantillon] = []
    echecs = 0
    for e in echantillons:
        try:
            r = pretraiter(decoder_image(e.fichier.read_bytes()), e.dpi, variante)
            modele, _ = client.modele(encoder_png(r.image), r.dpi)
            autres = []
            if multi_echelle:
                for facteur in ECHELLES:
                    h, w = r.image.shape
                    image = cv2.resize(r.image, (round(w * facteur), round(h * facteur)), interpolation=cv2.INTER_LINEAR)
                    autres.append(client.modele(encoder_png(image), r.dpi)[0])
        except Exception as erreur:  # une découpe illisible ne bloque pas l'évaluation
            print(f"  ! {e.session}/{e.fichier.name} : {erreur}", file=sys.stderr)
            echecs += 1
            continue
        modeles.append(modele)
        variantes_echelle.append(autres)
        gardes.append(e)

    n = len(modeles)
    tous = modeles + [m for autres in variantes_echelle for m in autres]
    brute = np.array(client.matrice(tous), dtype=float)
    # SourceAFIS n'est pas parfaitement symétrique : moyenne des deux sens.
    scores = (brute[:n, :n] + brute[:n, :n].T) / 2
    if multi_echelle:
        k = len(ECHELLES)
        for i in range(n):
            for j in range(n):
                if i == j:
                    continue
                # Sonde i (échelle 1) contre j à chaque échelle, et inversement.
                colonnes_j = [n + j * k + q for q in range(k)]
                colonnes_i = [n + i * k + q for q in range(k)]
                meilleur = max(brute[i, colonnes_j].max(), brute[j, colonnes_i].max())
                scores[i, j] = max(scores[i, j], meilleur)

    # --- Doigt par doigt ---
    authentiques, imposteurs = [], []
    for i in range(len(gardes)):
        for j in range(i + 1, len(gardes)):
            a, b = gardes[i], gardes[j]
            if a.personne == b.personne and a.iso == b.iso:
                if a.session != b.session:
                    authentiques.append(scores[i, j])
            else:
                imposteurs.append(scores[i, j])

    # --- Main entière (4 doigts, sans le pouce), comparée doigt à doigt de même position ---
    mains: dict[tuple[str, str, str], dict[int, int]] = defaultdict(dict)
    for indice, e in enumerate(gardes):
        if e.doigt != 0:
            mains[(e.personne, e.session, e.main)][e.doigt] = indice

    def score_main(m1: dict[int, int], m2: dict[int, int], fusion: str) -> float | None:
        communs = sorted(set(m1) & set(m2))
        if len(communs) < 3:
            return None
        valeurs = sorted((scores[m1[d], m2[d]] for d in communs), reverse=True)
        return float(sum(valeurs[:3] if fusion == "meilleurs3" else valeurs))

    cles = list(mains)
    paires_main = {"somme": ([], []), "meilleurs3": ([], [])}
    sondes = []
    for i, ci in enumerate(cles):
        candidats_identite: dict[str, float] = {}
        for j, cj in enumerate(cles):
            if i == j:
                continue
            meme_identite = ci[0] == cj[0] and ci[2] == cj[2]
            if ci[1] == cj[1] and meme_identite:
                continue
            for fusion, (auth, imp) in paires_main.items():
                s = score_main(mains[ci], mains[cj], fusion)
                if s is None or j < i:
                    continue
                (auth if meme_identite else imp).append(s)
            # Identification : meilleure session de chaque identité (autre session).
            if ci[1] != cj[1]:
                s = score_main(mains[ci], mains[cj], "somme")
                if s is not None:
                    identite = f"{cj[0]}/{cj[2]}"
                    candidats_identite[identite] = max(s, candidats_identite.get(identite, -1))
        vraie = f"{ci[0]}/{ci[2]}"
        if vraie in candidats_identite:
            sondes.append((vraie, candidats_identite))

    def synth(paire):
        auth, imp = paire
        return synthese(auth, imp) if auth and imp else None

    return ResultatVariante(
        variante=variante,
        doigt=synthese(authentiques, imposteurs),
        main_somme=synth(paires_main["somme"]),
        main_meilleurs3=synth(paires_main["meilleurs3"]),
        rang1_somme=rang1(sondes),
        echecs=echecs,
        scores_doigt=(authentiques, imposteurs),
        scores_main=paires_main["somme"],
    )


# ----------------------------------------------------------------------------- rapport


def _pc(x: float | None) -> str:
    return "—" if x is None or x != x else f"{x * 100:.1f} %"


def _n(x: float | None, chiffres: int = 1) -> str:
    return "—" if x is None or x != x else f"{x:.{chiffres}f}"


def tracer(resultat: ResultatVariante, dossier: Path) -> list[str]:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fichiers = []
    for titre, (auth, imp), nom in [
        ("Doigt par doigt", resultat.scores_doigt, "doigt"),
        ("Main entière (4 doigts, somme)", resultat.scores_main, "main"),
    ]:
        if not auth or not imp:
            continue
        fig, (h, d) = plt.subplots(1, 2, figsize=(11, 4))
        bornes = np.linspace(0, max(max(auth), max(imp)) * 1.05, 40)
        h.hist(imp, bins=bornes, alpha=0.6, label=f"imposteurs ({len(imp)})", color="#C98A1B")
        h.hist(auth, bins=bornes, alpha=0.6, label=f"authentiques ({len(auth)})", color="#0F5A45")
        h.set_xlabel("score SourceAFIS")
        h.set_ylabel("nombre de paires")
        h.legend()
        h.set_title(f"{titre} — distribution des scores")
        _, taux_fm, taux_fnm = courbe_det(np.array(auth), np.array(imp))
        d.plot(np.maximum(taux_fm, 1e-4), np.maximum(taux_fnm, 1e-4), color="#0F5A45")
        d.set_xscale("log")
        d.set_yscale("log")
        d.set_xlabel("FMR (fausses correspondances)")
        d.set_ylabel("FNMR (refus à tort)")
        d.set_title(f"{titre} — courbe DET")
        d.grid(True, which="both", alpha=0.3)
        fig.tight_layout()
        chemin = dossier / f"{resultat.variante.nom}_{nom}.png"
        fig.savefig(chemin, dpi=110)
        plt.close(fig)
        fichiers.append(chemin.name)
    return fichiers


def ecrire_rapport(
    dossier: Path, titre: str, echantillons: list[Echantillon], resultats: list[ResultatVariante], filtre: str
) -> Path:
    dossier.mkdir(parents=True, exist_ok=True)
    sessions = sorted({e.session for e in echantillons})
    personnes = sorted({e.personne for e in echantillons})

    # Meilleure variante : plus faible EER main entière, puis meilleure séparation doigt.
    def cle(r: ResultatVariante):
        eer_main = r.main_somme.eer if r.main_somme else 1.0
        return (eer_main, r.doigt.eer, -r.doigt.separation_d_prime)

    meilleure = min(resultats, key=cle)
    graphiques = tracer(meilleure, dossier)

    lignes = [
        f"# {titre}",
        "",
        f"> Généré le {date.today():%d/%m/%Y} par `evaluation/evaluer.py`. Prototype non officiel.",
        "> Aucune image d'empreinte dans ce rapport : seulement des scores.",
        "",
        "## Données",
        "",
        "| | |",
        "|---|---|",
        f"| Personnes | {len(personnes)} |",
        f"| Sessions de capture | {len(sessions)} |",
        f"| Découpes de doigts | {len(echantillons)} |",
        f"| Filtre | {filtre} |",
        "",
        "Paires **authentiques** : même doigt de la même personne, sessions différentes.",
        "Paires **imposteur** : doigts différents (autre doigt ou autre personne).",
        "",
        "## Résultats par variante de prétraitement",
        "",
        "### Doigt par doigt",
        "",
        "| Variante | Authentiques | Imposteurs | EER | d' | Médiane authentique | Max imposteur | FNMR à FMR 1 % |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for r in resultats:
        s = r.doigt
        lignes.append(
            f"| {r.variante.nom}{' ⭐' if r is meilleure else ''} | {s.nb_authentiques} | {s.nb_imposteurs} | "
            f"{_pc(s.eer)} | {_n(s.separation_d_prime, 2)} | {_n(s.authentique_mediane)} | {_n(s.imposteur_max)} | "
            f"{_pc(s.fnmr_a_fmr_1pc)} |"
        )
    lignes += [
        "",
        "### Main entière (4 doigts fusionnés)",
        "",
        "| Variante | Fusion | Authentiques | Imposteurs | EER | d' | Médiane authentique | Max imposteur | Rang 1 |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for r in resultats:
        for nom, s in [("somme", r.main_somme), ("3 meilleurs", r.main_meilleurs3)]:
            if s is None:
                lignes.append(f"| {r.variante.nom} | {nom} | — | — | — | — | — | — | — |")
                continue
            rang = _pc(r.rang1_somme) if nom == "somme" else ""
            lignes.append(
                f"| {r.variante.nom} | {nom} | {s.nb_authentiques} | {s.nb_imposteurs} | {_pc(s.eer)} | "
                f"{_n(s.separation_d_prime, 2)} | {_n(s.authentique_mediane)} | {_n(s.imposteur_max)} | {rang} |"
            )
    s = meilleure.doigt
    lignes += [
        "",
        f"## Meilleure variante : `{meilleure.variante.nom}`",
        "",
        f"- Seuil à l'EER (doigt) : {_n(s.seuil_eer)} ; seuil pour FMR ≤ 1 % : {_n(s.seuil_fmr_1pc)}.",
        f"- Découpes impossibles à traiter : {meilleure.echecs}.",
        "",
    ]
    lignes += [f"![{g}]({g})" for g in graphiques]
    lignes += [
        "",
        "## Limites",
        "",
        f"- Avec {s.nb_imposteurs} paires imposteur, on ne peut pas affirmer un FMR inférieur à "
        f"{_pc(s.fmr_mesurable_min)} (règle des 3).",
        "- Les variantes sont choisies sur ces mêmes données : le résultat est optimiste. "
        "À confirmer sur de nouvelles captures.",
    ]
    if len(personnes) == 1:
        lignes.append(
            "- **Une seule personne** : les imposteurs sont ses autres doigts. Cela mesure si un doigt "
            "se reconnaît d'une session à l'autre, pas la fiabilité sur une population."
        )
    chemin = dossier / "rapport.md"
    chemin.write_text("\n".join(lignes) + "\n", encoding="utf-8")
    return chemin


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--captures", type=Path, required=True)
    p.add_argument("--sortie", type=Path, required=True)
    p.add_argument("--personne", default="P01", help="personne par défaut de toutes les sessions")
    p.add_argument("--personnes", type=Path, help="CSV « session;personne »")
    p.add_argument("--nettete-min", type=float, default=None, help="ne garder que les découpes au moins aussi nettes")
    p.add_argument("--titre", default="Évaluation de la reconnaissance")
    p.add_argument("--variantes", default="toutes", help="noms séparés par des virgules")
    p.add_argument("--multi-echelle", action="store_true", help="comparer à plusieurs échelles (±15 %)")
    args = p.parse_args()

    personnes = {}
    if args.personnes:
        for ligne in args.personnes.read_text(encoding="utf-8").splitlines():
            if ";" in ligne:
                session, personne = ligne.strip().split(";", 1)
                personnes[session] = personne

    echantillons = collecter(args.captures, personnes, args.personne)
    filtre = "toutes les découpes"
    if args.nettete_min is not None:
        echantillons = [e for e in echantillons if e.nettete is not None and e.nettete >= args.nettete_min]
        filtre = f"netteté des crêtes ≥ {args.nettete_min} (sessions de l'étape 3c uniquement)"
    if args.multi_echelle:
        filtre += " ; comparaison multi-échelle (±15 %)"
    print(f"{len(echantillons)} découpes, {len({e.session for e in echantillons})} sessions")

    variantes = VARIANTES if args.variantes == "toutes" else [v for v in VARIANTES if v.nom in args.variantes.split(",")]
    client = ClientMatcher()
    resultats = []
    for v in variantes:
        print(f"→ {v.nom}")
        r = evaluer_variante(echantillons, v, client, multi_echelle=args.multi_echelle)
        print(
            f"   doigt : EER {_pc(r.doigt.eer)}, d' {_n(r.doigt.separation_d_prime, 2)} | "
            f"main : EER {_pc(r.main_somme.eer if r.main_somme else None)}, rang 1 {_pc(r.rang1_somme)}"
        )
        resultats.append(r)
    chemin = ecrire_rapport(args.sortie, args.titre, echantillons, resultats, filtre)
    print(f"Rapport : {chemin}")


if __name__ == "__main__":
    main()
