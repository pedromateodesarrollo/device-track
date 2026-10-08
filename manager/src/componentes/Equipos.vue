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

  <!-- Escritorio: tabla. -->
  <table v-if="visibles.length" class="tabla-equipos solo-ancho">
    <thead>
      <tr>
        <th>Equipo</th><th v-if="variosDominios">Dominio</th><th>Último usuario</th><th>Asignado a</th><th>Estado</th>
        <th>Última vez</th><th>Batería</th><th>Red</th><th>Alertas</th>
      </tr>
    </thead>
    <tbody>
      <tr v-for="e in visibles" :key="e.id" @click="abre(e)" :class="{ retirado: e.estado === 'retirado' }">
        <td>
          <a :href="`#/panel/equipos/${e.id}`" @click.stop><strong>{{ e.nombre }}</strong></a>
          <div class="apagado chico">
            <span v-if="e.etiqueta">{{ e.etiqueta }}</span>
            <span v-if="e.etiqueta && e.modelo"> · </span>
            <span v-if="e.modelo">{{ e.modelo }}</span>
          </div>
        </td>
        <td v-if="variosDominios">{{ e.dominio_nombre }}</td>
        <td :title="ultimoUsuario(e) ? fecha(ultimoUsuario(e).cuando) : ''">
          <template v-if="ultimoUsuario(e)">
            {{ ultimoUsuario(e).nombre }}
            <div class="apagado chico">
              {{ [ultimoUsuario(e).donde, ultimoUsuario(e).sinSesion && 'sin sesión'].filter(Boolean).join(' · ') }}
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
        <td class="apagado chico">{{ red(e) }}</td>
        <td>
          <span v-if="e.alertas" class="nueva rojo">{{ e.alertas }}</span>
        </td>
      </tr>
    </tbody>
  </table>

  <!-- Teléfono y tableta: tarjetas. -->
  <div v-if="visibles.length" class="tarjetas-equipos solo-angosto">
    <a
      v-for="e in visibles"
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
      <div v-if="ultimoUsuario(e)" class="chico">
        {{ ultimoUsuario(e).nombre }}<span class="apagado">{{
          [ultimoUsuario(e).donde, ultimoUsuario(e).sinSesion && 'sin sesión'].filter(Boolean).map((x) => ' · ' + x).join('')
        }}</span>
      </div>
      <div class="fila-3">
        <span>{{ e.conectado ? 'conectado' : hace(e.ultima_vez) }}</span>
        <Bateria :nivel="e.bateria" :cargando="e.cargando" />
        <span class="apagado">{{ red(e) }}</span>
      </div>
    </a>
  </div>
</template>
