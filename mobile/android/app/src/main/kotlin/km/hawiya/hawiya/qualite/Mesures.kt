package km.hawiya.hawiya.qualite

import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.sin

/**
 * Image en niveaux de gris (0..255), stockée ligne par ligne.
 * Indépendante d'Android : les calculs de qualité sont testables sur PC (JUnit).
 */
class ImageGris(val largeur: Int, val hauteur: Int, val pixels: IntArray) {
    init {
        require(pixels.size == largeur * hauteur) { "Taille incohérente" }
    }

    operator fun get(x: Int, y: Int): Int = pixels[y * largeur + x]

    companion object {
        /** Depuis des pixels ARGB (Bitmap.getPixels) : luminance Rec. 601. */
        fun depuisArgb(largeur: Int, hauteur: Int, argb: IntArray): ImageGris {
            val gris = IntArray(largeur * hauteur) { i ->
                val c = argb[i]
                ((c shr 16 and 0xFF) * 299 + (c shr 8 and 0xFF) * 587 + (c and 0xFF) * 114) / 1000
            }
            return ImageGris(largeur, hauteur, gris)
        }
    }
}

/**
 * Zone orientée qui contient l'empreinte d'un bout de doigt (en pixels).
 *
 * MÊME FORMULE que zoneEmpreinte() dans mobile/lib/capture/geometrie_doigts.dart :
 * de l'articulation jusqu'à 35 % au-delà du point « bout » MediaPipe,
 * largeur ≈ longueur de la dernière phalange.
 */
data class Zone(
    val cx: Float,
    val cy: Float,
    /** Le long du doigt. */
    val longueur: Float,
    /** En travers du doigt. */
    val largeur: Float,
    /** Angle (radians) de l'axe articulation → bout. */
    val angle: Float,
) {
    companion object {
        /** Bouts des doigts (pouce, index, majeur, annulaire, auriculaire), indices MediaPipe. */
        val BOUTS = intArrayOf(4, 8, 12, 16, 20)
        val ARTICULATIONS = intArrayOf(3, 7, 11, 15, 19)

        fun empreinte(boutX: Float, boutY: Float, artX: Float, artY: Float, agrandissement: Float = 1f): Zone {
            val sx = boutX - artX
            val sy = boutY - artY
            val segment = hypot(sx, sy)
            val finX = boutX + sx * 0.35f
            val finY = boutY + sy * 0.35f
            return Zone(
                cx = (artX + finX) / 2f,
                cy = (artY + finY) / 2f,
                longueur = segment * 1.35f * agrandissement,
                largeur = segment * 1.0f * agrandissement,
                angle = atan2(sy, sx),
            )
        }

        /**
         * Zone du doigt [doigt] (0 = pouce … 4 = auriculaire) à partir des 21 points
         * MediaPipe normalisés (x0, y0, x1, y1…), dans une image [largeur]×[hauteur].
         */
        fun pourDoigt(points: FloatArray, doigt: Int, largeur: Int, hauteur: Int, agrandissement: Float = 1f): Zone {
            val b = BOUTS[doigt]
            val a = ARTICULATIONS[doigt]
            return empreinte(
                points[2 * b] * largeur, points[2 * b + 1] * hauteur,
                points[2 * a] * largeur, points[2 * a + 1] * hauteur,
                agrandissement,
            )
        }
    }

    /** Les 4 coins (x, y). */
    fun coins(): List<Pair<Float, Float>> {
        val ax = cos(angle)
        val ay = sin(angle)
        val tx = -ay
        val ty = ax
        val l = longueur / 2f
        val w = largeur / 2f
        return listOf(
            Pair(cx - ax * l - tx * w, cy - ay * l - ty * w),
            Pair(cx + ax * l - tx * w, cy + ay * l - ty * w),
            Pair(cx + ax * l + tx * w, cy + ay * l + ty * w),
            Pair(cx - ax * l + tx * w, cy - ay * l + ty * w),
        )
    }

    /** Vrai si la zone entière est dans l'image (avec une marge en pixels). */
    fun dansImage(largeurImage: Int, hauteurImage: Int, marge: Float = 0f): Boolean =
        coins().all { (x, y) ->
            x >= marge && y >= marge && x <= largeurImage - marge && y <= hauteurImage - marge
        }
}

/** Mesures de qualité d'image, sur des images en niveaux de gris. */
object Mesures {

