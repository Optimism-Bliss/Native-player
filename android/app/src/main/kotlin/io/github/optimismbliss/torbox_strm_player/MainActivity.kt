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
import android.os.SystemClock
import android.view.KeyEvent
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
        // Android TV: Media3 player in its own activity (NativePlayerActivity).
        val native = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "torboxstrm/native_player")
        NativePlayerBridge.channel = native
        native.setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val args = call.arguments as? Map<*, *> ?: return@setMethodCallHandler result.success(false)
                    // a new title replaces the one playing
                    NativePlayerBridge.activity?.command("stop", emptyMap<String, Any>())
                    NativePlayerBridge.pendingArgs = args
                    startActivity(Intent(this, NativePlayerActivity::class.java))
                    result.success(true)
                }
                "command" -> {
                    val player = NativePlayerBridge.activity
                        ?: return@setMethodCallHandler result.success("Trình phát đã đóng")
                    val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
                    result.success(player.command(args["action"] as? String ?: "", args))
                }
                else -> result.notImplemented()
            }
        }
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
                    // Phone used as the TV's remote: the key goes through the window exactly like the
                    // real remote's (Flutter screens, the web page in the WebView, the player, dialogs).
                    "key" -> result.success(pressKey(call.argument<String>("key") ?: ""))
                    // start-up log line: free RAM and why the previous run ended (killed for memory, crash…)
                    "startInfo" -> result.success(startInfo())
                    // frame-rate matching on TVs: a display mode whose refresh rate fits the film (0 = default)
                    "frameRate" -> result.success(frameRate(call.argument<Double>("fps") ?: 0.0))
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
        // pair (phone ↔ TV), connect (server code), device (approve a TV's login)
        return if (data.scheme == "torboxstrm" && data.host in setOf("pair", "connect", "device")) data.toString() else null
    }

    private fun pressKey(name: String): Boolean {
        val code = when (name) {
            "up" -> KeyEvent.KEYCODE_DPAD_UP
            "down" -> KeyEvent.KEYCODE_DPAD_DOWN
            "left" -> KeyEvent.KEYCODE_DPAD_LEFT
            "right" -> KeyEvent.KEYCODE_DPAD_RIGHT
            "ok" -> KeyEvent.KEYCODE_DPAD_CENTER
            "back" -> KeyEvent.KEYCODE_BACK
            "playpause" -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
            else -> return false
        }
        // the TV player is on top: the key goes to it
        NativePlayerBridge.activity?.let { player ->
            player.runOnUiThread { player.pressKey(code) }
            return true
        }
        runOnUiThread {
            val t = SystemClock.uptimeMillis()
            dispatchKeyEvent(KeyEvent(t, t, KeyEvent.ACTION_DOWN, code, 0))
            dispatchKeyEvent(KeyEvent(t, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, code, 0))
        }
        return true
    }

    /// Picks the display mode with the current resolution whose refresh rate is a whole multiple of
    /// [fps] (23.976 → 23.976/24/47.95/48…, 25 → 50, 29.97 → 59.94), lowest first, and asks the window
    /// for it (Android TV switches the HDMI mode; the screen may go dark for a second). 0 restores the
    /// default mode. Returns the refresh rate expected afterwards, or null when nothing fits.
    private fun frameRate(fps: Double): Double? {
        @Suppress("DEPRECATION")
        val display = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display else windowManager.defaultDisplay)
            ?: return null
        val attrs = window.attributes
        if (fps <= 0.0) {
            attrs.preferredDisplayModeId = 0
            window.attributes = attrs
            return display.supportedModes.firstOrNull { it.modeId == display.mode.modeId }?.refreshRate?.toDouble()
        }
        val current = display.mode
        val best = display.supportedModes
            .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
            .filter {
                val k = it.refreshRate / fps
                val n = Math.round(k)
                n >= 1 && Math.abs(k - n) < 0.005 * n
            }
            .minByOrNull { it.refreshRate } ?: return null
        if (best.modeId == current.modeId) return best.refreshRate.toDouble()
        attrs.preferredDisplayModeId = best.modeId
        window.attributes = attrs
        return best.refreshRate.toDouble()
    }

    private fun startInfo(): String {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
        val mem = android.app.ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
        val mb = { b: Long -> b / (1024 * 1024) }
        var text = "RAM ${mb(mem.availMem)}/${mb(mem.totalMem)} MB free${if (mem.lowMemory) " (low)" else ""}" +
            ", app limit ${am.memoryClass}/${am.largeMemoryClass} MB"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val last = try {
                am.getHistoricalProcessExitReasons(packageName, 0, 1).firstOrNull()
            } catch (e: Exception) {
                null
            }
            if (last != null) {
                val reason = when (last.reason) {
                    android.app.ApplicationExitInfo.REASON_LOW_MEMORY -> "killed: low memory"
                    android.app.ApplicationExitInfo.REASON_CRASH -> "crash (Java)"
                    android.app.ApplicationExitInfo.REASON_CRASH_NATIVE -> "crash (native)"
                    android.app.ApplicationExitInfo.REASON_ANR -> "not responding (ANR)"
                    android.app.ApplicationExitInfo.REASON_SIGNALED -> "killed by signal ${last.status}"
                    android.app.ApplicationExitInfo.REASON_USER_REQUESTED -> "closed by the user"
                    android.app.ApplicationExitInfo.REASON_EXIT_SELF -> "exited"
                    android.app.ApplicationExitInfo.REASON_OTHER -> "killed by the system"
                    else -> "reason ${last.reason}"
                }
                val ago = (System.currentTimeMillis() - last.timestamp) / 1000
                text += "; previous run: $reason ${ago}s ago, used ${mb(last.pss * 1024)} MB" +
                    (last.description?.let { " ($it)" } ?: "")
            }
        }
        return text
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
