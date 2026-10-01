package km.hawiya.hawiya.capture

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Paint
import android.os.Build
import android.os.SystemClock
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import km.hawiya.hawiya.qualite.ImageGris
import km.hawiya.hawiya.qualite.Mesures
import km.hawiya.hawiya.qualite.QualiteCretes
import km.hawiya.hawiya.qualite.Zone
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.ExecutorService
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sin

/** Ce que Flutter demande de capturer. */
data class ParametresCapture(
    /** « droite » ou « gauche ». */
    val main: String,
    /** Doigts MediaPipe : 0 = pouce, 1 = index … 4 = auriculaire. */
    val doigts: List<Int>,
    /** Mode débogage : garde aussi les photos complètes, les découpes et un JSON détaillé. */
    val debogage: Boolean,
    /** Identifiant de la session (nom du dossier). */
    val session: String,
    /** Netteté des crêtes minimale (QualiteCretes, 0..1) pour accepter un doigt. */
    val seuilNettete: Double,
)

/**
 * Rafales de photos pleine résolution, puis découpe redressée de chaque bout de doigt.
 *
 * Pour chaque photo : nouvelle détection de la main SUR LA PHOTO (elle a pu bouger
 * depuis l'image d'analyse), découpe de chaque doigt, mesure de la netteté des
 * crêtes. On garde la découpe la plus nette de chaque doigt, sur toutes les
 * rafales d'une même capture (voir MoteurCapture : rafale ciblée sur les doigts flous).
 *
 * Tout se passe sur [executeur] (un seul fil : exigence du détecteur MediaPipe).
 */
