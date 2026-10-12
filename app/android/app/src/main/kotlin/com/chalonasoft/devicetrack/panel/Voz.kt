package com.chalonasoft.devicetrack.panel

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * La voz del asistente en el teléfono (canal `device_track_panel/voz`,
 * `lib/voz.dart`): grabar la nota de voz y tocar la respuesta. Android ya trae
 * MediaRecorder y MediaPlayer: dos paquetes de Flutter para esto serían
 * dependencias de más.
 *
 * La nota va en AAC (`audio/mp4`), mono a 16 kHz y 32 kbps: la voz se entiende
 * igual, y tres minutos son ~0,7 MB (el hub acepta hasta 1,4 MB).
 */
class Voz(private val actividad: Activity) {
    private var grabadora: MediaRecorder? = null
    private var nota: File? = null
    private var inicio = 0L

    private var reproductor: MediaPlayer? = null
    private var sonando: MethodChannel.Result? = null
    private var archivoSonando: File? = null
    private var permisoPedido: MethodChannel.Result? = null

    fun atiende(llamada: MethodCall, resultado: MethodChannel.Result) {
        when (llamada.method) {
            "permiso" -> permiso(resultado)
            "grabar" -> resultado.success(grabar())
            "terminar" -> resultado.success(terminar())
            "cancelar" -> {
                soltarGrabadora()
                nota?.delete()
                nota = null
                resultado.success(true)
            }
            "tocar" -> tocar(llamada.argument<ByteArray>("wav"), resultado)
            "callar" -> {
                callar()
                resultado.success(true)
            }
            else -> resultado.notImplemented()
        }
    }

    // ── Permiso ──

    private fun permiso(resultado: MethodChannel.Result) {
        if (actividad.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            resultado.success(true)
            return
        }
        permisoPedido?.success(false)
        permisoPedido = resultado
        actividad.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PEDIDO_MICROFONO)
    }

    /** Lo llama MainActivity con la respuesta del permiso. */
    fun permisoRespondido(codigo: Int, concedidos: IntArray) {
        if (codigo != PEDIDO_MICROFONO) return
        permisoPedido?.success(concedidos.isNotEmpty() && concedidos[0] == PackageManager.PERMISSION_GRANTED)
        permisoPedido = null
    }

    // ── Grabar ──

    /** null si empezó; si no, por qué. */
    private fun grabar(): String? {
        soltarGrabadora()
        val archivo = File(actividad.cacheDir, "nota-de-voz.m4a")
        archivo.delete()
        val r = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(actividad) else {
            @Suppress("DEPRECATION")
            MediaRecorder()
        }
        return try {
            r.setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioChannels(1)
            r.setAudioSamplingRate(16000)
            r.setAudioEncodingBitRate(32000)
            r.setOutputFile(archivo.absolutePath)
            r.prepare()
            r.start()
            grabadora = r
            nota = archivo
            inicio = System.currentTimeMillis()
            null
        } catch (e: Exception) {
            r.release()
            "No se pudo usar el micrófono: ${e.message ?: e.javaClass.simpleName}"
        }
    }

    /** `{audio, mime, segundos}`, o null si no había nota o salió vacía. */
    private fun terminar(): Map<String, Any?>? {
        val r = grabadora ?: return null
        grabadora = null
        val segundos = ((System.currentTimeMillis() - inicio) / 1000).coerceAtLeast(1)
        val bien = try {
            r.stop()
            true
        } catch (e: RuntimeException) {
            false // se soltó enseguida: no grabó nada
        } finally {
            r.release()
        }
        val archivo = nota ?: return null
        nota = null
        val bytes = if (bien && archivo.exists()) archivo.readBytes() else null
        archivo.delete()
        if (bytes == null || bytes.isEmpty()) return null
        return mapOf("audio" to bytes, "mime" to "audio/mp4", "segundos" to segundos)
    }

    private fun soltarGrabadora() {
        val r = grabadora ?: return
        grabadora = null
        try {
            r.stop()
        } catch (e: RuntimeException) {
            // no había empezado a grabar de verdad
        }
        r.release()
    }

    // ── Tocar ──

    /** Contesta cuando termina de sonar: true si sonó entera. */
    private fun tocar(wav: ByteArray?, resultado: MethodChannel.Result) {
        callar()
        if (wav == null || wav.isEmpty()) {
            resultado.success(false)
            return
        }
        val archivo = File(actividad.cacheDir, "voz-${System.nanoTime()}.wav")
        archivo.writeBytes(wav)
        val p = MediaPlayer()
        sonando = resultado
        reproductor = p
        archivoSonando = archivo
        fun fin(entera: Boolean) {
            if (reproductor !== p) return // ya lo calló callar()
            reproductor = null
            p.release()
            archivo.delete()
            archivoSonando = null
            sonando?.success(entera)
            sonando = null
        }
        try {
            p.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            p.setDataSource(archivo.absolutePath)
            p.setOnCompletionListener { fin(true) }
            p.setOnErrorListener { _, _, _ ->
                fin(false)
                true
            }
            p.prepare()
            p.start()
        } catch (e: Exception) {
            fin(false)
        }
    }

    fun callar() {
        val p = reproductor
        reproductor = null
        if (p != null) {
            try {
                p.stop()
            } catch (e: IllegalStateException) {
                // ya había terminado
            }
            p.release()
        }
        archivoSonando?.delete()
        archivoSonando = null
        sonando?.success(false)
        sonando = null
    }

    /** Al salir de la app: que no quede el micrófono abierto ni sonando. */
    fun suelta() {
        soltarGrabadora()
        nota?.delete()
        nota = null
        callar()
    }

    companion object {
        private const val PEDIDO_MICROFONO = 7301
    }
}
