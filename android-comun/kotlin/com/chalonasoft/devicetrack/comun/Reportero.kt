package com.chalonasoft.devicetrack.comun

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException

/**
 * Arma un reporte, lo manda con los que quedaron pendientes y deja aplicada la
 * configuración que contesta el hub. Si no sale, lo guarda en la [Cola].
 *
 * Bloquea (lee la ubicación y habla con el hub): desde un hilo de fondo.
 */
class Reportero(context: Context, private val tipo: String) {
    private val ctx = context.applicationContext
    private val almacen = Almacen(ctx)
    private val cola = Cola(ctx)

    /**
     * Devuelve la respuesta del hub (con las órdenes pendientes) o null si no
     * salió. [contexto] es lo que la app quiera contar (empresa, sesión).
     */
    @Synchronized
    fun reportar(motivo: String, contexto: JSONObject? = null, conUbicacion: Boolean = true): JSONObject? {
        if (!almacen.dadoDeAlta) return null
        almacen.ultimoIntentoT = System.currentTimeMillis()
        val r = Lectura.estado(ctx).put("t", Fechas.iso()).put("motivo", motivo)
        // Al apagarse no hay tiempo de esperar al GPS.
        if (conUbicacion && almacen.ubicacion && motivo != "apagando" && Ubicacion.tienePermiso(ctx)) {
            Ubicacion.leer(ctx)?.let { r.put("ubicacion", Ubicacion.json(it)) }
        }

        val cuerpo = JSONObject(r.toString())
        val atrasados = cola.pendientes()
        if (atrasados.length() > 0) cuerpo.put("reportes", atrasados)
        cuerpo.put("fuente", Lectura.fuente(ctx, tipo))
        cuerpo.put("equipo", JSONObject().put("android", android.os.Build.VERSION.SDK_INT))
        if (contexto != null) cuerpo.put("contexto", contexto)
        var firma: String? = null
        try {
            val apps: JSONArray = Lectura.apps(ctx)
            val f = Lectura.firma(apps)
            if (f != almacen.firmaApps) {
                cuerpo.put("apps", apps)
                firma = f
            }
        } catch (e: Exception) {
            Log.w("devicetrack", "No se pudo leer la lista de apps", e)
        }

        return try {
            val resp = Hub.reporte(almacen, cuerpo)
            cola.vaciar()
            if (firma != null) almacen.firmaApps = firma
            resp.optJSONObject("config")?.let { Hub.aplicarConfig(almacen, it) }
            almacen.ultimoReporteT = System.currentTimeMillis()
            almacen.ultimoError = ""
            resp
        } catch (e: ErrorHub) {
            almacen.ultimoError = if (e.status == 401) "credencial" else e.codigo
            // Un 400 no se arregla reintentando; lo demás (429, 5xx) sí.
            if (e.status == 429 || e.status >= 500) cola.agregar(r)
            Log.w("devicetrack", "El hub rechazó el reporte: ${e.status} ${e.codigo}")
            null
        } catch (e: IOException) {
            almacen.ultimoError = "sin_red"
            cola.agregar(r)
            Log.i("devicetrack", "Reporte guardado para después: ${e.message}")
            null
        }
    }

    val pendientes: Int get() = cola.tamano
}
