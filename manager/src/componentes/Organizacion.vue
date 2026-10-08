<script setup>
import { ref, reactive, computed, onMounted } from 'vue'
import { api, fecha } from '../api.js'

defineProps({ yo: Object })

const org = ref(null)
const f = reactive({ nombre: '', minutos: 10, ubicacion: true, dias_historial: 90, webhook_url: '' })
const error = ref('')
const listo = ref(false)
const guardando = ref(false)
const secreto = ref('')
const confirmaSecreto = ref(false)
const prueba = ref(null)
const probando = ref(false)
const copiado = ref(false)

function llena(o) {
  org.value = o
  Object.assign(f, {
    nombre: o.nombre,
    minutos: Math.round(o.intervalo_s / 60),
    ubicacion: o.ubicacion,
    dias_historial: o.dias_historial,
    webhook_url: o.webhook_url,
  })
}

onMounted(async () => {
  try {
    llena(await api.get('/v1/org'))
  } catch (e) {
    error.value = e.message
  }
})

const cambios = computed(() => {
  const o = org.value
  if (!o) return {}
  const c = {}
  if (f.nombre.trim() !== o.nombre) c.nombre = f.nombre.trim()
  if (Number(f.minutos) * 60 !== o.intervalo_s) c.intervalo_s = Math.round(Number(f.minutos) * 60)
  if (f.ubicacion !== o.ubicacion) c.ubicacion = f.ubicacion
  if (Number(f.dias_historial) !== o.dias_historial) c.dias_historial = Number(f.dias_historial)
  if (f.webhook_url.trim() !== o.webhook_url) c.webhook_url = f.webhook_url.trim()
  return c
})

async function guarda() {
  error.value = ''
  listo.value = false
  guardando.value = true
  try {
    llena(await api.patch('/v1/org', cambios.value))
    listo.value = true
    setTimeout(() => (listo.value = false), 3000)
  } catch (e) {
    error.value = e.message
  } finally {
    guardando.value = false
  }
}

async function generaSecreto() {
  if (org.value.webhook_firmado && !confirmaSecreto.value) {
    confirmaSecreto.value = true
    return
  }
  confirmaSecreto.value = false
  try {
    secreto.value = (await api.post('/v1/org/webhook/secreto')).secreto
    org.value.webhook_firmado = true
  } catch (e) {
    error.value = e.message
  }
}

async function prueba_() {
  prueba.value = null
  probando.value = true
  try {
    prueba.value = (await api.post('/v1/org/webhook/prueba')).estado_http
  } catch (e) {
    error.value = e.message
  } finally {
    probando.value = false
  }
}

async function copia() {
  try {
    await navigator.clipboard.writeText(secreto.value)
    copiado.value = true
    setTimeout(() => (copiado.value = false), 2000)
  } catch { /* está a la vista */ }
}

const intervaloTexto = computed(() => {
  const m = Number(f.minutos)
  if (!m) return ''
  if (m < 60) return `cada ${m} min`
  return `cada ${(m / 60).toFixed(m % 60 ? 1 : 0)} h`
})
</script>

