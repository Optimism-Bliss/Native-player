package io.github.optimismbliss.torbox_strm_player

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Opens the web UI's "intent://…" links for external players (VLC, MX Player…)
        // exactly as Chrome would, including S.browser_fallback_url.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "torboxstrm/intent")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> {
                        val raw = call.argument<String>("uri") ?: return@setMethodCallHandler result.success(false)
                        result.success(openIntentUri(raw))
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path") ?: return@setMethodCallHandler result.success(false)
                        result.success(installApk(path))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Hands a downloaded update to the system package installer. Returns false
    /// when the user first has to allow installs from this app (settings opened).
    private fun installApk(path: String): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            return false
        }
        val file = File(path)
        if (!file.exists() || file.parentFile?.canonicalPath != cacheDir.canonicalPath) return false
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
        startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        return true
    }

    private fun openIntentUri(raw: String): Boolean {
        val intent = try {
            Intent.parseUri(raw, Intent.URI_INTENT_SCHEME)
        } catch (e: Exception) {
            return false
        }
        // Never let a web page start private components of other apps.
        intent.addCategory(Intent.CATEGORY_BROWSABLE)
        intent.component = null
        intent.selector = null
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            val fallback = intent.getStringExtra("browser_fallback_url")
            if (fallback != null && (fallback.startsWith("https://") || fallback.startsWith("http://"))) {
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(fallback)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    true
                } catch (e2: ActivityNotFoundException) {
                    false
                }
            } else {
                false
            }
        }
    }
}
