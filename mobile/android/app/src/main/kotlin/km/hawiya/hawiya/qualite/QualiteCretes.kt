package km.hawiya.hawiya.qualite

import kotlin.math.ceil
import kotlin.math.exp
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Netteté des CRÊTES d'une découpe de doigt, entre 0 (aucune crête) et 1.
 *
 * Principe : les crêtes sont des lignes parallèles espacées d'environ 0,45 mm.
 * Connaissant la résolution (dpi), on sait à combien de pixels les attendre.
 * Pour chaque bloc de la pulpe du doigt :
 *  1. filtre passe-bande (différence de deux flous gaussiens) réglé sur cet
 *     espacement : garde les crêtes, retire l'éclairage, les plis larges et le bruit fin ;
 *  2. « clarté » = énergie après le passe-bande / contraste du bloc
 *     → indépendante de l'éclairage et de la couleur de peau ;
 *  3. « cohérence » = les contours vont-ils tous dans la même direction ?
 *     (crêtes : ≈ 1 ; bruit, peau sèche, flou : ≈ 0) ;
 *  4. score du bloc = clarté × cohérence ; score du doigt = médiane des blocs.
 *
 * Code pur (sans Android) : testé sur PC et utilisé tel quel sur le téléphone.
 */
object QualiteCretes {

    /** Espacement moyen entre deux crêtes d'un adulte. */
    const val ECART_CRETES_MM = 0.45

    /** Écart-type minimal d'un bloc (niveaux de gris) pour qu'il soit pris en compte. */
    private const val CONTRASTE_MIN = 2.0

    data class Resultat(
        /** 0..1 : médiane des blocs. */
        val score: Double,
        /** Part des blocs dont le score dépasse 0,3 (crêtes franches). */
        val partBlocsNets: Double,
        val nombreBlocs: Int,
        /** Espacement des crêtes attendu, en pixels. */
        val periodePx: Double,
    )

    fun periodePx(dpi: Double): Double = (ECART_CRETES_MM / 25.4 * dpi).coerceIn(4.0, 40.0)

    /**
     * [img] : la pulpe du doigt (déjà recadrée, par ex. Mesures.centre d'une découpe).
     * [dpi] : résolution estimée de la découpe.
     */
    fun evaluer(img: ImageGris, dpi: Double): Resultat {
        val p = periodePx(dpi)
        val source = FloatArray(img.pixels.size) { img.pixels[it].toFloat() }
        val fin = flouGaussien(source, img.largeur, img.hauteur, p / 6.0)
        val large = flouGaussien(source, img.largeur, img.hauteur, p / 3.0)
        val bande = FloatArray(fin.size) { fin[it] - large[it] }

        // Blocs d'environ 2,5 crêtes de côté.
        val cote = (2.5 * p).roundToInt().coerceAtLeast(8)
        val scores = mutableListOf<Double>()
        var y0 = 0
        while (y0 + cote <= img.hauteur) {
            var x0 = 0
            while (x0 + cote <= img.largeur) {
                scores += scoreBloc(fin, bande, img.largeur, x0, y0, cote)
                x0 += cote
            }
            y0 += cote
        }
        if (scores.isEmpty()) return Resultat(0.0, 0.0, 0, p)
        scores.sort()
        val mediane = if (scores.size % 2 == 1) {
            scores[scores.size / 2]
        } else {
            (scores[scores.size / 2 - 1] + scores[scores.size / 2]) / 2
        }
        return Resultat(mediane, scores.count { it > 0.3 }.toDouble() / scores.size, scores.size, p)
    }

    private fun scoreBloc(fin: FloatArray, bande: FloatArray, largeur: Int, x0: Int, y0: Int, cote: Int): Double {
        // Contraste du bloc (image peu floutée) et énergie des crêtes (passe-bande).
        var somme = 0.0
        var sommeCarres = 0.0
        var energie = 0.0
        var sommeBande = 0.0
        val n = cote * cote
        for (y in y0 until y0 + cote) {
            for (x in x0 until x0 + cote) {
                val i = y * largeur + x
                val v = fin[i].toDouble()
                somme += v
                sommeCarres += v * v
                val b = bande[i].toDouble()
                sommeBande += b
                energie += b * b
            }
        }
        val variance = sommeCarres / n - (somme / n) * (somme / n)
        if (variance < CONTRASTE_MIN * CONTRASTE_MIN) return 0.0
        val varianceBande = energie / n - (sommeBande / n) * (sommeBande / n)
        val clarte = (varianceBande / variance).coerceIn(0.0, 1.0)

        // Cohérence d'orientation : tenseur de structure des gradients du passe-bande.
        var jxx = 0.0
        var jyy = 0.0
        var jxy = 0.0
        for (y in y0 + 1 until y0 + cote - 1) {
            for (x in x0 + 1 until x0 + cote - 1) {
                val gx = (bande[y * largeur + x + 1] - bande[y * largeur + x - 1]).toDouble()
                val gy = (bande[(y + 1) * largeur + x] - bande[(y - 1) * largeur + x]).toDouble()
                jxx += gx * gx
                jyy += gy * gy
                jxy += gx * gy
            }
        }
        val trace = jxx + jyy
        if (trace <= 0.0) return 0.0
        val coherence = sqrt((jxx - jyy) * (jxx - jyy) + 4 * jxy * jxy) / trace
        return clarte * coherence
    }

    /** Flou gaussien séparable (bords : valeur du pixel le plus proche). */
    fun flouGaussien(src: FloatArray, largeur: Int, hauteur: Int, sigma: Double): FloatArray {
        val rayon = ceil(3 * sigma).toInt().coerceAtLeast(1)
        val noyau = FloatArray(2 * rayon + 1) { k ->
            val d = (k - rayon).toDouble()
            exp(-d * d / (2 * sigma * sigma)).toFloat()
        }
        val total = noyau.sum()
        for (k in noyau.indices) noyau[k] /= total

        val temp = FloatArray(src.size)
        for (y in 0 until hauteur) {
            val ligne = y * largeur
            for (x in 0 until largeur) {
                var s = 0f
                for (k in -rayon..rayon) {
                    val xx = (x + k).coerceIn(0, largeur - 1)
                    s += src[ligne + xx] * noyau[k + rayon]
                }
                temp[ligne + x] = s
            }
        }
        val sortie = FloatArray(src.size)
        for (y in 0 until hauteur) {
            for (x in 0 until largeur) {
                var s = 0f
                for (k in -rayon..rayon) {
                    val yy = (y + k).coerceIn(0, hauteur - 1)
                    s += temp[yy * largeur + x] * noyau[k + rayon]
                }
                sortie[y * largeur + x] = s
            }
        }
        return sortie
    }
}
