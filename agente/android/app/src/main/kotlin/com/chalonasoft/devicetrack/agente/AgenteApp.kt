package com.chalonasoft.devicetrack.agente

import android.app.Application
import android.net.Uri
import com.chalonasoft.apkserver.ApkServer
import com.chalonasoft.devicetrack.comun.Almacen
import org.json.JSONObject

class AgenteApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Avisos.crearCanales(this)
        actualizacion()
    }

    /**
     * Se actualiza solo con apk-server (por defecto https://apk.chalonasoft.com;
     * hub y app en app/build.gradle.kts). La biblioteca pregunta como mucho
     * cada hora tras un reporte (`quizas()` en AgenteService), baja con Wi-Fi y
     * desde Android 12 instala sin preguntar si alguien le dio una vez
     * «instalar apps desconocidas» (a mano, o por StageNow/MDM en una flota de
     * Zebra). Si Android pide confirmar —la primera actualización de un agente
     * que se instaló a mano, o Android 11 o menos— queda la notificación de
     * «lista», y al tocarla sale la pantalla del sistema.
     *
     * Sin WebSocket: el agente ya tiene el suyo con device-track y uno más
     * gasta batería; una versión nueva llega en la hora.
     */
    private fun actualizacion() {
        val almacen = Almacen(this)
        ApkServer.configurar(this) {
            avisos = false
            soloWifi = true
            autoInstalar = true
            icono = R.drawable.ic_stat_devicetrack
            contexto = {
                JSONObject()
                    .put("equipo", almacen.equipoNombre)
                    .put("hub", runCatching { Uri.parse(almacen.hub).host }.getOrNull() ?: "")
            }
        }
    }
}
