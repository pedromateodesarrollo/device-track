package com.chalonasoft.devicetrack.comun

import android.content.Context
import org.json.JSONArray

/**
 * Lo que el equipo recuerda entre arranques: a qué hub habla, su credencial,
 * la configuración que le mandó el hub y las órdenes que ya atendió.
 *
 * En las preferencias privadas de cada app: el agente y una app con el plugin
 * guardan cada uno lo suyo, y cada uno es una fuente distinta en el hub.
 */
class Almacen(context: Context) {
    private val p = context.applicationContext.getSharedPreferences("devicetrack", Context.MODE_PRIVATE)

    var hub: String
        get() = p.getString("hub", "") ?: ""
        set(v) = p.edit().putString("hub", v.trimEnd('/')).apply()

    var credencial: String
        get() = p.getString("credencial", "") ?: ""
        set(v) = p.edit().putString("credencial", v).apply()

    var equipoId: Long
        get() = p.getLong("equipo_id", 0)
        set(v) = p.edit().putLong("equipo_id", v).apply()

    var equipoNombre: String
        get() = p.getString("equipo_nombre", "") ?: ""
        set(v) = p.edit().putString("equipo_nombre", v).apply()

    /** Cada cuánto reportar, como lo dijo el hub. */
    var intervaloS: Int
        get() = p.getInt("intervalo_s", 600)
        set(v) = p.edit().putInt("intervalo_s", v.coerceIn(60, 86_400)).apply()

    /** Si la organización pide la ubicación. */
    var ubicacion: Boolean
        get() = p.getBoolean("ubicacion", true)
        set(v) = p.edit().putBoolean("ubicacion", v).apply()

    var firmaApps: String
        get() = p.getString("firma_apps", "") ?: ""
        set(v) = p.edit().putString("firma_apps", v).apply()

    var ultimoReporteT: Long
        get() = p.getLong("ultimo_reporte_t", 0)
        set(v) = p.edit().putLong("ultimo_reporte_t", v).apply()

    var ultimoIntentoT: Long
        get() = p.getLong("ultimo_intento_t", 0)
        set(v) = p.edit().putLong("ultimo_intento_t", v).apply()

    var ultimoError: String
        get() = p.getString("ultimo_error", "") ?: ""
        set(v) = p.edit().putString("ultimo_error", v).apply()

    val dadoDeAlta: Boolean get() = hub.isNotEmpty() && credencial.isNotEmpty()

    fun olvidar() = p.edit().clear().apply()

    /**
     * Una orden se entrega hasta que el equipo acusa recibo, así que puede
     * llegar dos veces (por el socket y en el reporte). Se recuerdan las
     * últimas 100 atendidas.
     */
    @Synchronized
    fun yaAtendida(id: Long): Boolean {
        val lista = JSONArray(p.getString("ordenes", "[]"))
        for (i in 0 until lista.length()) if (lista.getLong(i) == id) return true
        lista.put(id)
        val recorte = JSONArray()
        val desde = (lista.length() - 100).coerceAtLeast(0)
        for (i in desde until lista.length()) recorte.put(lista.getLong(i))
        p.edit().putString("ordenes", recorte.toString()).apply()
        return false
    }
}
