package com.chalonasoft.devicetrack.panel

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Lo poco que la app le pide a Android y que no merece un paquete aparte: la
 * versión instalada, abrir una ubicación en la app de mapas (o un enlace en el
 * navegador) y compartir un texto. Son diez líneas cada una; un paquete por
 * cada cosa serían tres dependencias más que mantener.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "device_track_panel/sistema")
            .setMethodCallHandler { llamada, resultado ->
                when (llamada.method) {
                    "version" -> resultado.success(version())
                    "abrir" -> resultado.success(abrir(llamada.argument<String>("url") ?: ""))
                    "compartir" -> {
                        compartir(
                            llamada.argument<String>("texto") ?: "",
                            llamada.argument<String>("asunto"),
                            llamada.argument<String>("titulo") ?: "Compartir",
                        )
                        resultado.success(true)
                    }
                    else -> resultado.notImplemented()
                }
            }
    }

    private fun version(): Map<String, Any?> {
        val info = if (Build.VERSION.SDK_INT >= 33) {
            packageManager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(packageName, 0)
        }
        val build = if (Build.VERSION.SDK_INT >= 28) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        return mapOf("version" to info.versionName, "build" to build, "paquete" to packageName)
    }

    /**
     * Solo mapas y web: lo que pide la app (`geo:` para la ubicación de un
     * equipo, `https:` para la atribución de OpenStreetMap). Cualquier otro
     * esquema se rechaza aquí aunque llegara a pedirse. `false` si ninguna app
     * lo abre.
     */
    private fun abrir(url: String): Boolean {
        val uri = Uri.parse(url)
        if (uri.scheme !in setOf("geo", "https", "http")) return false
        return try {
            startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    private fun compartir(texto: String, asunto: String?, titulo: String) {
        val intento = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, texto)
            if (!asunto.isNullOrBlank()) putExtra(Intent.EXTRA_SUBJECT, asunto)
        }
        startActivity(Intent.createChooser(intento, titulo))
    }
}
