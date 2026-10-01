package km.hawiya.hawiya

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import km.hawiya.hawiya.capture.CanalCapture

/**
 * FlutterFragmentActivity (et non FlutterActivity) : CameraX a besoin d'un
 * LifecycleOwner AndroidX pour démarrer et arrêter la caméra avec l'écran.
 */
class MainActivity : FlutterFragmentActivity() {
    private var capture: CanalCapture? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val canal = CanalCapture(this, flutterEngine.dartExecutor.binaryMessenger)
        flutterEngine.platformViewsController.registry
            .registerViewFactory(CanalCapture.VUE_APERCU, canal.fabriqueApercu)
        capture = canal
    }

    @Deprecated("Requis par ActivityCompat.requestPermissions")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        capture?.surResultatPermission(requestCode, grantResults)
    }

    override fun onDestroy() {
        capture?.liberer()
        super.onDestroy()
    }
}
