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
    /** Mode débogage : garde aussi les photos complètes et les découpes dans captures/. */
    val debogage: Boolean,
    /** Identifiant de la session (nom du dossier). */
    val session: String,
)

/**
 * Rafale de photos pleine résolution, puis découpe redressée de chaque bout de doigt.
 *
 * Pour chaque photo : nouvelle détection de la main SUR LA PHOTO (elle a pu bouger
 * depuis l'image d'analyse), découpe de chaque doigt, mesure de la netteté des
 * crêtes. On garde la découpe la plus nette de chaque doigt.
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

        /** Côté le plus long de l'image donnée à MediaPipe (il réduit de toute façon). */
        const val COTE_DETECTION = 1280

        val NOMS_DOIGTS = listOf("pouce", "index", "majeur", "annulaire", "auriculaire")
    }

    private class PhotoBrute(val octets: ByteArray, val rotation: Int)

    private class Decoupe(
        val doigt: Int,
        val image: Bitmap,
        val nettete: Double,
        val luminance: Double,
        val eblouissement: Double,
        val largeurDoigtPx: Float,
        val photo: Int,
    )

    private var detecteur: DetecteurMain? = null

    /** Lance la rafale ; [reponse] est appelée sur le fil [executeur]. */
    fun capturer(photo: ImageCapture, p: ParametresCapture, reponse: (Map<String, Any?>) -> Unit) {
        val debut = SystemClock.uptimeMillis()
        val photos = mutableListOf<PhotoBrute>()
        // Les photos s'enchaînent le plus vite possible ; le traitement vient après.
        fun suivante() {
            photo.takePicture(executeur, object : ImageCapture.OnImageCapturedCallback() {
                override fun onCaptureSuccess(image: ImageProxy) {
                    try {
                        photos += PhotoBrute(octetsJpeg(image), image.imageInfo.rotationDegrees)
                    } finally {
                        image.close()
                    }
                    if (photos.size < NB_PHOTOS) {
                        suivante()
                    } else {
                        val dureePhotos = SystemClock.uptimeMillis() - debut
                        reponse(traiterEnSecurite(photos, p, debut, dureePhotos))
                    }
                }

                override fun onError(exception: ImageCaptureException) {
                    reponse(echec("Photo impossible : ${exception.message}"))
                }
            })
        }
        suivante()
    }

    private fun traiterEnSecurite(
        photos: List<PhotoBrute>, p: ParametresCapture, debut: Long, dureePhotos: Long,
    ): Map<String, Any?> = try {
        traiter(photos, p, debut, dureePhotos)
    } catch (e: OutOfMemoryError) {
        echec("Mémoire insuffisante pour traiter les photos")
    } catch (e: Throwable) {
        echec("Traitement des photos : ${e.message}")
    }

    private fun traiter(
        photos: List<PhotoBrute>, p: ParametresCapture, debut: Long, dureePhotos: Long,
    ): Map<String, Any?> {
        val det = detecteur ?: DetecteurMain(context, video = false).also { detecteur = it }
        val dossier = dossierSortie(p)
        val meilleures = HashMap<Int, Decoupe>()
        var resolution = ""
        var photosSansMain = 0

        for ((k, brute) in photos.withIndex()) {
            if (p.debogage) File(dossier, "${p.main}_${typeEtape(p)}_photo${k + 1}.jpg").writeBytes(brute.octets)
            val image = decoder(brute)
            resolution = "${image.width}×${image.height}"

            val main = choisirMain(det, image, p.main)
            if (main == null) {
                photosSansMain++
                image.recycle()
                continue
            }
            for (doigt in p.doigts) {
                val zone = Zone.pourDoigt(main.points, doigt, image.width, image.height, AGRANDISSEMENT)
                if (!zone.dansImage(image.width, image.height)) continue
                val decoupe = decouper(image, zone)
                val centre = Mesures.centre(versGris(decoupe))
                val candidate = Decoupe(
                    doigt = doigt,
                    image = decoupe,
                    nettete = Mesures.varianceLaplacien(Mesures.flou3x3(centre)),
                    luminance = Mesures.luminanceMoyenne(centre),
                    eblouissement = Mesures.fractionEblouie(centre),
                    largeurDoigtPx = zone.largeur / AGRANDISSEMENT,
                    photo = k + 1,
                )
                val actuelle = meilleures[doigt]
                if (actuelle == null || candidate.nettete > actuelle.nettete) {
                    actuelle?.image?.recycle()
                    meilleures[doigt] = candidate
                } else {
                    decoupe.recycle()
                }
            }
            image.recycle()
        }

        // Enregistrement des meilleures découpes (PNG, sans perte).
        val resultats = meilleures.values.sortedBy { it.doigt }.map { d ->
            val fichier = File(dossier, "${p.main}_${NOMS_DOIGTS[d.doigt]}_iso${iso(p.main, d.doigt)}.png")
            fichier.outputStream().use { d.image.compress(Bitmap.CompressFormat.PNG, 100, it) }
            val resultat = mapOf(
                "doigt" to d.doigt,
                "iso" to iso(p.main, d.doigt),
                "nom" to NOMS_DOIGTS[d.doigt],
                "chemin" to fichier.absolutePath,
                "largeur" to d.image.width,
                "hauteur" to d.image.height,
                "nettete" to d.nettete,
                "luminance" to d.luminance,
                "eblouissement" to d.eblouissement,
                "largeurDoigtPx" to d.largeurDoigtPx.toDouble(),
                "dpiEstime" to (d.largeurDoigtPx / (LARGEUR_DOIGT_MM / 25.4f)).toDouble(),
                "photo" to d.photo,
            )
            d.image.recycle()
            resultat
        }

        val manquants = p.doigts.filter { it !in meilleures }
        val reponse = mapOf(
            "succes" to manquants.isEmpty(),
            "raison" to when {
                photosSansMain == photos.size -> "Main non retrouvée sur les photos : recommencez sans bouger."
                manquants.isNotEmpty() -> "Doigt(s) hors du cadre sur les photos : " +
                    manquants.joinToString { NOMS_DOIGTS[it] } + "."
                else -> null
            },
            "resultats" to resultats,
            "resolution" to resolution,
            "photosSansMain" to photosSansMain,
            "dureePhotosMs" to dureePhotos.toInt(),
            "dureeTotaleMs" to (SystemClock.uptimeMillis() - debut).toInt(),
            "dossier" to dossier.absolutePath,
        )
        if (p.debogage) ecrireJson(dossier, p, reponse)
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

    private fun decoder(brute: PhotoBrute): Bitmap {
        val image = BitmapFactory.decodeByteArray(brute.octets, 0, brute.octets.size)
        if (brute.rotation == 0) return image
        val droite = Bitmap.createBitmap(
            image, 0, 0, image.width, image.height,
            Matrix().apply { postRotate(brute.rotation.toFloat()) }, true,
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

    private fun ecrireJson(dossier: File, p: ParametresCapture, reponse: Map<String, Any?>) {
        val json = JSONObject().apply {
            put("telephone", "${Build.MANUFACTURER} ${Build.MODEL}")
            put("android", Build.VERSION.RELEASE)
            put("main", p.main)
            put("doigts", JSONArray(p.doigts))
            put("horodatage", System.currentTimeMillis())
            reponse.forEach { (cle, valeur) ->
                put(cle, if (valeur is List<*>) JSONArray(valeur.map { JSONObject(it as Map<*, *>) }) else valeur)
            }
        }
        File(dossier, "${p.main}_${typeEtape(p)}.json").writeText(json.toString(2))
    }

    private fun typeEtape(p: ParametresCapture) = if (p.doigts == listOf(0)) "pouce" else "4doigts"

    /** Numérotation ISO/IEC 19794 : 1 = pouce droit … 5 = auriculaire droit, 6 = pouce gauche … 10. */
    private fun iso(main: String, doigt: Int) = (if (main == "droite") 1 else 6) + doigt

    private fun echec(raison: String) = mapOf("succes" to false, "raison" to raison, "resultats" to emptyList<Any>())

    fun liberer() {
        detecteur?.close()
        detecteur = null
    }
}
