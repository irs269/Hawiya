package km.hawiya.hawiya.qualite

import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.util.Locale

/**
 * OUTIL de calibrage (pas un test au sens strict) : calcule l'ancienne et la
 * nouvelle mesure de netteté sur de vraies découpes, avec le MÊME code que le
 * téléphone, et écrit un tableau CSV.
 *
 * Ignoré sauf si la variable d'environnement HAWIYA_CAPTURES pointe vers le
 * dossier captures/. Préparation (les tests Android n'ont pas de lecteur PNG) :
 *   powershell -File mobile\outils\convertir_pgm.ps1 -Captures <...>\captures
 * puis :
 *   set HAWIYA_CAPTURES=<...>\captures
 *   gradlew :app:testDebugUnitTest --tests "*CalibrageNetteteTest*"
 * Résultat : captures/calibrage_nettete.csv (jamais versionné).
 */
class CalibrageNetteteTest {

    /** Doit rester égal à CaptureRafale.AGRANDISSEMENT et LARGEUR_DOIGT_MM. */
    private val agrandissement = 1.15
    private val largeurDoigtMm = 18.0

    @Test
    fun calibrer() {
        val dossier = System.getenv("HAWIYA_CAPTURES")?.let(::File)
        assumeTrue("HAWIYA_CAPTURES non défini : outil ignoré", dossier?.isDirectory == true)
        val index = File(dossier, "planche_contact_index.csv")
        val pgm = File(dossier, "calibrage_pgm")
        assumeTrue("index ou images PGM absents", index.isFile && pgm.isDirectory)

        val lignes = mutableListOf("numero;fichier;dpi;laplacien;cretes;part_blocs_nets;blocs")
        index.readLines(Charsets.UTF_8)
            .map { it.removePrefix("﻿").trim() }
            .filter { it.isNotEmpty() }
            .forEach { ligne ->
                val (numero, relatif) = ligne.split(';', limit = 2)
                val fichier = File(pgm, "$numero.pgm")
                if (!fichier.isFile) return@forEach
                val gris = lirePgm(fichier)
                val centre = Mesures.centre(gris)
                val dpi = gris.largeur / agrandissement / (largeurDoigtMm / 25.4)
                val ancienne = Mesures.varianceLaplacien(Mesures.flou3x3(centre))
                val nouvelle = QualiteCretes.evaluer(centre, dpi)
                lignes += String.format(
                    Locale.ROOT, "%s;%s;%.0f;%.1f;%.3f;%.2f;%d",
                    numero, relatif, dpi, ancienne, nouvelle.score, nouvelle.partBlocsNets, nouvelle.nombreBlocs,
                )
            }
        File(dossier, "calibrage_nettete.csv").writeText(lignes.joinToString("\n"))
        println(lignes.joinToString("\n"))
    }

    /** PGM binaire (P5) 8 bits, en-tête sans commentaire. */
    private fun lirePgm(fichier: File): ImageGris {
        val octets = fichier.readBytes()
        var pos = 0
        fun jeton(): String {
            while (octets[pos].toInt().toChar().isWhitespace()) pos++
            val debut = pos
            while (!octets[pos].toInt().toChar().isWhitespace()) pos++
            return String(octets, debut, pos - debut, Charsets.US_ASCII)
        }
        check(jeton() == "P5") { "Format PGM attendu" }
        val largeur = jeton().toInt()
        val hauteur = jeton().toInt()
        jeton() // valeur maximale (255)
        pos++ // un seul blanc avant les données
        val px = IntArray(largeur * hauteur) { octets[pos + it].toInt() and 0xFF }
        return ImageGris(largeur, hauteur, px)
    }
}
