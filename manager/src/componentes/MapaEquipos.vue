<script setup>
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import { api, consulta, cargaDominios, hace, fecha, distancia, estados, colorEquipo } from '../api.js'
import { creaMapa, circuloZona, colores, esc, L } from '../mapa.js'

defineProps({ yo: Object })

const equipos = ref([])
const zonas = ref([])
const dominios = ref([])
const dominio = ref('')
const variosDominios = computed(() => dominios.value.length > 1)
const error = ref('')
const elMapa = ref(null)
let mapa = null
let capaEquipos = null
let capaZonas = null
let reloj = null
let encuadrado = false

const conUbicacion = computed(() => equipos.value.filter((e) => e.lat != null))
const sinUbicacion = computed(() => equipos.value.length - conUbicacion.value.length)
// Con un dominio elegido, sus zonas y las de toda la organización.
const zonasVisibles = computed(() =>
  zonas.value.filter((z) => !dominio.value || z.dominio == null || String(z.dominio) === dominio.value),
)

async function carga() {
  try {
    equipos.value = (await api.get('/v1/equipos' + consulta({ dominio: dominio.value }))).equipos
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
           <span>${esc(estados[e.estado])}${variosDominios.value && e.dominio_nombre ? ` · ${esc(e.dominio_nombre)}` : ''}</span><br>
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
    ...zonasVisibles.value.map((z) => [z.lat, z.lng]),
  ]
  if (!puntos.length) return
  encuadrado = true
  if (puntos.length === 1) mapa.setView(puntos[0], 15)
  else mapa.fitBounds(L.latLngBounds(puntos).pad(0.15), { maxZoom: 16 })
}

function pintaZonas() {
  if (!capaZonas) return
  capaZonas.clearLayers()
  for (const z of zonasVisibles.value) {
    circuloZona(z)
      .bindTooltip(`${esc(z.nombre)} · radio ${esc(distancia(z.radio_m))}`, { sticky: true })
      .addTo(capaZonas)
  }
}

onMounted(async () => {
  mapa = creaMapa(elMapa.value)
  capaZonas = L.layerGroup().addTo(mapa)
  capaEquipos = L.layerGroup().addTo(mapa)
  // Los dominios antes de pintar: el globo de cada equipo dice el suyo solo
  // si hay más de uno.
  const [z, d] = await Promise.allSettled([api.get('/v1/zonas'), cargaDominios()])
  if (z.status === 'fulfilled') zonas.value = z.value.zonas
  if (d.status === 'fulfilled') dominios.value = d.value
  pintaZonas()
  await carga()
  reloj = setInterval(carga, 30000)
})
onUnmounted(() => {
  clearInterval(reloj)
  mapa?.remove()
})
watch(dominio, () => {
  encuadrado = false
  pintaZonas()
  carga()
})
</script>

<template>
  <div class="cabecera-seccion">
    <h2>Mapa</h2>
    <select v-if="variosDominios" v-model="dominio" style="width: auto; margin-left: auto" aria-label="Dominio">
      <option value="">Todos los dominios</option>
      <option v-for="d in dominios" :key="d.id" :value="String(d.id)">{{ d.nombre }}</option>
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
