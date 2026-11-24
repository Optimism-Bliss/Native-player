package io.github.optimismbliss.torbox_strm_player

import android.app.UiModeManager
import android.content.ActivityNotFoundException
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    /// Pairing link (torboxstrm://pair?...) that opened the app, until Flutter reads it.
    private var pendingLink: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingLink = pairLink(intent)
        // Opens the web UI's "intent://…" links for external players (VLC, MX Player…)
        // exactly as Chrome would, including S.browser_fallback_url.
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "torboxstrm/intent")
        channel!!.setMethodCallHandler { call, result ->
                when (call.method) {
                    // Android TV / Google TV / TV boxes: the app becomes a "Play on TV" receiver.
                    "isTv" -> result.success(isTv())
                    "initialLink" -> {
                        result.success(pendingLink)
                        pendingLink = null
                    }
                    "open" -> {
                        val raw = call.argument<String>("uri") ?: return@setMethodCallHandler result.success(false)
                        result.success(openIntentUri(raw))
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path") ?: return@setMethodCallHandler result.success(false)
                        result.success(installApk(path))
                    }
                    // Player swipe gestures: media volume and this window's brightness (0..1).
                    "getVolume" -> result.success(volume())
                    "setVolume" -> {
                        setVolume(call.argument<Double>("value") ?: 0.0)
                        result.success(null)
                    }
                    "getBrightness" -> result.success(brightness())
                    "setBrightness" -> {
                        setBrightness(call.argument<Double>("value"))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val link = pairLink(intent) ?: return
        channel?.invokeMethod("link", link) ?: run { pendingLink = link }
    }

    private fun pairLink(intent: Intent?): String? {
        val data = intent?.data ?: return null
        return if (data.scheme == "torboxstrm" && data.host == "pair") data.toString() else null
    }

    private fun isTv(): Boolean {
        val ui = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
        return ui.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    }

    private val audio get() = getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private fun volume(): Double {
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
        return audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max
    }

    private fun setVolume(value: Double) {
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val index = Math.round(value.coerceIn(0.0, 1.0) * max).toInt()
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, index, 0)
    }

    /// Window brightness, or the system setting while the window follows it.
    private fun brightness(): Double {
        val own = window.attributes.screenBrightness
        if (own >= 0f) return own.toDouble()
        return try {
            Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS) / 255.0
        } catch (e: Exception) {
            0.5
        }
    }

    /// null hands brightness back to the system setting.
    private fun setBrightness(value: Double?) {
        val attrs = window.attributes
        attrs.screenBrightness = value?.coerceIn(0.01, 1.0)?.toFloat()
            ?: android.view.WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
        window.attributes = attrs
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
