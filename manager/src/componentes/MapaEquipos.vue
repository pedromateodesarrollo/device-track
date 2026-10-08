<script setup>
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import { api, consulta, hace, fecha, distancia, estados, colorEquipo } from '../api.js'
import { creaMapa, circuloZona, colores, esc, L } from '../mapa.js'

defineProps({ yo: Object })

const equipos = ref([])
const zonas = ref([])
const grupos = ref([])
const grupo = ref('')
const error = ref('')
const elMapa = ref(null)
let mapa = null
let capaEquipos = null
let capaZonas = null
let reloj = null
let encuadrado = false

const conUbicacion = computed(() => equipos.value.filter((e) => e.lat != null))
const sinUbicacion = computed(() => equipos.value.length - conUbicacion.value.length)

async function carga() {
  try {
    equipos.value = (await api.get('/v1/equipos' + consulta({ grupo: grupo.value }))).equipos
    error.value = ''
    pinta()
  } catch (e) {
    error.value = e.message
  }
}

function pinta() {
  if (!mapa) return
  const c = colores()
  capaEquipos.clearLayers()
  // Lo que pide atención se pinta al último, para que quede encima.
  const peso = { gris: 0, apagado: 0, ok: 1, mal: 2 }
  const orden = [...conUbicacion.value].sort((a, b) => peso[colorEquipo(a)] - peso[colorEquipo(b)])
  for (const e of orden) {
    const color = c[colorEquipo(e)] || c.gris
    L.circleMarker([e.lat, e.lng], {
      radius: 9,
      color: '#fff',
      weight: 2,
      fillColor: color,
      fillOpacity: 1,
    })
      .bindTooltip(esc(e.nombre), { direction: 'top', offset: [0, -8] })
      .bindPopup(
        `<div class="popup-equipo">
           <strong>${esc(e.nombre)}</strong>${e.etiqueta ? ` · ${esc(e.etiqueta)}` : ''}<br>
           <span>${esc(estados[e.estado])}${e.grupo ? ` · ${esc(e.grupo)}` : ''}</span><br>
           <span>${e.conectado ? 'Conectado ahora' : `Visto ${esc(hace(e.ultima_vez))}`}</span>
           ${e.bateria != null ? `<br><span>Batería ${e.bateria} %${e.cargando ? ', cargando' : ''}</span>` : ''}
           ${e.alertas ? `<br><span style="color:${c.mal}">${e.alertas} ${e.alertas === 1 ? 'alerta abierta' : 'alertas abiertas'}</span>` : ''}
           <br><span style="opacity:.7">Posición del ${esc(fecha(e.ubicacion_t))}${e.precision_m ? ` · ± ${esc(distancia(e.precision_m))}` : ''}</span>
           <br><a href="#/panel/equipos/${e.id}">Abrir el equipo →</a>
         </div>`,
      )
      .addTo(capaEquipos)
  }
  // Se encuadra una vez; después, el refresco no le mueve el mapa a quien
  // lo está mirando.
  if (!encuadrado) encuadra()
}

function encuadra() {
  const puntos = [
    ...conUbicacion.value.map((e) => [e.lat, e.lng]),
    ...zonas.value.map((z) => [z.lat, z.lng]),
  ]
  if (!puntos.length) return
  encuadrado = true
  if (puntos.length === 1) mapa.setView(puntos[0], 15)
  else mapa.fitBounds(L.latLngBounds(puntos).pad(0.15), { maxZoom: 16 })
}

function pintaZonas() {
  if (!capaZonas) return
  capaZonas.clearLayers()
  for (const z of zonas.value) {
    circuloZona(z)
      .bindTooltip(`${esc(z.nombre)} · radio ${esc(distancia(z.radio_m))}`, { sticky: true })
      .addTo(capaZonas)
  }
}

onMounted(async () => {
  mapa = creaMapa(elMapa.value)
  capaZonas = L.layerGroup().addTo(mapa)
  capaEquipos = L.layerGroup().addTo(mapa)
  try { zonas.value = (await api.get('/v1/zonas')).zonas } catch { /* sin zonas */ }
  pintaZonas()
  await carga()
  api.get('/v1/grupos').then((d) => (grupos.value = d.grupos)).catch(() => {})
  reloj = setInterval(carga, 30000)
})
onUnmounted(() => {
  clearInterval(reloj)
  mapa?.remove()
})
watch(grupo, () => {
  encuadrado = false
  carga()
})
</script>

<template>
  <div class="cabecera-seccion">
    <h2>Mapa</h2>
    <select v-model="grupo" style="width: auto; margin-left: auto" aria-label="Grupo">
      <option value="">Todos los grupos</option>
      <option v-for="g in grupos" :key="g.grupo" :value="g.grupo">{{ g.grupo }}</option>
    </select>
  </div>
  <p v-if="error" class="aviso">{{ error }}</p>
  <div ref="elMapa" class="mapa grande"></div>
  <p class="apagado chico" style="margin-top: 8px">
    <span class="leyenda" style="margin-left: 0">
      <span><i class="ok"></i>conectado</span>
      <span><i class="gris"></i>desconectado</span>
      <span><i class="mal"></i>con alerta o perdido</span>
      <span><i class="zona"></i>zona</span>
    </span>
    <span style="margin-left: 12px">
      {{ conUbicacion.length }} en el mapa<template v-if="sinUbicacion">; {{ sinUbicacion }} sin ubicación todavía</template>.
    </span>
  </p>
</template>
