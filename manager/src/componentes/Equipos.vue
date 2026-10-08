<script>
import { reactive } from 'vue'

// Los filtros viven fuera del componente: al entrar a un equipo y volver, la
// lista sigue como estaba.
const recordados = reactive({
  q: '',
  dominio: '',
  estado: '',
  conectado: '',
  alerta: false,
  retirados: false,
})

// El orden de la lista es una preferencia de quien mira: se recuerda también
// al volver otro día. Sin almacenamiento (navegación privada), dura la visita.
const CLAVE_ORDEN = 'device-track-orden-equipos'
const orden = reactive({ col: 'equipo', dir: 1 })
try {
  const o = JSON.parse(localStorage.getItem(CLAVE_ORDEN) || 'null')
  if (o && typeof o.col === 'string' && (o.dir === 1 || o.dir === -1)) Object.assign(orden, o)
} catch { /* sin almacenamiento */ }
</script>

<script setup>
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import { api, consulta, cargaDominios, hace, fecha, estados, redes, colorEquipo } from '../api.js'
import Bateria from './Bateria.vue'

const props = defineProps({ yo: Object, filtros: { type: Object, default: () => ({}) } })

// Un enlace con filtros (desde el resumen) manda sobre lo recordado.
if (Object.keys(props.filtros).length) {
  Object.assign(recordados, { q: '', dominio: '', estado: '', conectado: '', alerta: false, retirados: false })
  for (const [k, v] of Object.entries(props.filtros)) {
    if (k in recordados) recordados[k] = typeof recordados[k] === 'boolean' ? v === '1' : v
  }
}
const f = recordados

const equipos = ref([])
const dominios = ref([])
// Con un solo dominio a la vista (la organización no los usa, o la persona
// está limitada a uno) no hay nada que filtrar ni que distinguir.
const variosDominios = computed(() => dominios.value.length > 1)
const error = ref('')
const cargando = ref(true)
let espera = null
let reloj = null

async function carga() {
  try {
    const d = await api.get('/v1/equipos' + consulta({
      q: f.q.trim(),
      dominio: f.dominio,
      estado: f.estado,
      // «sin contacto 24 h» no es un filtro del hub: se piden los
      // desconectados y se recorta aquí, con la misma regla que el resumen.
      conectado: f.conectado === 'sin24' ? '0' : f.conectado,
      alerta: f.alerta,
      retirados: f.retirados,
    }))
    equipos.value = d.equipos
    error.value = ''
  } catch (e) {
    error.value = e.message
  } finally {
    cargando.value = false
  }
}

const visibles = computed(() => {
  if (f.conectado !== 'sin24') return equipos.value
  const limite = Date.now() - 24 * 3600 * 1000
  return equipos.value.filter(
    (e) => ['activo', 'perdido'].includes(e.estado) && !e.conectado && new Date(e.ultima_vez).getTime() < limite,
  )
})

onMounted(async () => {
  carga()
  try {
    dominios.value = await cargaDominios()
    // Un filtro recordado de un dominio que ya no está (lo borraron, o es de
    // otra sesión) dejaría la lista vacía sin explicación.
    if (f.dominio && !dominios.value.some((d) => String(d.id) === String(f.dominio))) f.dominio = ''
  } catch { /* el filtro queda sin dominios */ }
  reloj = setInterval(carga, 30000)
})
onUnmounted(() => clearInterval(reloj))

// El texto espera a que se deje de escribir; lo demás, al momento.
watch(() => f.q, () => {
  clearTimeout(espera)
  espera = setTimeout(carga, 300)
})
watch(() => [f.dominio, f.estado, f.conectado, f.alerta, f.retirados], carga)

const hayFiltros = computed(() => f.q || f.dominio || f.estado || f.conectado || f.alerta || f.retirados)
function limpia() {
  Object.assign(f, { q: '', dominio: '', estado: '', conectado: '', alerta: false, retirados: false })
}

const abre = (e) => (location.hash = `#/panel/equipos/${e.id}`)

