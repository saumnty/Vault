package com.saumnty.vault

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Bundle
import android.os.StatFs
import android.os.SystemClock
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.concurrent.Executors

class MainActivity : FlutterFragmentActivity() {
    // v2 fase 6: selector de documentos propio (sin copia en claro a cache).
    private val pickerIo = Executors.newSingleThreadExecutor()
    private val openDocs = HashMap<Int, InputStream>()
    private var nextHandle = 1
    private var pendingPick: MethodChannel.Result? = null

    companion object {
        private const val REQ_OPEN_DOCUMENT = 4711
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // F7: protegido por defecto desde antes de dibujar el primer frame
        // (capturas, grabación y miniatura en recientes). Dart lo apaga en el
        // arranque solo si la preferencia "Proteger pantalla" está desactivada.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
        super.onCreate(savedInstanceState)
        // S-21: sin miniatura de la app en "recientes" (Android 13+).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            setRecentsScreenshotEnabled(false)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vault/picker")
            .setMethodCallHandler { call, result -> handlePicker(call, result) }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vault/security")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSecure" -> {
                        val secure = call.argument<Boolean>("secure") ?: true
                        runOnUiThread {
                            if (secure) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            }
                            result.success(null)
                        }
                    }
                    // S-07: reloj monotonico (no depende de la hora de pared) y
                    // contador de arranques para el retraso del PIN.
                    "monotonic" -> {
                        val boot = try {
                            Settings.Global.getInt(contentResolver, Settings.Global.BOOT_COUNT, -1)
                        } catch (e: Exception) {
                            -1
                        }
                        result.success(
                            mapOf(
                                "boot" to boot.toLong(),
                                "elapsedMs" to SystemClock.elapsedRealtime()
                            )
                        )
                    }
                    // Espacio libre (bytes) del almacenamiento de la app: lo usa el
                    // cambio de cuenta para avisar antes de bajar todo.
                    "freeSpace" -> {
                        val free = try {
                            StatFs(filesDir.path).availableBytes
                        } catch (e: Exception) {
                            -1L
                        }
                        result.success(if (free >= 0) free else null)
                    }
                    // Miniatura de un video LOCAL (fotograma central, JPEG con
                    // lado maximo `size`). Se hace aqui (y no con video_compress,
                    // que devuelve el fotograma a resolucion completa y no
                    // responde si falla). Devuelve null si no se pudo.
                    "videoThumbnail" -> {
                        val path = call.argument<String>("path")
                        val size = call.argument<Int>("size") ?: 256
                        if (path == null) {
                            result.error("bad_args", "path requerido", null)
                        } else {
                            Thread {
                                val bytes = try {
                                    videoFrameJpeg(path, size)
                                } catch (e: Exception) {
                                    null
                                }
                                runOnUiThread { result.success(bytes) }
                            }.start()
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ------------------------------------------------------------ selector
    // ACTION_OPEN_DOCUMENT + lectura por trozos del content:// (nada se copia
    // al disco de la app). Sin logs: ni nombres ni URIs.
    private fun handlePicker(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> {
                if (pendingPick != null) {
                    result.error("busy", "selector ya abierto", null)
                    return
                }
                pendingPick = result
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                }
                try {
                    startActivityForResult(intent, REQ_OPEN_DOCUMENT)
                } catch (e: Exception) {
                    pendingPick = null
                    result.error("no_picker", "sin selector de documentos", null)
                }
            }
            "read" -> {
                val handle = call.argument<Int>("handle") ?: -1
                val length = (call.argument<Int>("length") ?: 0).coerceIn(0, 4 shl 20)
                pickerIo.execute {
                    val stream = synchronized(openDocs) { openDocs[handle] }
                    try {
                        if (stream == null) {
                            runOnUiThread { result.error("closed", "documento cerrado", null) }
                            return@execute
                        }
                        val buf = ByteArray(length)
                        var filled = 0
                        while (filled < length) {
                            val n = stream.read(buf, filled, length - filled)
                            if (n < 0) break
                            filled += n
                        }
                        val out = if (filled == length) buf else buf.copyOf(filled)
                        runOnUiThread { result.success(out) }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("io", "lectura fallida", null) }
                    }
                }
            }
            "close" -> {
                val handle = call.argument<Int>("handle") ?: -1
                pickerIo.execute {
                    val stream = synchronized(openDocs) { openDocs.remove(handle) }
                    try {
                        stream?.close()
                    } catch (e: Exception) {
                        // ignorado
                    }
                    runOnUiThread { result.success(null) }
                }
            }
            else -> result.notImplemented()
        }
    }

    @Deprecated("API clásica; suficiente para un único selector")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_OPEN_DOCUMENT) return
        val result = pendingPick ?: return
        pendingPick = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        pickerIo.execute {
            try {
                var name = "archivo"
                var size: Long = -1
                contentResolver.query(
                    uri,
                    arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                    null, null, null
                )?.use { c ->
                    if (c.moveToFirst()) {
                        val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        val si = c.getColumnIndex(OpenableColumns.SIZE)
                        if (ni >= 0 && !c.isNull(ni)) name = c.getString(ni)
                        if (si >= 0 && !c.isNull(si)) size = c.getLong(si)
                    }
                }
                val stream = contentResolver.openInputStream(uri)
                    ?: throw IllegalStateException("sin flujo")
                val handle = synchronized(openDocs) {
                    val h = nextHandle++
                    openDocs[h] = stream
                    h
                }
                val reply = mapOf("handle" to handle, "name" to name, "size" to size)
                runOnUiThread { result.success(reply) }
            } catch (e: Exception) {
                runOnUiThread { result.error("open", "no se pudo abrir", null) }
            }
        }
    }

    override fun onDestroy() {
        synchronized(openDocs) {
            for (s in openDocs.values) {
                try { s.close() } catch (e: Exception) { }
            }
            openDocs.clear()
        }
        super.onDestroy()
    }

    private fun videoFrameJpeg(path: String, maxSide: Int): ByteArray? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val durationMs = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
            // Fotograma a mitad del video (en microsegundos); si falla, el primero.
            val frame = retriever.getFrameAtTime(
                durationMs * 500L,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            ) ?: retriever.getFrameAtTime(0) ?: return null
            val scale = maxSide.toFloat() / maxOf(frame.width, frame.height)
            val bitmap = if (scale < 1f) {
                Bitmap.createScaledBitmap(
                    frame,
                    maxOf(1, (frame.width * scale).toInt()),
                    maxOf(1, (frame.height * scale).toInt()),
                    true
                )
            } else {
                frame
            }
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, 80, out)
            return out.toByteArray()
        } finally {
            try {
                retriever.release()
            } catch (e: Exception) {
                // ignorado
            }
        }
    }
}
