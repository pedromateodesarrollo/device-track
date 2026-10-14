package com.chalonasoft.devicetrack.comun

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.HandlerThread
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Una posición, con el servicio de ubicación de Android y no con el de Google:
 * hay terminales (algunas Zebra) que vienen sin los servicios de Google, y ahí
 * el de Google no existe.
 *
 * Se piden a la vez el GPS y la red; gana la mejor que llegue antes del plazo.
 * Bajo techo el GPS no ve el cielo y la de la red (Wi-Fi y antenas) es lo único
 * que hay. Si no llega ninguna, se usa la última conocida si es reciente.
 */
object Ubicacion {
    fun tienePermiso(context: Context): Boolean =
        tiene(context, Manifest.permission.ACCESS_FINE_LOCATION) ||
            tiene(context, Manifest.permission.ACCESS_COARSE_LOCATION)

    private fun tiene(context: Context, permiso: String) =
        ContextCompat.checkSelfPermission(context, permiso) == PackageManager.PERMISSION_GRANTED

    /** Una posición y, siempre, el porqué: ver [leerConEstado]. */
    class Leida(val posicion: Location?, val estado: JSONObject)

    /** Bloquea hasta [plazoMs]. NO llamar desde el hilo principal. */
    fun leer(context: Context, plazoMs: Long = 30_000): Location? = leerConEstado(context, plazoMs).posicion

