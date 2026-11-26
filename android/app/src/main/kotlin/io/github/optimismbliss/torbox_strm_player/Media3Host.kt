package io.github.optimismbliss.torbox_strm_player

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.hardware.display.DisplayManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.TrackSelectionParameters
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.ts.TsExtractor
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.PlayerView
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.peerless2012.ass.media.kt.buildWithAssSupport
import io.github.peerless2012.ass.media.type.AssRenderType
import java.util.Locale

/**
 * Android TV: Media3 ExoPlayer behind the Flutter UI (channel `torboxstrm/media3`).
 *
 * The PlayerView (a SurfaceView) is added under the FlutterView in MainActivity's content; on TVs
 * the Flutter surface is transparent and on top (MainActivity.getTransparencyMode), so the app's
 * own Flutter player controls are drawn over a picture that goes straight from the hardware
 * decoder to the display. Dart side: lib/player/media3_player.dart (a media_kit PlatformPlayer).
 */
@OptIn(UnstableApi::class)
class Media3Host(private val activity: Activity, private val channel: MethodChannel) {
    private var player: ExoPlayer? = null
    private var view: PlayerView? = null
    private val handler = Handler(Looper.getMainLooper())
    private var url: String? = null
    private var pendingTextId: String? = null
    private var subCount = 0
    private var matchFrameRate = false
    private var matchedFps = 0f
    private var originalModeId: Int? = null
    private var videoDecoder = ""
    private var dropped = 0L
    private var released = true