    /**
     * Extrait la [zone], REDRESSÉE : bout du doigt en haut, sortie [largeurSortie]×[hauteurSortie].
     * Échantillonnage bilinéaire ; les pixels hors de l'image valent 0.
     * Même transformation que la découpe couleur pleine résolution (MoteurCapture.decouper).
     */
    fun redresser(src: ImageGris, zone: Zone, largeurSortie: Int, hauteurSortie: Int): ImageGris {
        val ax = cos(zone.angle)
        val ay = sin(zone.angle)
        val tx = -ay
        val ty = ax
        val pasU = zone.largeur / largeurSortie
        val pasV = zone.longueur / hauteurSortie
        val sortie = IntArray(largeurSortie * hauteurSortie)
        for (v in 0 until hauteurSortie) {
            // v = 0 en haut, du côté du bout du doigt
            val dv = (hauteurSortie / 2f - (v + 0.5f)) * pasV
            for (u in 0 until largeurSortie) {
                val du = ((u + 0.5f) - largeurSortie / 2f) * pasU
                val sx = zone.cx + tx * du + ax * dv
                val sy = zone.cy + ty * du + ay * dv
                sortie[v * largeurSortie + u] = bilineaire(src, sx, sy)
            }
        }
        return ImageGris(largeurSortie, hauteurSortie, sortie)
    }

    /** Valeur au point continu (x, y) ; le centre du pixel (i, j) est en (i + 0,5 ; j + 0,5). */
    private fun bilineaire(img: ImageGris, x: Float, y: Float): Int {
        val fx = x - 0.5f
        val fy = y - 0.5f
        val x0 = floor(fx).toInt()
        val y0 = floor(fy).toInt()
        if (x0 < 0 || y0 < 0 || x0 + 1 >= img.largeur || y0 + 1 >= img.hauteur) {
            // Bord : plus proche voisin si dans l'image, sinon 0.
            val xi = (x - 0.5f).let { Math.round(it) }
            val yi = (y - 0.5f).let { Math.round(it) }
            return if (xi in 0 until img.largeur && yi in 0 until img.hauteur) img[xi, yi] else 0
        }
        val dx = fx - x0
        val dy = fy - y0
        val haut = img[x0, y0] * (1 - dx) + img[x0 + 1, y0] * dx
        val bas = img[x0, y0 + 1] * (1 - dx) + img[x0 + 1, y0 + 1] * dx
        return Math.round(haut * (1 - dy) + bas * dy)
    }

    /**
     * Partie centrale d'une découpe redressée : là où se trouve la pulpe du doigt,
     * sans les bords du doigt ni le fond (qui fausseraient la netteté).
     */
    fun centre(img: ImageGris): ImageGris =
        region(img, 0.2f, 0.15f, 0.8f, 0.75f)

    /** Sous-image entre les fractions (x0, y0) et (x1, y1) de la largeur/hauteur. */
    fun region(img: ImageGris, x0: Float, y0: Float, x1: Float, y1: Float): ImageGris {
        val gx = (img.largeur * x0).toInt()
        val gy = (img.hauteur * y0).toInt()
        val dx = (img.largeur * x1).toInt().coerceAtLeast(gx + 1)
        val dy = (img.hauteur * y1).toInt().coerceAtLeast(gy + 1)
        val l = dx - gx
        val h = dy - gy
        val px = IntArray(l * h) { i -> img[gx + i % l, gy + i / l] }
        return ImageGris(l, h, px)
    }

    /** Flou 3×3 (moyenne) : atténue le bruit du capteur avant la mesure de netteté. */
    fun flou3x3(img: ImageGris): ImageGris {
        if (img.largeur < 3 || img.hauteur < 3) return img
        val sortie = img.pixels.copyOf()
        for (y in 1 until img.hauteur - 1) {
            for (x in 1 until img.largeur - 1) {
                var s = 0
                for (j in -1..1) for (i in -1..1) s += img[x + i, y + j]
                sortie[y * img.largeur + x] = s / 9
            }
        }
        return ImageGris(img.largeur, img.hauteur, sortie)
    }

    /**
     * Netteté : variance du Laplacien (4 voisins). Plus elle est grande, plus
     * l'image contient de détails fins (crêtes). 0 pour une image uniforme.
     */
    fun varianceLaplacien(img: ImageGris): Double {
        if (img.largeur < 3 || img.hauteur < 3) return 0.0
        var somme = 0.0
        var sommeCarres = 0.0
        var n = 0
        for (y in 1 until img.hauteur - 1) {
            for (x in 1 until img.largeur - 1) {
                val l = (img[x - 1, y] + img[x + 1, y] + img[x, y - 1] + img[x, y + 1] - 4 * img[x, y]).toDouble()
                somme += l
                sommeCarres += l * l
                n++
            }
        }
        val moyenne = somme / n
        return sommeCarres / n - moyenne * moyenne
    }

    fun luminanceMoyenne(img: ImageGris): Double = img.pixels.average()

    /** Part des pixels éblouis (reflet du flash), entre 0 et 1. */
    fun fractionEblouie(img: ImageGris, seuil: Int = 250): Double =
        img.pixels.count { it >= seuil }.toDouble() / img.pixels.size
}
