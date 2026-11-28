package io.github.optimismbliss.torbox_strm_player

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Environment
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// "Tải về máy" trên Android: giao cho DownloadManager của hệ thống — tải chạy nền kể cả khi app đã tắt, tự tải tiếp
/// khi có mạng lại, hiện tiến độ trên thanh thông báo. File nằm trong thư mục riêng của app
/// (Android/data/<app>/files/Movies/TorBoxSTRM), không cần quyền bộ nhớ, gỡ app thì mất theo.
class SystemDownloads(private val ctx: Context) {
    private val dm: DownloadManager
        get() = ctx.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager

    private fun dir(): File = File(ctx.getExternalFilesDir(Environment.DIRECTORY_MOVIES), "TorBoxSTRM").apply { mkdirs() }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "enqueue" -> {
                    val url = call.argument<String>("url") ?: return result.error("arg", "thiếu url", null)
                    val raw = call.argument<String>("fileName") ?: "video.mkv"
                    val name = raw.replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), " ").trim().ifEmpty { "video.mkv" }.take(150)
                    val title = call.argument<String>("title") ?: name
                    val base = name.substringBeforeLast('.', name)
                    val ext = name.substringAfterLast('.', "mkv")
                    var f = File(dir(), name)
                    var i = 2
                    while (f.exists()) {
                        f = File(dir(), "$base ($i).$ext")
                        i++
                    }
                    val req = DownloadManager.Request(Uri.parse(url))
                        .setTitle(title)
                        .setDescription("TorBox STRM — tải về máy")
                        .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                        .setDestinationUri(Uri.fromFile(f))
                        .setAllowedOverMetered(true)
                        .setAllowedOverRoaming(true)
                    val id = dm.enqueue(req)
                    result.success(mapOf("id" to id, "path" to f.absolutePath))
                }
                "query" -> {
                    val ids = (call.argument<List<Number>>("ids") ?: emptyList()).map { it.toLong() }.toLongArray()
                    if (ids.isEmpty()) return result.success(emptyList<Any>())
                    val out = mutableListOf<Map<String, Any?>>()
                    dm.query(DownloadManager.Query().setFilterById(*ids)).use { c ->
                        val cId = c.getColumnIndexOrThrow(DownloadManager.COLUMN_ID)
                        val cSt = c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)
                        val cDone = c.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)
                        val cTotal = c.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
                        val cReason = c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON)
                        while (c.moveToNext()) {
                            val st = when (c.getInt(cSt)) {
                                DownloadManager.STATUS_SUCCESSFUL -> "done"
                                DownloadManager.STATUS_FAILED -> "failed"
                                DownloadManager.STATUS_PAUSED -> "paused"
                                DownloadManager.STATUS_PENDING -> "pending"
                                else -> "running"
                            }
                            out.add(
                                mapOf(
                                    "id" to c.getLong(cId),
                                    "status" to st,
                                    "done" to c.getLong(cDone),
                                    "total" to c.getLong(cTotal),
                                    "reason" to c.getInt(cReason),
                                )
                            )
                        }
                    }
                    result.success(out)
                }
                "remove" -> {
                    val ids = (call.argument<List<Number>>("ids") ?: emptyList()).map { it.toLong() }.toLongArray()
                    result.success(if (ids.isEmpty()) 0 else dm.remove(*ids))
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("download", e.message, null)
        }
    }
}
