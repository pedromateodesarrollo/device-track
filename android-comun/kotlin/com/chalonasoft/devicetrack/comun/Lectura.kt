package com.chalonasoft.devicetrack.comun

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.Looper
import android.os.StatFs
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Lo que el equipo dice de sí mismo. Todo se lee sin pedir nada a la persona,
 * salvo el nombre de la red Wi-Fi (Android lo da solo con permiso de
 * ubicación) y la lista de apps (pide QUERY_ALL_PACKAGES en el manifiesto).
 */
object Lectura {
    /**
     * El ANDROID_ID. Sobrevive a desinstalar y reinstalar, y es el mismo para
     * todas las apps firmadas con la misma llave: con él el hub junta en un
     * solo equipo al agente y a las apps que corren en el mismo teléfono.
     */
    @SuppressLint("HardwareIds")
    fun huella(context: Context): String =
        Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID) ?: ""

    /** Modelo, fabricante y Android. La serie solo si el sistema la da. */
    fun equipo(context: Context): JSONObject = JSONObject()
        .put("modelo", Build.MODEL ?: "")
        .put("fabricante", Build.MANUFACTURER ?: "")
        .put("android", Build.VERSION.SDK_INT)
        .apply { serie(context)?.let { put("serie", it) } }

    /**
     * Android 10 cerró el número de serie a las apps comunes. Las Zebra lo
     * publican por su proveedor OEMInfo (con el permiso que el administrador
     * le dé por StageNow); si no está, no hay serie y se junta por huella.
     */
    private fun serie(context: Context): String? = try {
        context.contentResolver.query(
            android.net.Uri.parse("content://oem_info/oem.zebra.secure/build_serial"),
            null, null, null, null,
        )?.use { c -> if (c.moveToFirst()) c.getString(0)?.takeIf { it.isNotBlank() } else null }
    } catch (_: Exception) {
        null
    }

    /** Batería, si está cargando, la red y el espacio libre. */
    fun estado(context: Context): JSONObject {
        val bm = context.getSystemService(BatteryManager::class.java)
        val o = JSONObject()
        val nivel = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
        if (nivel in 0..100) o.put("bateria", nivel)
        if (bm != null) o.put("cargando", bm.isCharging)
        o.put("red", red(context))
        try {
            val fs = StatFs(Environment.getDataDirectory().path)
            o.put("almacenamiento", JSONObject().put("libre", fs.availableBytes).put("total", fs.totalBytes))
        } catch (_: Exception) {
        }
        return o
    }

    @SuppressLint("MissingPermission")
    fun red(context: Context): JSONObject {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val caps = try {
            cm?.getNetworkCapabilities(cm.activeNetwork)
        } catch (_: SecurityException) {
            null
        }
        val r = JSONObject()
        when {
            caps == null -> r.put("tipo", "ninguna")
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> {
                r.put("tipo", "wifi")
                ssid(context, caps)?.let { r.put("ssid", it) }
            }
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> r.put("tipo", "datos")
            else -> r.put("tipo", "otra")
        }
        return r
    }

    /**
     * El nombre de la red. Sin permiso de ubicación, Android devuelve
     * «<unknown ssid>». Desde Android 12, además, las capacidades de la red
     * activa llegan con el nombre tapado: hay que pedirlas con
     * FLAG_INCLUDE_LOCATION_INFO, en un callback (hasta 2 s, y nunca desde el
     * hilo principal).
     */
    @Suppress("DEPRECATION")
    @SuppressLint("MissingPermission")
    private fun ssid(context: Context, caps: NetworkCapabilities): String? {
        var info = if (Build.VERSION.SDK_INT >= 29) caps.transportInfo as? WifiInfo else null
        if (Build.VERSION.SDK_INT >= 31 && Looper.myLooper() != Looper.getMainLooper()) {
            conUbicacion(context)?.let { info = it }
        }
        val crudo = info?.ssid ?: try {
            context.applicationContext.getSystemService(WifiManager::class.java)?.connectionInfo?.ssid
        } catch (_: Exception) {
            null
        }
        val limpio = crudo?.trim('"')
        return if (limpio.isNullOrBlank() || limpio == "<unknown ssid>") null else limpio
    }

    @SuppressLint("MissingPermission")
    private fun conUbicacion(context: Context): WifiInfo? {
        if (Build.VERSION.SDK_INT < 31) return null
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return null
        val encontrado = AtomicReference<WifiInfo?>(null)
        val listo = CountDownLatch(1)
        val cb = object : ConnectivityManager.NetworkCallback(ConnectivityManager.NetworkCallback.FLAG_INCLUDE_LOCATION_INFO) {
            override fun onCapabilitiesChanged(network: Network, c: NetworkCapabilities) {
                (c.transportInfo as? WifiInfo)?.let {
                    encontrado.set(it)
                    listo.countDown()
                }
            }
        }
        return try {
            cm.registerNetworkCallback(
                NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(),
                cb,
            )
            listo.await(2, TimeUnit.SECONDS)
            encontrado.get()
        } catch (_: Exception) {
            null
        } finally {
            runCatching { cm.unregisterNetworkCallback(cb) }
        }
    }

    /**
     * Las apps que alguien instaló (y las del sistema que se actualizaron):
     * las de fábrica son cientos y no dicen nada del equipo.
     */
    fun apps(context: Context): JSONArray {
        val pm = context.packageManager
        val lista = try {
            if (Build.VERSION.SDK_INT >= 33) {
                pm.getInstalledPackages(PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                pm.getInstalledPackages(0)
            }
        } catch (_: Exception) {
            emptyList()
        }
        val r = JSONArray()
        for (p in lista.sortedBy { it.packageName }) {
            val ai = p.applicationInfo ?: continue
            val sistema = ai.flags and ApplicationInfo.FLAG_SYSTEM != 0
            val actualizada = ai.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP != 0
            if (sistema && !actualizada) continue
            val build = if (Build.VERSION.SDK_INT >= 28) p.longVersionCode else @Suppress("DEPRECATION") p.versionCode.toLong()
            r.put(
                JSONObject()
                    .put("paquete", p.packageName)
                    .put("version", p.versionName ?: "")
                    .put("build", build)
                    .put("nombre", try { pm.getApplicationLabel(ai).toString() } catch (_: Exception) { "" }),
            )
        }
        return r
    }

    /** Huella de la lista de apps: la lista se manda solo cuando cambia. */
    fun firma(apps: JSONArray): String =
        MessageDigest.getInstance("SHA-256").digest(apps.toString().toByteArray())
            .joinToString("") { "%02x".format(it) }

    /**
     * Quién reporta: su applicationId, el nombre que se ve en el lanzador
     * («WMS Duralon»; el panel lo enseña en la columna «Aplicación»),
     * versionName y versionCode.
     */
    fun fuente(context: Context, tipo: String): JSONObject {
        val pm = context.packageManager
        val info = pm.getPackageInfo(context.packageName, 0)
        val build = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
        val nombre = try { context.applicationInfo.loadLabel(pm).toString().trim() } catch (_: Exception) { "" }
        return JSONObject()
            .put("tipo", tipo)
            .put("paquete", context.packageName)
            .put("nombre", nombre)
            .put("version", info.versionName ?: "")
            .put("build", build)
    }
}
