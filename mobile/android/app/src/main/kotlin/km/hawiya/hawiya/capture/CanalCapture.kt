package km.hawiya.hawiya.capture

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.view.View
import androidx.camera.view.PreviewView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Pont entre Flutter et la capture native.
 *
 * - Vue native « hawiya/apercu » : l'aperçu caméra (PreviewView), affiché par Flutter.
 * - Canal « hawiya/capture » : commandes (permission, démarrer, flash, zoom…).
 * - Flux « hawiya/capture/flux » : résultats d'analyse envoyés à chaque image traitée.
 */
class CanalCapture(
    private val activite: FragmentActivity,
    messager: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val VUE_APERCU = "hawiya/apercu"
        private const val CODE_PERMISSION_CAMERA = 4210
    }

    private var puits: EventChannel.EventSink? = null
    private var apercu: PreviewView? = null
    private var resultatPermission: MethodChannel.Result? = null
    private val moteur = MoteurCapture(activite, activite) { evenement -> puits?.success(evenement) }

    val fabriqueApercu = object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
            val vue = PreviewView(context).apply {
                // TextureView : obligatoire pour être composée correctement par Flutter.
                implementationMode = PreviewView.ImplementationMode.COMPATIBLE
                // Image entière, sans recadrage : les coordonnées de l'analyse
                // correspondent directement à celles de l'aperçu (même format 3:4).
                scaleType = PreviewView.ScaleType.FIT_CENTER
            }
            apercu = vue
            return object : PlatformView {
                override fun getView(): View = vue
                override fun dispose() {
                    if (apercu === vue) apercu = null
                }
            }
        }
    }

    init {
        MethodChannel(messager, "hawiya/capture").setMethodCallHandler(this)
        EventChannel(messager, "hawiya/capture/flux").setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "permission" -> demanderPermission(result)
            "demarrer" -> {
                val vue = apercu
                if (vue == null) {
                    result.error("APERCU", "L'aperçu caméra n'est pas encore affiché", null)
                    return
                }
                moteur.demarrer(vue) { erreur ->
                    if (erreur == null) result.success(moteur.infos.toMap())
                    else result.error("CAMERA", erreur, null)
                }
            }
            "arreter" -> {
                moteur.arreter()
                result.success(null)
            }
            "flash" -> {
                moteur.flash(call.argument<Boolean>("actif") ?: true)
                result.success(null)
            }
            "zoom" -> {
                moteur.zoom((call.argument<Double>("lineaire") ?: 0.0).toFloat())
                result.success(null)
            }
            "mettreAuPoint" -> {
                val vue = apercu
                val x = call.argument<Double>("x")
                val y = call.argument<Double>("y")
                if (vue != null && x != null && y != null) moteur.mettreAuPoint(vue, x.toFloat(), y.toFloat())
                result.success(null)
            }
            "capturer" -> {
                val doigts = call.argument<List<Int>>("doigts")
                val main = call.argument<String>("main")
                val session = call.argument<String>("session")
                if (doigts.isNullOrEmpty() || main == null || session == null) {
                    result.error("ARGUMENTS", "main, doigts et session sont obligatoires", null)
                    return
                }
                val x = call.argument<Double>("x")
                val y = call.argument<Double>("y")
                moteur.capturer(
                    ParametresCapture(main, doigts, call.argument<Boolean>("debogage") ?: false, session),
                    apercu,
                    if (x != null && y != null) Pair(x.toFloat(), y.toFloat()) else null,
                ) { reponse -> result.success(reponse) }
            }
            "pause" -> {
                moteur.pause()
                result.success(null)
            }
            "reprendre" -> {
                moteur.reprendre()
                result.success(null)
            }
            "supprimerTemporaires" -> {
                moteur.supprimerTemporaires()
                result.success(null)
            }
            "infos" -> result.success(moteur.infos.toMap())
            else -> result.notImplemented()
        }
    }

    private fun demanderPermission(result: MethodChannel.Result) {
        val accordee = ContextCompat.checkSelfPermission(activite, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        if (accordee) {
            result.success(true)
            return
        }
        resultatPermission = result
        ActivityCompat.requestPermissions(
            activite, arrayOf(Manifest.permission.CAMERA), CODE_PERMISSION_CAMERA,
        )
    }

    fun surResultatPermission(code: Int, resultats: IntArray) {
        if (code != CODE_PERMISSION_CAMERA) return
        val accordee = resultats.firstOrNull() == PackageManager.PERMISSION_GRANTED
        resultatPermission?.success(accordee)
        resultatPermission = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        puits = events
    }

    override fun onCancel(arguments: Any?) {
        puits = null
    }

    fun liberer() = moteur.liberer()
}
