package com.cloudbridge.phone_bridge

import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * 云桥备份 PhoneBridge · P3 手机端原生层
 *
 * MethodChannel "cloudbridge/native" 提供：
 *  - 设备信息 / deep link（cloudbridge://connect）
 *  - 媒体权限申请（READ_MEDIA_* / READ_EXTERNAL_STORAGE）
 *  - MediaStore 相册：listAlbums / listPhotos / photoCreate / photoOp（删除/重命名）
 *  - SAF 目录：safPick（选择并持久化授权）/ listSafDir / safStats / safNames /
 *    safCreateFile / openRead / readChunk / writeChunk / closeWrite
 * 读句柄统一 256KB 分块（与 PC 端 P2 协议 CHUNK 一致）。
 */
class MainActivity : FlutterActivity() {

    companion object {
        const val CHANNEL = "cloudbridge/native"
        const val EVENTS = "cloudbridge/native/events"
        const val CHUNK = 256 * 1024
        const val REQ_MEDIA = 1001
        const val MIME_DIR = "vnd.android.document/directory"
    }

    /** 流句柄：读（input）或写（output）；photo 写回时带 pendingMediaUri（29+ IS_PENDING 清理）。 */
    private class StreamHandle(
        val input: InputStream? = null,
        val output: OutputStream? = null,
        val pendingMediaUri: Uri? = null,
        val photoId: String? = null,
        val name: String? = null,
        val album: String? = null,
        var written: Long = 0
    )

    private var eventSink: EventChannel.EventSink? = null
    private val handles = ConcurrentHashMap<Int, StreamHandle>()
    private val nextHandle = AtomicInteger(1)
    private val io: ExecutorService = Executors.newSingleThreadExecutor()
    private var pendingPermResult: MethodChannel.Result? = null
    private var pendingPickResult: MethodChannel.Result? = null
    private var launchUri: String? = null

