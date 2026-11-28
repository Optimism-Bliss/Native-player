package io.github.optimismbliss.torbox_strm_player

import android.app.PictureInPictureParams
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
import android.util.Rational
import android.os.SystemClock
import android.view.KeyEvent
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pipChannel: MethodChannel? = null
    private var media3: Media3Host? = null

    /// TVs: the Flutter surface is transparent and above the Media3 video surface, so the app's
    /// Flutter player controls are drawn over hardware-decoded video (no GPU copy). Elsewhere
    /// Flutter keeps its default opaque surface.
    private val tvSurface by lazy { isTv() }

    override fun getRenderMode(): RenderMode = if (tvSurface) RenderMode.surface else super.getRenderMode()

    override fun getTransparencyMode(): TransparencyMode =
        if (tvSurface) TransparencyMode.transparent else super.getTransparencyMode()

    override fun onDestroy() {
        media3?.release()
        media3 = null
        super.onDestroy()
    }

    /// Phone player playing: Home / recent apps shrink the video into a picture-in-picture window.
    private var pipArmed = false
    private var pipAspect = Rational(16, 9)

    /// Pairing link (torboxstrm://pair?...) that opened the app, until Flutter reads it.
    private var pendingLink: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingLink = pairLink(intent)
        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "torboxstrm/pip").also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "arm" -> {
                        pipArmed = call.argument<Boolean>("on") == true && supportsPip()
                        val w = call.argument<Int>("w") ?: 16
                        val h = call.argument<Int>("h") ?: 9
                        if (w > 0 && h > 0) {
                            // Android accepts 1:2.39 .. 2.39:1
                            val r = w.toDouble() / h
                            pipAspect = if (r > 2.39) Rational(239, 100) else if (r < 0.42) Rational(100, 239) else Rational(w, h)
                        }
                        updatePipParams()
                        result.success(pipArmed)
                    }
                    "enter" -> result.success(enterPip())
                    else -> result.notImplemented()
                }
            }
        }
        // "Tải về máy": DownloadManager của hệ thống (tải nền, kể cả khi app đã tắt) — SystemDownloads.kt
        val downloads = SystemDownloads(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "torboxstrm/downloads")
            .setMethodCallHandler { call, result -> downloads.handle(call, result) }
        // Android TV: Media3 player under the transparent Flutter surface (Media3Host.kt).
        val media3Channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "torboxstrm/media3")
        val host = Media3Host(this, media3Channel)
        media3 = host
        media3Channel.setMethodCallHandler { call, result -> host.handle(call, result) }
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

    private fun supportsPip(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !isTv() &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun pipParams(): PictureInPictureParams? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        val b = PictureInPictureParams.Builder().setAspectRatio(pipAspect)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            b.setAutoEnterEnabled(pipArmed)
            b.setSeamlessResizeEnabled(true)
        }
        return b.build()
    }

    private fun updatePipParams() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || !supportsPip()) return
        try {
            pipParams()?.let { setPictureInPictureParams(it) }
        } catch (e: Exception) {
        }
    }

    private fun enterPip(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || !supportsPip()) return false
        return try {
            enterPictureInPictureMode(pipParams()!!)
        } catch (e: Exception) {
            false
        }
    }

    private var started = false

    override fun onStart() {
        super.onStart()
        started = true
    }

    override fun onStop() {
        started = false
        super.onStop()
    }

    // Android 8-11 (12+ enters on its own with auto-enter)
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (pipArmed && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) enterPip()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        // closed from the small window (swiped away / ✕): the activity is stopped, playback should stop too
        val dismissed = !isInPictureInPictureMode && !started
        pipChannel?.invokeMethod("pip", mapOf("on" to isInPictureInPictureMode, "dismissed" to dismissed))
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
        // set even when already in that mode: phones with adaptive refresh drop to 60 Hz for video otherwise
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
