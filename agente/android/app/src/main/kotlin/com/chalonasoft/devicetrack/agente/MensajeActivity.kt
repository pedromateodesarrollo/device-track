package com.chalonasoft.devicetrack.agente

import android.app.Activity
import android.graphics.Typeface
import android.os.Bundle
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/** Un «mostrar mensaje» del panel, a pantalla completa. */
class MensajeActivity : Activity() {
    companion object {
        const val TITULO = "titulo"
        const val TEXTO = "texto"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val d = resources.displayMetrics.density
        val titulo = intent.getStringExtra(TITULO).orEmpty().ifEmpty { "Mensaje para este equipo" }
        val texto = intent.getStringExtra(TEXTO).orEmpty()
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding((32 * d).toInt(), (32 * d).toInt(), (32 * d).toInt(), (32 * d).toInt())
            addView(TextView(context).apply {
                text = titulo
                textSize = 26f
                setTypeface(typeface, Typeface.BOLD)
                gravity = Gravity.CENTER
            })
            addView(TextView(context).apply {
                text = texto
                textSize = 22f
                gravity = Gravity.CENTER
                setPadding(0, (24 * d).toInt(), 0, (32 * d).toInt())
            })
            addView(Button(context).apply {
                text = "Entendido"
                textSize = 18f
                setOnClickListener { finish() }
            })
        })
    }
}
