package io.github.optimismbliss.torbox_strm_player

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.hardware.display.DisplayManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Display
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import androidx.annotation.OptIn
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.TrackSelectionParameters
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.ts.TsExtractor
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.PlayerView
import io.flutter.plugin.common.MethodChannel
import io.github.peerless2012.ass.media.kt.buildWithAssSupport
import io.github.peerless2012.ass.media.type.AssRenderType
import java.io.File
import java.util.Locale

/**
 * Link between Flutter (channel `torboxstrm/native_player`) and the open [NativePlayerActivity].
 * Flutter sends `open` (queue, start, options) and `command`; the activity reports `state` every
 * second, `item` when the queue moves on, `log` lines and `closed` with the last position.
 */
object NativePlayerBridge {
    var channel: MethodChannel? = null
    var activity: NativePlayerActivity? = null
    var pendingArgs: Map<*, *>? = null
    private val main = Handler(Looper.getMainLooper())

    fun send(method: String, args: Any?) {
        main.post { channel?.invokeMethod(method, args) }
    }

    fun log(line: String) = send("log", line)
}

/**
 * Android TV player: Media3 ExoPlayer drawing straight to a surface (hardware decoding, no GPU
 * shader pass), like Fladder's TV player. FFmpeg audio decoders for DTS / TrueHD / AC-3 the box
 * cannot decode, libass for ASS subtitles, a buffer sized for weak boxes, frame-rate matching that
 * waits for the TV to switch and restores the mode before closing.
 */
@OptIn(UnstableApi::class)
class NativePlayerActivity : Activity() {
    private data class Item(
        val key: String,
        val url: String,
        val title: String,
        val subUrl: String?,
        val subLabel: String?,
        val subLang: String?,
    )

    private lateinit var player: ExoPlayer
    private lateinit var view: PlayerView
    private lateinit var titleView: TextView
    private lateinit var noticeView: TextView
    private val handler = Handler(Looper.getMainLooper())
    private var items: List<Item> = emptyList()
    private var matchFrameRate = false
    private var autoNext = true
    private var seekBackMs = 10_000L
    private var seekForwardMs = 30_000L
    private var bufferMb = 0
    private var audioLang = "vi"
    private var subLang = "vi"
    private var ready = false

    /// Server subtitle just added: selected as soon as its track shows up.
    private var pendingTextId: String? = null
    private var retries = 0
    private var lastError: String? = null
    private var lastIndex = -1

    // Frame-rate matching: mode before the first switch (restored on close), current film's rate.
    private var originalModeId: Int? = null
    private var matchedFps = 0f
    private var closing = false

