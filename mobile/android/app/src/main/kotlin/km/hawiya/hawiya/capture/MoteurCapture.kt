package km.hawiya.hawiya.capture

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.hardware.camera2.CameraCharacteristics
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Size
import androidx.annotation.OptIn
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Pilote la caméra arrière avec CameraX et analyse les images avec MediaPipe.
 *
 * Trois flux en même temps, tous au format 4:3 (même champ de vision) :
 *  - Preview      : l'aperçu affiché à l'écran ;
 *  - ImageAnalysis: ~640×480, analysée 5 à 10 fois par seconde (détection de la main) ;
 *  - ImageCapture : pleine résolution, pour les découpes des doigts (étape 3b).
 */
class MoteurCapture(
    private val context: Context,
    private val proprietaire: LifecycleOwner,
    private val surEvenement: (Map<String, Any?>) -> Unit,
) {
    companion object {
        /** Nombre maximal d'images analysées par seconde (économise batterie et chauffe). */
        const val IPS_MAX = 10
        val RESOLUTION_ANALYSE = Size(640, 480)
    }

    private val executeurAnalyse: ExecutorService = Executors.newSingleThreadExecutor()
    private val principal = Handler(Looper.getMainLooper())

    private var camera: Camera? = null
    private var fournisseur: ProcessCameraProvider? = null

    // Utilisés uniquement sur le fil d'analyse
    private var detecteur: DetecteurMain? = null
    private var detecteurEnErreur = false
    private var dernierTraitementMs = 0L
    private var dernierHorodatage = 0L
    private var ipsLissees = 0.0

    /** Diagnostic de la caméra, renvoyé à Flutter (lu sur le fil principal). */
    val infos = java.util.concurrent.ConcurrentHashMap<String, Any>()

    fun demarrer(apercu: PreviewView, reponse: (String?) -> Unit) {
        val futur = ProcessCameraProvider.getInstance(context)
        futur.addListener({
            try {
                val f = futur.get()
                fournisseur = f
                lier(f, apercu)
                reponse(null)
            } catch (e: Exception) {
                reponse(e.message ?: e.toString())
            }
        }, ContextCompat.getMainExecutor(context))
    }

    @OptIn(ExperimentalCamera2Interop::class)
    private fun lier(f: ProcessCameraProvider, apercu: PreviewView) {
        val format43 = AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY

        val preview = Preview.Builder()
            .setResolutionSelector(ResolutionSelector.Builder().setAspectRatioStrategy(format43).build())
            .build()
            .also { it.surfaceProvider = apercu.surfaceProvider }

        val analyse = ImageAnalysis.Builder()
            .setResolutionSelector(
                ResolutionSelector.Builder()
                    .setAspectRatioStrategy(format43)
                    .setResolutionStrategy(
                        ResolutionStrategy(
                            RESOLUTION_ANALYSE,
                            ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                        ),
                    )
                    .build(),
            )
            // On ne garde que la dernière image : jamais de retard accumulé.
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
            .build()
            .also { it.setAnalyzer(executeurAnalyse, ::analyser) }

        val photo = ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
            .setResolutionSelector(
                ResolutionSelector.Builder()
                    .setAspectRatioStrategy(format43)
                    .setResolutionStrategy(ResolutionStrategy.HIGHEST_AVAILABLE_STRATEGY)
                    .build(),
            )
            .build()

        f.unbindAll()
        val arriere = CameraSelector.DEFAULT_BACK_CAMERA
        // Certains téléphones n'acceptent pas les trois flux ensemble : on le mesure ici.
        var captureLiee = true
        val cam = try {
            f.bindToLifecycle(proprietaire, arriere, preview, analyse, photo)
        } catch (e: IllegalArgumentException) {
            captureLiee = false
            f.unbindAll()
            f.bindToLifecycle(proprietaire, arriere, preview, analyse)
        }
        camera = cam
        cam.cameraControl.enableTorch(true)

        // --- Diagnostic du téléphone (pour comparer les modèles) ---
        infos.clear()
        infos["modele"] = "${Build.MANUFACTURER} ${Build.MODEL}"
        infos["android"] = Build.VERSION.RELEASE
        infos["flashDisponible"] = cam.cameraInfo.hasFlashUnit()
        infos["captureLiee"] = captureLiee
        analyse.resolutionInfo?.resolution?.let { infos["resolutionAnalyse"] = "${it.width}×${it.height}" }
        if (captureLiee) {
            photo.resolutionInfo?.resolution?.let { infos["resolutionCapture"] = "${it.width}×${it.height}" }
        }
        preview.resolutionInfo?.resolution?.let { infos["resolutionApercu"] = "${it.width}×${it.height}" }
        cam.cameraInfo.zoomState.value?.let {
            infos["zoomMin"] = it.minZoomRatio.toDouble()
            infos["zoomMax"] = it.maxZoomRatio.toDouble()
        }
        // Distance minimale de mise au point, donnée en dioptries (1/mètres).
        val camera2 = Camera2CameraInfo.from(cam.cameraInfo)
        camera2.getCameraCharacteristic(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE)?.let { d ->
            if (d > 0f) infos["miseAuPointMinCm"] = 100.0 / d
            else infos["miseAuPointMinCm"] = -1.0 // focale fixe
        }
        camera2.getCameraCharacteristic(CameraCharacteristics.LENS_INFO_FOCUS_DISTANCE_CALIBRATION)?.let {
            infos["calibrationMiseAuPoint"] = when (it) {
                CameraCharacteristics.LENS_INFO_FOCUS_DISTANCE_CALIBRATION_CALIBRATED -> "calibrée"
                CameraCharacteristics.LENS_INFO_FOCUS_DISTANCE_CALIBRATION_APPROXIMATE -> "approximative"
                else -> "non calibrée"
            }
        }
        detecteur?.let { infos["delegue"] = it.delegue }
    }

    // ------------------------------------------------------------------ analyse

    private fun analyser(image: ImageProxy) {
        image.use {
            val maintenant = SystemClock.uptimeMillis()
            if (maintenant - dernierTraitementMs < 1000L / IPS_MAX) return
            if (dernierTraitementMs > 0) {
                val ips = 1000.0 / (maintenant - dernierTraitementMs)
                ipsLissees = if (ipsLissees == 0.0) ips else 0.8 * ipsLissees + 0.2 * ips
            }
            dernierTraitementMs = maintenant

            val det = obtenirDetecteur() ?: return

            // Image remise droite (portrait) : les coordonnées MediaPipe sont alors
            // directement celles de l'aperçu affiché.
            val brute = image.toBitmap()
            val rotation = image.imageInfo.rotationDegrees
            val droite = if (rotation == 0) brute else Bitmap.createBitmap(
                brute, 0, 0, brute.width, brute.height,
                Matrix().apply { postRotate(rotation.toFloat()) }, true,
            )

            val horodatage = maxOf(maintenant, dernierHorodatage + 1)
            dernierHorodatage = horodatage
            val debut = SystemClock.uptimeMillis()
            val mains = try {
                det.detecter(droite, horodatage)
            } catch (e: Exception) {
                envoyer(mapOf("type" to "erreur", "message" to "Détection : ${e.message}"))
                return
            }
            val latence = SystemClock.uptimeMillis() - debut

            envoyer(
                mapOf(
                    "type" to "analyse",
                    "ips" to ipsLissees,
                    "latenceMs" to latence.toInt(),
                    "largeur" to droite.width,
                    "hauteur" to droite.height,
                    "thermique" to etatThermique(),
                    "zoom" to (camera?.cameraInfo?.zoomState?.value?.zoomRatio?.toDouble() ?: 1.0),
                    "mains" to mains.map { m -> m.versMap() },
                ),
            )
        }
    }

    /** Crée le détecteur sur le fil d'analyse (exigence MediaPipe/GPU). */
    private fun obtenirDetecteur(): DetecteurMain? {
        detecteur?.let { return it }
        if (detecteurEnErreur) return null
        return try {
            DetecteurMain(context).also {
                detecteur = it
                infos["delegue"] = it.delegue
            }
        } catch (e: Exception) {
            detecteurEnErreur = true
            envoyer(
                mapOf(
                    "type" to "erreur",
                    "message" to "Modèle MediaPipe introuvable ou invalide " +
                        "(${DetecteurMain.MODELE}) : ${e.message}",
                ),
            )
            null
        }
    }

    /** 0 = normal … 6 = arrêt imminent (PowerManager.THERMAL_STATUS_*). */
    private fun etatThermique(): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return -1
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.currentThermalStatus
    }

    private fun envoyer(evenement: Map<String, Any?>) = principal.post { surEvenement(evenement) }

    // ------------------------------------------------------------------ commandes

    fun flash(actif: Boolean) {
        camera?.cameraControl?.enableTorch(actif)
    }

    /** Zoom linéaire 0..1 (le facteur réel est renvoyé dans chaque analyse : « zoom »). */
    fun zoom(lineaire: Float) {
        camera?.cameraControl?.setLinearZoom(lineaire.coerceIn(0f, 1f))
    }

    /** Mise au point et exposition sur un point de l'aperçu (coordonnées 0..1). */
    fun mettreAuPoint(apercu: PreviewView, x: Float, y: Float) {
        val cam = camera ?: return
        if (apercu.width == 0 || apercu.height == 0) return
        val point = apercu.meteringPointFactory.createPoint(x * apercu.width, y * apercu.height)
        val action = FocusMeteringAction.Builder(
            point, FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE,
        ).setAutoCancelDuration(3, TimeUnit.SECONDS).build()
        cam.cameraControl.startFocusAndMetering(action)
    }

    fun arreter() {
        fournisseur?.unbindAll()
        camera = null
    }

    fun liberer() {
        arreter()
        executeurAnalyse.execute {
            detecteur?.close()
            detecteur = null
        }
        executeurAnalyse.shutdown()
    }
}
