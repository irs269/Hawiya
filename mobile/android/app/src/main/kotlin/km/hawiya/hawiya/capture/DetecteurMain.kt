package km.hawiya.hawiya.capture

import android.content.Context
import android.graphics.Bitmap
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import java.io.Closeable

/** Une main détectée sur une image. Coordonnées normalisées (0..1), image droite (portrait). */
data class MainDetectee(
    /** « droite » ou « gauche », du point de vue de la personne filmée. */
    val cote: String,
    val confiance: Float,
    /** 21 points : x0, y0, x1, y1, … (numérotation MediaPipe). */
    val points: FloatArray,
    /** Estimation géométrique : la paume (et non le dos) est-elle tournée vers la caméra ? */
    val paumeVersCamera: Boolean,
) {
    fun versMap(): Map<String, Any> = mapOf(
        "cote" to cote,
        "confiance" to confiance.toDouble(),
        "points" to points.map { it.toDouble() },
        "paume" to paumeVersCamera,
    )
}

/**
 * Détection de la main avec MediaPipe Hand Landmarker (21 points de repère).
 *
 * À créer et utiliser sur un SEUL et même fil d'exécution (exigence du délégué GPU).
 */
class DetecteurMain(context: Context) : Closeable {

    companion object {
        /** Fichier dans android/app/src/main/assets (voir mobile/README.md). */
        const val MODELE = "hand_landmarker.task"

        // Indices MediaPipe utiles
        const val POIGNET = 0
        const val BASE_INDEX = 5
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
                .setRunningMode(RunningMode.VIDEO)
                .setNumHands(2) // 2 pour la capture des pouces (étape 3b)
                .setMinHandDetectionConfidence(0.5f)
                .setMinHandPresenceConfidence(0.5f)
                .setMinTrackingConfidence(0.5f)
                .build(),
        )

    /** [horodatageMs] doit augmenter strictement d'une image à l'autre (mode VIDEO). */
    fun detecter(image: Bitmap, horodatageMs: Long): List<MainDetectee> {
        val resultat = reperes.detectForVideo(BitmapImageBuilder(image).build(), horodatageMs)
        return resultat.landmarks().indices.map { i ->
            val reperesMain = resultat.landmarks()[i]
            val categorie = resultat.handedness()[i].first()
            // MediaPipe suppose une image miroir (caméra frontale) : avec la caméra
            // arrière, son « Left » correspond à la main DROITE de la personne.
            val cote = if (categorie.categoryName() == "Left") "droite" else "gauche"
            val points = FloatArray(reperesMain.size * 2)
            reperesMain.forEachIndexed { j, p ->
                points[2 * j] = p.x()
                points[2 * j + 1] = p.y()
            }
            MainDetectee(cote, categorie.score(), points, estPaume(points, cote))
        }
    }

    /**
     * Sens de rotation poignet → base de l'index → base de l'auriculaire.
     * Main droite, paume face à la caméra (doigts vers le haut) : l'index est à
     * droite de l'auriculaire sur l'image, le produit vectoriel est négatif.
     * C'est l'inverse pour la main gauche. Indépendant de l'inclinaison de la main.
     * ⚠️ Dépend du côté donné par MediaPipe : à confirmer sur téléphone (étape 3a).
     */
    private fun estPaume(p: FloatArray, cote: String): Boolean {
        val ax = p[2 * BASE_INDEX] - p[2 * POIGNET]
        val ay = p[2 * BASE_INDEX + 1] - p[2 * POIGNET + 1]
        val bx = p[2 * BASE_AURICULAIRE] - p[2 * POIGNET]
        val by = p[2 * BASE_AURICULAIRE + 1] - p[2 * POIGNET + 1]
        val produit = ax * by - ay * bx
        return if (cote == "droite") produit < 0 else produit > 0
    }

    override fun close() = reperes.close()
}