    private val tick = object : Runnable {
        override fun run() {
            sendState()
            handler.postDelayed(this, 500)
        }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        val p = player
        if (call.method != "create" && (p == null || released)) {
            result.success(null)
            return
        }
        when (call.method) {
            "create" -> {
                create(call.arguments as? Map<*, *> ?: emptyMap<String, Any>())
                result.success(true)
            }
            "open" -> {
                val u = call.argument<String>("url") ?: return result.error("args", "url", null)
                url = u
                subCount = 0
                pendingTextId = null
                matchedFps = 0f
                dropped = 0
                p!!.setMediaItem(MediaItem.Builder().setUri(u).build(), (call.argument<Number>("startMs") ?: 0).toLong())
                p.prepare()
                p.playWhenReady = call.argument<Boolean>("play") != false
                result.success(null)
            }
            "stop" -> { p!!.stop(); p.clearMediaItems(); result.success(null) }
            "play" -> { if (p!!.playbackState == Player.STATE_ENDED) p.seekTo(0); p.play(); result.success(null) }
            "pause" -> { p!!.pause(); result.success(null) }
            "seek" -> { p!!.seekTo((call.argument<Number>("ms") ?: 0).toLong().coerceAtLeast(0)); result.success(null) }
            "volume" -> { p!!.volume = ((call.argument<Number>("value") ?: 100).toFloat() / 100f).coerceIn(0f, 1f); result.success(null) }
            "rate" -> { p!!.playbackParameters = PlaybackParameters((call.argument<Number>("value") ?: 1).toFloat()); result.success(null) }
            "track" -> {
                val type = if (call.argument<String>("type") == "audio") C.TRACK_TYPE_AUDIO else C.TRACK_TYPE_TEXT
                result.success(selectTrack(type, call.argument<String>("id") ?: ""))
            }
            "subOff" -> {
                p!!.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
                    .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true).build()
                result.success(null)
            }
            "subAuto" -> {
                p!!.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
                    .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false).clearOverridesOfType(C.TRACK_TYPE_TEXT).build()
                result.success(null)
            }
            "addSub" -> result.success(addSubtitle(call))
            "fit" -> {
                view?.resizeMode = when (call.argument<String>("mode")) {
                    "fill" -> AspectRatioFrameLayout.RESIZE_MODE_FILL
                    "zoom" -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                    else -> AspectRatioFrameLayout.RESIZE_MODE_FIT
                }
                result.success(null)
            }
            "subStyle" -> { applySubStyle(call); result.success(null) }
            "release" -> { release(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    private fun log(line: String) = handler.post { channel.invokeMethod("log", line) }

    private fun create(args: Map<*, *>) {
        if (!released) release()
        released = false
        matchFrameRate = args["matchFrameRate"] == true
        val tunneling = args["tunneling"] == true
        val bufferMb = (args["bufferMb"] as? Number)?.toInt() ?: 0
        val langs = { k: String -> listOf(args[k] as? String ?: "", "vi", "en").filter { it.isNotEmpty() }.distinct().toTypedArray() }

        val lowRam = (activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).isLowRamDevice
        val extractors = DefaultExtractorsFactory()
            .setTsExtractorTimestampSearchBytes(
                if (lowRam) TsExtractor.TS_PACKET_SIZE * 1800 else TsExtractor.DEFAULT_TIMESTAMP_SEARCH_BYTES
            )
            .setConstantBitrateSeekingEnabled(true)
            .setConstantBitrateSeekingAlwaysEnabled(true)
        // /s/<key> on the server redirects to the TorBox CDN (other host, maybe https)
        val http = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setUserAgent("TorBoxSTRM-TV")
            .setConnectTimeoutMs(15_000)
            .setReadTimeoutMs(30_000)
        val renderers = DefaultRenderersFactory(activity)
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
            .setEnableDecoderFallback(true)
        val selector = DefaultTrackSelector(activity).apply {
            setParameters(
                buildUponParameters()
                    .setAudioOffloadPreferences(
                        TrackSelectionParameters.AudioOffloadPreferences.DEFAULT.buildUpon()
                            .setAudioOffloadMode(TrackSelectionParameters.AudioOffloadPreferences.AUDIO_OFFLOAD_MODE_ENABLED)
                            .build()
                    )
                    .setTunnelingEnabled(tunneling)
                    .setPreferredAudioLanguages(*langs("audioLang"))
                    .setPreferredTextLanguages(*langs("subLang"))
                    .setAllowInvalidateSelectionsOnRendererCapabilitiesChange(true)
            )
        }
        val load = DefaultLoadControl.Builder()
            .setBufferDurationsMs(30_000, 120_000, 2_500, 5_000)
            .setTargetBufferBytes(
                if (bufferMb > 0) bufferMb * 1024 * 1024 else if (lowRam) 48 * 1024 * 1024 else 96 * 1024 * 1024
            )
            .setPrioritizeTimeOverSizeThresholds(false)
            .build()
        val p = ExoPlayer.Builder(activity)
            .setTrackSelector(selector)
            .setLoadControl(load)
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
                true,
            )
            .setHandleAudioBecomingNoisy(true)
            .setVideoScalingMode(C.VIDEO_SCALING_MODE_SCALE_TO_FIT)
            .buildWithAssSupport(
                activity,
                renderType = AssRenderType.CUES,
                dataSourceFactory = DefaultDataSource.Factory(activity, http),
                extractorsFactory = extractors,
                renderersFactory = renderers,
            )
        p.addListener(listener)
        p.addAnalyticsListener(analytics)
        player = p

        val v = PlayerView(activity).apply {
            player = p
            useController = false
            isFocusable = false
            isFocusableInTouchMode = false
            setShutterBackgroundColor(Color.BLACK)
            setBackgroundColor(Color.BLACK)
            resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
            setShowBuffering(PlayerView.SHOW_BUFFERING_NEVER)
            subtitleView?.apply {
                setApplyEmbeddedFontSizes(false)
                setFractionalTextSize(0.055f)
                setBottomPaddingFraction(0.06f)
                setStyle(
                    CaptionStyleCompat(
                        Color.WHITE, Color.TRANSPARENT, Color.TRANSPARENT,
                        CaptionStyleCompat.EDGE_TYPE_OUTLINE, Color.BLACK, Typeface.DEFAULT_BOLD,
                    )
                )
            }
        }
        // under the FlutterView: the transparent Flutter surface draws the controls on top
        val content = activity.findViewById<FrameLayout>(android.R.id.content)
        content.addView(v, 0, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        view = v
        activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        log("media3: created (tunneling ${if (tunneling) "on" else "off"}, buffer ${if (bufferMb > 0) "$bufferMb MB" else "auto"})")
        handler.post(tick)
    }

    fun release() {
        if (released) return
        released = true
        handler.removeCallbacks(tick)
        player?.let {
            it.removeListener(listener)
            it.release()
        }
        player = null
        view?.let { (it.parent as? ViewGroup)?.removeView(it) }
        view = null
        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        originalModeId?.let { setMode(it) }
        originalModeId = null
    }

    // ---------------- events ----------------

    private val listener = object : Player.Listener {
        override fun onPlaybackStateChanged(state: Int) {
            if (state == Player.STATE_READY) log("media3: ready, ${describeTracks()}")
            sendState()
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) = sendState()

        override fun onTracksChanged(tracks: Tracks) {
            val pending = pendingTextId
            val p = player ?: return
            if (pending != null) {
                for (g in tracks.groups) {
                    if (g.type != C.TRACK_TYPE_TEXT) continue
                    for (t in 0 until g.length) {
                        if (g.getTrackFormat(t).id?.contains(pending) == true) {
                            pendingTextId = null
                            p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
                                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                                .setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, t))
                                .build()
                        }
                    }
                }
            }
            if (matchFrameRate) {
                val fps = selectedVideoFormat()?.frameRate ?: 0f
                if (fps > 10f && fps != matchedFps) {
                    matchedFps = fps
                    applyFrameRate(fps)
                }
            }
            sendState()
        }

        override fun onVideoSizeChanged(videoSize: VideoSize) = sendState()

        override fun onPlayerError(error: PlaybackException) {
            val message = "${error.errorCodeName}: ${error.cause?.message ?: error.message}"
            log("media3: error $message")
            // the Dart controller reopens the link (renews an expired CDN link) or shows the message
            handler.post { channel.invokeMethod("error", message) }
        }
    }

