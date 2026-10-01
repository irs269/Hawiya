package km.hawiya.hawiya.qualite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI

class MesuresTest {

    /** Image dont chaque pixel vaut sa colonne x (ou sa ligne y). */
    private fun degrade(largeur: Int, hauteur: Int, selonX: Boolean = true) =
        ImageGris(largeur, hauteur, IntArray(largeur * hauteur) { i -> if (selonX) i % largeur else i / largeur })

    @Test
    fun `zone identique a la version Dart`() {
        // Même cas que test/capture_test.dart : articulation (100,200), bout (100,160).
        val z = Zone.empreinte(100f, 160f, 100f, 200f)
        assertEquals(54f, z.longueur, 1e-4f)
        assertEquals(40f, z.largeur, 1e-4f)
        assertEquals(100f, z.cx, 1e-4f)
        assertEquals(173f, z.cy, 1e-4f)
        assertEquals((-PI / 2).toFloat(), z.angle, 1e-6f)
    }

    @Test
    fun `zone dans ou hors de l image`() {
        val z = Zone.empreinte(100f, 160f, 100f, 200f)
        assertTrue(z.dansImage(300, 300))
        assertFalse(z.dansImage(110, 300)) // déborde à droite
    }

    @Test
    fun `redresser un doigt vertical recopie la zone sans la retourner`() {
        val src = degrade(64, 64)
        // Doigt vertical vers le haut, zone 10 (large) × 20 (long) centrée en (20, 30).
        val zone = Zone(cx = 20f, cy = 30f, longueur = 20f, largeur = 10f, angle = (-PI / 2).toFloat())
        val sortie = Mesures.redresser(src, zone, 10, 20)
        for (u in 0 until 10) assertEquals(15 + u, sortie[u, 0])
        // Ligne y : on vérifie avec un dégradé vertical que le haut de la sortie = haut de l'image.
        val srcY = degrade(64, 64, selonX = false)
        val sortieY = Mesures.redresser(srcY, zone, 10, 20)
        assertEquals(20, sortieY[0, 0])
        assertEquals(39, sortieY[0, 19])
    }

    @Test
    fun `redresser un doigt pointant vers la droite met le bout en haut`() {
        val src = degrade(64, 64)
        val zone = Zone(cx = 32f, cy = 32f, longueur = 20f, largeur = 10f, angle = 0f)
        val sortie = Mesures.redresser(src, zone, 10, 20)
        // Bout du doigt (x grand) en haut de la sortie.
        assertTrue(sortie[5, 0] > sortie[5, 19])
        assertEquals(41, sortie[5, 0])
        assertEquals(22, sortie[5, 19])
    }

    @Test
    fun `netteté nulle sur une image uniforme, forte sur un damier`() {
        val uni = ImageGris(20, 20, IntArray(400) { 128 })
        assertEquals(0.0, Mesures.varianceLaplacien(uni), 1e-9)
        val damier = ImageGris(20, 20, IntArray(400) { i -> if ((i % 20 + i / 20) % 2 == 0) 0 else 255 })
        assertTrue(Mesures.varianceLaplacien(damier) > 100_000)
    }

    @Test
    fun `le flou réduit la netteté`() {
        // Rayures fines verticales (2 px) : comme des crêtes.
        val rayures = ImageGris(40, 40, IntArray(1600) { i -> if ((i % 40) / 2 % 2 == 0) 40 else 200 })
        val nette = Mesures.varianceLaplacien(rayures)
        val floue = Mesures.varianceLaplacien(Mesures.flou3x3(rayures))
        assertTrue(floue < nette)
    }

    @Test
    fun `luminance et éblouissement`() {
        val img = ImageGris(10, 1, intArrayOf(0, 0, 100, 100, 100, 100, 255, 255, 252, 50))
        assertEquals(121.2, Mesures.luminanceMoyenne(img), 1e-9)
        assertEquals(0.3, Mesures.fractionEblouie(img), 1e-9)
    }

    @Test
    fun `centre garde la partie médiane`() {
        val img = degrade(100, 100)
        val c = Mesures.centre(img)
        assertEquals(60, c.largeur)
        assertEquals(60, c.hauteur)
        assertEquals(20, c[0, 0])
    }

    @Test
    fun `conversion ARGB vers gris`() {
        val blanc = 0xFFFFFFFF.toInt()
        val rouge = 0xFFFF0000.toInt()
        val img = ImageGris.depuisArgb(2, 1, intArrayOf(blanc, rouge))
        assertEquals(255, img[0, 0])
        assertEquals(76, img[1, 0])
    }
}