// Quién lo tenía: el `usuario` del contexto de la fuente que reportó más
// reciente (la app manda quién tiene la sesión, por convención; ver
// docs/api.md). `almacen` o `lugar`, si vienen, van debajo. Con `sesion: false`
// la app ya cerró la sesión y el nombre es el de la ÚLTIMA: justo lo que se
// pregunta cuando una terminal no aparece.
const ultimoUsuario = (e) => {
  const fuentes = Array.isArray(e.fuentes) ? e.fuentes : []
  const f = fuentes
    .filter((x) => x?.contexto && typeof x.contexto.usuario === 'string' && x.contexto.usuario.trim())
    .sort((a, b) => new Date(b.ultima_vez) - new Date(a.ultima_vez))[0]
  if (!f) return null
  const c = f.contexto
  const donde = typeof c.almacen === 'string' ? c.almacen : typeof c.lugar === 'string' ? c.lugar : ''
  return { nombre: c.usuario.trim(), donde, sinSesion: c.sesion === false, cuando: f.ultima_vez }
}
const red = (e) => {
  if (!e.red_tipo) return ''
  return e.red_tipo === 'wifi' && e.red_ssid ? `Wi-Fi · ${e.red_ssid}` : redes[e.red_tipo] || e.red_tipo
}

// Qué app está reportando: la fuente que reportó más reciente (el agente o una
// app con el plugin), con el nombre que manda (`fuente.nombre`) o, si no lo
// sabe, su paquete. Las demás fuentes del equipo van debajo.
const nombreFuente = (x) => (typeof x.nombre === 'string' && x.nombre.trim()) || x.paquete || x.tipo
const aplicacion = (e) => {
  const fuentes = (Array.isArray(e.fuentes) ? e.fuentes : [])
    .slice()
    .sort((a, b) => new Date(b.ultima_vez) - new Date(a.ultima_vez))
  if (!fuentes.length) return null
  const [f, ...otras] = fuentes
  const tambien = otras.length === 1 ? `también ${nombreFuente(otras[0])}` : otras.length ? `y ${otras.length} más` : ''
  return {
    nombre: nombreFuente(f),
    debajo: [f.version, tambien].filter(Boolean).join(' · '),
    detalle: fuentes
      .map((x) => [nombreFuente(x) + (x.version ? ` ${x.version}` : ''), x.paquete, hace(x.ultima_vez)].join(' · '))
      .join('\n'),
  }
}

// Una fila por equipo con lo que se calcula una vez: lo pintan la tabla y las
// tarjetas, y por ello se ordena.
const filas = computed(() =>
  visibles.value.map((e) => ({ e, app: aplicacion(e), usuario: ultimoUsuario(e), red: red(e) })),
)

// Cada columna dice con qué valor se ordena y hacia dónde va el primer clic:
// las fechas, lo más reciente primero; las alertas, el que más tiene.
const sentidos = {
  texto: { 1: 'de la A a la Z', '-1': 'de la Z a la A' },
  numero: { 1: 'de menor a mayor', '-1': 'de mayor a menor' },
  fecha: { 1: 'lo más antiguo primero', '-1': 'lo más reciente primero' },
}
const columnas = computed(() => [
  { id: 'equipo', titulo: 'Equipo', tipo: 'texto', valor: (x) => x.e.nombre },
  ...(variosDominios.value ? [{ id: 'dominio', titulo: 'Dominio', tipo: 'texto', valor: (x) => x.e.dominio_nombre }] : []),
  { id: 'aplicacion', titulo: 'Aplicación', tipo: 'texto', valor: (x) => x.app?.nombre },
  { id: 'usuario', titulo: 'Último usuario', tipo: 'texto', valor: (x) => x.usuario?.nombre },
  { id: 'asignado', titulo: 'Asignado a', tipo: 'texto', valor: (x) => x.e.asignado_a },
  { id: 'estado', titulo: 'Estado', tipo: 'texto', valor: (x) => estados[x.e.estado] || x.e.estado },
  {
    id: 'ultima', titulo: 'Última vez', tipo: 'fecha', primero: -1,
    // Conectado ahora es lo más reciente que hay.
    valor: (x) => (x.e.conectado ? Infinity : x.e.ultima_vez ? new Date(x.e.ultima_vez).getTime() : null),
  },
  { id: 'bateria', titulo: 'Batería', tipo: 'numero', valor: (x) => x.e.bateria },
  { id: 'red', titulo: 'Red', tipo: 'texto', valor: (x) => x.red },
  { id: 'alertas', titulo: 'Alertas', tipo: 'numero', primero: -1, valor: (x) => x.e.alertas || 0 },
])
// Ordenado por una columna que ya no se ve (el dominio, cuando queda uno
// solo), manda la primera.
const columna = computed(() => columnas.value.find((c) => c.id === orden.col) || columnas.value[0])

// El sentido vale para la columna guardada; si esa ya no se ve, el de la
// primera columna es el de su primer clic.
const dirActual = computed(() => (columna.value.id === orden.col ? orden.dir : columna.value.primero || 1))

