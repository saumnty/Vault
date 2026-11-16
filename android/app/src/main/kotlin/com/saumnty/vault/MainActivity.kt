package com.saumnty.vault

import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
                    else -> result.notImplemented()
                }
            }
    }
}
