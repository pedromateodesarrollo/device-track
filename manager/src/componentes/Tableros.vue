<script setup>
// La portada: los tableros. Quien no tiene uno propio ve el «Resumen» de
// siempre (id 0). Con el asistente encendido se le pide que lo personalice o
// que arme otros; renombrar, compartir, quitar paneles y borrar se hace aquí
// mismo, también sin asistente.
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import { api } from '../api.js'
import PanelTablero from './PanelTablero.vue'

const props = defineProps({ yo: Object })

const CLAVE = 'device-track-tablero'
const tableros = ref([])
const conIa = ref(false)
const actual = ref(null) // el tablero con sus datos
const elegido = ref(Number(leeElegido()))
const error = ref('')
const cargando = ref(true)
const renombrando = ref(false)
const nombreNuevo = ref('')
const confirmaBorrar = ref(false)
let reloj = null

function leeElegido() {
  try { return localStorage.getItem(CLAVE) || '0' } catch { return '0' }
}
watch(elegido, (v) => {
  try { localStorage.setItem(CLAVE, String(v)) } catch { /* navegación privada */ }
})

const elTablero = computed(() => tableros.value.find((t) => t.id === elegido.value) || tableros.value[0])
const propio = computed(() => !!elTablero.value?.propio)

async function cargaLista() {
  const r = await api.get('/v1/tableros')
  tableros.value = r.tableros
  conIa.value = r.ia
  if (!tableros.value.some((t) => t.id === elegido.value)) elegido.value = tableros.value[0]?.id ?? 0
}

async function cargaDatos() {
  if (!elTablero.value) return
  try {
    actual.value = await api.get(`/v1/tableros/${elTablero.value.id}/datos`)
    error.value = ''
  } catch (e) {
    error.value = e.message
  }
}

async function carga() {
  try {
    await cargaLista()
    await cargaDatos()
  } catch (e) {
    error.value = e.message
  } finally {
    cargando.value = false
  }
}

onMounted(() => {
  carga()
  // Lo de la portada cambia solo: se refresca cada medio minuto mientras se mira.
  reloj = setInterval(cargaDatos, 30000)
})
onUnmounted(() => clearInterval(reloj))

function elige(t) {
  elegido.value = t.id
  actual.value = null
  renombrando.value = false
  confirmaBorrar.value = false
  cargaDatos()
}

// Al asistente, con la pregunta empezada.
const enlaceAsistente = computed(() => {
  const t = elTablero.value
  const pregunta = !t || t.id === 0
    ? 'Quiero personalizar mi Resumen: '
    : t.propio
      ? `Quiero cambiar mi tablero «${t.nombre}»: `
      : 'Quiero un tablero nuevo con '
  return `#/panel/asistente?pregunta=${encodeURIComponent(pregunta)}`
})

async function renombra() {
  try {
    await api.patch(`/v1/tableros/${elTablero.value.id}`, { nombre: nombreNuevo.value.trim() })
    renombrando.value = false
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

async function alternaCompartido() {
  try {
    await api.patch(`/v1/tableros/${elTablero.value.id}`, { compartido: !elTablero.value.compartido })
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

async function borra() {
  if (!confirmaBorrar.value) {
    confirmaBorrar.value = true
    setTimeout(() => (confirmaBorrar.value = false), 4000)
    return
  }
  confirmaBorrar.value = false
  try {
    await api.del(`/v1/tableros/${elTablero.value.id}`)
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

async function quitaPanel(p) {
  try {
    await api.del(`/v1/tableros/${elTablero.value.id}/paneles/${encodeURIComponent(p.id)}`)
    await cargaDatos()
  } catch (e) {
    error.value = e.message
  }
}

// Las cifras van juntas en su fila, como en la portada de siempre; los
// demás paneles, en la rejilla de abajo.
const cifras = computed(() => (actual.value?.paneles || []).filter((p) => p.forma === 'cifra' && !p.error))
const otros = computed(() => (actual.value?.paneles || []).filter((p) => !(p.forma === 'cifra' && !p.error)))
</script>

<template>
  <div class="cabecera-seccion">
    <h2>{{ elTablero?.nombre || 'Inicio' }}</h2>
    <a v-if="conIa" :href="enlaceAsistente" class="boton chico">
      {{ elTablero?.id === 0 ? 'Personalizar con el asistente' : propio ? 'Cambiar con el asistente' : 'Otro tablero con el asistente' }}
    </a>
  </div>
  <p v-if="error" class="aviso">{{ error }}</p>
  <p v-if="cargando" class="apagado">Cargando…</p>

  <nav v-if="tableros.length > 1" class="pestanas" aria-label="Tableros">
    <button
      v-for="t in tableros"
      :key="t.id"
      :class="{ activo: t.id === elTablero?.id }"
      :title="t.propio ? (t.compartido ? 'Tuyo, compartido con la organización' : 'Tuyo') : `De ${t.de}`"
      @click="elige(t)"
    >
      {{ t.nombre }}<span v-if="!t.propio && t.id !== 0" class="apagado"> · {{ t.de }}</span>
    </button>
  </nav>

  <div v-if="propio" class="en-linea acciones-tablero">
    <template v-if="renombrando">
      <input v-model="nombreNuevo" maxlength="80" style="max-width: 260px" @keydown.enter="renombra" />
      <button class="boton chico" :disabled="!nombreNuevo.trim()" @click="renombra">Guardar</button>
      <button class="boton suave chico" @click="renombrando = false">Cancelar</button>
    </template>
    <template v-else>
      <button class="boton suave chico" @click="(nombreNuevo = elTablero.nombre), (renombrando = true)">Renombrar</button>
      <button class="boton suave chico" @click="alternaCompartido">
        {{ elTablero.compartido ? 'Dejar de compartir' : 'Compartir con la organización' }}
      </button>
      <button class="boton chico" :class="confirmaBorrar ? 'peligro' : 'suave'" @click="borra">
        {{ confirmaBorrar ? '¿Borrar el tablero?' : 'Borrar' }}
      </button>
      <span v-if="elTablero.compartido" class="apagado chico">Lo ve toda la organización, cada quien con sus equipos.</span>
    </template>
  </div>
  <p v-else-if="elTablero && elTablero.id !== 0" class="apagado chico">
    Tablero de {{ elTablero.de }}: lo ves con tus equipos, pero solo lo cambia quien lo hizo.
  </p>
  <p v-else-if="!conIa && props.yo?.rol === 'admin' && !cargando" class="apagado chico">
    Con el asistente de IA (Organización → Asistente IA) este tablero se puede personalizar y se pueden
    armar otros.
  </p>

  <div v-if="cifras.length" class="cifras" style="margin-top: 14px">
    <PanelTablero v-for="p in cifras" :key="p.id" :panel="p" :quitable="propio" @quitar="quitaPanel(p)" />
  </div>
  <div v-if="otros.length" class="rejilla-paneles">
    <PanelTablero v-for="p in otros" :key="p.id" :panel="p" :quitable="propio" @quitar="quitaPanel(p)" />
  </div>
  <p v-if="actual && !actual.paneles?.length" class="apagado" style="margin-top: 14px">
    Este tablero está vacío.<template v-if="conIa"> Pídele al asistente que le agregue paneles.</template>
  </p>
</template>
