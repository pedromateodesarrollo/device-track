<script setup>
// Un panel de un tablero, ya con sus datos (`GET /v1/tableros/:id/datos`).
// Cada forma se dibuja aquí; los datos los calcula el hub con la sesión de
// quien mira.
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { hace, colorEquipo } from '../api.js'
import { creaMapa, colores, esc, L } from '../mapa.js'

const props = defineProps({ panel: Object, quitable: Boolean })
const emit = defineEmits(['quitar'])

const d = computed(() => props.panel.datos || {})
const series = computed(() => d.value.series || [])
const maximo = computed(() => Math.max(1, ...series.value.map((s) => s.valor)))
const confirma = ref(false)

// Los colores de las barras y la dona: de la paleta del panel, en orden.
const paleta = ['var(--marca)', 'var(--zona)', '#0d9488', '#db2777', '#f97316', '#06b6d4', '#84cc16', '#64748b', 'var(--tibio)', '#a1a1aa', 'var(--ok)', 'var(--mal)']
// Los grupos que ya dicen algo llevan su color: lo malo en rojo, lo bueno en
// verde. Los demás, de la paleta en orden.
const conSentido = {
  '0–15 %': 'var(--mal)', '16–50 %': 'var(--tibio)', '51–100 %': 'var(--ok)',
  activo: 'var(--ok)', perdido: 'var(--mal)', guardado: 'var(--tibio)', retirado: 'var(--gris-mapa)',
  Conectado: 'var(--ok)', Desconectado: 'var(--gris-mapa)', Abierta: 'var(--mal)', Cerrada: 'var(--gris-mapa)',
  'Sin dato': 'var(--fondo-3)',
}
const colorDe = (s, i) => conSentido[s.etiqueta] || paleta[i % paleta.length]

// La dona: arcos de un círculo de radio 15.915 (perímetro 100), así cada
// trozo es su porcentaje.
const arcos = computed(() => {
  const total = series.value.reduce((t, s) => t + s.valor, 0) || 1
  let acumulado = 0
  return series.value.map((s, i) => {
    const largo = (s.valor / total) * 100
    const arco = { ...s, color: colorDe(s, i), largo, desde: acumulado, pct: Math.round((s.valor / total) * 100) }
    acumulado += largo
    return arco
  })
})

const fechas = new Set(['ultima_vez', 'abierta', 'cerrada'])
function celda(columna, v) {
  if (v == null || v === '') return '—'
  if (fechas.has(columna)) return hace(v)
  if (columna === 'bateria') return `${v} %`
  if (columna === 'conectado') return v ? 'sí' : 'no'
  return String(v)
}
const enlaceFila = (f) => (f.id != null ? `#/panel/equipos/${f.id}` : null)

// El mapa: Leaflet, como la pantalla de Mapa.
const elMapa = ref(null)
let mapa = null
function pinta() {
  if (!mapa) return
  mapa.eachLayer((l) => { if (l instanceof L.CircleMarker) mapa.removeLayer(l) })
  const c = colores()
  const puntos = d.value.puntos || []
  for (const p of puntos) {
    L.circleMarker([p.lat, p.lng], { radius: 7, color: '#fff', weight: 2, fillColor: c[colorEquipo(p)] || c.gris, fillOpacity: 1 })
      .bindPopup(`<a href="#/panel/equipos/${p.id}"><strong>${esc(p.nombre || `Equipo ${p.id}`)}</strong></a>` +
        (p.bateria != null ? `<br>Batería ${p.bateria} %` : ''))
      .addTo(mapa)
  }
  if (puntos.length) mapa.fitBounds(L.latLngBounds(puntos.map((p) => [p.lat, p.lng])).pad(0.2), { maxZoom: 16 })
}
onMounted(() => {
  if (props.panel.forma === 'mapa' && elMapa.value) {
    mapa = creaMapa(elMapa.value, { zoom: 11 })
    pinta()
  }
})
watch(() => props.panel.datos, pinta)
onUnmounted(() => mapa?.remove())

function quita() {
  if (!confirma.value) {
    confirma.value = true
    setTimeout(() => (confirma.value = false), 4000)
    return
  }
  emit('quitar')
}
</script>

