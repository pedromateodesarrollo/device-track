package com.chalonasoft.devicetrack.comun

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log

/**
 * «Hacer sonar»: el sonido de alarma del teléfono, a todo volumen y en el
 * canal de alarmas, que suena aunque el teléfono esté en silencio o en «no
 * molestar» (las alarmas pasan). Vibra a la vez. Para cuando pasa el tiempo o
 * cuando alguien lo toca ([detener]).
 *
 * El volumen de alarma que tenía la persona se devuelve al terminar.
 */
object Sonar {
    private val main = Handler(Looper.getMainLooper())
    private var reproductor: MediaPlayer? = null
    private var app: Context? = null
    private var volumenAntes = -1
    private var inicio = 0L
    private var alTerminar: ((tocado: Boolean, segundos: Int) -> Unit)? = null
    private val parar = Runnable { terminar(tocado = false) }

    val sonando: Boolean get() = reproductor != null

    /** [alTerminar] se llama una vez: con `tocado` si alguien lo paró. */
    fun iniciar(context: Context, segundos: Int, alTerminar: (tocado: Boolean, segundos: Int) -> Unit) {
        main.post {
            if (reproductor != null || this.alTerminar != null) terminar(tocado = false)
            val app = context.applicationContext
            this.app = app
            val audio = app.getSystemService(AudioManager::class.java)
            try {
                volumenAntes = audio.getStreamVolume(AudioManager.STREAM_ALARM)
                audio.setStreamVolume(AudioManager.STREAM_ALARM, audio.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0)
            } catch (e: Exception) {
                volumenAntes = -1
                Log.w("devicetrack", "No se pudo subir el volumen de alarma", e)
            }
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            try {
                reproductor = MediaPlayer().apply {
                    setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_ALARM)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build(),
                    )
                    setDataSource(app, uri)
                    isLooping = true
                    prepare()
                    start()
                }
            } catch (e: Exception) {
                Log.e("devicetrack", "No se pudo sonar", e)
                reproductor = null
            }
            vibrar(app, segundos)
            inicio = System.currentTimeMillis()
            this.alTerminar = alTerminar
            main.postDelayed(parar, segundos * 1000L)
        }
    }

    /** Alguien lo tocó. */
    fun detener() = main.post { terminar(tocado = true) }

    private fun terminar(tocado: Boolean) {
        main.removeCallbacks(parar)
        // Sin reproductor (el equipo no tiene tono de alarma o falló) igual hay
        // quien espera el aviso y un volumen que devolver.
        val r = reproductor
        if (r == null && alTerminar == null) return
        reproductor = null
        r?.let {
            runCatching { it.stop() }
            runCatching { it.release() }
        }
        restaurarVolumen()
        val f = alTerminar
        alTerminar = null
        val seg = ((System.currentTimeMillis() - inicio) / 1000).toInt()
        f?.invoke(tocado, seg)
    }

    private fun vibrar(context: Context, segundos: Int) {
        try {
            val v: Vibrator = if (Build.VERSION.SDK_INT >= 31) {
                context.getSystemService(VibratorManager::class.java).defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Vibrator::class.java)
            }
            val patron = LongArray(segundos.coerceIn(1, 300)) { if (it % 2 == 0) 700L else 300L }
            // VibrationEffect es de Android 8: en el 7 falta la clase y el error
            // (NoClassDefFoundError) no lo atrapa este catch.
            if (Build.VERSION.SDK_INT >= 26) {
                v.vibrate(VibrationEffect.createWaveform(patron, -1))
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(patron, -1)
            }
        } catch (_: Exception) {
        }
    }

    /** Devuelve el volumen de alarma como estaba la persona. */
    private fun restaurarVolumen() {
        val c = app ?: return
        if (volumenAntes < 0) return
        runCatching {
            c.getSystemService(AudioManager::class.java)
                .setStreamVolume(AudioManager.STREAM_ALARM, volumenAntes, 0)
        }
        volumenAntes = -1
    }
}
