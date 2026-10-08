package com.chalonasoft.devicetrack.agente

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import com.chalonasoft.devicetrack.comun.Almacen

/**
 * La alarma de cada reporte. Exacta y «allowWhileIdle» para que llegue también
 * en Doze (pantalla apagada, equipo quieto): en Doze Android deja una cada ~9
 * minutos por app, y por eso el intervalo por defecto del hub es de 10.
 * Entre una y otra el procesador duerme: no se retiene un wakelock.
 */
object Programador {
    private const val REQ = 5301

    private fun pendiente(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context, REQ,
        Intent(context, TomaReceiver::class.java).setAction(TomaReceiver.ACCION),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    fun intervaloMs(context: Context): Long = Almacen(context).intervaloS * 1000L

    fun programar(context: Context, enMs: Long = intervaloMs(context)) {
        val am = context.getSystemService(AlarmManager::class.java)
        val cuando = System.currentTimeMillis() + enMs.coerceAtLeast(0)
        val pi = pendiente(context)
        try {
            if (Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms()) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, cuando, pi)
            } else {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, cuando, pi)
            }
        } catch (e: SecurityException) {
            Log.w("devicetrack", "Sin alarmas exactas: va inexacta", e)
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, cuando, pi)
        }
    }

    /** Cuánto falta para el próximo reporte según el último intento; 0 = ya toca. */
    fun restante(context: Context): Long {
        val i = intervaloMs(context)
        return (Almacen(context).ultimoIntentoT + i - System.currentTimeMillis()).coerceIn(0, i)
    }

    fun cancelar(context: Context) {
        context.getSystemService(AlarmManager::class.java).cancel(pendiente(context))
    }
}
