package com.chalonasoft.devicetrack.comun

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.Looper
import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * El WebSocket con el hub (`/v1/ws`, la credencial en la cabecera). Mientras
 * está abierto el equipo figura conectado y las órdenes llegan al instante.
 *
 * Se cae y vuelve: con espera creciente (5 s a 5 min) y en cuanto aparece una
 * red. Si cambia de red (Wi-Fi ↔ datos) el socket viejo quedó colgado de la
 * anterior y se rehace.
 */
class Canal(
    context: Context,
    private val alMensaje: (JSONObject) -> Unit,
    private val alCambiar: (conectado: Boolean) -> Unit = {},
) {
    private val ctx = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private var activo = false
    private var socket: WebSocket? = null
    private var espera = ESPERA_MIN
    private var red: ConnectivityManager.NetworkCallback? = null
    private var redActual: Network? = null
    private val reconectar = Runnable { conectar() }

    var conectado = false
        private set

    companion object {
        private const val ESPERA_MIN = 5_000L
        private const val ESPERA_MAX = 5 * 60_000L

        // El ping mantiene abierta la ruta de la operadora (su NAT olvida una
        // conexión callada) y descubre un socket muerto.
        private val cliente by lazy { OkHttpClient.Builder().pingInterval(4, TimeUnit.MINUTES).build() }
    }

    fun iniciar() = main.post {
        if (!activo) {
            activo = true
            vigilarRed()
        }
        if (socket == null) {
            main.removeCallbacks(reconectar)
            conectar()
        }
    }

    fun detener() = main.post {
        activo = false
        main.removeCallbacks(reconectar)
        red?.let { runCatching { ctx.getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) } }
        red = null
        redActual = null
        socket?.close(1000, null)
        socket = null
        marcar(false)
    }

    /** Volvió al frente: si estaba esperando para reconectar, ya. */
    fun ahora() = main.post {
        if (activo && socket == null) {
            main.removeCallbacks(reconectar)
            espera = ESPERA_MIN
            conectar()
        }
    }

    private fun conectar() {
        if (!activo || socket != null) return
        val a = Almacen(ctx)
        if (!a.dadoDeAlta) return
        val url = a.hub.replaceFirst(Regex("^http"), "ws") + "/v1/ws"
        val pet = Request.Builder().url(url).header("Authorization", "Bearer ${a.credencial}").build()
        socket = cliente.newWebSocket(pet, Oyente())
    }

    private fun marcar(c: Boolean) {
        if (conectado == c) return
        conectado = c
        alCambiar(c)
    }

    private fun vigilarRed() {
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                main.post {
                    if (!activo) return@post
                    val cambio = redActual != null && redActual != network
                    redActual = network
                    if (cambio) {
                        socket?.cancel()
                        socket = null
                    }
                    if (socket == null) {
                        main.removeCallbacks(reconectar)
                        espera = ESPERA_MIN
                        conectar()
                    }
                }
            }
        }
        try {
            ctx.getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(cb)
            red = cb
        } catch (e: Exception) {
            Log.w("devicetrack", "Sin aviso de cambios de red", e)
        }
    }

    private inner class Oyente : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            main.post { marcar(true) }
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            val m = runCatching { JSONObject(text) }.getOrNull() ?: return
            main.post {
                // La espera vuelve a la corta cuando el hub habló (su «hola»), no
                // al abrir: un socket que se abre y se cae al instante (un proxy,
                // una extensión rechazada) reintentaría cada 5 s para siempre.
                espera = ESPERA_MIN
                if (m.optString("tipo") != "hola") alMensaje(m)
            }
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = caido(webSocket, "cerrado $code")

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            // 401: la credencial ya no vale (otra alta la reemplazó, o borraron el
            // equipo). Reintentar no la arregla: se espera al próximo reporte.
            if (response?.code == 401) Almacen(ctx).ultimoError = "credencial"
            caido(webSocket, "falló: ${t.message}")
        }

        private fun caido(webSocket: WebSocket, por: String) {
            main.post {
                if (socket !== webSocket) return@post
                socket = null
                marcar(false)
                if (!activo) return@post
                Log.i("devicetrack", "Socket $por; vuelve en ${espera / 1000} s")
                main.postDelayed(reconectar, espera)
                espera = minOf(espera * 2, ESPERA_MAX)
            }
        }
    }
}