    /** SAF 目录选择器（需在 activity 创建前注册）。 */
    private val pickLauncher =
        registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
            val r = pendingPickResult
            pendingPickResult = null
            if (uri == null) {
                r?.success(null)
                return@registerForActivityResult
            }
            try {
                contentResolver.takePersistableUriPermission(
                    uri, Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: Exception) {
            }
            r?.success(uri.toString())
        }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> onCall(call, result) }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                }

                override fun onCancel(args: Any?) {
                    eventSink = null
                }
            })
        launchUri = takeCloudbridgeUri(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val uri = takeCloudbridgeUri(intent)
        if (uri != null) {
            launchUri = uri
            eventSink?.success(mapOf("type" to "deeplink", "uri" to uri))
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_MEDIA) {
            val ok = grantResults.isNotEmpty() &&
                grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            pendingPermResult?.success(ok)
            pendingPermResult = null
        }
    }

    private fun takeCloudbridgeUri(intent: Intent?): String? {
        val data = intent?.data ?: return null
        return if (data.scheme == "cloudbridge") data.toString() else null
    }

    /* ================= 分发 ================= */

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "deviceInfo" -> result.success(mapOf(
                "name" to "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
                "model" to Build.MODEL,
                "android" to androidName()
            ))
            "launchUri" -> result.success(launchUri)
            "safPick" -> {
                pendingPickResult = result
                pickLauncher.launch(null)
            }
            "requestMediaPermission" -> {
                val need = when {
                    Build.VERSION.SDK_INT >= 33 -> listOf(
                        Manifest.permission.READ_MEDIA_IMAGES,
                        Manifest.permission.READ_MEDIA_VIDEO
                    )
                    Build.VERSION.SDK_INT >= 29 -> listOf(
                        Manifest.permission.READ_EXTERNAL_STORAGE
                    )
                    else -> listOf(
                        Manifest.permission.READ_EXTERNAL_STORAGE,
                        Manifest.permission.WRITE_EXTERNAL_STORAGE
                    )
                }
                val missing = need.filter {
                    ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
                }
                if (missing.isEmpty()) result.success(true)
                else {
                    pendingPermResult = result
                    ActivityCompat.requestPermissions(this, missing.toTypedArray(), REQ_MEDIA)
                }
            }
            else -> io.execute {
                try {
                    result.success(runIo(call))
                } catch (e: Exception) {
                    result.error("CB_ERROR", e.message ?: e.toString(), null)
                }
            }
        }
    }

    private fun runIo(call: MethodCall): Any? = when (call.method) {
        "listAlbums" -> listAlbums()
        "listPhotos" -> listPhotos()
        "safTreeName" -> mapOf("name" to treeName(Uri.parse(reqUri(call))))
        "safStats" -> safStats(Uri.parse(reqUri(call)), reqPath(call))
        "listSafDir" -> listSafDir(Uri.parse(reqUri(call)), reqPath(call))
        "safNames" -> safNames(Uri.parse(reqUri(call)), reqPath(call))
        "safCreateFile" -> safCreateFile(call)
        "openRead" -> openRead(call)
        "readChunk" -> readChunk(call)
        "writeChunk" -> {
            writeChunk(call)
            mapOf("ok" to true)
        }
        "closeWrite" -> closeWrite(call)
        "closeHandle" -> {
            closeHandle(call)
            mapOf("ok" to true)
        }
        "photoCreate" -> photoCreate(call)
        "photoOp" -> photoOp(call)
        else -> throw Exception("未知方法 ${call.method}")
    }

    private fun reqUri(call: MethodCall): String =
        call.argument<String>("uri") ?: throw Exception("缺少 uri")

    private fun reqPath(call: MethodCall): String = call.argument<String>("path") ?: ""

    /* ================= 通用工具 ================= */

    private fun androidName(): String = when (Build.VERSION.SDK_INT) {
        26 -> "8"
        27 -> "8.1"
        28 -> "9"
        29 -> "10"
        30 -> "11"
        31 -> "12"
        32 -> "12L"
        33 -> "13"
        34 -> "14"
        35 -> "15"
        36 -> "16"
        else -> Build.VERSION.SDK_INT.toString()
    }

    fun fmtBytes(n: Long): String = when {
        n < 1024 -> "$n B"
        n < 1024L * 1024 -> String.format(Locale.US, "%.1f KB", n / 1024.0)
        n < 1024L * 1024 * 1024 -> String.format(Locale.US, "%.1f MB", n / 1024.0 / 1024.0)
        else -> String.format(Locale.US, "%.2f GB", n / 1024.0 / 1024.0 / 1024.0)
    }

    private fun fmtDate(sec: Long): String =
        SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US).format(Date(sec * 1000))

    private fun fmtDur(ms: Long): String {
        val s = ms / 1000
        return if (s < 3600) String.format(Locale.US, "%02d:%02d", s / 60, s % 60)
        else String.format(Locale.US, "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    private fun register(h: StreamHandle): Int {
        val id = nextHandle.getAndIncrement()
        handles[id] = h
        return id
    }

    /* ================= MediaStore 相册 ================= */

    private fun listAlbums(): Map<String, Any> {
        val albums = LinkedHashMap<String, MutableMap<String, Any?>>()
        // 图片
        queryBuckets(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "i") { m ->
            albums[m["id"] as String] = m
        }
        // 视频
        queryBuckets(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, "v") { m ->
            albums[m["id"] as String] = m
        }
        var total = 0L
        var totalBytes = 0L
        for (m in albums.values) {
            total += m["count"] as Long
            totalBytes += m["sizeBytes"] as Long
        }
        val list = mutableListOf<Map<String, Any?>>()
        list.add(mapOf(
            "id" to "all", "name" to "全部",
            "count" to total, "sizeBytes" to totalBytes, "size" to fmtBytes(totalBytes)
        ))
        for (m in albums.values) {
            list.add(m + ("size" to fmtBytes(m["sizeBytes"] as Long)))
        }
        return mapOf("albums" to list)
    }

    private fun queryBuckets(
        uri: Uri,
        prefix: String,
        add: (Map<String, Any?>) -> Unit
    ) {
        contentResolver.query(
            uri,
            arrayOf(
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.BUCKET_ID,
                MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
                MediaStore.MediaColumns.SIZE
            ),
            null, null, null
        )?.use { c ->
            val iId = c.getColumnIndex(MediaStore.MediaColumns._ID)
            val iBucket = c.getColumnIndex(MediaStore.MediaColumns.BUCKET_ID)
            val iName = c.getColumnIndex(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
            val iSize = c.getColumnIndex(MediaStore.MediaColumns.SIZE)
            val acc = HashMap<String, MutableMap<String, Any?>>()
            while (c.moveToNext()) {
                val bucketId = c.getLong(iBucket)
                val key = "$prefix$bucketId"
                val m = acc.getOrPut(key) {
                    mutableMapOf<String, Any?>(
                        "id" to key,
                        "name" to (c.getString(iName) ?: "相册"),
                        "count" to 0L,
                        "sizeBytes" to 0L
                    )
                }
                m["count"] = (m["count"] as Long) + 1
                m["sizeBytes"] = (m["sizeBytes"] as Long) + c.getLong(iSize)
            }
            acc.values.forEach { add(it) }
        }
    }

    private fun listPhotos(): Map<String, Any> {
        val photos = mutableListOf<Map<String, Any?>>()
        // 图片
        contentResolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            arrayOf(
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.SIZE,
                MediaStore.MediaColumns.BUCKET_ID,
                MediaStore.MediaColumns.DATE_ADDED
            ),
            null, null, MediaStore.MediaColumns.DATE_ADDED + " DESC"
        )?.use { c ->
            while (c.moveToNext()) {
                photos.add(mapOf(
                    "id" to "i" + c.getLong(0),
                    "name" to (c.getString(1) ?: "图片"),
                    "type" to "image",
                    "size" to fmtBytes(c.getLong(2)),
                    "sizeBytes" to c.getLong(2),
                    "time" to fmtDate(c.getLong(4)),
                    "album" to "i" + c.getLong(3)
                ))
            }
        }
        // 视频
        contentResolver.query(
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            arrayOf(
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.SIZE,
                MediaStore.MediaColumns.BUCKET_ID,
                MediaStore.MediaColumns.DATE_ADDED,
                MediaStore.Video.Media.DURATION
            ),
            null, null, MediaStore.MediaColumns.DATE_ADDED + " DESC"
        )?.use { c ->
            while (c.moveToNext()) {
                photos.add(mapOf(
                    "id" to "v" + c.getLong(0),
                    "name" to (c.getString(1) ?: "视频"),
                    "type" to "video",
                    "size" to fmtBytes(c.getLong(2)),
                    "sizeBytes" to c.getLong(2),
                    "time" to fmtDate(c.getLong(4)),
                    "album" to "v" + c.getLong(3),
                    "duration" to fmtDur(c.getLong(5))
                ))
            }
        }
        return mapOf("photos" to photos)
    }

    /** 相册 id（"i12"/"v34"/"all"/"video"）→ 相册显示名。 */
    private fun resolveAlbumName(album: String?): String {
        if (album == null || album.isEmpty() || album == "all" || album == "video") return "云桥备份"
        val m = Regex("^(i|v)(\\d+)$").find(album) ?: return "云桥备份"
        val uri = if (m.groupValues[1] == "v")
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        else
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        contentResolver.query(
            uri,
            arrayOf(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME),
            "${MediaStore.MediaColumns.BUCKET_ID} = ?",
            arrayOf(m.groupValues[2]),
            null
        )?.use { c ->
            if (c.moveToFirst()) return c.getString(0) ?: "云桥备份"
        }
        return "云桥备份"
    }

    private fun photoCreate(call: MethodCall): Map<String, Any> {
        val album = call.argument<String>("album") ?: "all"
        val name = call.argument<String>("name") ?: "photo.jpg"
        val mime = call.argument<String>("mime") ?: "image/jpeg"
        val bucket = resolveAlbumName(album)
        return if (Build.VERSION.SDK_INT >= 29) {
            val cv = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, mime.ifEmpty { "image/jpeg" })
                put(MediaStore.Images.Media.BUCKET_DISPLAY_NAME, bucket)
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/$bucket/")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, cv)
                ?: throw Exception("写入相册失败")
            val os = contentResolver.openOutputStream(uri) ?: throw Exception("打开写入流失败")
            val h = register(StreamHandle(
                output = os,
                pendingMediaUri = uri,
                photoId = "i" + uri.lastPathSegment,
                name = name,
                album = album
            ))
            mapOf("handle" to h)
        } else {
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), bucket)
            if (!dir.exists() && !dir.mkdirs()) throw Exception("创建相册目录失败")
            val os = FileOutputStream(File(dir, name))
            val h = register(StreamHandle(output = os, name = name, album = album))
            mapOf("handle" to h)
        }
    }

    private fun collectionOf(id: String): Uri =
        if (id.startsWith("v")) MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        else MediaStore.Images.Media.EXTERNAL_CONTENT_URI

    private fun photoOp(call: MethodCall): Map<String, Any> {
        val op = call.argument<String>("op") ?: return mapOf("ok" to false, "error" to "缺少 op")
        val ids = call.argument<List<String>>("ids") ?: emptyList()
        return when (op) {
            "del" -> {
                val imgIds = ids.filter { !it.startsWith("v") }
                val vidIds = ids.filter { it.startsWith("v") }
                var failed = 0
                if (imgIds.isNotEmpty()) failed += deleteMedia(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "i", imgIds)
                if (vidIds.isNotEmpty()) failed += deleteMedia(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, "v", vidIds)
                mapOf("ok" to true, "failed" to failed)
            }
            "rename" -> {
                val id = ids.firstOrNull()
                val newName = call.argument<String>("name")
                if (id == null || newName.isNullOrEmpty()) return mapOf("ok" to false, "error" to "参数缺失")
                if (renameMedia(id, newName)) {
                    mapOf("ok" to true, "photo" to mapOf("id" to id, "name" to newName))
                } else {
                    mapOf("ok" to false, "error" to "重命名失败")
                }
            }
            else -> mapOf("ok" to false, "error" to "未知操作 $op")
        }
    }

    private fun deleteMedia(uri: Uri, prefix: String, ids: List<String>): Int {
        val numIds = ids.map { it.removePrefix(prefix) }
        if (Build.VERSION.SDK_INT >= 29) {
            val sel = "${MediaStore.MediaColumns._ID} IN (${numIds.joinToString(",")})"
            val n = contentResolver.delete(uri, sel, null)
            return numIds.size - n
        }
        val want = numIds.toSet()
        var failed = 0
        contentResolver.query(uri, arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DATA), null, null, null)
            ?.use { c ->
                while (c.moveToNext()) {
                    if (want.contains(c.getLong(0).toString())) {
                        val f = File(c.getString(1))
                        if (f.exists() && !f.delete()) failed++
                    }
                }
            }
        return failed
    }

    private fun renameMedia(id: String, name: String): Boolean {
        val col = collectionOf(id)
        val numId = id.removePrefix("i").removePrefix("v")
        return if (Build.VERSION.SDK_INT >= 29) {
            val uri = Uri.withAppendedPath(col, numId)
            val exists = contentResolver.query(uri, null, null, null, null)
                ?.use { it.moveToFirst() } == true
            if (!exists) return false
            val cv1 = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 1) }
            contentResolver.update(uri, cv1, null, null)
            val cv2 = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            contentResolver.update(uri, cv2, null, null) > 0
        } else {
            var src: File? = null
            contentResolver.query(col, arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DATA), null, null, null)
                ?.use { c ->
                    while (c.moveToNext()) {
                        if (c.getLong(0).toString() == numId) {
                            src = File(c.getString(1))
                            break
                        }
                    }
                }
            if (src == null || !src.exists()) return false
            val dst = File(src.parentFile, name)
            dst.exists() || src.renameTo(dst)
        }
    }

    private fun mediaSize(col: Uri, numId: String): Long {
        contentResolver.query(
            Uri.withAppendedPath(col, numId),
            arrayOf(MediaStore.MediaColumns.SIZE), null, null, null
        )?.use { c ->
            if (c.moveToFirst()) return c.getLong(0)
        }
        return -1L
    }

    /* ================= SAF 目录 ================= */

    private fun treeName(treeUri: Uri): String {
        contentResolver.query(treeUri, arrayOf(DocumentsContract.Document.DISPLAY_NAME), null, null, null)
            ?.use { c ->
                if (c.moveToFirst()) return c.getString(0) ?: "目录"
            }
        return "目录"
    }

    private fun treeDocPath(treeUri: Uri, path: String): String {
        val base = DocumentsContract.getTreeDocumentId(treeUri)
        return if (path.isEmpty()) base else "$base/$path"
    }

    private fun docUri(treeUri: Uri, path: String): Uri =
        DocumentsContract.buildDocumentUriUsingPath(treeUri, treeDocPath(treeUri, path))

    private fun listSafDir(treeUri: Uri, path: String): Map<String, Any> {
        val files = mutableListOf<Map<String, Any?>>()
        val dirs = mutableListOf<Map<String, Any?>>()
        contentResolver.query(
            docUri(treeUri, path),
            arrayOf(
                DocumentsContract.Document.DISPLAY_NAME,
                DocumentsContract.Document.MIME_TYPE,
                DocumentsContract.Document.SIZE,
                DocumentsContract.Document.DATE_MODIFIED
            ),
            null, null, null
        )?.use { c ->
            while (c.moveToNext()) {
                val name = c.getString(0) ?: continue
                val mime = c.getString(1)
                if (mime == MIME_DIR) {
                    dirs.add(mapOf("name" to name))
                } else {
                    files.add(mapOf("name" to name, "size" to c.getLong(2), "mtime" to c.getLong(3)))
                }
            }
        }
        return mapOf("files" to files, "dirs" to dirs)
    }

    private fun safStats(treeUri: Uri, path: String): Map<String, Any> {
        var count = 0L
        var bytes = 0L
        contentResolver.query(
            docUri(treeUri, path),
            arrayOf(DocumentsContract.Document.MIME_TYPE, DocumentsContract.Document.SIZE),
            null, null, null
        )?.use { c ->
            while (c.moveToNext()) {
                if (c.getString(0) != MIME_DIR) {
                    count++
                    bytes += c.getLong(1)
                }
            }
        }
        return mapOf("count" to count, "bytes" to bytes)
    }

    private fun safNames(treeUri: Uri, path: String): List<String> {
        val names = mutableListOf<String>()
        contentResolver.query(
            docUri(treeUri, path),
            arrayOf(DocumentsContract.Document.DISPLAY_NAME, DocumentsContract.Document.MIME_TYPE),
            null, null, null
        )?.use { c ->
            while (c.moveToNext()) {
                if (c.getString(1) != MIME_DIR) {
                    val n = c.getString(0)
                    if (n != null) names.add(n)
                }
            }
        }
        return names
    }

    private fun safCreateFile(call: MethodCall): Map<String, Any> {
        val treeUri = Uri.parse(reqUri(call))
        val path = reqPath(call)
        val name = call.argument<String>("name") ?: throw Exception("缺少 name")
        val mime = (call.argument<String>("mime") ?: "").ifEmpty { "application/octet-stream" }
        val doc = contentResolver.createDocument(docUri(treeUri, path), mime, name)
            ?: throw Exception("创建文件失败")
        val os = contentResolver.openOutputStream(doc) ?: throw Exception("打开写入流失败")
        val h = register(StreamHandle(output = os, name = name))
        return mapOf("handle" to h)
    }

    private fun docSize(u: Uri): Long {
        contentResolver.query(
            u, arrayOf(DocumentsContract.Document.SIZE), null, null, null
        )?.use { c ->
            if (c.moveToFirst()) return c.getLong(0)
        }
        return -1L
    }

    private fun openRead(call: MethodCall): Map<String, Any> {
        val kind = call.argument<String>("kind") ?: throw Exception("缺少 kind")
        val (uri, total) = if (kind == "photo") {
            val ref = call.argument<String>("ref") ?: throw Exception("缺少 ref")
            val col = collectionOf(ref)
            val u = Uri.withAppendedPath(col, ref.removePrefix("i").removePrefix("v"))
            u to mediaSize(col, ref.removePrefix("i").removePrefix("v"))
        } else {
            val treeUri = Uri.parse(reqUri(call))
            val u = docUri(treeUri, reqPath(call))
            u to docSize(u)
        }
        val is = contentResolver.openInputStream(uri) ?: throw Exception("打开读取流失败")
        val h = register(StreamHandle(input = is))
        return mapOf("handle" to h, "total" to total)
    }

    private fun readChunk(call: MethodCall): List<Int>? {
        val handle = call.argument<Int>("handle") ?: throw Exception("缺少 handle")
        val h = handles[handle] ?: throw Exception("无效句柄")
        val is = h.input ?: throw Exception("非读句柄")
        val buf = ByteArray(CHUNK)
        val n = is.read(buf)
        if (n < 0) return null
        return buf.copyOf(n).map { it.toInt() }
    }

    private fun writeChunk(call: MethodCall) {
        val handle = call.argument<Int>("handle") ?: throw Exception("缺少 handle")
        val h = handles[handle] ?: throw Exception("无效句柄")
        val os = h.output ?: throw Exception("非写句柄")
        val bytes = call.argument<List<Int>>("bytes") ?: emptyList()
        os.write(bytes.toByteArray { it.toByte() })
        h.written += bytes.size
    }

    private fun closeWrite(call: MethodCall): Map<String, Any> {
        val handle = call.argument<Int>("handle") ?: throw Exception("缺少 handle")
        val h = handles.remove(handle) ?: return mapOf("ok" to true)
        try {
            h.output?.flush()
            h.output?.close()
        } catch (_: Exception) {
        }
        val out = mutableMapOf<String, Any?>(
            "ok" to true,
            "sizeBytes" to h.written
        )
        if (h.pendingMediaUri != null) {
            val cv = ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }
            contentResolver.update(h.pendingMediaUri, cv, null, null)
            out["photo"] = mapOf(
                "id" to h.photoId,
                "name" to h.name,
                "album" to h.album,
                "type" to "image",
                "sizeBytes" to h.written,
                "size" to fmtBytes(h.written)
            )
        }
        return out
    }

    private fun closeHandle(call: MethodCall) {
        val handle = call.argument<Int>("handle") ?: return
        val h = handles.remove(handle) ?: return
        try {
            h.input?.close()
        } catch (_: Exception) {
        }
    }
}
