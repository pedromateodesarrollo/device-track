package com.chalonasoft.devicetrack.agente

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.chalonasoft.devicetrack.comun.Almacen
import com.chalonasoft.devicetrack.comun.Sonar

/** Arranca (o despierta) el servicio si el equipo está dado de alta. */
fun despertar(context: Context, accion: String, motivo: String? = null): Boolean {
    if (!Almacen(context).dadoDeAlta) return false
    return try {
        AgenteService.enviar(context, accion, motivo)
        true
    } catch (e: Exception) {
        // ForegroundServiceStartNotAllowedException y parientes: la próxima alarma lo reintenta.
        Log.w("devicetrack", "No se pudo arrancar el servicio ($accion)", e)
        Programador.programar(context)
        false
    }
}

/** La alarma de cada reporte. Se lo pasa al servicio: un receptor vive ~10 s. */
class TomaReceiver : BroadcastReceiver() {
    companion object {
        const val ACCION = "com.chalonasoft.devicetrack.TOMA"
    }

    override fun onReceive(context: Context, intent: Intent) {
        despertar(context, AgenteService.ACCION_REPORTAR, "periodico")
    }
}

/** Al encender el equipo o al actualizarse el agente, sigue solo. */
class ArranqueReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val motivo = if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) "abrir" else "encendido"
        despertar(context, AgenteService.ACCION_REPORTAR, motivo)
    }
}

/** «Lo encontré» en la notificación de sonar. */
class SonarReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Sonar.detener()
    }
}