    private val tick = object : Runnable {
        override fun run() {
            sendState()
            handler.postDelayed(this, 1000)
        }
    }
    private val hideNotice = Runnable { noticeView.visibility = View.GONE }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val args = NativePlayerBridge.pendingArgs
        NativePlayerBridge.pendingArgs = null
        if (args == null) {
            // recreated by the system after the app was killed: Flutter no longer knows this session
            finish()
            return
        }
        NativePlayerBridge.activity = this
        items = (args["queue"] as? List<*>).orEmpty().mapNotNull { raw ->
            val m = raw as? Map<*, *> ?: return@mapNotNull null
            Item(
                key = m["key"] as? String ?: return@mapNotNull null,
                url = m["url"] as? String ?: return@mapNotNull null,
                title = m["title"] as? String ?: "",
                subUrl = m["subUrl"] as? String,
                subLabel = m["subLabel"] as? String,
                subLang = m["subLang"] as? String,
            )
        }
        if (items.isEmpty()) {
            finish()
            return
        }
        matchFrameRate = args["matchFrameRate"] == true
        val tunneling = args["tunneling"] == true
        autoNext = args["autoNext"] != false
        seekBackMs = (args["seekBackMs"] as? Number)?.toLong() ?: 10_000L
        seekForwardMs = (args["seekForwardMs"] as? Number)?.toLong() ?: 30_000L
        bufferMb = (args["bufferMb"] as? Number)?.toInt() ?: 0
        audioLang = (args["audioLang"] as? String).orEmpty()
        subLang = (args["subLang"] as? String).orEmpty()
        val index = ((args["index"] as? Number)?.toInt() ?: 0).coerceIn(0, items.size - 1)
        val startMs = (args["startMs"] as? Number)?.toLong() ?: 0L

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }

        player = buildPlayer(tunneling)
        buildViews()
        player.addListener(listener)
        player.setMediaItems(items.map(::mediaItem), index, startMs)
        player.prepare()
        player.playWhenReady = true
        NativePlayerBridge.log(
            "native player: open \"${items[index].title}\"${if (startMs > 0) " at ${startMs / 1000}s" else ""}" +
                " (media3, tunneling ${if (tunneling) "on" else "off"})"
        )
        handler.post(tick)
    }

    private fun buildPlayer(tunneling: Boolean): ExoPlayer {
        val lowRam = (getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).isLowRamDevice
        val extractors = DefaultExtractorsFactory()
            .setTsExtractorTimestampSearchBytes(
                if (lowRam) TsExtractor.TS_PACKET_SIZE * 1800 else TsExtractor.DEFAULT_TIMESTAMP_SEARCH_BYTES
            )
            .setConstantBitrateSeekingEnabled(true)
            .setConstantBitrateSeekingAlwaysEnabled(true)
        // The server answers /s/<key> with a redirect to the TorBox CDN (other host, maybe https).
        val http = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setUserAgent("TorBoxSTRM-TV")
            .setConnectTimeoutMs(15_000)
            .setReadTimeoutMs(30_000)
        val dataSource = DefaultDataSource.Factory(this, http)
        // Platform decoders first; FFmpeg only for audio the box cannot decode (DTS, TrueHD…).
        val renderers = DefaultRenderersFactory(this)
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
            .setEnableDecoderFallback(true)
        val selector = DefaultTrackSelector(this).apply {
            setParameters(
                buildUponParameters()
                    .setAudioOffloadPreferences(
                        TrackSelectionParameters.AudioOffloadPreferences.DEFAULT.buildUpon()
                            .setAudioOffloadMode(TrackSelectionParameters.AudioOffloadPreferences.AUDIO_OFFLOAD_MODE_ENABLED)
                            .build()
                    )
                    .setTunnelingEnabled(tunneling)
                    .setPreferredAudioLanguages(*listOf(audioLang, "vi", "en").filter { it.isNotEmpty() }.distinct().toTypedArray())
                    .setPreferredTextLanguages(*listOf(subLang, "vi", "en").filter { it.isNotEmpty() }.distinct().toTypedArray())
                    .setAllowInvalidateSelectionsOnRendererCapabilitiesChange(true)
            )
        }
        // Streaming from a CDN: keep up to 2 minutes ahead, capped in bytes for 1-2 GB boxes.
        val load = DefaultLoadControl.Builder()
            .setBufferDurationsMs(30_000, 120_000, 2_500, 5_000)
            .setTargetBufferBytes(
                if (bufferMb > 0) bufferMb * 1024 * 1024 else if (lowRam) 48 * 1024 * 1024 else 96 * 1024 * 1024
            )
            .setPrioritizeTimeOverSizeThresholds(false)
            .build()
        return ExoPlayer.Builder(this)
            .setTrackSelector(selector)
            .setLoadControl(load)
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
                true,
            )
            .setHandleAudioBecomingNoisy(true)
            .setSeekBackIncrementMs(seekBackMs)
            .setSeekForwardIncrementMs(seekForwardMs)
            .setPauseAtEndOfMediaItems(!autoNext)
            .setVideoScalingMode(C.VIDEO_SCALING_MODE_SCALE_TO_FIT)
            .buildWithAssSupport(
                this,
                renderType = AssRenderType.CUES,
                dataSourceFactory = dataSource,
                extractorsFactory = extractors,
                renderersFactory = renderers,
            )
    }

    private fun buildViews() {
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        view = PlayerView(this).apply {
            player = this@NativePlayerActivity.player
            useController = true
            controllerShowTimeoutMs = 4000
            controllerAutoShow = true
            resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
            setShowBuffering(PlayerView.SHOW_BUFFERING_ALWAYS)
            setShowSubtitleButton(true)
            setShowNextButton(items.size > 1)
            setShowPreviousButton(items.size > 1)
            setShowFastForwardButton(true)
            setShowRewindButton(true)
            keepScreenOn = true
            isFocusable = true
            isFocusableInTouchMode = true
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
        titleView = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
            setShadowLayer(6f, 0f, 0f, Color.BLACK)
            setPadding(dp(48), dp(28), dp(48), dp(12))
            maxLines = 2
        }
        noticeView = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            setBackgroundColor(0xB0000000.toInt())
            setPadding(dp(20), dp(10), dp(20), dp(10))
            visibility = View.GONE
        }
        view.setControllerVisibilityListener(PlayerView.ControllerVisibilityListener { v -> titleView.visibility = v })
        root.addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        root.addView(
            titleView,
            FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP),
        )
        root.addView(
            noticeView,
            FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER),
        )
        setContentView(root)
        updateTitle()
        view.requestFocus()
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun mediaItem(item: Item): MediaItem {
        val subs = item.subUrl?.let {
            listOf(
                MediaItem.SubtitleConfiguration.Builder(Uri.parse(it))
                    .setId("req:${item.key}")
                    .setMimeType(mimeFor(it))
                    .setLanguage(item.subLang)
                    .setLabel(item.subLabel)
                    .setSelectionFlags(C.SELECTION_FLAG_DEFAULT)
                    .build()
            )
        }.orEmpty()
        return MediaItem.Builder()
            .setUri(item.url)
            .setMediaId(item.key)
            .setMediaMetadata(MediaMetadata.Builder().setTitle(item.title).build())
            .setSubtitleConfigurations(subs)
            .build()
    }

    private fun mimeFor(name: String): String {
        val n = name.lowercase(Locale.ROOT).substringBefore('?')
        return when {
            n.endsWith(".ass") || n.endsWith(".ssa") -> MimeTypes.TEXT_SSA
            n.endsWith(".vtt") -> MimeTypes.TEXT_VTT
            else -> MimeTypes.APPLICATION_SUBRIP
        }
    }

    private val current: Item? get() = items.getOrNull(player.currentMediaItemIndex)

    private fun updateTitle() {
        titleView.text = current?.title ?: ""
    }

    private fun say(text: String) {
        noticeView.text = text
        noticeView.visibility = View.VISIBLE
        handler.removeCallbacks(hideNotice)
        handler.postDelayed(hideNotice, 2500)
    }

    // ---------------- player events ----------------

    private val listener = object : Player.Listener {
        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            updateTitle()
            val i = player.currentMediaItemIndex
            if (i != lastIndex) {
                lastIndex = i
                retries = 0
                lastError = null
                pendingTextId = null
                NativePlayerBridge.send("item", mapOf("index" to i, "key" to (current?.key ?: "")))
            }
        }

        override fun onPlaybackStateChanged(state: Int) {
            if (state == Player.STATE_READY && !ready) {
                ready = true
                NativePlayerBridge.log("native player: ready, ${describeTracks()}")
            }
            if (state == Player.STATE_ENDED) {
                // last item finished
                finish()
            }
            sendState()
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            if (isPlaying) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                lastError = null
            }
            sendState()
        }

        override fun onTracksChanged(tracks: Tracks) {
            val pending = pendingTextId
            if (pending != null) {
                for (g in tracks.groups) {
                    if (g.type != C.TRACK_TYPE_TEXT) continue
                    for (t in 0 until g.length) {
                        if (g.getTrackFormat(t).id?.contains(pending) == true) {
                            pendingTextId = null
                            player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
                                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                                .setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, t))
                                .build()
                        }
                    }
                }
            }
            if (matchFrameRate) {
                val fps = tracks.groups.firstOrNull { it.type == C.TRACK_TYPE_VIDEO && it.isSelected }
                    ?.let { g -> (0 until g.length).firstOrNull { g.isTrackSelected(it) }?.let { g.getTrackFormat(it).frameRate } }
                if (fps != null && fps > 10f && fps != matchedFps) {
                    matchedFps = fps
                    applyFrameRate(fps)
                }
            }
        }

        override fun onPlayerError(error: PlaybackException) {
            val message = "${error.errorCodeName}: ${error.cause?.message ?: error.message}"
            NativePlayerBridge.log("native player: error $message")
            // Reopening /s/<key> renews an expired CDN link; network hiccups recover the same way.
            if (retries < 3) {
                retries++
                val pos = player.currentPosition
                say("Đang kết nối lại… ($retries)")
                handler.postDelayed({
                    if (!closing) {
                        player.seekTo(player.currentMediaItemIndex, pos)
                        player.prepare()
                        player.playWhenReady = true
                    }
                }, 1500L * retries)
                return
            }
            lastError = when (error.errorCode) {
                PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
                PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
                PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES ->
                    "Box không giải mã được định dạng video này. Thử tắt \"Trình phát Media3\" trên màn hình TV."
                PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS -> "Máy chủ / CDN từ chối link phát (link hết hạn?)."
                else -> "Lỗi phát: ${error.errorCodeName}"
            }
            say(lastError!!)
            sendState()
        }
    }

    private fun describeTracks(): String {
        val parts = ArrayList<String>()
        for (g in player.currentTracks.groups) {
            if (!g.isSelected) continue
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

    // ---------------- state for Flutter / the phone remote ----------------

    private fun sendState() {
        if (!::player.isInitialized || closing) return
        val item = current ?: return
        NativePlayerBridge.send(
            "state",
            mapOf(
                "key" to item.key,
                "index" to player.currentMediaItemIndex,
                "title" to item.title,
                "position" to player.currentPosition.coerceAtLeast(0),
                "duration" to player.duration.let { if (it == C.TIME_UNSET) 0L else it },
                "playing" to player.isPlaying,
                "buffering" to (player.playbackState == Player.STATE_BUFFERING),
                "volume" to (player.volume * 100).toDouble(),
                "audio" to tracksOf(C.TRACK_TYPE_AUDIO),
                "subs" to tracksOf(C.TRACK_TYPE_TEXT),
                "subsOff" to player.trackSelectionParameters.disabledTrackTypes.contains(C.TRACK_TYPE_TEXT),
                "error" to lastError,
            ),
        )
    }

    private fun tracksOf(type: Int): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        player.currentTracks.groups.forEachIndexed { gi, g ->
            if (g.type != type) return@forEachIndexed
            for (t in 0 until g.length) {
                if (!g.isTrackSupported(t, true)) continue
                val f = g.getTrackFormat(t)
                out += mapOf(
                    "id" to "$gi:$t",
                    "label" to label(f, type),
                    "selected" to g.isTrackSelected(t),
                    // tracks added from the server's subtitle list (the phone lists those separately)
                    "server" to (f.id?.contains("srv:") == true),
                )
            }
        }
        return out
    }

    private fun label(f: Format, type: Int): String {
        val lang = f.language?.takeIf { it.isNotEmpty() && it != "und" }?.let {
            Locale.forLanguageTag(it).getDisplayLanguage(Locale.forLanguageTag("vi")).ifEmpty { it }
        }
        val codec = when (f.sampleMimeType) {
            MimeTypes.AUDIO_AC3 -> "AC3"
            MimeTypes.AUDIO_E_AC3, MimeTypes.AUDIO_E_AC3_JOC -> "E-AC3"
            MimeTypes.AUDIO_DTS, MimeTypes.AUDIO_DTS_HD, MimeTypes.AUDIO_DTS_EXPRESS -> "DTS"
            MimeTypes.AUDIO_TRUEHD -> "TrueHD"
            MimeTypes.AUDIO_AAC -> "AAC"
            MimeTypes.AUDIO_OPUS -> "Opus"
            MimeTypes.AUDIO_FLAC -> "FLAC"
            MimeTypes.TEXT_SSA -> "ASS"
            MimeTypes.APPLICATION_SUBRIP -> "SRT"
            MimeTypes.APPLICATION_PGS -> "PGS"
            MimeTypes.TEXT_VTT -> "VTT"
            else -> null
        }
        val channels = if (type == C.TRACK_TYPE_AUDIO && f.channelCount > 0) {
            when (f.channelCount) { 1 -> "mono"; 2 -> "2.0"; 6 -> "5.1"; 8 -> "7.1"; else -> "${f.channelCount}ch" }
        } else null
        val name = f.label?.takeIf { it.isNotBlank() }
        return listOfNotNull(name ?: lang, if (name != null) lang else null, codec, channels)
            .distinct().joinToString(" · ").ifEmpty { if (type == C.TRACK_TYPE_AUDIO) "Âm thanh" else "Phụ đề" }
    }

    // ---------------- commands from Flutter ----------------

    /** Returns null when done, or a user-facing (Vietnamese) reason. */
    fun command(action: String, args: Map<*, *>): String? {
        if (closing) return "Trình phát đang đóng"
        when (action) {
            "toggle" -> if (player.isPlaying) player.pause() else player.play()
            "play" -> player.play()
            "pause" -> player.pause()
            "seek" -> player.seekTo(((args["ms"] as? Number)?.toLong() ?: 0L).coerceAtLeast(0))
            "seekBy" -> seekBy((args["ms"] as? Number)?.toLong() ?: 0L)
            "next" -> if (player.hasNextMediaItem()) player.seekToNextMediaItem()
            "prev" -> if (player.hasPreviousMediaItem()) player.seekToPreviousMediaItem()
            "volume" -> player.volume = (((args["value"] as? Number)?.toFloat() ?: 100f) / 100f).coerceIn(0f, 1f)
            "audio", "sub" -> {
                val id = args["id"] as? String ?: return "Thiếu rãnh"
                val type = if (action == "audio") C.TRACK_TYPE_AUDIO else C.TRACK_TYPE_TEXT
                if (!selectTrack(type, id)) return if (action == "audio") "Không có rãnh âm thanh này" else "Không có phụ đề này"
            }
            "subOff" -> player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true).build()
            "addSub" -> return addSubtitle(args)
            "stop" -> finish()
            else -> return "Lệnh không hỗ trợ"
        }
        sendState()
        return null
    }

    private fun seekBy(ms: Long) {
        val d = player.duration
        var to = player.currentPosition + ms
        if (to < 0) to = 0
        if (d != C.TIME_UNSET && to > d) to = d
        player.seekTo(to)
        say((if (ms >= 0) "+" else "−") + "${Math.abs(ms) / 1000}s  ${fmt(to)}")
    }

    private fun fmt(ms: Long): String {
        val s = ms / 1000
        return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
    }

    private fun selectTrack(type: Int, id: String): Boolean {
        val parts = id.split(":")
        val gi = parts.getOrNull(0)?.toIntOrNull() ?: return false
        val ti = parts.getOrNull(1)?.toIntOrNull() ?: return false
        val g = player.currentTracks.groups.getOrNull(gi) ?: return false
        if (g.type != type || ti >= g.length) return false
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(type, false)
            .setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, ti))
            .build()
        return true
    }

    /// A subtitle from the server (text saved by Flutter in the cache dir), added to the current item.
    private fun addSubtitle(args: Map<*, *>): String? {
        val path = args["path"] as? String ?: return "Thiếu phụ đề"
        val file = File(path)
        if (!file.exists() || file.parentFile?.canonicalPath?.startsWith(cacheDir.canonicalPath) != true) {
            return "Phụ đề không hợp lệ"
        }
        val id = "srv:${args["id"] as? String ?: file.name}"
        val index = player.currentMediaItemIndex
        val item = player.currentMediaItem ?: return "Chưa phát gì"
        val config = MediaItem.SubtitleConfiguration.Builder(Uri.fromFile(file))
            .setId(id)
            .setMimeType(args["mime"] as? String ?: MimeTypes.APPLICATION_SUBRIP)
            .setLanguage(args["lang"] as? String)
            .setLabel(args["label"] as? String)
            .build()
        val keep = item.localConfiguration?.subtitleConfigurations.orEmpty().filter { it.id != id }
        val pos = player.currentPosition
        pendingTextId = id
        player.replaceMediaItem(index, item.buildUpon().setSubtitleConfigurations(keep + config).build())
        if (player.currentMediaItemIndex == index && Math.abs(player.currentPosition - pos) > 2000) {
            player.seekTo(index, pos)
        }
        say("Đã bật phụ đề: ${args["label"] as? String ?: ""}")
        return null
    }

    // ---------------- keys ----------------

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val shown = view.isControllerFullyVisible
        when (event.keyCode) {
            KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_ESCAPE -> {
                if (event.action == KeyEvent.ACTION_UP) {
                    if (shown) view.hideController() else finish()
                }
                return true
            }
            // Controls hidden: left / right seek 10 s (held: keeps seeking), OK / up / down show them.
            KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> if (!shown) {
                if (event.action == KeyEvent.ACTION_DOWN) {
                    val step = if (event.repeatCount > 8) maxOf(30_000L, seekBackMs) else seekBackMs
                    seekBy(if (event.keyCode == KeyEvent.KEYCODE_DPAD_LEFT) -step else step)
                }
                return true
            }
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER,
            KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN -> if (!shown) {
                if (event.action == KeyEvent.ACTION_DOWN) view.showController()
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    /// The phone remote's keys, delivered like the real remote's.
    fun pressKey(code: Int) {
        val t = android.os.SystemClock.uptimeMillis()
        dispatchKeyEvent(KeyEvent(t, t, KeyEvent.ACTION_DOWN, code, 0))
        dispatchKeyEvent(KeyEvent(t, android.os.SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, code, 0))
    }

    // ---------------- frame-rate matching ----------------

    @Suppress("DEPRECATION")
    private fun currentDisplay(): Display? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display else windowManager.defaultDisplay

    /// A mode with the same resolution whose refresh rate is a whole multiple of the film's
    /// (23.976 → 23.976 / 47.95; 25 → 50; 29.97 → 59.94). The picture pauses while the TV switches.
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
        NativePlayerBridge.log(
            "frame rate: film %.3f fps, display %.2f Hz -> %s".format(
                Locale.ROOT, fps, current.refreshRate, target?.let { "%.2f Hz".format(Locale.ROOT, it.refreshRate) } ?: "no matching mode"
            )
        )
        if (target == null || target.modeId == current.modeId) return
        if (originalModeId == null) originalModeId = current.modeId
        val wasPlaying = player.playWhenReady
        player.playWhenReady = false
        switchMode(target.modeId) {
            // non-seamless switch: give the TV / AVR time to sync before the picture moves
            handler.postDelayed({ if (wasPlaying && !closing) player.playWhenReady = true }, 2000)
        }
    }

    private fun switchMode(modeId: Int, done: () -> Unit) {
        val dm = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val displayId = currentDisplay()?.displayId ?: Display.DEFAULT_DISPLAY
        var finished = false
        lateinit var listener: DisplayManager.DisplayListener
        val complete = {
            if (!finished) {
                finished = true
                dm.unregisterDisplayListener(listener)
                done()
            }
        }
        listener = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(id: Int) {}
            override fun onDisplayRemoved(id: Int) {}
            override fun onDisplayChanged(id: Int) {
                if (id == displayId) complete()
            }
        }
        dm.registerDisplayListener(listener, handler)
        val attrs = window.attributes
        attrs.preferredDisplayModeId = modeId
        window.attributes = attrs
        handler.postDelayed({ complete() }, 5000)
    }

    // ---------------- closing ----------------

    override fun finish() {
        if (closing || !::player.isInitialized) {
            super.finish()
            return
        }
        closing = true
        handler.removeCallbacks(tick)
        val item = current
        NativePlayerBridge.send(
            "closed",
            mapOf(
                "key" to (item?.key ?: ""),
                "index" to player.currentMediaItemIndex,
                "position" to player.currentPosition.coerceAtLeast(0),
                "duration" to player.duration.let { if (it == C.TIME_UNSET) 0L else it },
                "ended" to (player.playbackState == Player.STATE_ENDED),
            ),
        )
        player.playWhenReady = false
        // Restore the display mode while the window is still alive (switching during teardown can
        // leave pass-through soundbars / AVRs on a black screen).
        val mode = originalModeId
        if (mode != null) {
            originalModeId = null
            switchMode(mode) { finishNow() }
        } else {
            super.finish()
        }
    }

    private fun finishNow() = super.finish()

    override fun onPause() {
        super.onPause()
        if (::player.isInitialized && !closing) player.pause()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        if (::player.isInitialized) {
            if (!closing) {
                closing = true
                NativePlayerBridge.send(
                    "closed",
                    mapOf("key" to (current?.key ?: ""), "index" to player.currentMediaItemIndex,
                        "position" to player.currentPosition.coerceAtLeast(0), "duration" to 0L, "ended" to false),
                )
            }
            player.removeListener(listener)
            player.release()
        }
        if (originalModeId != null) {
            val attrs = window.attributes
            attrs.preferredDisplayModeId = 0
            window.attributes = attrs
        }
        if (NativePlayerBridge.activity === this) NativePlayerBridge.activity = null
        super.onDestroy()
    }
}
