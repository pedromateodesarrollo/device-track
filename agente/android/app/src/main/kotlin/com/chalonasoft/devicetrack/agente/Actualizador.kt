package com.chalonasoft.devicetrack.agente

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.IntentCompat
import com.chalonasoft.devicetrack.comun.Almacen
import com.chalonasoft.devicetrack.comun.Lectura
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * El agente se actualiza solo con apk-server (por defecto https://apk.chalonasoft.com), como
 * trackme: pregunta como mucho cada hora después de un reporte, baja con Wi-Fi
 * y desde Android 12 instala sin preguntar si alguien le dio una vez «instalar
 * apps desconocidas» (a mano, o por StageNow/MDM en una flota de Zebra). Si
 * Android pide confirmar, sale una notificación.
 *
 * Así una versión nueva llega a todos los equipos sin ir uno por uno.
 */
object Actualizador {
    // De build.gradle.kts (devicetrack.apkServer / devicetrack.apkApp).
    private val HUB = BuildConfig.APK_SERVER.trimEnd('/')
    private val APP = BuildConfig.APK_APP
    private const val CADA_MS = 3_600_000L
    private const val ID_AVISO = 3

    private val enCurso = AtomicBoolean(false)

    fun quizas(context: Context) {
        if (HUB.isEmpty()) return // compilado sin servidor de actualizaciones
        val p = context.getSharedPreferences("actualizacion", Context.MODE_PRIVATE)
        if (System.currentTimeMillis() - p.getLong("ultimo", 0) < CADA_MS) return
        revisar(context, manual = false)
    }

    /** [manual]: baja aunque sea con datos móviles. */
    fun revisar(context: Context, manual: Boolean) {
        if (!enCurso.compareAndSet(false, true)) return
        val app = context.applicationContext
        Thread {
            try {
                val disponible = consultar(app)
                app.getSharedPreferences("actualizacion", Context.MODE_PRIVATE).edit()
                    .putLong("ultimo", System.currentTimeMillis()).apply()
                if (disponible != null) {
                    val (version, url) = disponible
                    val medido = app.getSystemService(ConnectivityManager::class.java).isActiveNetworkMetered
                    if (manual || !medido) instalar(app, descargar(app, url, version), version)
                }
            } catch (e: Exception) {
                Log.w("devicetrack", "Actualización: ${e.message}")
            } finally {
                enCurso.set(false)
            }
        }.start()
    }

    private fun clave(context: Context): String {
        val p = context.getSharedPreferences("actualizacion", Context.MODE_PRIVATE)
        p.getString("instalacion", null)?.let { return it }
        val nueva = UUID.randomUUID().toString().replace("-", "")
        p.edit().putString("instalacion", nueva).apply()
        return nueva
    }

    /** (versión, URL del APK) si hay una más nueva. Cada consulta anota el equipo en apk-server. */
    @SuppressLint("HardwareIds")
    private fun consultar(context: Context): Pair<String, String>? {
        val c = URL("$HUB/v1/apps/$APP/consulta").openConnection() as HttpURLConnection
        try {
            c.requestMethod = "POST"
            c.connectTimeout = 20_000
            c.readTimeout = 30_000
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/json")
            val a = Almacen(context)
            val f = Lectura.fuente(context, "agente")
            val cuerpo = JSONObject()
                .put("build", f.optLong("build"))
                .put("version", f.optString("version"))
                .put("instalacion", clave(context))
                .put("huella", Lectura.huella(context))
                .put("modelo", Build.MODEL)
                .put("fabricante", Build.MANUFACTURER)
                .put("android", Build.VERSION.SDK_INT)
                .put(
                    "contexto",
                    JSONObject()
                        .put("equipo", a.equipoNombre)
                        .put("hub", runCatching { Uri.parse(a.hub).host }.getOrNull() ?: ""),
                )
            c.outputStream.use { it.write(cuerpo.toString().toByteArray()) }
            if (c.responseCode != 200) return null
            val r = JSONObject(c.inputStream.bufferedReader().readText())
            if (!r.optBoolean("actualizar")) return null
            val v = r.optJSONObject("version") ?: return null
            val url = v.optString("url").ifEmpty { "$HUB${v.optString("ruta")}" }
            return v.optString("version") to url
        } finally {
            c.disconnect()
        }
    }

    /** Baja a un .part y renombra al final: un APK con nombre siempre está completo. */
    private fun descargar(context: Context, url: String, version: String): File {
        val dir = File(context.cacheDir, "actualizacion").apply { mkdirs() }
        val destino = File(dir, "devicetrack_$version.apk")
        dir.listFiles()?.filter { it.name != destino.name }?.forEach { it.delete() }
        if (destino.exists()) return destino
        val parcial = File(dir, "${destino.name}.part")
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            c.connectTimeout = 20_000
            c.readTimeout = 60_000
            if (c.responseCode != 200) throw IllegalStateException("Descarga HTTP ${c.responseCode}")
            c.inputStream.use { e -> parcial.outputStream().use { s -> e.copyTo(s, 64 * 1024) } }
            val total = c.contentLengthLong
            if (total > 0 && parcial.length() != total) throw IllegalStateException("Descarga incompleta")
            parcial.renameTo(destino)
            return destino
        } finally {
            c.disconnect()
            if (parcial.exists()) parcial.delete()
        }
    }

    private fun instalar(context: Context, apk: File, version: String) {
        if (Build.VERSION.SDK_INT >= 26 && !context.packageManager.canRequestPackageInstalls()) {
            Log.i("devicetrack", "Hay versión $version pero falta «instalar apps desconocidas»")
            return
        }
        val instalador = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            if (Build.VERSION.SDK_INT >= 31) {
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
        }
        val id = instalador.createSession(params)
        instalador.openSession(id).use { sesion ->
            sesion.openWrite("devicetrack.apk", 0, apk.length()).use { salida ->
                apk.inputStream().use { it.copyTo(salida) }
                sesion.fsync(salida)
            }
            val i = Intent(context, InstalacionReceiver::class.java)
                .setAction(InstalacionReceiver.ACCION)
                .putExtra("version", version)
            // MUTABLE: el instalador del sistema le agrega el resultado.
            val pi = PendingIntent.getBroadcast(context, id, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
            sesion.commit(pi.intentSender)
        }
    }

    internal fun resultado(context: Context, intent: Intent) {
        val version = intent.getStringExtra("version") ?: ""
        val estado = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        Log.i("devicetrack", "Instalación de $version: estado $estado")
        when (estado) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                // Android pide confirmar: la primera actualización de un agente que
                // se instaló a mano (el instalador de registro no es el agente), o
                // Android 11 o menos. Después de esa, las demás van sin preguntar.
                val confirmar = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_INTENT, Intent::class.java)
                if (confirmar == null) {
                    Log.w("devicetrack", "Android pide confirmar la instalación pero no mandó la pantalla")
                    return
                }
                confirmar.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                val pi = PendingIntent.getActivity(context, 7, confirmar, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                Avisos.publicar(
                    context, ID_AVISO,
                    NotificationCompat.Builder(context, "mensajes")
                        .setSmallIcon(R.drawable.ic_stat_devicetrack)
                        .setContentTitle("Hay una versión nueva de device-track ($version)")
                        .setContentText("Toca para instalarla.")
                        .setAutoCancel(true)
                        .setContentIntent(pi)
                        .build(),
                )
            }
            PackageInstaller.STATUS_SUCCESS -> Log.i("devicetrack", "Actualizado a $version")
            else -> Log.w("devicetrack", "La instalación de $version falló: ${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)}")
        }
    }
}

class InstalacionReceiver : BroadcastReceiver() {
    companion object {
        const val ACCION = "com.chalonasoft.devicetrack.INSTALACION"
    }

    override fun onReceive(context: Context, intent: Intent) = Actualizador.resultado(context, intent)
}