    private val analytics = object : AnalyticsListener {
        override fun onVideoDecoderInitialized(
            eventTime: AnalyticsListener.EventTime, decoderName: String,
            initializedTimestampMs: Long, initializationDurationMs: Long,
        ) {
            videoDecoder = decoderName
            log("media3: video decoder $decoderName")
        }

        override fun onAudioDecoderInitialized(
            eventTime: AnalyticsListener.EventTime, decoderName: String,
            initializedTimestampMs: Long, initializationDurationMs: Long,
        ) {
            log("media3: audio decoder $decoderName")
        }

        override fun onDroppedVideoFrames(eventTime: AnalyticsListener.EventTime, droppedFrames: Int, elapsedMs: Long) {
            dropped += droppedFrames
        }

        override fun onVideoInputFormatChanged(
            eventTime: AnalyticsListener.EventTime, format: Format, decoderReuseEvaluation: DecoderReuseEvaluation?,
        ) {}
    }

    private fun selectedVideoFormat(): Format? {
        val p = player ?: return null
        for (g in p.currentTracks.groups) {
            if (g.type != C.TRACK_TYPE_VIDEO) continue
            for (t in 0 until g.length) if (g.isTrackSelected(t)) return g.getTrackFormat(t)
        }
        return null
    }

    private fun describeTracks(): String {
        val p = player ?: return ""
        val parts = ArrayList<String>()
        for (g in p.currentTracks.groups) {
            for (t in 0 until g.length) {
                if (!g.isTrackSelected(t)) continue
                val f = g.getTrackFormat(t)
                when (g.type) {
                    C.TRACK_TYPE_VIDEO -> parts += "video ${f.sampleMimeType} ${f.width}x${f.height}" +
                        (if (f.frameRate > 0) " %.3f fps".format(Locale.ROOT, f.frameRate) else "")
                    C.TRACK_TYPE_AUDIO -> parts += "audio ${f.sampleMimeType} ${f.channelCount}ch"
                    C.TRACK_TYPE_TEXT -> parts += "sub ${f.sampleMimeType ?: f.codecs}"
                }
            }
        }
        return parts.joinToString(", ").ifEmpty { "no tracks" }
    }

