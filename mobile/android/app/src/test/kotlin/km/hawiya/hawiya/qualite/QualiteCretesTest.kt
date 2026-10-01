package km.hawiya.hawiya.qualite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

/** Tests sur des crêtes SYNTHÉTIQUES (aucune vraie empreinte dans le dépôt). */
class QualiteCretesTest {

    private val dpi = 550.0
    private val periode = QualiteCretes.periodePx(dpi) // ≈ 9,7 px

    /** Crêtes sinusoïdales d'orientation [angle], d'amplitude [amplitude] autour de [fond]. */
    private fun cretes(
        angle: Double = 0.3,
        amplitude: Double = 40.0,
        fond: Double = 130.0,
        taille: Int = 240,
        bruit: Double = 0.0,
    ): ImageGris {
        val hasard = Random(42)
        val px = IntArray(taille * taille) { i ->
            val x = i % taille
            val y = i / taille
            val t = (x * cos(angle) + y * sin(angle)) * 2 * PI / periode
            (fond + amplitude * sin(t) + bruit * hasard.nextGaussian()).roundToInt().coerceIn(0, 255)
        }
        return ImageGris(taille, taille, px)
    }

    private fun flouter(img: ImageGris, sigma: Double): ImageGris {
        val f = QualiteCretes.flouGaussien(
            FloatArray(img.pixels.size) { img.pixels[it].toFloat() }, img.largeur, img.hauteur, sigma,
        )
        return ImageGris(img.largeur, img.hauteur, IntArray(f.size) { f[it].roundToInt() })
    }

    private fun score(img: ImageGris) = QualiteCretes.evaluer(img, dpi).score

    @Test
    fun `période attendue d'environ 10 px à 550 dpi`() {
        assertEquals(9.74, periode, 0.01)
    }

    @Test
    fun `crêtes nettes donnent un score élevé`() {
        assertTrue("score = ${score(cretes())}", score(cretes()) > 0.4)
    }

    @Test
    fun `image uniforme donne un score nul`() {
        assertEquals(0.0, score(ImageGris(200, 200, IntArray(40_000) { 128 })), 1e-9)
    }

    @Test
    fun `crêtes floues donnent un score faible`() {
        val nettes = score(cretes())
        val floues = score(flouter(cretes(), periode / 2.5))
        assertTrue("nettes=$nettes floues=$floues", floues < 0.25 * nettes)
    }

    @Test
    fun `bruit seul donne un score faible`() {
        val bruit = cretes(amplitude = 0.0, bruit = 30.0)
        assertTrue("bruit = ${score(bruit)}", score(bruit) < 0.1)
    }

    @Test
    fun `indépendant de l'orientation`() {
        val a = score(cretes(angle = 0.0))
        val b = score(cretes(angle = 1.1))
        assertEquals(a, b, 0.1)
    }

    @Test
    fun `indépendant du contraste et de la luminosité`() {
        val fort = score(cretes(amplitude = 60.0, fond = 120.0))
        val faible = score(cretes(amplitude = 10.0, fond = 180.0))
        assertEquals(fort, faible, 0.1)
    }

    @Test
    fun `crêtes légèrement bruitées restent bien notées`() {
        val propre = score(cretes())
        val bruitee = score(cretes(bruit = 8.0))
        assertTrue("propre=$propre bruitée=$bruitee", bruitee > 0.6 * propre)
    }

    @Test
    fun `mauvaise résolution supposée dégrade le score`() {
        // Crêtes d'environ 10 px, mais on annonce une résolution 3 fois plus faible.
        val juste = QualiteCretes.evaluer(cretes(), dpi).score
        val faux = QualiteCretes.evaluer(cretes(), dpi / 3).score
        assertTrue("juste=$juste faux=$faux", faux < juste)
    }
}
