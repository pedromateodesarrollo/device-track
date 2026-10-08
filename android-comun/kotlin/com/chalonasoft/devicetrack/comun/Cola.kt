package com.chalonasoft.devicetrack.comun

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Los reportes que no salieron (sin red, hub caído). Se mandan juntos en el
 * siguiente, cada uno con su hora: el historial queda con cuándo pasó, no con
 * cuándo llegó. Tope de 500: un equipo que pasó una semana sin red no llena el
 * disco, y se quedan los más nuevos.
 */
class Cola(context: Context) {
    private val archivo = File(context.applicationContext.filesDir, "devicetrack-cola.json")

    @Synchronized
    fun agregar(r: JSONObject) {
        val lista = leer()
        lista.put(r)
        guardar(recortar(lista, 500))
    }

    /** Los guardados, sin sacarlos. Se sacan con [vaciar] cuando el hub contestó. */
    @Synchronized
    fun pendientes(): JSONArray = recortar(leer(), 499)

    @Synchronized
    fun vaciar() {
        archivo.delete()
    }

    val tamano: Int @Synchronized get() = leer().length()

    private fun leer(): JSONArray = try {
        if (archivo.exists()) JSONArray(archivo.readText()) else JSONArray()
    } catch (_: Exception) {
        JSONArray()
    }

    private fun guardar(l: JSONArray) {
        val tmp = File(archivo.path + ".tmp")
        tmp.writeText(l.toString())
        tmp.renameTo(archivo)
    }

    private fun recortar(l: JSONArray, max: Int): JSONArray {
        if (l.length() <= max) return l
        val r = JSONArray()
        for (i in l.length() - max until l.length()) r.put(l.get(i))
        return r
    }
}
