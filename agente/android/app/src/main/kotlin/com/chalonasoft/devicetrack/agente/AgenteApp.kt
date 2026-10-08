package com.chalonasoft.devicetrack.agente

import android.app.Application

class AgenteApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Avisos.crearCanales(this)
    }
}