const colador = new Intl.Collator('es', { numeric: true, sensitivity: 'base' })
const vacio = (v) => v == null || v === '' || Number.isNaN(v)
const ordenadas = computed(() => {
  const c = columna.value
  const dir = dirActual.value
  return filas.value
    .map((x) => ({ x, v: c.valor(x) }))
    .sort((a, b) => {
      // Lo que no tiene valor va al final, en los dos sentidos.
      if (vacio(a.v) !== vacio(b.v)) return vacio(a.v) ? 1 : -1
      const n = vacio(a.v)
        ? 0
        : typeof a.v === 'number' && typeof b.v === 'number'
          ? (a.v === b.v ? 0 : a.v < b.v ? -1 : 1) * dir
          : colador.compare(String(a.v), String(b.v)) * dir
      return n || colador.compare(a.x.e.nombre || '', b.x.e.nombre || '') || a.x.e.id - b.x.e.id
    })
    .map((a) => a.x)
})

function ordena(col, dir) {
  Object.assign(orden, { col, dir })
  try { localStorage.setItem(CLAVE_ORDEN, JSON.stringify({ col, dir })) } catch { /* sin almacenamiento */ }
}
// Otro clic en la misma columna invierte el sentido.
const ordenaPor = (c) => ordena(c.id, columna.value.id === c.id ? -dirActual.value : c.primero || 1)
// En el teléfono: el selector cambia la columna y el botón, el sentido.
function eligeColumna(id) {
  const c = columnas.value.find((x) => x.id === id)
  if (c) ordena(c.id, c.primero || 1)
}
const invierte = () => ordena(columna.value.id, -dirActual.value)
const ariaOrden = (c) => (columna.value.id !== c.id ? 'none' : dirActual.value > 0 ? 'ascending' : 'descending')
const sentido = (c, dir) => sentidos[c.tipo][dir]
</script>