    private fun sendState() {
        val p = player ?: return
        if (released) return
        val duration = p.duration.let { if (it == C.TIME_UNSET) 0L else it }
        val v = p.videoSize
        val video = selectedVideoFormat()
        channel.invokeMethod(
            "state",
            mapOf(
                "position" to p.currentPosition.coerceAtLeast(0),
                "duration" to duration,
                "buffered" to p.bufferedPosition.coerceAtLeast(0),
                "playing" to p.isPlaying,
                "buffering" to (p.playbackState == Player.STATE_BUFFERING),
                "ended" to (p.playbackState == Player.STATE_ENDED),
                "volume" to (p.volume * 100).toDouble(),
                "rate" to p.playbackParameters.speed.toDouble(),
                "width" to (if (v.width > 0) v.width else null),
                "height" to (if (v.height > 0) v.height else null),
                "audio" to tracksOf(C.TRACK_TYPE_AUDIO),
                "subs" to tracksOf(C.TRACK_TYPE_TEXT),
                "video" to tracksOf(C.TRACK_TYPE_VIDEO),
                "subsOff" to p.trackSelectionParameters.disabledTrackTypes.contains(C.TRACK_TYPE_TEXT),
                "videoDecoder" to videoDecoder,
                "container" to (video?.containerMimeType ?: ""),
                "dropped" to dropped,
                "fps" to (video?.frameRate?.takeIf { it > 0 }?.toDouble()),
            ),
        )
    }

    private fun tracksOf(type: Int): List<Map<String, Any?>> {
        val p = player ?: return emptyList()
        val out = ArrayList<Map<String, Any?>>()
        p.currentTracks.groups.forEachIndexed { gi, g ->
            if (g.type != type) return@forEachIndexed
            for (t in 0 until g.length) {
                if (!g.isTrackSupported(t, true)) continue
                val f = g.getTrackFormat(t)
                out += mapOf(
                    "id" to "$gi:$t",
                    "title" to f.label,
                    "language" to f.language?.takeIf { it != "und" },
                    "codec" to codec(f),
                    "channels" to (if (f.channelCount > 0) f.channelCount else null),
                    "width" to (if (f.width > 0) f.width else null),
                    "height" to (if (f.height > 0) f.height else null),
                    "fps" to (if (f.frameRate > 0) f.frameRate.toDouble() else null),
                    "selected" to g.isTrackSelected(t),
                    "default" to ((f.selectionFlags and C.SELECTION_FLAG_DEFAULT) != 0),
                )
            }
        }
        return out
    }

    /// mpv-style codec names, which the app's labels already know.
    private fun codec(f: Format): String? = when (f.sampleMimeType) {
        MimeTypes.VIDEO_H264 -> "h264"
        MimeTypes.VIDEO_H265 -> "hevc"
        MimeTypes.VIDEO_AV1 -> "av1"
        MimeTypes.VIDEO_VP9 -> "vp9"
        MimeTypes.VIDEO_DOLBY_VISION -> "hevc"
        MimeTypes.AUDIO_AC3 -> "ac3"
        MimeTypes.AUDIO_E_AC3, MimeTypes.AUDIO_E_AC3_JOC -> "eac3"
        MimeTypes.AUDIO_DTS, MimeTypes.AUDIO_DTS_EXPRESS -> "dts"
        MimeTypes.AUDIO_DTS_HD -> "dts"
        MimeTypes.AUDIO_TRUEHD -> "truehd"
        MimeTypes.AUDIO_AAC -> "aac"
        MimeTypes.AUDIO_OPUS -> "opus"
        MimeTypes.AUDIO_FLAC -> "flac"
        MimeTypes.AUDIO_MPEG -> "mp3"
        MimeTypes.TEXT_SSA -> "ass"
        MimeTypes.APPLICATION_SUBRIP -> "subrip"
        MimeTypes.APPLICATION_PGS -> "hdmv_pgs_subtitle"
        MimeTypes.TEXT_VTT -> "webvtt"
        MimeTypes.APPLICATION_VOBSUB -> "dvd_subtitle"
        else -> f.sampleMimeType?.substringAfter('/')
    }

