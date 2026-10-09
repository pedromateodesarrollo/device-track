<script setup>
import { ref, reactive, computed, onMounted, onUnmounted, watch, nextTick } from 'vue'
import { api, cargaDominios, puede, acotado, alcanza, distancia, tiposRegla } from '../api.js'
import { creaMapa, circuloZona, colores, esc, L } from '../mapa.js'

const props = defineProps({ yo: Object })
const puedeEditar = computed(() => puede(props.yo, 'editar'))

const zonas = ref([])
const reglas = ref([])
const dominios = ref([])
const error = ref('')

// ================================================================ dominios
//
// Una regla o una zona es de toda la organización (`dominio` null) o de un
// dominio. Quien está limitada a unos dominios ve las de toda la organización
// pero solo crea y toca las de los suyos.
const sinAcotar = computed(() => !acotado(props.yo))
// El selector «a quién» sale solo si hay algo que elegir: con un único
// dominio a la vista, sin acotar va todo a la organización y acotada, a ese.
const eligeDominio = computed(() => dominios.value.length > 1)
const dominioPorDefecto = () => {
  if (sinAcotar.value) return null
  return dominios.value.length === 1 ? dominios.value[0].id : ''
}
// Si esta sesión puede editar o borrar esa regla o zona.
const toca = (x) => puedeEditar.value && alcanza(props.yo, x.dominio ?? null)

async function carga() {
  try {
    const [z, r] = await Promise.all([api.get('/v1/zonas'), api.get('/v1/reglas')])
    zonas.value = z.zonas
    reglas.value = r.reglas
    error.value = ''
    pintaZonas()
  } catch (e) {
    error.value = e.message
  }
}

// ================================================================== zonas

const elMapa = ref(null)
let mapa = null
let capaZonas = null
let borrador = null
let encuadrado = false

// La zona que se está creando o editando. `id` vacío = nueva.
const zona = reactive({ id: null, nombre: '', dominio: null, lat: null, lng: null, radio_m: 150 })
const editandoZona = ref(false)
const errorZona = ref('')
const confirmaZona = ref(null)

function pintaZonas() {
  if (!capaZonas) return
  capaZonas.clearLayers()
  for (const z of zonas.value) {
    if (editandoZona.value && z.id === zona.id) continue
    circuloZona(z)
      .bindTooltip(esc(z.nombre), { permanent: true, direction: 'center', className: 'etiqueta-zona' })
      .addTo(capaZonas)
  }
  if (!encuadrado && zonas.value.length) {
    encuadrado = true
    const b = L.latLngBounds([])
    for (const z of zonas.value) b.extend(L.latLng(z.lat, z.lng).toBounds(z.radio_m * 2))
    mapa.fitBounds(b.pad(0.2), { maxZoom: 16 })
  }
}

function pintaBorrador() {
  if (!mapa) return
  if (borrador) { mapa.removeLayer(borrador); borrador = null }
  if (!editandoZona.value || zona.lat == null) return
  const c = colores()
  borrador = L.circle([zona.lat, zona.lng], {
    radius: Number(zona.radio_m) || 10,
    color: c.tibio,
    weight: 2,
    dashArray: '6 6',
    fillColor: c.tibio,
    fillOpacity: 0.15,
    interactive: false,
  }).addTo(mapa)
}
watch(() => [zona.lat, zona.lng, zona.radio_m, editandoZona.value], pintaBorrador)
// Al abrir el formulario el mapa cambia de ancho, y Leaflet no se entera solo.
watch(editandoZona, async () => {
  await nextTick()
  mapa?.invalidateSize()
})

function nuevaZona() {
  Object.assign(zona, { id: null, nombre: '', dominio: dominioPorDefecto(), lat: null, lng: null, radio_m: 150 })
  editandoZona.value = true
  errorZona.value = ''
  pintaZonas()
  elMapa.value?.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
}

function editaZona(z) {
  Object.assign(zona, { id: z.id, nombre: z.nombre, dominio: z.dominio ?? null, lat: z.lat, lng: z.lng, radio_m: z.radio_m })
  editandoZona.value = true
  errorZona.value = ''
  pintaZonas()
  mapa?.fitBounds(L.latLng(z.lat, z.lng).toBounds(z.radio_m * 2.6), { maxZoom: 17 })
  elMapa.value?.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
}

function cancelaZona() {
  editandoZona.value = false
  zona.id = null
  pintaZonas()
}

