# mobile/

Application Flutter (Android d'abord), interface en français.

## État

- **Étape 3a (en cours de validation)** : écran de test caméra. Il affiche l'aperçu de la caméra arrière avec le flash, détecte la main en direct (MediaPipe, 21 points), dessine les zones d'empreintes et donne un diagnostic du téléphone.
- Étape 3b : qualité, guidage et capture automatique des doigts.
- Phase 2 : écrans et formulaires.

## Architecture de la capture

La capture est faite en Kotlin natif, car il n'existe pas de plugin Flutter MediaPipe officiel. Elle est reliée à Flutter par :

| Canal | Rôle |
|---|---|
| vue `hawiya/apercu` | aperçu caméra (PreviewView), affiché par Flutter |
| méthodes `hawiya/capture` | `permission`, `demarrer`, `arreter`, `flash`, `zoom`, `mettreAuPoint`, `infos` |
| flux `hawiya/capture/flux` | une analyse par image traitée (5 à 10 par seconde) |

Fichiers natifs (`android/app/src/main/kotlin/km/hawiya/hawiya/capture/`) :

- `MoteurCapture.kt` : CameraX avec trois flux 4:3 (aperçu, analyse en environ 640×480, photo en pleine résolution), le flash, le zoom, la mise au point et le diagnostic.
- `DetecteurMain.kt` : MediaPipe Hand Landmarker, correction main droite/gauche pour la caméra arrière, estimation paume ou dos de la main.
- `CanalCapture.kt` : le pont avec Flutter.

## Modèle MediaPipe

`android/app/src/main/assets/hand_landmarker.task` (licence Apache 2.0) :

- version `float16/1` ;
- 7 819 105 octets ;
- SHA-256 `FBC2A30080C3C557093B5DDFC334698132EB341044CCEE322CCF8BCF3607CDE1`.

Pour le télécharger à nouveau :

```bash
powershell -File outils\telecharger_modele.ps1
```

## Lancer sur un téléphone

1. Activer les **Options pour les développeurs**, puis le **Débogage USB**, et brancher le téléphone.
2. Vérifier qu'il apparaît :
   ```bash
   flutter devices
   ```
3. Lancer l'application :
   ```bash
   flutter run
   ```

## Tests

```bash
flutter analyze
flutter test
```
