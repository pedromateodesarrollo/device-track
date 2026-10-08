package com.chalonasoft.devicetrack.comun

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.HandlerThread
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
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    /** Bloquea hasta [plazoMs]. NO llamar desde el hilo principal. */
    @SuppressLint("MissingPermission")
    fun leer(context: Context, plazoMs: Long = 30_000): Location? {
        if (!tienePermiso(context)) return null
        val lm = context.getSystemService(LocationManager::class.java) ?: return null
        val proveedores = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            .filter { runCatching { lm.isProviderEnabled(it) }.getOrDefault(false) }
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
    @SuppressLint("MissingPermission")
    private fun reciente(lm: LocationManager): Location? {
        val ahora = System.currentTimeMillis()
        return listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER, LocationManager.PASSIVE_PROVIDER)
            .mapNotNull { runCatching { lm.getLastKnownLocation(it) }.getOrNull() }
            .filter { ahora - it.time < 10 * 60_000 }
            .minByOrNull { it.accuracy }
    }

    fun json(l: Location): JSONObject = JSONObject()
        .put("lat", l.latitude)
        .put("lng", l.longitude)
        .put("precision_m", l.accuracy.toDouble())
        .put("t", Fechas.iso(l.time))
}
