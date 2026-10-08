package com.chalonasoft.devicetrack.agente

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.chalonasoft.devicetrack.comun.Almacen
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Las notificaciones del agente. La fija del servicio es la que dice, siempre
 * a la vista, que este equipo reporta a quién: no hay seguimiento a escondidas.
 */
object Avisos {
    const val ID_SERVICIO = 1
    const val ID_SONAR = 2
    private const val ID_MENSAJE_BASE = 1000
    private const val CANAL_SERVICIO = "servicio"
    private const val CANAL_SONAR = "sonar"
    private const val CANAL_MENSAJES = "mensajes"

    private val es = Locale.forLanguageTag("es-DO")

    fun hora(t: Long): String = SimpleDateFormat("h:mm a", es).format(Date(t))

    fun crearCanales(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CANAL_SERVICIO, "Seguimiento del equipo", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Aviso fijo: este equipo reporta su estado a la organización"
                setShowBadge(false)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(CANAL_SONAR, "Hacer sonar", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Cuando lo hacen sonar desde el panel, para encontrarlo"
                setSound(null, null)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(CANAL_MENSAJES, "Mensajes", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Avisos que manda la organización a este equipo"
            },
        )
    }

    private fun abrirApp(context: Context): PendingIntent = PendingIntent.getActivity(
        context, 0,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE,
    )

    fun servicio(context: Context): Notification {
        val a = Almacen(context)
        val host = runCatching { Uri.parse(a.hub).host }.getOrNull() ?: a.hub
        val texto = buildString {
            append("Reporta su estado")
            if (a.ubicacion) append(" y su ubicación")
            append(" a $host")
            if (a.ultimoReporteT > 0) append(" · último: ${hora(a.ultimoReporteT)}")
            if (a.ultimoError == "sin_red") append(" · sin red, se manda al volver")
            if (a.ultimoError == "credencial") append(" · hay que darlo de alta de nuevo")
        }
        return NotificationCompat.Builder(context, CANAL_SERVICIO)
            .setSmallIcon(R.drawable.ic_stat_devicetrack)
            .setContentTitle("Equipo con seguimiento: ${a.equipoNombre.ifEmpty { "device-track" }}")
            .setContentText(texto)
            .setStyle(NotificationCompat.BigTextStyle().bigText(texto))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(abrirApp(context))
            .build()
    }

    fun sonando(context: Context, segundos: Int): Notification {
        val parar = PendingIntent.getBroadcast(
            context, 0,
            Intent(context, SonarReceiver::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(context, CANAL_SONAR)
            .setSmallIcon(R.drawable.ic_stat_devicetrack)
            .setContentTitle("Están buscando este equipo")
            .setContentText("Lo hicieron sonar desde el panel. Toca para parar.")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setOngoing(true)
            .setTimeoutAfter(segundos * 1000L + 5_000)
            .setContentIntent(parar)
            .setDeleteIntent(parar)
            .addAction(0, "Lo encontré", parar)
            .setFullScreenIntent(parar, true)
            .build()
    }

    fun mensaje(context: Context, id: Long, titulo: String, texto: String) {
        val abrir = PendingIntent.getActivity(
            context, id.toInt(),
            Intent(context, MensajeActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(MensajeActivity.TITULO, titulo)
                .putExtra(MensajeActivity.TEXTO, texto),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(context, CANAL_MENSAJES)
            .setSmallIcon(R.drawable.ic_stat_devicetrack)
            .setContentTitle(titulo.ifEmpty { "Mensaje para este equipo" })
            .setContentText(texto)
            .setStyle(NotificationCompat.BigTextStyle().bigText(texto))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setContentIntent(abrir)
            .setFullScreenIntent(abrir, true)
            .build()
        publicar(context, ID_MENSAJE_BASE + (id % 1000).toInt(), n)
    }

    fun publicar(context: Context, id: Int, n: Notification) {
        try {
            NotificationManagerCompat.from(context).notify(id, n)
        } catch (_: SecurityException) {
            // Sin permiso de notificaciones: el servicio sigue, solo no se ve.
        }
    }

    fun quitar(context: Context, id: Int) = NotificationManagerCompat.from(context).cancel(id)
}
