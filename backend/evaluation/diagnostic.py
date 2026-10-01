"""Diagnostic : pourquoi le même doigt ne se reconnaît-il pas d'une session à l'autre ?

1. « Même instant » : les 3 photos d'une même rafale (même pose, même échelle).
   Les doigts sont redécoupés dans chaque photo complète, avec les points de la
   main enregistrés dans le JSON (mode débogage, sessions de l'étape 3c).
   → Scores bas même ici = la chaîne de traitement est en cause.
2. « Échelle » : une découpe comparée à elle-même, avec une échelle volontairement
   faussée de 5 à 20 % → sensibilité de SourceAFIS à une erreur d'échelle.

Ne produit que des chiffres (aucune image).
  python -m evaluation.diagnostic --captures /captures/s23ultra
"""

import argparse
import json
from dataclasses import replace
from pathlib import Path

import cv2
import numpy as np

from app.biometrie.client_matcher import ClientMatcher
from app.biometrie.pretraitement import VARIANTES, Variante, decoder_image, encoder_png, pretraiter

# Mêmes constantes que l'application (Zone.kt / CaptureRafale.kt).
BOUTS = [4, 8, 12, 16, 20]
ARTICULATIONS = [3, 7, 11, 15, 19]
AGRANDISSEMENT = 1.15
LARGEUR_DOIGT_MM = 18.0
NOMS = ["pouce", "index", "majeur", "annulaire", "auriculaire"]


def decouper(photo: np.ndarray, points: list[float], doigt: int) -> tuple[np.ndarray, float]:
    """Même découpe redressée que le téléphone (bout du doigt en haut)."""
    h, w = photo.shape[:2]
    b, a = BOUTS[doigt], ARTICULATIONS[doigt]
    bout = np.array([points[2 * b] * w, points[2 * b + 1] * h])
    art = np.array([points[2 * a] * w, points[2 * a + 1] * h])
    segment = bout - art
    longueur_seg = float(np.hypot(*segment))
    debut = 0.45 if doigt == 0 else 0.0
    depart = art + segment * debut
    fin = bout + segment * 0.35
    centre = (depart + fin) / 2
    longueur = longueur_seg * (1 + 0.35 - debut) * AGRANDISSEMENT
    largeur = longueur_seg * AGRANDISSEMENT
    axe = segment / longueur_seg
    travers = np.array([-axe[1], axe[0]])
    wl, hl = round(largeur), round(longueur)
    # Points de la sortie (0,0), (w,0), (0,h) → points de la photo.
    source = np.float32([
        centre - travers * wl / 2 + axe * hl / 2,
        centre + travers * wl / 2 + axe * hl / 2,
        centre - travers * wl / 2 - axe * hl / 2,
    ])
    destination = np.float32([[0, 0], [wl, 0], [0, hl]])
    matrice = cv2.getAffineTransform(source, destination)
    decoupe = cv2.warpAffine(photo, matrice, (wl, hl), flags=cv2.INTER_LINEAR)
    dpi = (largeur / AGRANDISSEMENT) / (LARGEUR_DOIGT_MM / 25.4)
    return decoupe, dpi


def modele(client: ClientMatcher, image: np.ndarray, dpi: float, variante: Variante) -> bytes:
    r = pretraiter(image, dpi, variante)
    return client.modele(encoder_png(r.image), r.dpi)[0]


def meme_instant(dossier: Path, client: ClientMatcher, variante: Variante) -> list[float]:
    scores = []
    for session in sorted(p for p in dossier.iterdir() if p.is_dir()):
        for fichier_json in sorted(session.glob("*.json")):
            donnees = json.loads(fichier_json.read_text(encoding="utf-8"))
            photos = [p for p in donnees.get("photos", []) if p.get("points")]
            if len(photos) < 2:
                continue
            etape = fichier_json.stem  # ex. droite_4doigts
            par_rafale: dict[int, list[dict]] = {}
            for p in photos:
                par_rafale.setdefault(p["rafale"], []).append(p)
            for rafale, liste in par_rafale.items():
                modeles: dict[int, list[bytes]] = {}
                for p in liste:
                    chemin = session / f"{etape}_r{rafale}_photo{p['photo']}.jpg"
                    if not chemin.exists():
                        continue
                    image = cv2.imread(str(chemin))
                    for doigt in donnees["doigts"]:
                        decoupe, dpi = decouper(image, p["points"], doigt)
                        modeles.setdefault(doigt, []).append(modele(client, decoupe, dpi, variante))
                for doigt, liste_modeles in modeles.items():
                    for i in range(len(liste_modeles)):
                        for j in range(i + 1, len(liste_modeles)):
                            s = client.comparer(liste_modeles[i], liste_modeles[j])
                            scores.append(s)
                            print(f"   {session.name} {etape} r{rafale} {NOMS[doigt]:<12} photos {i + 1}-{j + 1} : {s:6.1f}")
    return scores


def echelle(dossier: Path, client: ClientMatcher, variante: Variante) -> None:
    decoupes = sorted(dossier.glob("session_20261001_172107/*_iso*.png"))[:4]
    for chemin in decoupes:
        image = decoder_image(chemin.read_bytes())
        reference = modele(client, image, 500, variante)
        resultats = []
        for facteur in [1.0, 0.95, 0.9, 0.85, 0.8]:
            # Même image, mais annoncée à une autre résolution → mise à l'échelle faussée.
            faux = modele(client, image, 500 * facteur, variante)
            resultats.append(f"{int((1 - facteur) * 100):>2} % → {client.comparer(reference, faux):6.1f}")
        print(f"   {chemin.stem:<28} " + " | ".join(resultats))


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--captures", type=Path, required=True)
    p.add_argument("--variante", default="gabor_inverse_largeur")
    p.add_argument("--sans-rafale", action="store_true", help="ne faire que le test d'échelle")
    args = p.parse_args()
    variante = next(v for v in VARIANTES if v.nom == args.variante)
    client = ClientMatcher()

    print(f"Variante : {variante.nom}")
    print("1. Même instant (photos d'une même rafale) :")
    scores = [] if args.sans_rafale else meme_instant(args.captures, client, variante)
    if scores:
        print(f"   → {len(scores)} paires, médiane {np.median(scores):.1f}, "
              f"min {min(scores):.1f}, max {max(scores):.1f}")
    print("2. Sensibilité à une erreur d'échelle (découpe comparée à elle-même) :")
    # Échelle imposée (dpi annoncé), sans mesure des crêtes qui la corrigerait.
    echelle(args.captures, client, replace(variante, echelle="largeur"))


if __name__ == "__main__":
    main()