    /**
     * La posición y el estado de la ubicación del equipo, con el MOTIVO por el
     * que hay (o no hay) posición: es lo que el panel enseña en «Ubicación»
     * (`ubicacion_estado` del reporte, ver docs/api.md).
     *
     * [segundoPlano]: quien lee corre sin pantalla delante (el servicio del
     * agente), y entonces hace falta «Permitir todo el tiempo». [actividad]:
     * la pantalla de la app, si está delante; con ella Android dice si el
     * permiso se puede volver a pedir.
     *
     * Bloquea hasta [plazoMs]. NO llamar desde el hilo principal. No lanza.
     */
    fun leerConEstado(
        context: Context,
        plazoMs: Long = 30_000,
        segundoPlano: Boolean = false,
        actividad: Activity? = null,
    ): Leida {
        val inicio = SystemClock.elapsedRealtime()
        val e = JSONObject()
        fun fin(motivo: String, l: Location? = null) = Leida(l, e.put("motivo", motivo))
        return try {
            val alm = Almacen(context)
            val permiso = when {
                tiene(context, Manifest.permission.ACCESS_FINE_LOCATION) -> "precisa"
                tiene(context, Manifest.permission.ACCESS_COARSE_LOCATION) -> "aproximada"
                else -> "ninguno"
            }
            e.put("permiso", permiso)
            e.put("pedido", alm.ubicacionPedida || permiso != "ninguno")
            if (Build.VERSION.SDK_INT >= 29) {
                e.put("segundo_plano", tiene(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION))
            }
            e.put("necesita_segundo_plano", segundoPlano)
            val lm = context.getSystemService(LocationManager::class.java)
            val gps = lm != null && runCatching { lm.isProviderEnabled(LocationManager.GPS_PROVIDER) }.getOrDefault(false)
            val red = lm != null && runCatching { lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER) }.getOrDefault(false)
            val servicio = servicioEncendido(context, lm)
            e.put("servicio", servicio).put("gps", gps).put("red", red)
            e.put("red_existe", lm != null && runCatching { LocationManager.NETWORK_PROVIDER in lm.allProviders }.getOrDefault(false))
            e.put("google_play", googlePlay(context))
            val ahorro = ahorro(context, e)
            e.put("avion", runCatching { Settings.Global.getInt(context.contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) == 1 }.getOrDefault(false))
            context.applicationContext.getSystemService(WifiManager::class.java)?.let { w ->
                runCatching { e.put("wifi", w.isWifiEnabled) }
                @Suppress("DEPRECATION")
                runCatching { e.put("escaneo_wifi", w.isScanAlwaysAvailable) }
            }

            if (!declarada(context)) return fin("no_declarada")
            if (permiso == "ninguno") return fin(rechazo(context, alm, actividad))
            if (lm == null) return fin("sin_proveedor")
            if (!servicio) return fin("servicio_apagado")
            if (!gps && !red) return fin("sin_proveedor")

            val l = posicion(lm, listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER).filter {
                if (it == LocationManager.GPS_PROVIDER) gps else red
            }, plazoMs)
            e.put("espera_s", (SystemClock.elapsedRealtime() - inicio) / 1000)
            if (l != null) {
                val edad = edadS(l)
                val simulada = simulada(l)
                e.put("proveedor", l.provider ?: "")
                    .put("precision_m", l.accuracy.toDouble())
                    .put("edad_s", edad)
                    .put("simulada", simulada)
                return fin(
                    when {
                        simulada -> "simulada"
                        edad > 120 -> "vieja"
                        permiso == "aproximada" -> "aproximada"
                        else -> "ok"
                    },
                    l,
                )
            }
            // Sin posición: la última que tenga el teléfono, de cuándo es.
            ultimaConocida(lm)?.let { u ->
                e.put("ultima_edad_s", edadS(u)).put("ultima_proveedor", u.provider ?: "")
            }
            val sinFondo = segundoPlano && Build.VERSION.SDK_INT >= 29 &&
                !tiene(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION)
            fin(
                when {
                    sinFondo -> "sin_segundo_plano"
                    ahorro -> "ahorro_bateria"
                    else -> "sin_senal"
                },
            )
        } catch (t: Throwable) {
            // Un Android raro (o una clase que falta) no deja el reporte sin
            // estado: el panel dice que no se pudo leer.
            e.put("error", t.javaClass.simpleName)
            fin("error")
        }
    }

    /**
     * Lo que contestó la persona al pedirle el permiso. Llamarlo desde la
     * pantalla, justo después de la respuesta (`onRequestPermissionsResult`):
     * solo con la pantalla delante Android dice si se puede volver a pedir.
     */
    fun anotarRespuesta(actividad: Activity) {
        val a = Almacen(actividad)
        a.ubicacionPedida = true
        a.ubicacionRechazo = when {
            tienePermiso(actividad) -> ""
            puedeVolverAPedir(actividad) -> "denegada"
            else -> "denegada_siempre"
        }
    }

    /** La app la pidió (sin saber todavía qué contestaron). */
    fun anotarPedida(context: Context) {
        Almacen(context).ubicacionPedida = true
    }

    private fun puedeVolverAPedir(a: Activity) =
        a.shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_FINE_LOCATION) ||
            a.shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_COARSE_LOCATION)

    /**
     * Sin permiso: ¿nunca se pidió, dijeron que no o que no para siempre?
     * Con la pantalla delante Android lo dice («se puede volver a pedir»); sin
     * ella, vale lo anotado la última vez que se pidió.
     */
    private fun rechazo(context: Context, alm: Almacen, actividad: Activity?): String {
        if (actividad != null) {
            if (puedeVolverAPedir(actividad)) return "denegada"
            return if (alm.ubicacionPedida) "denegada_siempre" else "sin_pedir"
        }
        if (!alm.ubicacionPedida) return "sin_pedir"
        return alm.ubicacionRechazo.ifEmpty { "denegada" }
    }

    /** Si la app declara el permiso en su manifiesto: sin eso, nunca la tendrá. */
    private fun declarada(context: Context): Boolean = try {
        val pm = context.packageManager
        val info = if (Build.VERSION.SDK_INT >= 33) {
            pm.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(PackageManager.GET_PERMISSIONS.toLong()))
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
        }
        val pedidos = info.requestedPermissions ?: emptyArray()
        Manifest.permission.ACCESS_FINE_LOCATION in pedidos || Manifest.permission.ACCESS_COARSE_LOCATION in pedidos
    } catch (_: Exception) {
        true
    }

    /** El interruptor «Ubicación» del teléfono. */
    @Suppress("DEPRECATION")
    private fun servicioEncendido(context: Context, lm: LocationManager?): Boolean = try {
        if (Build.VERSION.SDK_INT >= 28 && lm != null) {
            lm.isLocationEnabled
        } else {
            Settings.Secure.getInt(context.contentResolver, Settings.Secure.LOCATION_MODE) !=
                Settings.Secure.LOCATION_MODE_OFF
        }
    } catch (_: Exception) {
        true
    }

    /**
     * Los servicios de Google. No se usan para leer (va el servicio de
     * Android), pero sin ellos muchos teléfonos no tienen ubicación por red:
     * bajo techo, sin GPS, no queda nada.
     */
    private fun googlePlay(context: Context): Boolean = try {
        context.packageManager.getApplicationInfo("com.google.android.gms", 0).enabled
    } catch (_: Exception) {
        false
    }

    /**
     * El ahorro de batería y el reposo (Doze). Anota lo que hay en [e] y dice
     * si, tal como está, le quita la ubicación a quien lee.
     */
    private fun ahorro(context: Context, e: JSONObject): Boolean {
        val pm = context.getSystemService(PowerManager::class.java) ?: return false
        val activo = runCatching { pm.isPowerSaveMode }.getOrDefault(false)
        e.put("ahorro", activo)
        runCatching { e.put("sin_optimizar", pm.isIgnoringBatteryOptimizations(context.packageName)) }
        val reposo = runCatching { pm.isDeviceIdleMode }.getOrDefault(false)
        e.put("reposo", reposo)
        val pantalla = runCatching { pm.isInteractive }.getOrDefault(true)
        var limita = reposo
        if (activo && Build.VERSION.SDK_INT >= 28) {
            val modo = pm.locationPowerSaveMode
            e.put(
                "ahorro_ubicacion",
                when (modo) {
                    PowerManager.LOCATION_MODE_NO_CHANGE -> "sin_cambio"
                    PowerManager.LOCATION_MODE_GPS_DISABLED_WHEN_SCREEN_OFF -> "sin_gps_pantalla_apagada"
                    PowerManager.LOCATION_MODE_ALL_DISABLED_WHEN_SCREEN_OFF -> "sin_ubicacion_pantalla_apagada"
                    PowerManager.LOCATION_MODE_FOREGROUND_ONLY -> "solo_al_frente"
                    PowerManager.LOCATION_MODE_THROTTLE_REQUESTS_WHEN_SCREEN_OFF -> "limitada"
                    else -> "otro"
                },
            )
            if (modo != PowerManager.LOCATION_MODE_NO_CHANGE && !pantalla) limita = true
            if (modo == PowerManager.LOCATION_MODE_FOREGROUND_ONLY && e.optBoolean("necesita_segundo_plano")) limita = true
        }
        return limita
    }

    private fun simulada(l: Location): Boolean =
        if (Build.VERSION.SDK_INT >= 31) l.isMock else @Suppress("DEPRECATION") l.isFromMockProvider

    /** Segundos desde que se tomó, con el reloj del arranque (no el de la pared). */
    private fun edadS(l: Location): Long {
        val ns = SystemClock.elapsedRealtimeNanos() - l.elapsedRealtimeNanos
        return if (l.elapsedRealtimeNanos > 0 && ns >= 0) {
            ns / 1_000_000_000
        } else {
            ((System.currentTimeMillis() - l.time) / 1000).coerceAtLeast(0)
        }
    }

    /** GPS y red a la vez; gana la mejor que llegue antes de [plazoMs]. */
    @SuppressLint("MissingPermission")
    private fun posicion(lm: LocationManager, proveedores: List<String>, plazoMs: Long): Location? {
        if (proveedores.isEmpty()) return reciente(lm)

        val mejor = AtomicReference<Location?>(null)
        val listo = CountDownLatch(1)
        fun llega(l: Location?) {
            if (l == null) return
            mejor.getAndUpdate { a -> if (a == null || l.accuracy < a.accuracy) l else a }
            // Una lectura precisa (bajo 30 m) no mejora esperando más.
            if (l.accuracy <= 30f) listo.countDown()
        }

        val cancelar = CancellationSignal()
        val hilo = HandlerThread("devicetrack-ubicacion").apply { start() }
        val oyentes = mutableListOf<LocationListener>()
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                val ex = Executors.newSingleThreadExecutor()
                for (p in proveedores) {
                    try {
                        lm.getCurrentLocation(p, cancelar, ex) { llega(it) }
                    } catch (_: Exception) {
                    }
                }
                listo.await(plazoMs, TimeUnit.MILLISECONDS)
                ex.shutdown()
            } else {
                for (p in proveedores) {
                    val o = Oyente(::llega)
                    oyentes.add(o)
                    try {
                        @Suppress("DEPRECATION")
                        lm.requestSingleUpdate(p, o, hilo.looper)
                    } catch (_: Exception) {
                    }
                }
                listo.await(plazoMs, TimeUnit.MILLISECONDS)
            }
        } finally {
            cancelar.cancel()
            for (o in oyentes) runCatching { lm.removeUpdates(o) }
            hilo.quitSafely()
        }
        return mejor.get() ?: reciente(lm)
    }

    /**
     * Con los cuatro métodos escritos, no con una lambda. Antes de Android 11
     * `onStatusChanged`, `onProviderEnabled` y `onProviderDisabled` son
     * abstractos (el `default` llegó en la API 30): una lambda solo trae
     * `onLocationChanged` y, cuando el sistema avisa un cambio de estado del
     * GPS, `AbstractMethodError` en el hilo de la lectura tumba la app entera.
     * Pasó en las Zebra TC52/TC56/TC57 con Android 8.1 (2026-10-08).
     */
    private class Oyente(private val llega: (Location?) -> Unit) : LocationListener {
        override fun onLocationChanged(location: Location) = llega(location)

        @Deprecated("Solo lo llama Android 10 o anterior")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

        override fun onProviderEnabled(provider: String) {}

        override fun onProviderDisabled(provider: String) {}
    }

    /** La última conocida, si no tiene más de 10 minutos. */
    private fun reciente(lm: LocationManager): Location? {
        val ahora = System.currentTimeMillis()
        return conocidas(lm).filter { ahora - it.time < 10 * 60_000 }.minByOrNull { it.accuracy }
    }

    /** La más nueva que tenga el teléfono, sea de cuando sea. */
    private fun ultimaConocida(lm: LocationManager): Location? = conocidas(lm).maxByOrNull { it.time }

    @SuppressLint("MissingPermission")
    private fun conocidas(lm: LocationManager): List<Location> =
        listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER, LocationManager.PASSIVE_PROVIDER)
            .mapNotNull { runCatching { lm.getLastKnownLocation(it) }.getOrNull() }

    fun json(l: Location): JSONObject = JSONObject()
        .put("lat", l.latitude)
        .put("lng", l.longitude)
        .put("precision_m", l.accuracy.toDouble())
        .put("t", Fechas.iso(l.time))
}