async function guardaZona() {
  errorZona.value = ''
  const cuerpo = {
    nombre: zona.nombre.trim(),
    // Sin elegir (la lista de dominios no llegó): decide el hub.
    ...(zona.dominio !== '' ? { dominio: zona.dominio } : {}),
    lat: Number(zona.lat),
    lng: Number(zona.lng),
    radio_m: Math.round(Number(zona.radio_m)),
  }
  try {
    if (zona.id) await api.patch(`/v1/zonas/${zona.id}`, cuerpo)
    else await api.post('/v1/zonas', cuerpo)
    editandoZona.value = false
    zona.id = null
    await carga()
  } catch (e) {
    errorZona.value = e.message
  }
}

async function borraZona(z) {
  if (confirmaZona.value !== z.id) {
    confirmaZona.value = z.id
    setTimeout(() => (confirmaZona.value === z.id ? (confirmaZona.value = null) : null), 4000)
    return
  }
  confirmaZona.value = null
  try {
    await api.del(`/v1/zonas/${z.id}`)
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

onMounted(async () => {
  mapa = creaMapa(elMapa.value, { zoom: 12 })
  capaZonas = L.layerGroup().addTo(mapa)
  // Mientras se crea o edita una zona, un clic en el mapa pone el centro.
  mapa.on('click', (ev) => {
    if (!editandoZona.value || !puedeEditar.value) return
    zona.lat = Number(ev.latlng.lat.toFixed(6))
    zona.lng = Number(ev.latlng.lng.toFixed(6))
  })
  cargaDominios().then((d) => (dominios.value = d)).catch(() => {})
  await carga()
})
onUnmounted(() => mapa?.remove())

const nombreZona = (id) => zonas.value.find((z) => z.id === Number(id))?.nombre

// ================================================================= reglas

const regla = reactive({ id: null, tipo: 'sin_reporte', nombre: '', dominio: null, minutos: 60, porcentaje: 20, zona: '', activa: true, avisar: '' })
const editandoRegla = ref(false)
const errorRegla = ref('')
const confirmaRegla = ref(null)

// «Fuera de zona» solo con una zona de toda la organización o del mismo
// dominio que la regla: una regla de toda la organización, solo con las de
// toda la organización.
const zonasRegla = computed(() =>
  zonas.value.filter((z) => z.dominio == null || (regla.dominio != null && regla.dominio !== '' && z.dominio === regla.dominio)),
)
// Al cambiar a quién vigila, la zona elegida puede dejar de valer.
watch(() => regla.dominio, () => {
  if (!zonasRegla.value.some((z) => z.id === Number(regla.zona))) regla.zona = zonasRegla.value[0]?.id ?? ''
})

function nuevaRegla() {
  Object.assign(regla, { id: null, tipo: 'sin_reporte', nombre: '', dominio: dominioPorDefecto(), minutos: 60, porcentaje: 20, zona: '', activa: true, avisar: '' })
  regla.zona = zonasRegla.value[0]?.id ?? ''
  editandoRegla.value = true
  errorRegla.value = ''
}

function editaRegla(r) {
  const p = r.parametros || {}
  Object.assign(regla, {
    id: r.id, tipo: r.tipo, nombre: r.nombre, dominio: r.dominio ?? null,
    minutos: p.minutos ?? 60, porcentaje: p.porcentaje ?? 20, zona: p.zona ?? '', activa: r.activa,
    avisar: (r.avisar || []).join(', '),
  })
  editandoRegla.value = true
  errorRegla.value = ''
}

function parametrosDe(r) {
  if (r.tipo === 'sin_reporte') return { minutos: Number(r.minutos) }
  if (r.tipo === 'bateria_baja') return { porcentaje: Number(r.porcentaje) }
  if (r.tipo === 'fuera_de_zona') return { zona: Number(r.zona) }
  return {}
}

async function guardaRegla() {
  errorRegla.value = ''
  if (regla.dominio === '' && eligeDominio.value) {
    errorRegla.value = 'Elige a qué equipos vigila.'
    return
  }
  const cuerpo = {
    nombre: regla.nombre.trim(),
    ...(regla.dominio !== '' ? { dominio: regla.dominio } : {}),
    parametros: parametrosDe(regla),
    activa: regla.activa,
    // Separados por coma, punto y coma, espacio o renglón.
    avisar: regla.avisar.split(/[\s,;]+/).map((c) => c.trim()).filter(Boolean),
  }
  try {
    if (regla.id) await api.patch(`/v1/reglas/${regla.id}`, cuerpo)
    else await api.post('/v1/reglas', { ...cuerpo, tipo: regla.tipo })
    editandoRegla.value = false
    await carga()
  } catch (e) {
    errorRegla.value = e.message
  }
}

// Encender o apagar sin abrir el formulario. El hub pide la regla entera.
async function alternaRegla(r) {
  try {
    await api.patch(`/v1/reglas/${r.id}`, { nombre: r.nombre, dominio: r.dominio ?? null, parametros: r.parametros, activa: !r.activa })
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

async function borraRegla(r) {
  if (confirmaRegla.value !== r.id) {
    confirmaRegla.value = r.id
    setTimeout(() => (confirmaRegla.value === r.id ? (confirmaRegla.value = null) : null), 4000)
    return
  }
  confirmaRegla.value = null
  try {
    await api.del(`/v1/reglas/${r.id}`)
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

function describe(r) {
  const p = r.parametros || {}
  switch (r.tipo) {
    case 'sin_reporte': return `más de ${p.minutos} min sin contacto`
    case 'bateria_baja': return `por debajo del ${p.porcentaje} % sin cargar`
    case 'fuera_de_zona': return `fuera de ${nombreZona(p.zona) || `la zona ${p.zona}`}`
    case 'apagado': return 'cuando avisa que se apaga'
    default: return ''
  }
}

function minutosLegibles(m) {
  m = Number(m)
  if (!m) return ''
  if (m < 60) return `${m} min`
  if (m < 1440) return `${(m / 60).toFixed(m % 60 ? 1 : 0)} h`
  return `${(m / 1440).toFixed(m % 1440 ? 1 : 0)} días`
}
</script>

<template>
  <div class="cabecera-seccion"><h2>Reglas y zonas</h2></div>
  <p class="apagado" style="max-width: 760px">
    Una <strong>regla</strong> dice qué vigilar, para todos los equipos o solo para los de un
    dominio; cuando se cumple abre una alerta, que se cierra sola cuando el equipo se recupera.
    Una <strong>zona</strong> es un círculo en el mapa (el almacén, la sucursal) para la regla
    «fuera de zona».
    <template v-if="!sinAcotar"> Las de toda la organización las ves, pero solo las cambia quien
    ve toda la organización.</template>
  </p>
  <p v-if="error" class="aviso">{{ error }}</p>

  <!-- Reglas -->
  <section class="tarjeta" style="margin-top: 14px">
    <div class="cabecera-seccion" style="margin-bottom: 10px">
      <h3 style="margin: 0">Reglas</h3>
      <button v-if="puedeEditar && !editandoRegla" class="boton chico" @click="nuevaRegla">Nueva regla</button>
    </div>

    <form v-if="editandoRegla" class="subcaja" style="margin-top: 0; margin-bottom: 16px" @submit.prevent="guardaRegla">
      <div class="rejilla-campos">
        <div>
          <label>Tipo</label>
          <select v-model="regla.tipo" :disabled="!!regla.id">
            <option v-for="(t, k) in tiposRegla" :key="k" :value="k">{{ t.nombre }}</option>
          </select>
        </div>
        <div>
          <label>Nombre</label>
          <input v-model="regla.nombre" maxlength="200" :placeholder="tiposRegla[regla.tipo].nombre" />
        </div>
        <div v-if="eligeDominio">
          <label>A quién</label>
          <!-- Sin `required`: la opción de toda la organización vale null, el
               navegador la ve vacía y no dejaría guardar. -->
          <select v-model="regla.dominio">
            <option v-if="sinAcotar" :value="null">Todos los equipos de la organización</option>
            <option v-else value="" disabled>Elige un dominio…</option>
            <option v-for="d in dominios" :key="d.id" :value="d.id">Los equipos de {{ d.nombre }}</option>
          </select>
        </div>
        <div v-if="regla.tipo === 'sin_reporte'">
          <label>Minutos sin contacto</label>
          <input v-model="regla.minutos" type="number" min="5" max="10080" required />
          <span class="apagado chico">{{ minutosLegibles(regla.minutos) }} · de 5 min a una semana</span>
        </div>
        <div v-if="regla.tipo === 'bateria_baja'">
          <label>Por debajo de (%)</label>
          <input v-model="regla.porcentaje" type="number" min="1" max="99" required />
        </div>
        <div v-if="regla.tipo === 'fuera_de_zona'">
          <label>Zona</label>
          <select v-model="regla.zona" required>
            <option value="" disabled>Elige una zona…</option>
            <option v-for="z in zonasRegla" :key="z.id" :value="z.id">{{ z.nombre }} (radio {{ distancia(z.radio_m) }})</option>
          </select>
          <span v-if="!zonas.length" class="apagado chico">Primero crea una zona, abajo.</span>
          <span v-else-if="!zonasRegla.length" class="apagado chico">
            Ninguna zona sirve para estos equipos: crea una abajo, de toda la organización o de su dominio.
          </span>
          <span v-else-if="eligeDominio" class="apagado chico">Solo las zonas de toda la organización o de su mismo dominio.</span>
        </div>
      </div>
      <p class="apagado chico" style="margin: 10px 0 0">{{ tiposRegla[regla.tipo].explica }}</p>
      <label>Avisar por correo a <span class="apagado">(opcional)</span></label>
      <input v-model="regla.avisar" type="text" inputmode="email" autocomplete="off" placeholder="encargado@tu-empresa.com, otra@tu-empresa.com" />
      <span class="apagado chico">
        Cuando la regla abre una alerta les llega un correo, por el correo de salida de la
        organización (Organización → Correo de salida). Por el mismo equipo, como mucho uno por hora.
      </span>
      <label class="casilla" style="margin-top: 10px"><input type="checkbox" v-model="regla.activa" /> Activa</label>
      <p v-if="regla.id" class="apagado chico" style="margin: 6px 0 0">
        Al guardar, las alertas abiertas de esta regla se cierran y se vuelven a evaluar con lo nuevo.
      </p>
      <p v-if="errorRegla" class="aviso" style="margin-top: 10px">{{ errorRegla }}</p>
      <div class="en-linea" style="margin-top: 12px">
        <button class="boton chico">{{ regla.id ? 'Guardar' : 'Crear regla' }}</button>
        <button type="button" class="boton suave chico" @click="editandoRegla = false">Cancelar</button>
      </div>
    </form>

    <p v-if="!reglas.length && !editandoRegla" class="apagado">
      Todavía no hay reglas: los equipos reportan, pero nada abre alertas.
    </p>
    <table v-if="reglas.length" class="tarjetas">
      <thead><tr><th>Regla</th><th>Vigila</th><th>A quién</th><th>Abiertas</th><th>Activa</th><th></th></tr></thead>
      <tbody>
        <tr v-for="r in reglas" :key="r.id" :class="{ cerrada: !r.activa }">
          <td data-t="Regla">
            <strong>{{ r.nombre || tiposRegla[r.tipo]?.nombre }}</strong>
            <div v-if="r.nombre && r.nombre !== tiposRegla[r.tipo]?.nombre" class="apagado chico">{{ tiposRegla[r.tipo]?.nombre }}</div>
            <div v-if="r.avisar?.length" class="apagado chico" :title="r.avisar.join(', ')">
              avisa por correo a {{ r.avisar.length === 1 ? r.avisar[0] : `${r.avisar.length} personas` }}
            </div>
          </td>
          <td data-t="Vigila">{{ describe(r) }}</td>
          <td data-t="A quién">{{ r.dominio != null ? `los de ${r.dominio_nombre}` : 'todos los equipos' }}</td>
          <td data-t="Abiertas">
            <a v-if="r.abiertas" href="#/panel/alertas" class="nueva rojo">{{ r.abiertas }}</a>
            <span v-else class="apagado">0</span>
          </td>
          <td data-t="Activa">
            <button v-if="toca(r)" class="interruptor" :class="{ encendido: r.activa }" :aria-pressed="r.activa" :title="r.activa ? 'Apagar' : 'Encender'" @click="alternaRegla(r)"><span></span></button>
            <span v-else>{{ r.activa ? 'sí' : 'no' }}</span>
          </td>
          <td style="white-space: nowrap; text-align: right">
            <template v-if="toca(r)">
              <button class="boton suave chico" @click="editaRegla(r)">Editar</button>
              <button class="boton chico" :class="confirmaRegla === r.id ? 'peligro' : 'suave'" style="margin-left: 6px" @click="borraRegla(r)">
                {{ confirmaRegla === r.id ? '¿Seguro?' : 'Borrar' }}
              </button>
            </template>
          </td>
        </tr>
      </tbody>
    </table>

    <details class="explica-tipos">
      <summary>Qué hace cada tipo</summary>
      <dl>
        <template v-for="(t, k) in tiposRegla" :key="k">
          <dt>{{ t.nombre }} <code class="apagado">{{ k }}</code></dt>
          <dd class="apagado">{{ t.explica }}</dd>
        </template>
      </dl>
    </details>
  </section>

  <!-- Zonas -->
  <section class="tarjeta" style="margin-top: 18px">
    <div class="cabecera-seccion" style="margin-bottom: 10px">
      <h3 style="margin: 0">Zonas</h3>
      <button v-if="puedeEditar && !editandoZona" class="boton chico" @click="nuevaZona">Nueva zona</button>
    </div>

    <div class="zonas-rejilla" :class="{ editando: editandoZona }">
      <!-- La clase va en un envoltorio: si Vue la pusiera en el div del mapa,
           al cambiarla borraría las que le puso Leaflet (y con ellas el
           `overflow: hidden` que recorta las teselas). -->
      <div :class="{ apuntando: editandoZona }">
        <div ref="elMapa" class="mapa"></div>
        <p v-if="editandoZona" class="apagado chico" style="margin: 6px 0 0">
          {{ zona.lat == null ? 'Haz clic en el mapa para poner el centro de la zona.' : 'Clic en otro sitio del mapa para mover el centro.' }}
        </p>
      </div>

      <form v-if="editandoZona" class="subcaja" style="margin: 0" @submit.prevent="guardaZona">
        <strong>{{ zona.id ? 'Editar zona' : 'Zona nueva' }}</strong>
        <label>Nombre</label>
        <input v-model="zona.nombre" maxlength="200" placeholder="Almacén central" required />
        <template v-if="eligeDominio">
          <label>De quién</label>
          <select v-model="zona.dominio">
            <option v-if="sinAcotar" :value="null">Toda la organización</option>
            <option v-else value="" disabled>Elige un dominio…</option>
            <option v-for="d in dominios" :key="d.id" :value="d.id">{{ d.nombre }}</option>
          </select>
          <span class="apagado chico">
            {{ zona.dominio == null ? 'La ven todos y sirve para cualquier regla.' : 'Solo la ven quienes alcanzan ese dominio, y sirve para sus reglas.' }}
          </span>
        </template>
        <label>Radio</label>
        <input type="range" v-model.number="zona.radio_m" min="10" max="5000" step="10" />
        <div class="en-linea">
          <input type="number" v-model.number="zona.radio_m" min="10" max="100000" style="width: 120px" required />
          <span class="apagado chico">metros · {{ distancia(zona.radio_m) }}</span>
        </div>
        <label>Centro</label>
        <p class="mono" style="margin: 0">
          {{ zona.lat == null ? 'sin poner: clic en el mapa' : `${zona.lat}, ${zona.lng}` }}
        </p>
        <p v-if="errorZona" class="aviso" style="margin-top: 10px">{{ errorZona }}</p>
        <div class="en-linea" style="margin-top: 14px">
          <button class="boton chico" :disabled="zona.lat == null || !zona.nombre.trim() || zona.dominio === ''">{{ zona.id ? 'Guardar' : 'Crear zona' }}</button>
          <button type="button" class="boton suave chico" @click="cancelaZona">Cancelar</button>
        </div>
      </form>
    </div>

    <p v-if="!zonas.length && !editandoZona" class="apagado" style="margin-top: 12px">Todavía no hay zonas.</p>
    <table v-if="zonas.length" class="tarjetas" style="margin-top: 14px">
      <thead><tr><th>Zona</th><th v-if="eligeDominio">De quién</th><th>Radio</th><th>Centro</th><th></th></tr></thead>
      <tbody>
        <tr v-for="z in zonas" :key="z.id">
          <td data-t="Zona"><strong>{{ z.nombre }}</strong></td>
          <td v-if="eligeDominio" data-t="De quién">{{ z.dominio != null ? z.dominio_nombre : 'toda la organización' }}</td>
          <td data-t="Radio">{{ distancia(z.radio_m) }}</td>
          <td data-t="Centro" class="mono">{{ z.lat.toFixed(5) }}, {{ z.lng.toFixed(5) }}</td>
          <td style="white-space: nowrap; text-align: right">
            <template v-if="toca(z)">
              <button class="boton suave chico" @click="editaZona(z)">Editar</button>
              <button class="boton chico" :class="confirmaZona === z.id ? 'peligro' : 'suave'" style="margin-left: 6px" @click="borraZona(z)">
                {{ confirmaZona === z.id ? '¿Seguro?' : 'Borrar' }}
              </button>
            </template>
          </td>
        </tr>
      </tbody>
    </table>
  </section>
</template>