<template>
  <!-- La cifra es la tarjeta de siempre de la portada, con su enlace. -->
  <component
    :is="d.enlace ? 'a' : 'div'"
    v-if="panel.forma === 'cifra' && !panel.error"
    :href="d.enlace"
    class="cifra panel-tablero"
    :class="{ alarma: d.alarma }"
  >
    <span class="numero">{{ d.valor ?? 0 }}</span>
    <span class="titulo">{{ panel.titulo }}</span>
    <button v-if="quitable" class="quitar-panel" :class="{ confirma }" :title="confirma ? '¿Seguro?' : 'Quitar el panel'" @click.prevent.stop="quita">
      {{ confirma ? '¿Quitar?' : '×' }}
    </button>
  </component>

  <section v-else class="tarjeta panel-tablero" :class="{ doble: panel.ancho === 2 }">
    <header class="cabeza-panel">
      <h3>{{ panel.titulo }}</h3>
      <span v-if="d.total != null && panel.forma !== 'cifra'" class="apagado chico">{{ d.total }}</span>
      <button v-if="quitable" class="quitar-panel" :class="{ confirma }" :title="confirma ? '¿Seguro?' : 'Quitar el panel'" @click="quita">
        {{ confirma ? '¿Quitar?' : '×' }}
      </button>
    </header>

    <p v-if="panel.error" class="aviso">No sale: {{ panel.error }}</p>

    <p v-else-if="panel.forma === 'cifra'" class="numero-grande">{{ d.valor ?? 0 }}</p>

    <template v-else-if="panel.forma === 'barras'">
      <p v-if="!series.length" class="apagado chico">Nada que contar.</p>
      <div v-for="(s, i) in series" :key="s.etiqueta" class="barra-fila">
        <span class="barra-etiqueta" :title="s.etiqueta">{{ s.etiqueta }}</span>
        <span class="barra-pista"><span class="barra-relleno" :style="{ width: `${(s.valor / maximo) * 100}%`, background: colorDe(s, i) }"></span></span>
        <span class="barra-valor">{{ s.valor }}</span>
      </div>
    </template>

    <div v-else-if="panel.forma === 'dona'" class="dona">
      <p v-if="!series.length" class="apagado chico">Nada que contar.</p>
      <template v-else>
        <svg viewBox="0 0 42 42" class="dona-svg" role="img" :aria-label="panel.titulo">
          <circle cx="21" cy="21" r="15.915" fill="none" stroke="var(--fondo-3)" stroke-width="6" />
          <circle
            v-for="a in arcos"
            :key="a.etiqueta"
            cx="21" cy="21" r="15.915" fill="none"
            :stroke="a.color" stroke-width="6"
            :stroke-dasharray="`${a.largo} ${100 - a.largo}`"
            :stroke-dashoffset="25 - a.desde"
          />
          <text x="21" y="23" text-anchor="middle" class="dona-total">{{ d.total }}</text>
        </svg>
        <ul class="leyenda-dona">
          <li v-for="a in arcos" :key="a.etiqueta">
            <i :style="{ background: a.color }"></i>{{ a.etiqueta }}
            <span class="apagado">{{ a.valor }} · {{ a.pct }} %</span>
          </li>
        </ul>
      </template>
    </div>

    <template v-else-if="panel.forma === 'tabla'">
      <p v-if="!(d.filas || []).length" class="apagado chico">Nada que enseñar.</p>
      <div v-else class="tabla-panel">
        <table>
          <thead><tr><th v-for="c in d.columnas" :key="c.id">{{ c.titulo }}</th></tr></thead>
          <tbody>
            <tr v-for="(f, i) in d.filas" :key="i">
              <td v-for="(c, j) in d.columnas" :key="c.id">
                <a v-if="j === 0 && enlaceFila(f)" :href="enlaceFila(f)">{{ celda(c.id, f.valores[j]) }}</a>
                <template v-else>{{ celda(c.id, f.valores[j]) }}</template>
              </td>
            </tr>
          </tbody>
        </table>
        <p v-if="d.total > d.filas.length" class="apagado chico" style="margin: 6px 0 0">
          {{ d.filas.length }} de {{ d.total }}
        </p>
      </div>
    </template>

    <template v-else-if="panel.forma === 'mapa'">
      <div ref="elMapa" class="mapa mapa-panel"></div>
      <p class="apagado chico" style="margin: 6px 0 0">
        {{ (d.puntos || []).length }} con ubicación de {{ d.total ?? 0 }}
      </p>
    </template>
  </section>
</template>
