package com.chalonasoft.devicetrack.agente

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.chalonasoft.devicetrack.comun.Almacen
import com.chalonasoft.devicetrack.comun.Cola
import com.chalonasoft.devicetrack.comun.ErrorHub
import com.chalonasoft.devicetrack.comun.Hub
import com.chalonasoft.devicetrack.comun.Ubicacion
import com.google.zxing.integration.android.IntentIntegrator

/**
 * La única pantalla del agente. Sin alta: escanear o pegar el código de la
 * organización. Con alta: qué está reportando, a dónde, y los permisos que
 * faltan. El agente trabaja con esta pantalla cerrada; abrirla solo sirve
 * para mirar o arreglar algo.
 */
class MainActivity : Activity() {
    companion object {
        private val HUB_POR_DEFECTO = BuildConfig.HUB_POR_DEFECTO
        private const val PIDE_NOTIFICACIONES = 1
        private const val PIDE_UBICACION = 2
        private const val PIDE_UBICACION_FONDO = 3
    }

    private val main = Handler(Looper.getMainLooper())
    private lateinit var almacen: Almacen
    private val refrescar = object : Runnable {
        override fun run() {
            if (almacen.dadoDeAlta) pintarEstado()
            main.postDelayed(this, 2_000)
        }
    }

    private var d = 1f
    private lateinit var raiz: LinearLayout

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        almacen = Almacen(this)
        d = resources.displayMetrics.density
        raiz = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(px(20), px(24), px(20), px(24))
        }
        setContentView(ScrollView(this).apply { addView(raiz) })
        pintar()
        alIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        alIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        // Con la pantalla delante el servicio arranca con permiso de ubicación
        // «en primer plano»: tras un reinicio de fondo, abrir la app lo recupera.
        if (almacen.dadoDeAlta) despertar(this, AgenteService.ACCION_INICIAR)
        main.post(refrescar)
    }

    override fun onPause() {
        main.removeCallbacks(refrescar)
        super.onPause()
    }

    /** `devicetrack://alta?…` abierto desde la cámara o un enlace. */
    private fun alIntent(i: Intent?) {
        val texto = i?.dataString ?: return
        if (Hub.leerQr(texto) == null) return
        if (almacen.dadoDeAlta) {
            AlertDialog.Builder(this)
                .setTitle("Este equipo ya está dado de alta")
                .setMessage("Para cambiarlo de organización, primero quítalo del seguimiento.")
                .setPositiveButton("Entendido", null)
                .show()
            return
        }
        pintar(texto)
    }

    // ------------------------------------------------------------ pantallas

    private fun pintar(textoInicial: String = "") {
        raiz.removeAllViews()
        if (almacen.dadoDeAlta) pintarEstado() else pintarAlta(textoInicial)
    }

    private lateinit var campo: EditText
    private lateinit var campoHub: EditText
    private lateinit var error: TextView
    private lateinit var botonAlta: Button

    private fun pintarAlta(textoInicial: String) {
        raiz.addView(titulo("device-track"))
        raiz.addView(texto("Da de alta este equipo con el código de tu organización. Está en el panel, en «Códigos de alta»."))
        campo = EditText(this).apply {
            hint = "Escanea o pega el código de alta"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            imeOptions = EditorInfo.IME_ACTION_DONE
            minLines = 2
            setText(textoInicial)
            // El lector de una Zebra escribe el QR aquí y termina con Enter.
            setOnEditorActionListener { _, _, _ -> darDeAlta(); true }
        }
        raiz.addView(campo, margen())
        campoHub = EditText(this).apply {
            hint = "Dirección del hub"
            setText(HUB_POR_DEFECTO)
            inputType = InputType.TYPE_TEXT_VARIATION_URI
            visibility = View.GONE
        }
        raiz.addView(campoHub, margen())
        campo.addTextChangedListener(object : android.text.TextWatcher {
            override fun afterTextChanged(s: android.text.Editable?) {
                // Un código suelto (`dta_…`) no dice a qué hub: se pregunta.
                campoHub.visibility = if (s.toString().trim().startsWith("dta_")) View.VISIBLE else View.GONE
            }
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
        })
        raiz.addView(boton("Escanear con la cámara") { escanear() }, margen())
        botonAlta = boton("Dar de alta") { darDeAlta() }
        raiz.addView(botonAlta, margen())
        error = texto("").apply { setTextColor(0xFFB91C1C.toInt()) }
        raiz.addView(error, margen())
        raiz.addView(
            texto(
                "Después de darlo de alta, este equipo reporta su batería, su red, las apps que tiene y —si tu " +
                    "organización lo pide— su ubicación, y una notificación fija lo dice siempre.",
            ).apply { setTextColor(0xFF64748B.toInt()); textSize = 13f },
            margen(),
        )
        if (textoInicial.isNotEmpty()) darDeAlta()
    }

    private fun escanear() {
        IntentIntegrator(this)
            .setDesiredBarcodeFormats(IntentIntegrator.QR_CODE)
            .setPrompt("Apunta al código QR del código de alta")
            .setBeepEnabled(true)
            .setOrientationLocked(false)
            .initiateScan()
    }

    @Deprecated("Activity sin androidx: el resultado del escáner llega por aquí")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        val r = IntentIntegrator.parseActivityResult(requestCode, resultCode, data)
        if (r != null) {
            r.contents?.let {
                campo.setText(it)
                darDeAlta()
            }
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun darDeAlta() {
        val texto = campo.text.toString().trim()
        val (hub, codigo) = Hub.leerQr(texto)
            ?: if (texto.startsWith("dta_")) {
                campoHub.text.toString().trim().trimEnd('/') to texto
            } else {
                error.text = "Eso no es un código de alta. Empieza por «dta_» o es el QR del panel."
                return
            }
        error.text = ""
        botonAlta.isEnabled = false
        botonAlta.text = "Dando de alta…"
        Thread {
            val falla = try {
                Hub.alta(this, hub, codigo, "agente")
                null
            } catch (e: ErrorHub) {
                e.message ?: e.codigo
            } catch (e: Exception) {
                "No se pudo hablar con $hub. Revisa la red y vuelve a intentar."
            }
            main.post {
                if (falla != null) {
                    error.text = falla
                    botonAlta.isEnabled = true
                    botonAlta.text = "Dar de alta"
                } else {
                    pintar()
                    despertar(this, AgenteService.ACCION_REPORTAR, "abrir")
                    pedirPermisos()
                }
            }
        }.start()
    }

    private val lineas = mutableMapOf<String, TextView>()

    private fun pintarEstado() {
        if (raiz.childCount == 0 || lineas.isEmpty()) {
            raiz.removeAllViews()
            lineas.clear()
            raiz.addView(titulo(almacen.equipoNombre.ifEmpty { "Este equipo" }))
            for (k in listOf("hub", "conexion", "reporte", "cola", "ubicacion", "notificaciones", "bateria", "error")) {
                val t = texto("")
                lineas[k] = t
                raiz.addView(t, margen(6))
            }
            raiz.addView(boton("Reportar ahora") { despertar(this, AgenteService.ACCION_REPORTAR, "manual") }, margen(20))
            raiz.addView(boton("Revisar permisos") { pedirPermisos() }, margen())
            raiz.addView(boton("Quitar este equipo del seguimiento") { quitar() }, margen(28))
        }
        val host = runCatching { Uri.parse(almacen.hub).host }.getOrNull() ?: almacen.hub
        lineas["hub"]?.text = "Reporta a $host"
        lineas["conexion"]?.text = if (AgenteService.conectado) "● Conectado: las órdenes llegan al instante" else "○ Sin conexión ahora: las órdenes llegan en el próximo reporte"
        lineas["reporte"]?.text = if (almacen.ultimoReporteT > 0) {
            "Último reporte: ${Avisos.hora(almacen.ultimoReporteT)} · cada ${almacen.intervaloS / 60} min"
        } else {
            "Todavía no ha reportado"
        }
        val cola = Cola(this).tamano
        lineas["cola"]?.text = if (cola > 0) "$cola reportes esperando red" else ""
        lineas["ubicacion"]?.text = when {
            !almacen.ubicacion -> "Ubicación: tu organización no la pide"
            !Ubicacion.tienePermiso(this) -> "⚠ Ubicación: sin permiso"
            Build.VERSION.SDK_INT >= 29 && !tiene(Manifest.permission.ACCESS_BACKGROUND_LOCATION) ->
                "⚠ Ubicación: solo con la app abierta (falta «Permitir todo el tiempo»)"
            else -> "Ubicación: permitida"
        }
        lineas["notificaciones"]?.text = if (Build.VERSION.SDK_INT >= 33 && !tiene(Manifest.permission.POST_NOTIFICATIONS)) {
            "⚠ Notificaciones: sin permiso (no se ve el aviso fijo ni los mensajes)"
        } else {
            ""
        }
        lineas["bateria"]?.text = if (!sinOptimizar()) "⚠ Ahorro de batería activo: puede retrasar los reportes" else ""
        lineas["error"]?.text = when (almacen.ultimoError) {
            "credencial" -> "⚠ El hub ya no reconoce este equipo: quítalo del seguimiento y dalo de alta de nuevo"
            "sin_red" -> "Sin red en el último intento"
            "" -> ""
            else -> "Último error: ${almacen.ultimoError}"
        }
        for (t in lineas.values) t.visibility = if (t.text.isEmpty()) View.GONE else View.VISIBLE
    }

    private fun quitar() {
        AlertDialog.Builder(this)
            .setTitle("¿Quitar este equipo del seguimiento?")
            .setMessage("Deja de reportar y se olvida del código. En el panel el equipo sigue con su historial; para que vuelva hay que darlo de alta otra vez.")
            .setPositiveButton("Quitar") { _, _ ->
                AgenteService.enviar(this, AgenteService.ACCION_DETENER)
                Programador.cancelar(this)
                Cola(this).vaciar()
                almacen.olvidar()
                lineas.clear()
                pintar()
            }
            .setNegativeButton("Cancelar", null)
            .show()
    }

    // ------------------------------------------------------------- permisos

    /**
     * En orden, uno a la vez: notificaciones, ubicación, ubicación «todo el
     * tiempo» (desde Android 11 solo se da en Ajustes) y sin ahorro de batería.
     */
    private fun pedirPermisos() {
        if (Build.VERSION.SDK_INT >= 33 && !tiene(Manifest.permission.POST_NOTIFICATIONS)) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PIDE_NOTIFICACIONES)
            return
        }
        if (almacen.ubicacion && !Ubicacion.tienePermiso(this)) {
            requestPermissions(
                arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION),
                PIDE_UBICACION,
            )
            return
        }
        if (almacen.ubicacion && Build.VERSION.SDK_INT >= 29 && !tiene(Manifest.permission.ACCESS_BACKGROUND_LOCATION)) {
            AlertDialog.Builder(this)
                .setTitle("Ubicación con la pantalla apagada")
                .setMessage("Para reportar dónde está el equipo con la app cerrada, en la siguiente pantalla elige «Permitir todo el tiempo».")
                .setPositiveButton("Seguir") { _, _ ->
                    requestPermissions(arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION), PIDE_UBICACION_FONDO)
                }
                .setNegativeButton("Ahora no") { _, _ -> pedirBateria() }
                .show()
            return
        }
        pedirBateria()
    }

    @SuppressLint("BatteryLife")
    private fun pedirBateria() {
        if (sinOptimizar()) return
        try {
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")),
            )
        } catch (_: Exception) {
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        // Con la ubicación concedida el servicio cambia a tipo ubicación.
        if (requestCode == PIDE_UBICACION || requestCode == PIDE_UBICACION_FONDO) {
            despertar(this, AgenteService.ACCION_INICIAR)
        }
        if (requestCode == PIDE_UBICACION_FONDO) pedirBateria() else pedirPermisos()
    }

    private fun tiene(p: String) = checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    private fun sinOptimizar(): Boolean =
        getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(packageName) ?: true

    // --------------------------------------------------------------- vistas

    private fun px(dp: Int) = (dp * d).toInt()

    private fun margen(arriba: Int = 12) = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT,
    ).apply { topMargin = px(arriba) }

    private fun titulo(t: String) = TextView(this).apply {
        text = t
        textSize = 24f
        setTypeface(typeface, Typeface.BOLD)
        setTextColor(0xFF0F172A.toInt())
    }

    private fun texto(t: String) = TextView(this).apply {
        text = t
        textSize = 16f
        setTextColor(0xFF334155.toInt())
        gravity = Gravity.START
    }

    private fun boton(t: String, alTocar: () -> Unit) = Button(this).apply {
        text = t
        isAllCaps = false
        textSize = 16f
        setOnClickListener { alTocar() }
    }
}
