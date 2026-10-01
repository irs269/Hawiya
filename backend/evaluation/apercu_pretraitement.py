"""Outil de mise au point : enregistre le résultat de chaque variante de
prétraitement pour UNE découpe, côte à côte, avec la période mesurée.

Les images produites sont des empreintes : à écrire uniquement dans captures/
(jamais versionné).
  python -m evaluation.apercu_pretraitement <découpe.png> <dpi> <sortie.png>
"""

import sys

import cv2
import numpy as np

from app.biometrie.pretraitement import VARIANTES, decoder_image, pretraiter


def main() -> None:
    source, dpi, sortie = sys.argv[1], float(sys.argv[2]), sys.argv[3]
    image = decoder_image(open(source, "rb").read())
    vignettes = []
    hauteur = 420
    for v in VARIANTES:
        r = pretraiter(image, dpi, v)
        echelle = hauteur / r.image.shape[0]
        vignette = cv2.resize(r.image, (round(r.image.shape[1] * echelle), hauteur))
        vignette = cv2.cvtColor(vignette, cv2.COLOR_GRAY2BGR)
        periode = "?" if r.periode_mesuree_px is None else f"{r.periode_mesuree_px:.1f}"
        cv2.putText(vignette, v.nom, (4, 14), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (0, 0, 255), 1)
        cv2.putText(vignette, f"p={periode} x{r.facteur_echelle:.2f}", (4, 30),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.4, (0, 0, 255), 1)
        vignettes.append(vignette)
    largeur_max = max(v.shape[1] for v in vignettes)
    vignettes = [cv2.copyMakeBorder(v, 0, 0, 0, largeur_max - v.shape[1], cv2.BORDER_CONSTANT, value=(255, 255, 255))
                 for v in vignettes]
    cv2.imwrite(sortie, np.hstack(vignettes))
    print(sortie)


if __name__ == "__main__":
    main()
