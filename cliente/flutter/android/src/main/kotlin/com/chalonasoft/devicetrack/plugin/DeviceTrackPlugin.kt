package com.chalonasoft.devicetrack.plugin

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.chalonasoft.devicetrack.comun.Almacen
import com.chalonasoft.devicetrack.comun.Cola
import com.chalonasoft.devicetrack.comun.Lectura
import com.chalonasoft.devicetrack.comun.Sonar
import com.chalonasoft.devicetrack.comun.Ubicacion
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * El canal `device_track` entre Dart (`EquipoNativo`, `DeviceTrack`) y
 * Android. Lee el equipo con el mismo código que el agente (`android-comun`) y
 * guarda lo que la app tiene que recordar. NO habla con el hub: eso lo hace
 * Dart (paquete `device_track`). NO pide permisos: la ubicación la pide la app.
 *
 * Leer el equipo:
 * - `equipo` → `{huella, modelo, fabricante, android, serie?}`.
 * - `fuente` → `{tipo: app, paquete, version, build}` de la app que lo usa.
 * - `estado` → `{bateria, cargando, red: {tipo, ssid?}, almacenamiento: {libre, total}}`.
 * - `ubicacion {plazo_ms}` → `{lat, lng, precision_m, t}`, o null si la app no
 *   tiene el permiso o no llegó ninguna a tiempo.
 * - `permisoUbicacion` → si la app tiene el permiso (fino o aproximado).
 * - `apps` → `[{paquete, version, build, nombre}]`; `firma` → su SHA-256.
 *
 * Hacer sonar:
 * - `sonar {segundos}` → `{tocado, segundos}` cuando termina: si alguien lo
 *   paró ([detenerSonar]) y cuánto sonó.
 * - `detenerSonar`, `sonando`.
 *
 * Recordar (en las preferencias y los archivos privados de la app, con
 * `Almacen` y `Cola`):
 * - `almacen` → `{hub, credencial, equipo_id, equipo_nombre, intervalo_s,
 *   ubicacion, firma_apps, huella_alta, ultimo_reporte_t, pendientes}`.
 * - `guardar {…}` (las mismas claves; solo cambia lo que viene), `olvidar`.
 * - `colaAgregar {reporte}` → cuántos quedan; `colaPendientes`; `colaVaciar`.
 * - `yaAtendida {id}` → si esa orden ya se atendió (y la anota si no).
 *
 * Todo lo que bloquea (el GPS espera hasta su plazo, la lista de apps tarda
 * en un equipo con cientos, el disco) corre en un hilo de fondo; el canal se
 * contesta siempre en el principal.
 */
class DeviceTrackPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var canal: MethodChannel? = null
    private var contexto: Context? = null
    private var fondo: ExecutorService? = null
    private val principal = Handler(Looper.getMainLooper())

    companion object {
        // Uno por proceso: `Almacen.yaAtendida` y la `Cola` se sincronizan por
        // instancia, y con dos (dos motores de Flutter) una orden podía pasar
        // dos veces.
        private var almacen: Almacen? = null
        private var cola: Cola? = null

        @Synchronized
        private fun almacen(ctx: Context): Almacen = almacen ?: Almacen(ctx).also { almacen = it }

        @Synchronized
        private fun cola(ctx: Context): Cola = cola ?: Cola(ctx).also { cola = it }

        /** Lo que no es de `Almacen` va en el mismo archivo de preferencias. */
        private fun prefs(ctx: Context) =
            ctx.applicationContext.getSharedPreferences("devicetrack", Context.MODE_PRIVATE)

        private val NO_IMPLEMENTADO = Any()
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        contexto = binding.applicationContext
        fondo = Executors.newCachedThreadPool()
        canal = MethodChannel(binding.binaryMessenger, "device_track").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        canal?.setMethodCallHandler(null)
        canal = null
        fondo?.shutdown()
        fondo = null
        contexto = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = contexto
        if (ctx == null) {
            result.error("sin_contexto", "El plugin no está enganchado", null)
            return
        }
        when (call.method) {
            "sonar" -> {
                val segundos = (call.argument<Int>("segundos") ?: 30).coerceIn(5, 300)
                // Sonar llama al terminar desde el hilo principal, una sola vez
                // (también si otro «sonar» lo interrumpe).
                Sonar.iniciar(ctx, segundos) { tocado, seg ->
                    principal.post { result.success(mapOf("tocado" to tocado, "segundos" to seg)) }
                }
            }
            "detenerSonar" -> {
                Sonar.detener()
                result.success(null)
            }
            "sonando" -> result.success(Sonar.sonando)
            else -> enFondo(result) { leer(ctx, call) }
        }
    }

    /** Corre [trabajo] en el hilo de fondo y contesta en el principal. */
    private fun enFondo(result: MethodChannel.Result, trabajo: () -> Any?) {
        val ex = fondo
        if (ex == null) {
            result.error("sin_contexto", "El plugin no está enganchado", null)
            return
        }
        try {
            ex.execute {
                // runCatching atrapa también los Error (una clase que falta en
                // un Android viejo): nada de aquí tumba la app.
                val r = runCatching(trabajo)
                principal.post {
                    r.fold(
                        { v -> if (v === NO_IMPLEMENTADO) result.notImplemented() else result.success(v) },
                        { e -> result.error("error", e.message ?: e.javaClass.simpleName, null) },
                    )
                }
            }
        } catch (e: RejectedExecutionException) {
            result.error("sin_contexto", "El plugin se está cerrando", null)
        }
    }

    private fun leer(ctx: Context, call: MethodCall): Any? = when (call.method) {
        "equipo" -> aDart(Lectura.equipo(ctx).put("huella", Lectura.huella(ctx)))
        "fuente" -> aDart(Lectura.fuente(ctx, "app"))
        "estado" -> aDart(Lectura.estado(ctx))
        "ubicacion" -> {
            val plazo = (call.argument<Number>("plazo_ms")?.toLong() ?: 20_000L).coerceIn(1_000L, 60_000L)
            if (Ubicacion.tienePermiso(ctx)) Ubicacion.leer(ctx, plazo)?.let { aDart(Ubicacion.json(it)) } else null
        }
        "permisoUbicacion" -> Ubicacion.tienePermiso(ctx)
        "apps" -> aDart(Lectura.apps(ctx))
        "firma" -> Lectura.firma(Lectura.apps(ctx))
        "almacen" -> leerAlmacen(ctx)
        "guardar" -> {
            guardar(ctx, call.arguments as? Map<*, *> ?: emptyMap<String, Any?>())
            null
        }
        "olvidar" -> {
            almacen(ctx).olvidar()
            cola(ctx).vaciar()
            null
        }
        "colaAgregar" -> {
            val r = call.argument<Map<*, *>>("reporte") ?: emptyMap<String, Any?>()
            val c = cola(ctx)
            c.agregar(JSONObject(r))
            c.tamano
        }
        "colaPendientes" -> aDart(cola(ctx).pendientes())
        "colaVaciar" -> {
            cola(ctx).vaciar()
            null
        }
        "yaAtendida" -> {
            val id = call.argument<Number>("id")?.toLong() ?: 0L
            id > 0 && almacen(ctx).yaAtendida(id)
        }
        else -> NO_IMPLEMENTADO
    }

    private fun leerAlmacen(ctx: Context): Map<String, Any?> {
        val a = almacen(ctx)
        return mapOf(
            "hub" to a.hub,
            "credencial" to a.credencial,
            "equipo_id" to a.equipoId,
            "equipo_nombre" to a.equipoNombre,
            "intervalo_s" to a.intervaloS,
            "ubicacion" to a.ubicacion,
            "firma_apps" to a.firmaApps,
            "ultimo_reporte_t" to a.ultimoReporteT,
            "huella_alta" to (prefs(ctx).getString("huella_alta", "") ?: ""),
            "pendientes" to cola(ctx).tamano,
        )
    }

    /** Solo cambia lo que viene. */
    private fun guardar(ctx: Context, m: Map<*, *>) {
        val a = almacen(ctx)
        (m["hub"] as? String)?.let { a.hub = it }
        (m["credencial"] as? String)?.let { a.credencial = it }
        (m["equipo_id"] as? Number)?.let { a.equipoId = it.toLong() }
        (m["equipo_nombre"] as? String)?.let { a.equipoNombre = it }
        (m["intervalo_s"] as? Number)?.let { a.intervaloS = it.toInt() }
        (m["ubicacion"] as? Boolean)?.let { a.ubicacion = it }
        (m["firma_apps"] as? String)?.let { a.firmaApps = it }
        (m["ultimo_reporte_t"] as? Number)?.let { a.ultimoReporteT = it.toLong() }
        // Con qué ANDROID_ID se sacó la credencial. Si una copia de seguridad
        // trae estas preferencias a otro teléfono, la huella ya no es la misma
        // y la app se da de alta como el equipo que es (ver DeviceTrack).
        (m["huella_alta"] as? String)?.let { prefs(ctx).edit().putString("huella_alta", it).apply() }
    }

    /** De org.json a lo que entiende el canal: mapas, listas y escalares. */
    private fun aDart(v: Any?): Any? = when (v) {
        null, JSONObject.NULL -> null
        is JSONObject -> {
            val m = HashMap<String, Any?>()
            for (k in v.keys()) m[k] = aDart(v.opt(k))
            m
        }
        is JSONArray -> List(v.length()) { aDart(v.opt(it)) }
        else -> v
    }
}
