"""Client HTTP du service de comparaison (matcher/, SourceAFIS)."""

import base64
import os
from dataclasses import dataclass

import httpx


class ErreurMatcher(RuntimeError):
    """Le matcher est injoignable ou a refusé la demande."""


@dataclass
class Candidat:
    id: str
    score: float
    scores_doigts: dict[int, float]


def _b64(octets: bytes) -> str:
    return base64.b64encode(octets).decode("ascii")


class ClientMatcher:
    def __init__(self, url: str | None = None, cle: str | None = None, delai: float = 60.0):
        self.url = (url or os.environ.get("MATCHER_URL", "http://matcher:8080")).rstrip("/")
        cle = cle or os.environ.get("MATCHER_CLE")
        if not cle:
            raise ErreurMatcher("MATCHER_CLE manquant")
        self._client = httpx.Client(base_url=self.url, headers={"X-Cle-Matcher": cle}, timeout=delai)

    def _appel(self, methode: str, chemin: str, **kwargs) -> httpx.Response:
        try:
            reponse = self._client.request(methode, chemin, **kwargs)
        except httpx.HTTPError as e:
            raise ErreurMatcher(f"Matcher injoignable : {e}") from e
        if reponse.status_code >= 400:
            raise ErreurMatcher(f"Matcher : {reponse.status_code} {reponse.text[:200]}")
        return reponse

    def sante(self) -> dict:
        return self._appel("GET", "/sante").json()

    def modele(self, image_png: bytes, dpi: float) -> tuple[bytes, str]:
        """Image prétraitée → (modèle sérialisé, version du moteur)."""
        r = self._appel("POST", "/modeles", json={"image": _b64(image_png), "dpi": dpi}).json()
        return base64.b64decode(r["modele"]), r["version"]

    def comparer(self, sonde: bytes, candidat: bytes) -> float:
        return self._appel("POST", "/comparer", json={"sonde": _b64(sonde), "candidat": _b64(candidat)}).json()[
            "score"
        ]

    def matrice(self, modeles: list[bytes]) -> list[list[float]]:
        """Scores de chaque modèle (ligne = sonde) contre chacun des autres ; diagonale = -1."""
        return self._appel("POST", "/matrice", json={"modeles": [_b64(m) for m in modeles]}).json()["scores"]

    def identifier(self, doigts: dict[int, bytes], fusion: str = "SOMME", limite: int = 5) -> list[Candidat]:
        corps = {
            "doigts": [{"doigt": d, "modele": _b64(m)} for d, m in doigts.items()],
            "fusion": fusion,
            "limite": limite,
        }
        candidats = self._appel("POST", "/identifier", json=corps).json()["candidats"]
        return [
            Candidat(c["id"], c["score"], {int(k): v for k, v in c["scoresDoigts"].items()}) for c in candidats
        ]

    def ajouter(self, identifiant: str, doigts: dict[int, bytes]) -> None:
        corps = {"doigts": [{"doigt": d, "modele": _b64(m)} for d, m in doigts.items()]}
        self._appel("PUT", f"/galerie/{identifiant}", json=corps)

    def retirer(self, identifiant: str) -> None:
        reponse = self._client.delete(f"/galerie/{identifiant}")
        if reponse.status_code not in (204, 404):
            raise ErreurMatcher(f"Matcher : {reponse.status_code}")
