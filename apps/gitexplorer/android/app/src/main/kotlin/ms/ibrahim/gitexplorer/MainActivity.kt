package ms.ibrahim.gitexplorer

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Answers whether this app may read the files in folders the user picks, and
 * asks for that when it may not.
 *
 * Two calls' worth of platform code rather than a permission plugin: the
 * maintained ones now require compiling against a preview SDK, which is a large
 * thing to accept for `isExternalStorageManager` and one intent.
 */
class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL = "gitexplorer/storage_access"
        const val ALL_FILES_REQUEST = 8011
        const val LEGACY_REQUEST = 8012
    }

    /** Held while the user is away in Settings, answered when they return. */
    private var pending: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> onCall(call, result) }
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isGranted" -> result.success(isGranted())
            "request" -> request(result)
            else -> result.notImplemented()
        }
    }

    private fun isGranted(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Scoped storage: reading another app's files needs All files access.
            Environment.isExternalStorageManager()
        } else {
            checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }

    private fun request(result: MethodChannel.Result) {
        if (isGranted()) {
            result.success(true)
            return
        }
        // One question at a time; a second while the first is unanswered would
        // leave a Dart future with nobody to complete it.
        if (pending != null) {
            result.success(false)
            return
        }
        pending = result

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // All files access is granted on a Settings screen, not in a dialog,
            // so this leaves the app and the answer arrives on the way back.
            val intent = Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:$packageName"),
            )
            try {
                startActivityForResult(intent, ALL_FILES_REQUEST)
            } catch (_: Exception) {
                // Some builds have no per-app screen; the whole list still works.
                try {
                    startActivityForResult(
                        Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION),
                        ALL_FILES_REQUEST,
                    )
                } catch (_: Exception) {
                    answer(false)
                }
            }
        } else {
            requestPermissions(
                arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE),
                LEGACY_REQUEST,
            )
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        // The Settings screen reports nothing useful in its result code, so what
        // matters is what is true now that we are back.
        if (requestCode == ALL_FILES_REQUEST) answer(isGranted())
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == LEGACY_REQUEST) answer(isGranted())
    }

    private fun answer(granted: Boolean) {
        pending?.success(granted)
        pending = null
    }
}
