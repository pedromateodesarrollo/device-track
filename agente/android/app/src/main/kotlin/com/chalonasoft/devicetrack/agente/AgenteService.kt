package com.chalonasoft.devicetrack.agente

import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.chalonasoft.devicetrack.comun.Almacen
import com.chalonasoft.devicetrack.comun.Canal
import com.chalonasoft.devicetrack.comun.Hub
import com.chalonasoft.devicetrack.comun.Reportero
import com.chalonasoft.devicetrack.comun.Ubicacion
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * El agente en marcha: servicio en primer plano con su notificación fija.
 * Mantiene el WebSocket con el hub (las órdenes llegan al instante) y manda un
 * reporte en cada alarma ([Programador]), al encender y al apagarse.
 *
 * De tipo ubicación cuando hay permiso (es lo que deja leerla en segundo
 * plano); si no, de uso especial: sigue reportando lo demás.
 */
class AgenteService : Service() {
    companion object {
        const val ACCION_INICIAR = "com.chalonasoft.devicetrack.INICIAR"
        const val ACCION_REPORTAR = "com.chalonasoft.devicetrack.REPORTAR"
        const val ACCION_DETENER = "com.chalonasoft.devicetrack.DETENER"
        private const val EXTRA_MOTIVO = "motivo"

        @Volatile
        var conectado = false
            private set

        @Volatile
        var corriendo = false
            private set

        fun enviar(context: Context, accion: String, motivo: String? = null) {
            val i = Intent(context, AgenteService::class.java).setAction(accion)
            if (motivo != null) i.putExtra(EXTRA_MOTIVO, motivo)
            ContextCompat.startForegroundService(context, i)
        }
    }

    // Un hilo: los reportes van de a uno (el Reportero además se sincroniza).
    private val hilo = Executors.newSingleThreadExecutor()
    private lateinit var reportero: Reportero
    private lateinit var canal: Canal
    private lateinit var ordenes: OrdenesAgente

    private val apagado = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            // Al apagarse hay segundos: sin GPS, y sin esperar al hilo.
            if (i.action == Intent.ACTION_SHUTDOWN) {
                Thread { runCatching { reportero.reportar("apagando", conUbicacion = false) } }.start()
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        reportero = Reportero(this, "agente")
        ordenes = OrdenesAgente(this) { motivo -> reportar(motivo) }
        canal = Canal(this, ::alMensaje) { c ->
            conectado = c
            actualizarNotificacion()
        }
        ContextCompat.registerReceiver(
            this, apagado, IntentFilter(Intent.ACTION_SHUTDOWN), ContextCompat.RECEIVER_EXPORTED,
        )
        corriendo = true
    }

    override fun onDestroy() {
        corriendo = false
        conectado = false
        canal.detener()
        runCatching { unregisterReceiver(apagado) }
        hilo.shutdown()
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // intent null = Android revivió el servicio (START_STICKY) tras matar el proceso.
        val accion = intent?.action ?: ACCION_INICIAR
        if (!primerPlano()) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (accion == ACCION_DETENER || !Almacen(this).dadoDeAlta) {
            Programador.cancelar(this)
            canal.detener()
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        canal.iniciar()
        val motivo = intent?.getStringExtra(EXTRA_MOTIVO)
        if (accion == ACCION_REPORTAR) {
            // La próxima primero: si este reporte falla, la cadena sigue.
            Programador.programar(this)
            reportar(motivo ?: "periodico")
            Actualizador.quizas(this)
        } else {
            // Abrir la app no suma reportes de más: solo si ya tocaba.
            val falta = Programador.restante(this)
            if (falta == 0L) {
                Programador.programar(this)
                reportar(motivo ?: "abrir")
            } else {
                Programador.programar(this, falta)
            }
        }
        return START_STICKY
    }

    private fun reportar(motivo: String) {
        hilo.execute {
            val wl = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "devicetrack:reporte")
                .apply { acquire(90_000) }
            try {
                val r = reportero.reportar(motivo)
                r?.optJSONArray("ordenes")?.let { lista ->
                    for (i in 0 until lista.length()) ordenes.atender(lista.getJSONObject(i))
                }
            } catch (e: Exception) {
                Log.e("devicetrack", "Falló el reporte", e)
            } finally {
                if (wl.isHeld) wl.release()
                actualizarNotificacion()
            }
        }
    }

    private fun alMensaje(m: JSONObject) {
        when (m.optString("tipo")) {
            "orden" -> m.optJSONObject("orden")?.let { o -> hilo.execute { ordenes.atender(o) } }
            "config" -> m.optJSONObject("config")?.let { c ->
                Hub.aplicarConfig(Almacen(this), c)
                Programador.programar(this, Programador.restante(this))
                actualizarNotificacion()
            }
        }
    }

    private fun primerPlano(): Boolean = try {
        val tipo = when {
            Build.VERSION.SDK_INT < 29 -> 0
            Almacen(this).ubicacion && Ubicacion.tienePermiso(this) -> ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
            Build.VERSION.SDK_INT >= 34 -> ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            else -> 0
        }
        ServiceCompat.startForeground(this, Avisos.ID_SERVICIO, Avisos.servicio(this), tipo)
        true
    } catch (e: Exception) {
        Log.e("devicetrack", "No pudo ponerse en primer plano", e)
        false
    }

    private fun actualizarNotificacion() = Avisos.publicar(this, Avisos.ID_SERVICIO, Avisos.servicio(this))
}