<template>
  <div class="cabecera-seccion">
    <h2>Equipos</h2>
    <span class="apagado" v-if="!cargando">{{ visibles.length }} {{ visibles.length === 1 ? 'equipo' : 'equipos' }}</span>
  </div>

  <div class="filtros">
    <input v-model="f.q" type="search" placeholder="Buscar por nombre, etiqueta, serie, modelo o persona" class="buscar" />
    <select v-if="variosDominios" v-model="f.dominio" aria-label="Dominio">
      <option value="">Todos los dominios</option>
      <option v-for="d in dominios" :key="d.id" :value="String(d.id)">{{ d.nombre }} ({{ d.equipos }})</option>
    </select>
    <select v-model="f.estado" aria-label="Estado">
      <option value="">Cualquier estado</option>
      <option v-for="(t, k) in estados" :key="k" :value="k">{{ t }}</option>
    </select>
    <select v-model="f.conectado" aria-label="Conexión">
      <option value="">Conectados o no</option>
      <option value="1">Conectados ahora</option>
      <option value="0">Desconectados</option>
      <option value="sin24">Sin contacto 24 h</option>
    </select>
    <label class="casilla"><input type="checkbox" v-model="f.alerta" /> Con alerta</label>
    <label class="casilla" v-if="!f.estado"><input type="checkbox" v-model="f.retirados" /> Mostrar retirados</label>
    <button v-if="hayFiltros" class="boton suave chico" @click="limpia">Quitar filtros</button>
    <span class="ordenar-angosto">
      <select :value="columna.id" aria-label="Ordenar por" @change="eligeColumna($event.target.value)">
        <option v-for="c in columnas" :key="c.id" :value="c.id">Ordenar por {{ c.titulo.toLowerCase() }}</option>
      </select>
      <button class="boton suave chico" type="button" @click="invierte" :title="'Cambiar a ' + sentido(columna, -dirActual)">
        {{ dirActual > 0 ? '↑' : '↓' }} {{ sentido(columna, dirActual) }}
      </button>
    </span>
  </div>

  <p v-if="error" class="aviso">{{ error }}</p>
  <p v-if="cargando" class="apagado">Cargando…</p>
  <div v-else-if="!visibles.length" class="vacio">
    <template v-if="hayFiltros">Ningún equipo con esos filtros.</template>
    <template v-else>
      Todavía no hay equipos. Crea un <a href="#/panel/altas">código de alta</a> y
      escanéalo con el agente desde el equipo.
    </template>
  </div>

  <!-- Escritorio: tabla. Cada encabezado ordena por su columna. -->
  <table v-if="visibles.length" class="tabla-equipos solo-ancho">
    <thead>
      <tr>
        <th v-for="c in columnas" :key="c.id" class="ordenable" :aria-sort="ariaOrden(c)">
          <button
            type="button"
            @click="ordenaPor(c)"
            :title="columna.id === c.id ? 'Ordenado ' + sentido(c, dirActual) + '. Clic para invertir.' : 'Ordenar ' + sentido(c, c.primero || 1)"
          >
            {{ c.titulo }}
            <span class="flecha" aria-hidden="true">{{ columna.id === c.id ? (dirActual > 0 ? '▲' : '▼') : '↕' }}</span>
          </button>
        </th>
      </tr>
    </thead>
    <tbody>
      <tr v-for="{ e, app, usuario, red: r } in ordenadas" :key="e.id" @click="abre(e)" :class="{ retirado: e.estado === 'retirado' }">
        <td>
          <a :href="`#/panel/equipos/${e.id}`" @click.stop><strong>{{ e.nombre }}</strong></a>
          <div class="apagado chico">
            <span v-if="e.etiqueta">{{ e.etiqueta }}</span>
            <span v-if="e.etiqueta && e.modelo"> · </span>
            <span v-if="e.modelo">{{ e.modelo }}</span>
          </div>
        </td>
        <td v-if="variosDominios">{{ e.dominio_nombre }}</td>
        <td :title="app ? app.detalle : ''">
          <template v-if="app">
            {{ app.nombre }}
            <div class="apagado chico">{{ app.debajo }}</div>
          </template>
        </td>
        <td :title="usuario ? fecha(usuario.cuando) : ''">
          <template v-if="usuario">
            {{ usuario.nombre }}
            <div class="apagado chico">
              {{ [usuario.donde, usuario.sinSesion && 'sin sesión'].filter(Boolean).join(' · ') }}
            </div>
          </template>
        </td>
        <td>{{ e.asignado_a }}</td>
        <td><span class="estado-equipo" :class="e.estado">{{ estados[e.estado] }}</span></td>
        <td :title="fecha(e.ultima_vez)">
          <span class="estado">
            <span class="punto" :class="e.conectado ? 'ok' : ''" :title="e.conectado ? 'Conectado' : 'Desconectado'"></span>
            {{ e.conectado ? 'conectado' : hace(e.ultima_vez) }}
          </span>
        </td>
        <td><Bateria :nivel="e.bateria" :cargando="e.cargando" /></td>
        <td class="apagado chico">{{ r }}</td>
        <td>
          <span v-if="e.alertas" class="nueva rojo">{{ e.alertas }}</span>
        </td>
      </tr>
    </tbody>
  </table>

  <!-- Teléfono y tableta: tarjetas. -->
  <div v-if="visibles.length" class="tarjetas-equipos solo-angosto">
    <a
      v-for="{ e, app, usuario, red: r } in ordenadas"
      :key="e.id"
      :href="`#/panel/equipos/${e.id}`"
      class="tarjeta-equipo"
      :class="[colorEquipo(e), { retirado: e.estado === 'retirado' }]"
    >
      <div class="fila-1">
        <span class="punto" :class="e.conectado ? 'ok' : ''"></span>
        <strong>{{ e.nombre }}</strong>
        <span v-if="e.alertas" class="nueva rojo">{{ e.alertas }} {{ e.alertas === 1 ? 'alerta' : 'alertas' }}</span>
        <span class="estado-equipo" :class="e.estado" style="margin-left: auto">{{ estados[e.estado] }}</span>
      </div>
      <div class="apagado chico">
        {{ [e.etiqueta, variosDominios && e.dominio_nombre, e.asignado_a].filter(Boolean).join(' · ') || e.modelo }}
      </div>
      <div v-if="usuario" class="chico">
        {{ usuario.nombre }}<span class="apagado">{{
          [usuario.donde, usuario.sinSesion && 'sin sesión'].filter(Boolean).map((x) => ' · ' + x).join('')
        }}</span>
      </div>
      <div v-if="app" class="chico">
        {{ app.nombre }}<span class="apagado">{{ app.debajo ? ' · ' + app.debajo : '' }}</span>
      </div>
      <div class="fila-3">
        <span>{{ e.conectado ? 'conectado' : hace(e.ultima_vez) }}</span>
        <Bateria :nivel="e.bateria" :cargando="e.cargando" />
        <span class="apagado">{{ r }}</span>
      </div>
    </a>
  </div>
</template>