    private fun selectTrack(type: Int, id: String): Boolean {
        val p = player ?: return false
        val parts = id.split(":")
        val gi = parts.getOrNull(0)?.toIntOrNull() ?: return false
        val ti = parts.getOrNull(1)?.toIntOrNull() ?: return false
        val g = p.currentTracks.groups.getOrNull(gi) ?: return false
        if (g.type != type || ti >= g.length) return false
        p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(type, false)
            .setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, ti))
            .build()
        return true
    }

    /// External subtitle (server URL or a file Flutter wrote): added to the item, then selected.
    private fun addSubtitle(call: MethodCall): Boolean {
        val p = player ?: return false
        val uri = call.argument<String>("uri") ?: return false
        val item = p.currentMediaItem ?: return false
        val id = "ext${++subCount}"
        val config = MediaItem.SubtitleConfiguration.Builder(Uri.parse(uri))
            .setId(id)
            .setMimeType(call.argument<String>("mime") ?: MimeTypes.APPLICATION_SUBRIP)
            .setLanguage(call.argument<String>("lang"))
            .setLabel(call.argument<String>("label"))
            .build()
        val keep = item.localConfiguration?.subtitleConfigurations.orEmpty()
        val pos = p.currentPosition
        val playing = p.playWhenReady
        pendingTextId = id
        p.setMediaItem(item.buildUpon().setSubtitleConfigurations(keep + config).build(), pos)
        p.prepare()
        p.playWhenReady = playing
        return true
    }

    private fun applySubStyle(call: MethodCall) {
        val sv = view?.subtitleView ?: return
        val scale = (call.argument<Number>("scale") ?: 1.0).toFloat()
        val color = (call.argument<Number>("color") ?: 0xFFFFFFFF).toLong().toInt()
        val box = call.argument<Boolean>("box") == true
        // 0xB0 translucent, 0xFF solid (also hides subtitles burned into the picture)
        val boxAlpha = (call.argument<Number>("boxAlpha") ?: 0xB0).toInt().coerceIn(0, 255)
        val bold = call.argument<Boolean>("bold") != false
        val border = (call.argument<Number>("border") ?: 3).toFloat()
        // bundled Vietnamese-friendly typeface (Flutter asset), bold file when "bold" is on
        val asset = (if (bold) call.argument<String>("fontBold") else null) ?: call.argument<String>("font")
        val face = asset?.let { a ->
            typefaces.getOrPut(a) { runCatching { Typeface.createFromAsset(activity.assets, a) }.getOrNull() }
        } ?: if (bold) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
        sv.setFractionalTextSize(0.055f * scale)
        sv.setStyle(
            CaptionStyleCompat(
                color,
                if (box) (boxAlpha shl 24) else Color.TRANSPARENT,
                Color.TRANSPARENT,
                if (border > 0 && !box) CaptionStyleCompat.EDGE_TYPE_OUTLINE else CaptionStyleCompat.EDGE_TYPE_NONE,
                Color.BLACK,
                face,
            )
        )
    }

    private val typefaces = HashMap<String, Typeface?>()

    // ---------------- frame-rate matching ----------------

    @Suppress("DEPRECATION")
    private fun currentDisplay(): Display? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) activity.display else activity.windowManager.defaultDisplay

    /// Same resolution, refresh rate a whole multiple of the film's; playback pauses while the TV switches.
    private fun applyFrameRate(fps: Float) {
        val display = currentDisplay() ?: return
        val current = display.mode
        val target = display.supportedModes
            .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
            .filter {
                val k = it.refreshRate / fps
                val n = Math.round(k)
                n >= 1 && Math.abs(k - n) < 0.005f * n
            }
            .minByOrNull { it.refreshRate }
        log(
            "frame rate: film %.3f fps, display %.2f Hz -> %s".format(
                Locale.ROOT, fps, current.refreshRate,
                target?.let { "%.2f Hz".format(Locale.ROOT, it.refreshRate) } ?: "no matching mode",
            )
        )
        if (target == null || target.modeId == current.modeId) return
        if (originalModeId == null) originalModeId = current.modeId
        val p = player ?: return
        val wasPlaying = p.playWhenReady
        p.playWhenReady = false
        setMode(target.modeId) {
            handler.postDelayed({ if (wasPlaying && !released) player?.playWhenReady = true }, 2000)
        }
    }

    private fun setMode(modeId: Int, done: (() -> Unit)? = null) {
        val dm = activity.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val displayId = currentDisplay()?.displayId ?: Display.DEFAULT_DISPLAY
        var finished = false
        lateinit var l: DisplayManager.DisplayListener
        val complete = {
            if (!finished) {
                finished = true
                dm.unregisterDisplayListener(l)
                done?.invoke()
            }
        }
        l = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(id: Int) {}
            override fun onDisplayRemoved(id: Int) {}
            override fun onDisplayChanged(id: Int) {
                if (id == displayId) complete()
            }
        }
        dm.registerDisplayListener(l, handler)
        val attrs = activity.window.attributes
        attrs.preferredDisplayModeId = modeId
        activity.window.attributes = attrs
        handler.postDelayed({ complete() }, 5000)
    }
}
