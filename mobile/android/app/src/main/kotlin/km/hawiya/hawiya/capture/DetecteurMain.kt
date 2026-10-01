package km.hawiya.hawiya.capture

import android.content.Context
import android.graphics.Bitmap
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarkerResult
import java.io.Closeable
import kotlin.math.hypot

/** Une main détectée sur une image. Coordonnées normalisées (0..1), image droite (portrait). */
data class MainDetectee(
    /** « droite » ou « gauche », du point de vue de la personne filmée. */
    val cote: String,
    val confiance: Float,
    /** 21 points : x0, y0, x1, y1, … (numérotation MediaPipe). */
    val points: FloatArray,
    /** Estimation géométrique : la paume (et non le dos) est-elle tournée vers la caméra ? */
    val paumeVersCamera: Boolean,
    /** Diagnostic : étiquette MediaPipe brute (« Left »/« Right »). */
    val etiquetteBrute: String,
    /** Diagnostic : produit vectoriel poignet→index × poignet→auriculaire (en pixels). */
    val produit: Float,
    /** Taille de la main en pixels (poignet → base du majeur), pour choisir la plus grande. */
    val taillePx: Float,
) {
    fun versMap(): Map<String, Any> = mapOf(
        "cote" to cote,
        "confiance" to confiance.toDouble(),
        "points" to points.map { it.toDouble() },
        "paume" to paumeVersCamera,
        "etiquetteBrute" to etiquetteBrute,
        "produit" to produit.toDouble(),
    )
}

/**
 * Détection de la main avec MediaPipe Hand Landmarker (21 points de repère).
 *
 * [video] = vrai pour le flux d'analyse en direct, faux pour les photos pleine
 * résolution (mode « image »). À créer et utiliser sur UN SEUL fil d'exécution
 * (exigence du délégué GPU).
 */
class DetecteurMain(context: Context, private val video: Boolean = true) : Closeable {

    companion object {
        /** Fichier dans android/app/src/main/assets (voir mobile/README.md). */
        const val MODELE = "hand_landmarker.task"

        const val POIGNET = 0
        const val BASE_INDEX = 5
        const val BASE_MAJEUR = 9
        const val BASE_AURICULAIRE = 17
    }

    /** « GPU » ou « CPU » selon ce que le téléphone accepte. */
    val delegue: String
    private val reperes: HandLandmarker

    init {
        var choisi = "GPU"
        reperes = try {
            creer(context, Delegate.GPU)
        } catch (e: RuntimeException) {
            // Délégué GPU refusé par le téléphone : repli sur le processeur.
            choisi = "CPU"
            creer(context, Delegate.CPU)
        }
        delegue = choisi
    }

    private fun creer(context: Context, delegate: Delegate): HandLandmarker =
        HandLandmarker.createFromOptions(
            context,
            HandLandmarker.HandLandmarkerOptions.builder()
                .setBaseOptions(
                    BaseOptions.builder().setModelAssetPath(MODELE).setDelegate(delegate).build(),
                )
                .setRunningMode(if (video) RunningMode.VIDEO else RunningMode.IMAGE)
                .setNumHands(2)
                .setMinHandDetectionConfidence(0.5f)
                .setMinHandPresenceConfidence(0.5f)
                .setMinTrackingConfidence(0.5f)
                .build(),
        )

    /** Flux vidéo : [horodatageMs] doit augmenter strictement d'une image à l'autre. */
    fun detecter(image: Bitmap, horodatageMs: Long): List<MainDetectee> =
        convertir(reperes.detectForVideo(BitmapImageBuilder(image).build(), horodatageMs), image)

    /** Photo isolée (mode image). */
    fun detecterImage(image: Bitmap): List<MainDetectee> =
        convertir(reperes.detect(BitmapImageBuilder(image).build()), image)

    private fun convertir(resultat: HandLandmarkerResult, image: Bitmap): List<MainDetectee> =
        resultat.landmarks().indices.map { i ->
            val reperesMain = resultat.landmarks()[i]
            val categorie = resultat.handedness()[i].first()
            // Vérifié sur Galaxy S23 Ultra (01/10/2026) : avec les images de la caméra
            // arrière, l'étiquette MediaPipe correspond DIRECTEMENT à la main de la
            // personne (« Left » = main gauche). Aucune inversion à faire.
            val cote = if (categorie.categoryName() == "Left") "gauche" else "droite"
            val points = FloatArray(reperesMain.size * 2)
            reperesMain.forEachIndexed { j, p ->
                points[2 * j] = p.x()
                points[2 * j + 1] = p.y()
            }
            val produit = produitVectoriel(points, image.width, image.height)
            val paume = if (cote == "droite") produit < 0 else produit > 0
            val taille = hypot(
                (points[2 * BASE_MAJEUR] - points[2 * POIGNET]) * image.width,
                (points[2 * BASE_MAJEUR + 1] - points[2 * POIGNET + 1]) * image.height,
            )
            MainDetectee(cote, categorie.score(), points, paume, categorie.categoryName(), produit, taille)
        }

    /**
     * Sens de rotation poignet → base de l'index → base de l'auriculaire, en pixels.
     * Main droite, paume face à la caméra : produit négatif ; main gauche : positif.
     * Confirmé sur téléphone (paume gauche > 0, dos de la main gauche < 0).
     */
    private fun produitVectoriel(p: FloatArray, largeur: Int, hauteur: Int): Float {
        val ax = (p[2 * BASE_INDEX] - p[2 * POIGNET]) * largeur
        val ay = (p[2 * BASE_INDEX + 1] - p[2 * POIGNET + 1]) * hauteur
        val bx = (p[2 * BASE_AURICULAIRE] - p[2 * POIGNET]) * largeur
        val by = (p[2 * BASE_AURICULAIRE + 1] - p[2 * POIGNET + 1]) * hauteur
        return ax * by - ay * bx
    }

    override fun close() = reperes.close()
}