<template>
  <div class="cabecera-seccion"><h2>Organización</h2></div>
  <p v-if="error" class="aviso">{{ error }}</p>
  <p v-if="!org && !error" class="apagado">Cargando…</p>

  <template v-if="org">
    <p class="apagado chico">
      <code>{{ org.slug }}</code> · creada el {{ fecha(org.creado) }}
    </p>

    <form class="tarjeta" style="max-width: 680px" @submit.prevent="guarda">
      <h3>Datos y equipos</h3>
      <label>Nombre</label>
      <input v-model="f.nombre" maxlength="200" required />

      <label>Cada cuánto reportan los equipos</label>
      <div class="en-linea">
        <input v-model="f.minutos" type="number" min="1" max="1440" style="width: 110px" required />
        <span class="apagado chico">minutos · {{ intervaloTexto }}</span>
      </div>
      <p class="apagado chico" style="margin: 6px 0 0">
        Diez minutos es lo que Android deja con el teléfono dormido; menos gasta batería sin
        ganar mucho. Los equipos conectados se enteran al momento; los demás, en su próximo reporte.
      </p>

      <label class="casilla" style="margin-top: 16px">
        <input type="checkbox" v-model="f.ubicacion" /> Pedir la ubicación a los equipos
      </label>
      <p class="apagado chico" style="margin: 4px 0 0">
        Apagada, el equipo no la manda y el hub no la guarda. Sin ubicación no hay mapa, recorrido
        ni regla «fuera de zona».
      </p>

      <label>Días que se guarda el historial</label>
      <div class="en-linea">
        <input v-model="f.dias_historial" type="number" min="1" max="3650" style="width: 110px" required />
        <span class="apagado chico">los reportes más viejos se borran solos</span>
      </div>

      <h3 style="margin-top: 26px">Webhook</h3>
      <p class="apagado chico">
        Cuando se abre o se cierra una alerta, el hub manda un POST con la alerta a esta dirección,
        firmado con HMAC-SHA256 en la cabecera <code>X-Device-Track-Firma</code>. Sin reintentos: lo
        que no llega se ve en el panel igual.
      </p>
      <label>URL</label>
      <input v-model="f.webhook_url" type="url" placeholder="https://tu-sistema.ejemplo.com/avisos" />

      <p v-if="listo" class="apagado" style="margin-top: 12px">Listo: guardado.</p>
      <button class="boton" style="margin-top: 16px" :disabled="!Object.keys(cambios).length || guardando">
        {{ guardando ? 'Guardando…' : 'Guardar' }}
      </button>
    </form>

    <div class="tarjeta" style="max-width: 680px; margin-top: 18px">
      <h3>Firma y prueba del webhook</h3>
      <p class="apagado chico">
        {{ org.webhook_firmado ? 'El webhook ya tiene secreto: cada aviso va firmado.' : 'Todavía no hay secreto: los avisos van sin firmar.' }}
      </p>

      <div v-if="secreto" class="exito" style="margin-top: 10px">
        Cópialo ahora: <strong>no se vuelve a mostrar</strong>. Ponlo en el sistema que recibe los avisos.
        <div class="secreto">{{ secreto }}</div>
        <div class="en-linea" style="margin-top: 10px">
          <button class="boton chico" @click="copia">{{ copiado ? 'Copiado' : 'Copiar' }}</button>
          <button class="boton suave chico" @click="secreto = ''">Ya lo copié</button>
        </div>
      </div>

      <p v-if="confirmaSecreto" class="aviso">
        Generar otro invalida el de ahora: el sistema que recibe los avisos dejará de reconocerlos
        hasta que le pongas el nuevo.
      </p>
      <div class="en-linea" style="flex-wrap: wrap; margin-top: 10px">
        <button class="boton chico" :class="{ peligro: confirmaSecreto }" @click="generaSecreto">
          {{ confirmaSecreto ? 'Sí, generar otro' : org.webhook_firmado ? 'Generar otro secreto' : 'Generar secreto' }}
        </button>
        <button v-if="confirmaSecreto" class="boton suave chico" @click="confirmaSecreto = false">Cancelar</button>
        <button class="boton suave chico" :disabled="!org.webhook_url || probando" @click="prueba_">
          {{ probando ? 'Probando…' : 'Probar webhook' }}
        </button>
      </div>
      <p v-if="!org.webhook_url" class="apagado chico" style="margin-top: 8px">Para probarlo, primero guarda la URL.</p>
      <p v-if="prueba !== null" class="chico" style="margin-top: 10px" :class="prueba >= 200 && prueba < 300 ? '' : 'aviso'">
        <template v-if="prueba === 0">No se pudo llegar a la URL (no contestó o no existe).</template>
        <template v-else-if="prueba >= 200 && prueba < 300">Llegó: contestó HTTP {{ prueba }}.</template>
        <template v-else>Llegó, pero contestó HTTP {{ prueba }}.</template>
      </p>
    </div>
  </template>
</template>