class CaptureRafale(
    private val context: Context,
    private val executeur: ExecutorService,
) {
    companion object {
        const val NB_PHOTOS = 3

        /** Largeur supposée d'un bout de doigt adulte, pour estimer la résolution (dpi). */
        const val LARGEUR_DOIGT_MM = 18f

        /** Marge autour de la zone, pour ne pas couper la pulpe du doigt. */
        const val AGRANDISSEMENT = 1.15f

        /**
         * Résolution minimale d'une découpe : en dessous, la main s'est éloignée
         * pendant la rafale (constaté sur S23 Ultra : rafale ciblée prise main à ~30 cm).
         */
        const val DPI_MIN_PHOTO = 350.0

        /** Côté le plus long de l'image donnée à MediaPipe (il réduit de toute façon). */
        const val COTE_DETECTION = 1280

        val NOMS_DOIGTS = listOf("pouce", "index", "majeur", "annulaire", "auriculaire")
    }

    internal class Decoupe(
        val doigt: Int,
        val image: Bitmap,
        /** Netteté des crêtes, 0..1 (QualiteCretes). */
        val score: Double,
        /** Ancienne mesure, gardée pour comparaison. */
        val laplacien: Double,
        val luminance: Double,
        val eblouissement: Double,
        val largeurDoigtPx: Float,
        val dpi: Double,
        val rafale: Int,
        val photo: Int,
    )

    /** Ce qui s'accumule pendant une capture (une ou plusieurs rafales). */
    inner class EtatCapture(val p: ParametresCapture) {
        internal val meilleures = HashMap<Int, Decoupe>()
        internal val journalPhotos = JSONArray()
        val debut = SystemClock.uptimeMillis()
        var rafales = 0
            internal set
        internal var photosTotal = 0
        internal var photosSansMain = 0

        /** Découpes écartées car la main était trop loin (elle a bougé pendant la rafale). */
        internal var decoupesTropLoin = 0
        internal var dureePhotosMs = 0L
        internal var resolution = ""

        /** Points (normalisés) de la main sur la dernière photo où elle a été trouvée. */
        var derniersPoints: FloatArray? = null
            internal set

        /** Doigts absents ou sous le seuil de netteté. */
        fun doigtsARefaire(): List<Int> =
            p.doigts.filter { (meilleures[it]?.score ?: -1.0) < p.seuilNettete }
    }

    private var detecteur: DetecteurMain? = null

    fun nouvelEtat(p: ParametresCapture) = EtatCapture(p)

    /**
     * Une rafale de [NB_PHOTOS] photos, traitées et ajoutées à [etat].
     * [fin] est appelée sur le fil [executeur] (avec l'erreur éventuelle).
     */
    fun rafale(
        photo: ImageCapture,
        etat: EtatCapture,
        pointMiseAuPoint: Pair<Float, Float>?,
        fin: (String?) -> Unit,
    ) {
        etat.rafales++
        val numeroRafale = etat.rafales
        val debut = SystemClock.uptimeMillis()
        val brutes = mutableListOf<Pair<ByteArray, Int>>()
        fun suivante() {
            photo.takePicture(executeur, object : ImageCapture.OnImageCapturedCallback() {
                override fun onCaptureSuccess(image: ImageProxy) {
                    try {
                        brutes += Pair(octetsJpeg(image), image.imageInfo.rotationDegrees)
                    } finally {
                        image.close()
                    }
                    if (brutes.size < NB_PHOTOS) {
                        suivante()
                        return
                    }
                    etat.dureePhotosMs += SystemClock.uptimeMillis() - debut
                    val erreur = try {
                        brutes.forEachIndexed { k, (octets, rotation) ->
                            traiterPhoto(etat, numeroRafale, k + 1, octets, rotation, pointMiseAuPoint)
                        }
                        null
                    } catch (e: OutOfMemoryError) {
                        "Mémoire insuffisante pour traiter les photos"
                    } catch (e: Throwable) {
                        "Traitement des photos : ${e.message}"
                    }
                    fin(erreur)
                }

                override fun onError(exception: ImageCaptureException) {
                    fin("Photo impossible : ${exception.message}")
                }
            })
        }
        suivante()
    }

    private fun traiterPhoto(
        etat: EtatCapture,
        numeroRafale: Int,
        numeroPhoto: Int,
        octets: ByteArray,
        rotation: Int,
        pointMiseAuPoint: Pair<Float, Float>?,
    ) {
        val p = etat.p
        val det = detecteur ?: DetecteurMain(context, video = false).also { detecteur = it }
        val dossier = dossierSortie(p)
        etat.photosTotal++
        if (p.debogage) {
            File(dossier, "${p.main}_${typeEtape(p)}_r${numeroRafale}_photo$numeroPhoto.jpg").writeBytes(octets)
        }
        val image = decoder(octets, rotation)
        etat.resolution = "${image.width}×${image.height}"
        val journal = JSONObject().apply {
            put("rafale", numeroRafale)
            put("photo", numeroPhoto)
            pointMiseAuPoint?.let { put("miseAuPoint", JSONArray(listOf(it.first.toDouble(), it.second.toDouble()))) }
        }

        val main = choisirMain(det, image, p.main)
        if (main == null) {
            etat.photosSansMain++
            journal.put("main", JSONObject.NULL)
            etat.journalPhotos.put(journal)
            image.recycle()
            return
        }
        etat.derniersPoints = main.points
        journal.put("cote", main.cote)
        journal.put("points", JSONArray(main.points.map { it.toDouble() }))
        val mesuresDoigts = JSONArray()

        for (doigt in p.doigts) {
            val zone = Zone.pourDoigt(main.points, doigt, image.width, image.height, AGRANDISSEMENT)
            if (!zone.dansImage(image.width, image.height)) {
                mesuresDoigts.put(JSONObject().put("doigt", doigt).put("dansCadre", false))
                continue
            }
            val largeurDoigt = zone.largeur / AGRANDISSEMENT
            val dpi = (largeurDoigt / (LARGEUR_DOIGT_MM / 25.4f)).toDouble()
            if (dpi < DPI_MIN_PHOTO) {
                etat.decoupesTropLoin++
                mesuresDoigts.put(JSONObject().put("doigt", doigt).put("dansCadre", true).put("dpi", dpi).put("tropLoin", true))
                continue
            }
            val decoupe = decouper(image, zone)
            val centre = Mesures.centre(versGris(decoupe))
            val cretes = QualiteCretes.evaluer(centre, dpi)
            val candidate = Decoupe(
                doigt = doigt,
                image = decoupe,
                score = cretes.score,
                laplacien = Mesures.varianceLaplacien(Mesures.flou3x3(centre)),
                luminance = Mesures.luminanceMoyenne(centre),
                eblouissement = Mesures.fractionEblouie(centre),
                largeurDoigtPx = largeurDoigt,
                dpi = dpi,
                rafale = numeroRafale,
                photo = numeroPhoto,
            )
            mesuresDoigts.put(
                JSONObject()
                    .put("doigt", doigt)
                    .put("dansCadre", true)
                    .put("nettete", candidate.score)
                    .put("partBlocsNets", cretes.partBlocsNets)
                    .put("laplacien", candidate.laplacien)
                    .put("luminance", candidate.luminance)
                    .put("eblouissement", candidate.eblouissement)
                    .put("dpi", dpi),
            )
            val actuelle = etat.meilleures[doigt]
            if (actuelle == null || candidate.score > actuelle.score) {
                actuelle?.image?.recycle()
                etat.meilleures[doigt] = candidate
            } else {
                decoupe.recycle()
            }
        }
        journal.put("doigts", mesuresDoigts)
        etat.journalPhotos.put(journal)
        image.recycle()
    }

    /** Enregistre les meilleures découpes et construit la réponse pour Flutter. */
    fun finaliser(etat: EtatCapture): Map<String, Any?> {
        val p = etat.p
        val dossier = dossierSortie(p)
        val resultats = etat.meilleures.values.sortedBy { it.doigt }.map { d ->
            val fichier = File(dossier, "${p.main}_${NOMS_DOIGTS[d.doigt]}_iso${iso(p.main, d.doigt)}.png")
            fichier.outputStream().use { d.image.compress(Bitmap.CompressFormat.PNG, 100, it) }
            val resultat = mapOf(
                "doigt" to d.doigt,
                "iso" to iso(p.main, d.doigt),
                "nom" to NOMS_DOIGTS[d.doigt],
                "chemin" to fichier.absolutePath,
                "largeur" to d.image.width,
                "hauteur" to d.image.height,
                "nettete" to d.score,
                "netteteLaplacien" to d.laplacien,
                "acceptee" to (d.score >= p.seuilNettete),
                "luminance" to d.luminance,
                "eblouissement" to d.eblouissement,
                "largeurDoigtPx" to d.largeurDoigtPx.toDouble(),
                "dpiEstime" to d.dpi,
                "rafale" to d.rafale,
                "photo" to d.photo,
            )
            d.image.recycle()
            resultat
        }
        etat.meilleures.clear()

        val absents = p.doigts.filter { d -> resultats.none { it["doigt"] == d } }
        val flous = resultats.filter { it["acceptee"] == false }.map { it["doigt"] as Int }
        val reponse = mapOf(
            "succes" to (absents.isEmpty() && flous.isEmpty()),
            "raison" to when {
                etat.photosSansMain == etat.photosTotal ->
                    "Main non retrouvée sur les photos : recommencez sans bouger."
                absents.isNotEmpty() && etat.decoupesTropLoin > 0 ->
                    "La main s'est éloignée pendant la capture : recommencez sans bouger."
                absents.isNotEmpty() ->
                    "Doigt(s) hors du cadre sur les photos : ${absents.joinToString { NOMS_DOIGTS[it] }}."
                flous.isNotEmpty() ->
                    "Doigt(s) flou(s) : ${flous.joinToString { NOMS_DOIGTS[it] }}. " +
                        "Recommencez en tenant la main bien à plat, face au téléphone."
                else -> null
            },
            "resultats" to resultats,
            "doigtsFlous" to flous,
            "seuilNettete" to p.seuilNettete,
            "rafales" to etat.rafales,
            "resolution" to etat.resolution,
            "photosSansMain" to etat.photosSansMain,
            "decoupesTropLoin" to etat.decoupesTropLoin,
            "dureePhotosMs" to etat.dureePhotosMs.toInt(),
            "dureeTotaleMs" to (SystemClock.uptimeMillis() - etat.debut).toInt(),
            "dossier" to dossier.absolutePath,
        )
        if (p.debogage) ecrireJson(dossier, etat, reponse)
        return reponse
    }

    /** Main attendue de préférence ; sinon la plus grande. */
    private fun choisirMain(det: DetecteurMain, image: Bitmap, cote: String): MainDetectee? {
        val echelle = COTE_DETECTION.toFloat() / max(image.width, image.height)
        val reduite = if (echelle < 1f) {
            Bitmap.createScaledBitmap(
                image, (image.width * echelle).roundToInt(), (image.height * echelle).roundToInt(), true,
            )
        } else image
        // Les points sont normalisés : valables aussi pour l'image pleine résolution.
        val mains = det.detecterImage(reduite)
        if (reduite !== image) reduite.recycle()
        return mains.filter { it.cote == cote }.maxByOrNull { it.taillePx }
            ?: mains.maxByOrNull { it.taillePx }
    }

    /**
     * Découpe couleur redressée (bout du doigt en haut), à l'échelle 1:1 :
     * aucune perte de résolution. Même transformation que Mesures.redresser().
     */
    private fun decouper(src: Bitmap, z: Zone): Bitmap {
        val w = z.largeur.roundToInt().coerceAtLeast(8)
        val h = z.longueur.roundToInt().coerceAtLeast(8)
        val ax = cos(z.angle)
        val ay = sin(z.angle)
        val tx = -ay
        val ty = ax
        // Sortie (u, v) → source : centre + t·(u − w/2) − a·(v − h/2)
        val versSource = Matrix().apply {
            setValues(
                floatArrayOf(
                    tx, -ax, z.cx - tx * w / 2f + ax * h / 2f,
                    ty, -ay, z.cy - ty * w / 2f + ay * h / 2f,
                    0f, 0f, 1f,
                ),
            )
        }
        val versSortie = Matrix()
        versSource.invert(versSortie)
        val sortie = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        Canvas(sortie).drawBitmap(src, versSortie, Paint(Paint.FILTER_BITMAP_FLAG))
        return sortie
    }

    private fun decoder(octets: ByteArray, rotation: Int): Bitmap {
        val image = BitmapFactory.decodeByteArray(octets, 0, octets.size)
        if (rotation == 0) return image
        val droite = Bitmap.createBitmap(
            image, 0, 0, image.width, image.height,
            Matrix().apply { postRotate(rotation.toFloat()) }, true,
        )
        image.recycle()
        return droite
    }

    private fun octetsJpeg(image: ImageProxy): ByteArray {
        if (image.format == ImageFormat.JPEG) {
            val tampon = image.planes[0].buffer
            return ByteArray(tampon.remaining()).also { tampon.get(it) }
        }
        // Repli (format inattendu) : conversion en JPEG haute qualité.
        val bmp = image.toBitmap()
        return ByteArrayOutputStream().use {
            bmp.compress(Bitmap.CompressFormat.JPEG, 97, it)
            bmp.recycle()
            it.toByteArray()
        }
    }

    private fun versGris(bmp: Bitmap): ImageGris {
        val argb = IntArray(bmp.width * bmp.height)
        bmp.getPixels(argb, 0, bmp.width, 0, 0, bmp.width, bmp.height)
        return ImageGris.depuisArgb(bmp.width, bmp.height, argb)
    }

    /**
     * Mode débogage : dossier visible par `adb pull` (Android/data/…/files/captures).
     * Sinon : cache privé, vidé par supprimerTemporaires().
     */
    private fun dossierSortie(p: ParametresCapture): File {
        val racine = if (p.debogage) {
            File(context.getExternalFilesDir(null), "captures")
        } else {
            File(context.cacheDir, "decoupes")
        }
        return File(racine, p.session).apply { mkdirs() }
    }

    fun supprimerTemporaires() {
        File(context.cacheDir, "decoupes").deleteRecursively()
    }

    private fun ecrireJson(dossier: File, etat: EtatCapture, reponse: Map<String, Any?>) {
        val p = etat.p
        val json = JSONObject().apply {
            put("telephone", "${Build.MANUFACTURER} ${Build.MODEL}")
            put("android", Build.VERSION.RELEASE)
            put("main", p.main)
            put("doigts", JSONArray(p.doigts))
            put("horodatage", System.currentTimeMillis())
            reponse.forEach { (cle, valeur) ->
                put(
                    cle,
                    when {
                        valeur is List<*> && valeur.firstOrNull() is Map<*, *> ->
                            JSONArray(valeur.map { JSONObject(it as Map<*, *>) })
                        valeur is List<*> -> JSONArray(valeur)
                        else -> valeur
                    },
                )
            }
            // Détail de chaque photo (points de la main, mesures de tous les doigts)
            // pour réanalyser les captures sur PC (phase 4).
            put("photos", etat.journalPhotos)
        }
        File(dossier, "${p.main}_${typeEtape(p)}.json").writeText(json.toString(2))
    }

    private fun typeEtape(p: ParametresCapture) = if (p.doigts == listOf(0)) "pouce" else "4doigts"

    /** Numérotation ISO/IEC 19794 : 1 = pouce droit … 5 = auriculaire droit, 6 = pouce gauche … 10. */
    private fun iso(main: String, doigt: Int) = (if (main == "droite") 1 else 6) + doigt

    fun liberer() {
        detecteur?.close()
        detecteur = null
    }
}
