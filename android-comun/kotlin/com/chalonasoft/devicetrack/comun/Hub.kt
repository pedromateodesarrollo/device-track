package com.chalonasoft.devicetrack.comun

import android.content.Context
import android.net.Uri
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/** El hub contestó con un error suyo (`{error, mensaje}`). */
class ErrorHub(val status: Int, val codigo: String, mensaje: String) : Exception(mensaje)

/**
 * Las tres llamadas del equipo al hub: el alta, el reporte y el acuse de una
 * orden. Bloquean: se llaman desde un hilo de fondo.
 */
object Hub {
    /** `devicetrack://alta?hub=…&codigo=dta_…` (lo que lleva el QR) → (hub, código). */
    fun leerQr(texto: String): Pair<String, String>? {
        val t = texto.trim()
        if (t.startsWith("dta_")) return null
        val u = runCatching { Uri.parse(t) }.getOrNull() ?: return null
        if (u.scheme != "devicetrack" || u.host != "alta") return null
        val hub = u.getQueryParameter("hub")?.trim()?.trimEnd('/') ?: return null
        val codigo = u.getQueryParameter("codigo")?.trim() ?: return null
        if (!codigo.startsWith("dta_") || !(hub.startsWith("https://") || hub.startsWith("http://"))) return null
        return hub to codigo
    }

    /**
     * Da de alta este equipo y guarda en [Almacen] la credencial que devuelve
     * el hub. [tipo] es `agente` o `app`.
     */
    fun alta(context: Context, hub: String, codigo: String, tipo: String, nombre: String? = null): JSONObject {
        val equipo = Lectura.equipo(context)
        if (!nombre.isNullOrBlank()) equipo.put("nombre", nombre)
        val r = post(
            "${hub.trimEnd('/')}/v1/alta",
            codigo,
            JSONObject()
                .put("huella", Lectura.huella(context))
                .put("fuente", Lectura.fuente(context, tipo))
                .put("equipo", equipo),
        )
        val a = Almacen(context)
        a.hub = hub
        a.credencial = r.getString("credencial")
        val e = r.getJSONObject("equipo")
        a.equipoId = e.optLong("id")
        a.equipoNombre = e.optString("nombre")
        r.optJSONObject("config")?.let { aplicarConfig(a, it) }
        a.firmaApps = "" // que el primer reporte mande la lista de apps
        a.ultimoError = ""
        return r
    }

    fun reporte(a: Almacen, cuerpo: JSONObject): JSONObject = post("${a.hub}/v1/reporte", a.credencial, cuerpo)

    /** `recibida`, `hecha` o `fallida`. */
    fun estadoOrden(a: Almacen, id: Long, estado: String, detalle: String = "") {
        post("${a.hub}/v1/ordenes/$id/estado", a.credencial, JSONObject().put("estado", estado).put("detalle", detalle))
    }

    fun aplicarConfig(a: Almacen, c: JSONObject) {
        if (c.has("intervalo_s")) a.intervaloS = c.optInt("intervalo_s", 600)
        if (c.has("ubicacion")) a.ubicacion = c.optBoolean("ubicacion", true)
    }

    fun post(url: String, credencial: String?, cuerpo: JSONObject): JSONObject {
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            c.requestMethod = "POST"
            c.connectTimeout = 20_000
            c.readTimeout = 30_000
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/json")
            if (!credencial.isNullOrEmpty()) c.setRequestProperty("Authorization", "Bearer $credencial")
            c.outputStream.use { it.write(cuerpo.toString().toByteArray()) }
            val st = c.responseCode
            val texto = (if (st < 400) c.inputStream else c.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
            val json = runCatching { JSONObject(texto) }.getOrDefault(JSONObject())
            if (st >= 400) throw ErrorHub(st, json.optString("error", "http_$st"), json.optString("mensaje", "HTTP $st"))
            return json
        } catch (e: ErrorHub) {
            throw e
        } catch (e: Exception) {
            throw IOException("Sin respuesta del hub: ${e.message}", e)
        } finally {
            c.disconnect()
        }
    }
}
