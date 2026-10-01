# Convertit les découpes PNG listées dans captures/planche_contact_index.csv en
# images PGM en niveaux de gris (même formule de luminance que le téléphone),
# pour l'outil de calibrage Kotlin (CalibrageNetteteTest), qui n'a pas accès
# aux bibliothèques d'images de Java.
# Utilisation : powershell -File outils\convertir_pgm.ps1 -Captures C:\...\Hawiya\captures
param([Parameter(Mandatory)][string]$Captures)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$sortie = Join-Path $Captures "calibrage_pgm"
New-Item -ItemType Directory -Force $sortie | Out-Null

foreach ($ligne in Get-Content (Join-Path $Captures "planche_contact_index.csv") -Encoding UTF8) {
    if (-not $ligne.Trim()) { continue }
    $numero, $relatif = $ligne.Split(';', 2)
    $bmp = New-Object System.Drawing.Bitmap (Join-Path $Captures $relatif)
    $rect = New-Object System.Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height
    $donnees = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $octets = New-Object byte[] ($donnees.Stride * $bmp.Height)
    [System.Runtime.InteropServices.Marshal]::Copy($donnees.Scan0, $octets, 0, $octets.Length)
    $bmp.UnlockBits($donnees)

    $gris = New-Object byte[] ($bmp.Width * $bmp.Height)
    for ($y = 0; $y -lt $bmp.Height; $y++) {
        $ligneSource = $y * $donnees.Stride
        for ($x = 0; $x -lt $bmp.Width; $x++) {
            $i = $ligneSource + 4 * $x # ordre B, G, R, A
            $gris[$y * $bmp.Width + $x] = [byte][math]::Floor(($octets[$i + 2] * 299 + $octets[$i + 1] * 587 + $octets[$i] * 114) / 1000)
        }
    }
    $entete = [Text.Encoding]::ASCII.GetBytes("P5`n$($bmp.Width) $($bmp.Height)`n255`n")
    $flux = [IO.File]::Create((Join-Path $sortie "$numero.pgm"))
    $flux.Write($entete, 0, $entete.Length)
    $flux.Write($gris, 0, $gris.Length)
    $flux.Close()
    $bmp.Dispose()
}
Write-Output "Conversion terminée : $sortie"
