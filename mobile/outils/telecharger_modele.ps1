# Télécharge le modèle MediaPipe Hand Landmarker (licence Apache 2.0) dans les assets Android.
# Utilisation (depuis mobile/) :  powershell -File outils\telecharger_modele.ps1
$ErrorActionPreference = "Stop"

$url = "https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task"
$destination = Join-Path $PSScriptRoot "..\android\app\src\main\assets\hand_landmarker.task"

New-Item -ItemType Directory -Force (Split-Path $destination) | Out-Null
Invoke-WebRequest -Uri $url -OutFile $destination -UseBasicParsing

$taille = (Get-Item $destination).Length
$sha = (Get-FileHash $destination -Algorithm SHA256).Hash
Write-Output "Modèle téléchargé : $taille octets, SHA-256 $sha"
