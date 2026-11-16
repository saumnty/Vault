package com.saumnty.vault

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Bundle
import android.os.StatFs
import android.os.SystemClock
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterFragmentActivity() {
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
