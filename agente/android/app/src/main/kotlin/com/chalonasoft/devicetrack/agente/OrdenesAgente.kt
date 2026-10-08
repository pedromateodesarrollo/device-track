package com.chalonasoft.devicetrack.agente

import android.content.Context
import android.util.Log
import com.chalonasoft.devicetrack.comun.Almacen
import com.chalonasoft.devicetrack.comun.Hub
import com.chalonasoft.devicetrack.comun.Sonar
import org.json.JSONObject

/**
 * Lo que hace el agente con cada orden del panel, y el acuse al hub.
 *
 * Una orden puede llegar dos veces (por el socket y en la respuesta de un
 * reporte: el hub la repite hasta el acuse); [Almacen.yaAtendida] la deja
 * pasar una sola vez. Corre en el hilo de los reportes.
 */
class OrdenesAgente(context: Context, private val reportarYa: (motivo: String) -> Unit) {
    private val ctx = context.applicationContext
    private val almacen = Almacen(ctx)

    fun atender(o: JSONObject) {
        val id = o.optLong("id")
        if (id <= 0) return
        if (almacen.yaAtendida(id)) {
            // Ya se hizo, pero el hub no se enteró (el acuse se perdió sin red):
            // se le vuelve a decir, sin repetirla.
            acuse(id, "hecha", "ya atendida")
            return
        }
        val datos = o.optJSONObject("datos") ?: JSONObject()
        acuse(id, "recibida")
        when (o.optString("tipo")) {
            "sonar" -> {
                val segundos = datos.optInt("segundos", 30).coerceIn(5, 300)
                Avisos.publicar(ctx, Avisos.ID_SONAR, Avisos.sonando(ctx, segundos))
                Sonar.iniciar(ctx, segundos) { tocado, seg ->
                    Avisos.quitar(ctx, Avisos.ID_SONAR)
                    Thread {
                        acuse(id, "hecha", if (tocado) "la tocaron a los $seg s" else "sonó $seg s")
                    }.start()
                }
            }
            "mensaje" -> {
                Avisos.mensaje(ctx, id, datos.optString("titulo"), datos.optString("texto"))
                acuse(id, "hecha", "mostrado")
            }
            "reportar" -> {
                reportarYa("orden")
                acuse(id, "hecha")
            }
            else -> acuse(id, "fallida", "no_soportada")
        }
    }

    private fun acuse(id: Long, estado: String, detalle: String = "") {
        try {
            Hub.estadoOrden(almacen, id, estado, detalle)
        } catch (e: Exception) {
            // Sin red: el hub la vuelve a mandar en el próximo reporte y ahí se
            // acusa (sin repetirla).
            Log.w("devicetrack", "No se pudo acusar la orden $id ($estado): ${e.message}")
        }
    }
}
