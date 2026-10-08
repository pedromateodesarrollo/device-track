<script setup>
import { ref, reactive, computed, onMounted, onUnmounted, watch, nextTick } from 'vue'
import {
  api, consulta, puede, hace, fecha, hora, bytes, distancia, hoyIso,
  estados, redes, motivos, estadosOrden, tiposOrden, tiposRegla, detalleAlerta,
} from '../api.js'
import { creaMapa, circuloZona, colores, esc, panelEncima, L } from '../mapa.js'
import Bateria from './Bateria.vue'

const props = defineProps({ id: Number, yo: Object })

const e = ref(null)
const error = ref('')
const puedeEditar = computed(() => puede(props.yo, 'editar'))
const puedeOrdenar = computed(() => puede(props.yo, 'ordenar'))
const esAdmin = computed(() => props.yo?.rol === 'admin')

// ------------------------------------------------------------------ carga

const ficha = reactive({ nombre: '', etiqueta: '', serie: '', grupo: '', asignado_a: '', notas: '', estado: 'activo' })
const grupos = ref([])
const zonas = ref([])

async function carga() {
  try {
    e.value = await api.get(`/v1/equipos/${props.id}`)
    for (const k of Object.keys(ficha)) ficha[k] = e.value[k] ?? ''
    ordenes.value = e.value.ordenes || []
    error.value = ''
  } catch (err) {
    error.value = err.message
  }
}

onMounted(async () => {
  await carga()
  if (!e.value) return
  api.get('/v1/grupos').then((d) => (grupos.value = d.grupos)).catch(() => {})
  api.get('/v1/zonas').then((d) => { zonas.value = d.zonas; pintaZonas() }).catch(() => {})
  await nextTick()
  montaMapa()
  cargaRecorrido()
})
onUnmounted(() => {
  clearTimeout(relojOrdenes)
  mapa?.remove()
})

// ------------------------------------------------------------------ ficha

const cambios = computed(() => {
  if (!e.value) return {}
  const c = {}
  for (const k of Object.keys(ficha)) if ((ficha[k] ?? '') !== (e.value[k] ?? '')) c[k] = ficha[k]
  return c
})
const hayCambios = computed(() => Object.keys(cambios.value).length > 0)
const guardando = ref(false)
const guardado = ref(false)
const errorFicha = ref('')

async function guarda() {
  errorFicha.value = ''
  guardando.value = true
  try {
    await api.patch(`/v1/equipos/${props.id}`, cambios.value)
    await carga()
    guardado.value = true
    setTimeout(() => (guardado.value = false), 2500)
  } catch (err) {
    errorFicha.value = err.message
  } finally {
    guardando.value = false
  }
}
const deshace = () => { for (const k of Object.keys(ficha)) ficha[k] = e.value[k] ?? '' }

// ---------------------------------------------------------- estado actual

/// Nivel de SDK → versión de Android que la gente conoce.
const versionesAndroid = {
  21: '5.0', 22: '5.1', 23: '6', 24: '7.0', 25: '7.1', 26: '8.0', 27: '8.1', 28: '9',
  29: '10', 30: '11', 31: '12', 32: '12L', 33: '13', 34: '14', 35: '15', 36: '16',
}
const android = computed(() => {
  const n = e.value?.android
  if (!n) return ''
  return versionesAndroid[n] ? `Android ${versionesAndroid[n]} (SDK ${n})` : `SDK ${n}`
})
const usoDisco = computed(() => {
  const { almacenamiento_libre: libre, almacenamiento_total: total } = e.value || {}
  if (!total) return null
  return { libre, total, pct: Math.round(((total - (libre ?? 0)) / total) * 100) }
})
const red = computed(() => {
  if (!e.value?.red_tipo) return 'Sin dato'
  return redes[e.value.red_tipo] || e.value.red_tipo
})

// ------------------------------------------------------------------- mapa

const elMapa = ref(null)
let mapa = null
let capaUltima = null
let capaRecorrido = null
let capaZonas = null

function montaMapa() {
  if (!elMapa.value) return
  const conPunto = e.value.lat != null
  mapa = creaMapa(elMapa.value, {
    centro: conPunto ? [e.value.lat, e.value.lng] : undefined,
    zoom: conPunto ? 16 : 12,
  })
  capaZonas = L.layerGroup().addTo(mapa)
  capaRecorrido = L.layerGroup().addTo(mapa)
  capaUltima = L.layerGroup().addTo(mapa)
  pintaUltima()
  pintaZonas()
}

function pintaUltima() {
  if (!mapa || !capaUltima) return
  capaUltima.clearLayers()
  if (e.value.lat == null) return
  const c = colores()
  const punto = [e.value.lat, e.value.lng]
  if (e.value.precision_m) {
    L.circle(punto, {
      radius: e.value.precision_m, color: c.marca, weight: 1, fillColor: c.marca, fillOpacity: 0.12, interactive: false,
    }).addTo(capaUltima)
  }
  // En su propio panel: si no, el último punto del recorrido (que se pinta
  // después) la tapa.
  L.circleMarker(punto, {
    radius: 8, color: '#fff', weight: 2.5, fillColor: c.marca, fillOpacity: 1, pane: panelEncima(mapa),
  })
    .bindPopup(
      `<strong>${esc(e.value.nombre)}</strong><br>${esc(fecha(e.value.ubicacion_t))}` +
        (e.value.precision_m ? `<br>precisión ± ${esc(distancia(e.value.precision_m))}` : ''),
    )
    .addTo(capaUltima)
}

function pintaZonas() {
  if (!capaZonas) return
  capaZonas.clearLayers()
  for (const z of zonas.value) {
    circuloZona(z, { interactive: false }).addTo(capaZonas)
  }
}

// -------------------------------------------------------------- recorrido

const diaRecorrido = ref(hoyIso())
const puntos = ref([])
const cargandoRecorrido = ref(false)

async function cargaRecorrido() {
  if (!diaRecorrido.value) return
  cargandoRecorrido.value = true
  // El día se cuenta en la hora del navegador: de 00:00 a 00:00 del siguiente.
  const desde = new Date(`${diaRecorrido.value}T00:00:00`)
  const hasta = new Date(desde)
  hasta.setDate(hasta.getDate() + 1)
  try {
    const d = await api.get(
      `/v1/equipos/${props.id}/recorrido` + consulta({ desde: desde.toISOString(), hasta: hasta.toISOString() }),
    )
    puntos.value = d.puntos
    pintaRecorrido()
  } catch (err) {
    error.value = err.message
  } finally {
    cargandoRecorrido.value = false
  }
}
watch(diaRecorrido, cargaRecorrido)

function pintaRecorrido() {
  if (!mapa) return
  capaRecorrido.clearLayers()
  const pts = puntos.value
  if (!pts.length) return
  const c = colores()
  const linea = pts.map((p) => [p.lat, p.lng])
  L.polyline(linea, { color: c.marca, weight: 3, opacity: 0.8 }).addTo(capaRecorrido)
  pts.forEach((p, i) => {
    const extremo = i === 0 || i === pts.length - 1
    L.circleMarker([p.lat, p.lng], {
      radius: extremo ? 6 : 3.5,
      color: '#fff',
      weight: extremo ? 2 : 1,
      fillColor: i === 0 ? c.ok : i === pts.length - 1 ? c.mal : c.marca,
      fillOpacity: 1,
    })
      .bindTooltip(
        `${esc(hora(p.t))}${p.precision_m ? ` · ± ${esc(distancia(p.precision_m))}` : ''}` +
          (p.motivo && p.motivo !== 'periodico' ? ` · ${esc(motivos[p.motivo] || p.motivo)}` : ''),
      )
      .addTo(capaRecorrido)
  })
  mapa.fitBounds(L.latLngBounds(linea).pad(0.2), { maxZoom: 17 })
}

const recorridoTexto = computed(() => {
  const pts = puntos.value
  if (!pts.length) return 'Ese día no hay puntos de ubicación.'
  let m = 0
  for (let i = 1; i < pts.length; i++) m += metros(pts[i - 1], pts[i])
  return `${pts.length} ${pts.length === 1 ? 'punto' : 'puntos'}, de ${hora(pts[0].t)} a ${hora(pts.at(-1).t)}` +
    (pts.length > 1 ? `, unos ${distancia(m)} en línea recta entre puntos` : '')
})

function metros(a, b) {
  const r = 6371000
  const rad = (g) => (g * Math.PI) / 180
  const dLat = rad(b.lat - a.lat)
  const dLng = rad(b.lng - a.lng)
  const x = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2
  return 2 * r * Math.asin(Math.min(1, Math.sqrt(x)))
}

function centraUltima() {
  if (mapa && e.value?.lat != null) mapa.setView([e.value.lat, e.value.lng], 17)
}

// ---------------------------------------------------------------- órdenes

const ordenes = ref([])
const segundos = ref(30)
const titulo = ref('')
const mensaje = ref('')
const errorOrden = ref('')
const enviando = ref('')
const avisoOrden = ref('')
let relojOrdenes = null

async function ordena(tipo) {
  errorOrden.value = ''
  avisoOrden.value = ''
  enviando.value = tipo
  const datos = tipo === 'sonar'
    ? { segundos: Number(segundos.value) || 30 }
    : tipo === 'mensaje'
      ? { titulo: titulo.value, texto: mensaje.value }
      : {}
  try {
    const o = await api.post(`/v1/equipos/${props.id}/ordenes`, { tipo, datos })
    avisoOrden.value = o.estado === 'enviada'
      ? 'Enviada: el equipo está conectado y le llegó ya.'
      : 'En espera: le llega en cuanto se conecte o mande su próximo reporte.'
    if (tipo === 'mensaje') { titulo.value = ''; mensaje.value = '' }
    await cargaOrdenes()
  } catch (err) {
    errorOrden.value = err.message
  } finally {
    enviando.value = ''
  }
}

async function cargaOrdenes() {
  clearTimeout(relojOrdenes)
  try {
    ordenes.value = (await api.get(`/v1/equipos/${props.id}/ordenes`)).ordenes.slice(0, 10)
  } catch { /* se queda la lista de antes */ }
  // Mientras haya una orden reciente sin terminar, se mira cada pocos
  // segundos en qué va: es lo que la persona está esperando ver.
  const hace5min = Date.now() - 5 * 60 * 1000
  const enCurso = ordenes.value.some(
    (o) => ['pendiente', 'enviada', 'recibida'].includes(o.estado) && new Date(o.creado).getTime() > hace5min,
  )
  if (enCurso) relojOrdenes = setTimeout(cargaOrdenes, 4000)
}

function datosOrden(o) {
  const d = o.datos || {}
  if (o.tipo === 'sonar') return `${d.segundos ?? 30} s`
  if (o.tipo === 'mensaje') return [d.titulo, d.texto].filter(Boolean).join(': ')
  return ''
}
const claseOrden = (s) => ({ hecha: 'verde', fallida: 'rojo', vencida: 'gris', pendiente: 'gris' })[s] || ''

// --------------------------------------------------------- unir y borrar

const otros = ref([])
const unirCon = ref('')
const uniendo = ref(false)
const confirmaUnir = ref(false)
const errorUnir = ref('')
const abiertoUnir = ref(false)

async function abreUnir() {
  abiertoUnir.value = !abiertoUnir.value
  if (abiertoUnir.value && !otros.value.length) {
    try {
      otros.value = (await api.get('/v1/equipos?retirados=1')).equipos.filter((x) => x.id !== props.id)
    } catch (err) {
      errorUnir.value = err.message
    }
  }
}
const elegido = computed(() => otros.value.find((x) => String(x.id) === String(unirCon.value)))

async function une() {
  if (!confirmaUnir.value) { confirmaUnir.value = true; return }
  uniendo.value = true
  errorUnir.value = ''
  try {
    await api.post(`/v1/equipos/${props.id}/unir`, { con: Number(unirCon.value) })
    confirmaUnir.value = false
    abiertoUnir.value = false
    unirCon.value = ''
    otros.value = []
    await carga()
    pintaUltima()
    cargaRecorrido()
  } catch (err) {
    errorUnir.value = err.message
  } finally {
    uniendo.value = false
  }
}

const confirmaBorrar = ref(false)
const errorBorrar = ref('')
async function borra() {
  errorBorrar.value = ''
  try {
    await api.del(`/v1/equipos/${props.id}`)
    location.hash = '#/panel/equipos'
  } catch (err) {
    errorBorrar.value = err.message
  }
}
async function retira() {
  try {
    await api.patch(`/v1/equipos/${props.id}`, { estado: 'retirado' })
    confirmaBorrar.value = false
    await carga()
  } catch (err) {
    errorBorrar.value = err.message
  }
}

// ---------------------------------------------------------------- fuentes

function pares(contexto) {
  if (!contexto || typeof contexto !== 'object') return []
  return Object.entries(contexto).map(([k, v]) => [k, v !== null && typeof v === 'object' ? JSON.stringify(v) : String(v)])
}
const fuentesVivas = computed(() => (e.value?.fuentes || []).filter((f) => !f.revocada))
const fuentesRevocadas = computed(() => (e.value?.fuentes || []).filter((f) => f.revocada))
const apps = computed(() => e.value?.apps || [])
</script>

<template>
  <p style="margin-bottom: 10px"><a href="#/panel/equipos">← Equipos</a></p>
  <p v-if="error" class="aviso">{{ error }}</p>
  <p v-if="!e && !error" class="apagado">Cargando…</p>

  <template v-if="e">
    <div class="cabecera-equipo">
      <span class="punto grande" :class="e.conectado ? 'ok' : ''" :title="e.conectado ? 'Conectado' : 'Desconectado'"></span>
      <div>
        <h2 style="margin: 0">{{ e.nombre }}</h2>
        <div class="apagado" style="font-size: 14px">
          {{ [e.etiqueta, e.modelo, e.grupo].filter(Boolean).join(' · ') }}
          <template v-if="!e.etiqueta && !e.modelo && !e.grupo">Equipo {{ e.id }}</template>
        </div>
      </div>
      <span class="estado-equipo" :class="e.estado">{{ estados[e.estado] }}</span>
      <span class="apagado chico">{{ e.conectado ? 'conectado ahora' : `visto ${hace(e.ultima_vez)}` }}</span>
    </div>

    <!-- Alertas abiertas: arriba, que es lo primero que hay que ver. -->
    <div v-if="e.alertas_abiertas?.length" class="caja-alerta">
      <strong>{{ e.alertas_abiertas.length === 1 ? 'Una alerta abierta' : `${e.alertas_abiertas.length} alertas abiertas` }}</strong>
      <ul>
        <li v-for="a in e.alertas_abiertas" :key="a.id">
          {{ a.regla || tiposRegla[a.tipo]?.nombre }}: {{ detalleAlerta(a) }}
          <span class="apagado"> · {{ hace(a.abierta) }}</span>
        </li>
      </ul>
      <a href="#/panel/alertas" class="chico">Ir a alertas</a>
    </div>

    <div class="dos-columnas">
      <!-- Estado actual -->
      <section class="tarjeta">
        <h3>Estado actual</h3>
        <dl class="datos">
          <dt>Batería</dt>
          <dd><Bateria :nivel="e.bateria" :cargando="e.cargando" /><span v-if="e.cargando" class="apagado chico"> cargando</span></dd>
          <dt>Red</dt>
          <dd>{{ red }}<span v-if="e.red_ssid" class="apagado"> · {{ e.red_ssid }}</span></dd>
          <dt>Almacenamiento</dt>
          <dd>
            <template v-if="usoDisco">
              {{ bytes(usoDisco.libre) }} libres de {{ bytes(usoDisco.total) }}
              <div class="barrita"><div :style="{ width: usoDisco.pct + '%' }" :class="{ lleno: usoDisco.pct > 90 }"></div></div>
            </template>
            <span v-else class="apagado">Sin dato</span>
          </dd>
          <dt>Android</dt>
          <dd>{{ android || 'Sin dato' }}</dd>
          <dt>Modelo</dt>
          <dd>{{ [e.fabricante, e.modelo].filter(Boolean).join(' ') || 'Sin dato' }}</dd>
          <dt>Último reporte</dt>
          <dd>
            <template v-if="e.ultimo_reporte">
              {{ fecha(e.ultimo_reporte) }}
              <span class="apagado">· {{ motivos[e.ultimo_motivo] || e.ultimo_motivo }}</span>
            </template>
            <span v-else class="apagado">Todavía no ha reportado</span>
          </dd>
          <dt>Última vez</dt>
          <dd>{{ e.conectado ? 'Conectado ahora' : fecha(e.ultima_vez) }}</dd>
          <dt>Ubicación</dt>
          <dd>
            <template v-if="e.lat != null">
              {{ fecha(e.ubicacion_t) }}<span v-if="e.precision_m" class="apagado"> · ± {{ distancia(e.precision_m) }}</span>
            </template>
            <span v-else class="apagado">Sin ubicación todavía</span>
          </dd>
          <dt>En el inventario desde</dt>
          <dd>{{ fecha(e.primera_vez) }}</dd>
          <dt>Huella</dt>
          <dd class="mono">{{ e.huella || '—' }}</dd>
        </dl>
      </section>
      <!-- Ficha -->
      <section class="tarjeta">
        <h3>Ficha</h3>
        <p class="apagado chico" style="margin-bottom: 4px">{{ puedeEditar ? 'Lo que pones tú.' : 'Lo que puso quien administra.' }} El estado actual lo cuenta el equipo.</p>
        <form @submit.prevent="guarda" class="ficha">
          <div class="campo"><label>Nombre</label><input v-model="ficha.nombre" :disabled="!puedeEditar" maxlength="200" required /></div>
          <div class="campo"><label>Etiqueta <span class="apagado">(número de activo)</span></label><input v-model="ficha.etiqueta" :disabled="!puedeEditar" maxlength="200" /></div>
          <div class="campo"><label>Serie</label><input v-model="ficha.serie" :disabled="!puedeEditar" maxlength="200" /></div>
          <div class="campo">
            <label>Grupo</label>
            <input v-model="ficha.grupo" :disabled="!puedeEditar" list="grupos-equipo" maxlength="200" placeholder="Almacén, Ruta norte…" />
            <datalist id="grupos-equipo"><option v-for="g in grupos" :key="g.grupo" :value="g.grupo" /></datalist>
          </div>
          <div class="campo"><label>Asignado a</label><input v-model="ficha.asignado_a" :disabled="!puedeEditar" maxlength="200" /></div>
          <div class="campo">
            <label>Estado</label>
            <select v-model="ficha.estado" :disabled="!puedeEditar">
              <option v-for="(t, k) in estados" :key="k" :value="k">{{ t }}</option>
            </select>
          </div>
          <div class="campo ancho">
            <label>Notas</label>
            <textarea v-model="ficha.notas" :disabled="!puedeEditar" maxlength="2000" rows="3"></textarea>
          </div>
        </form>
        <p v-if="puedeEditar && (ficha.estado === 'guardado' || ficha.estado === 'retirado') && ficha.estado !== e.estado" class="apagado chico">
          {{ ficha.estado === 'guardado' ? 'Guardado' : 'Retirado' }}: deja de vigilarse y sus alertas abiertas se cierran.
        </p>
        <p v-if="errorFicha" class="aviso">{{ errorFicha }}</p>
        <div v-if="puedeEditar" style="display: flex; gap: 8px; align-items: center; margin-top: 12px">
          <button class="boton chico" :disabled="!hayCambios || guardando" @click="guarda">{{ guardando ? 'Guardando…' : 'Guardar' }}</button>
          <button v-if="hayCambios" class="boton suave chico" @click="deshace">Deshacer</button>
          <span v-if="guardado" class="apagado chico">Guardado.</span>
        </div>
      </section>

    </div>

    <!-- Mapa y recorrido -->
    <section class="tarjeta" style="margin-top: 18px">
      <div class="cabecera-seccion" style="margin-bottom: 10px">
        <h3 style="margin: 0">Dónde está</h3>
        <div class="recorrido-controles">
          <label for="dia-recorrido" class="chico" style="margin: 0">Recorrido del</label>
          <input id="dia-recorrido" type="date" v-model="diaRecorrido" :max="hoyIso()" />
          <button v-if="e.lat != null" class="boton suave chico" @click="centraUltima">Última posición</button>
        </div>
      </div>
      <div ref="elMapa" class="mapa"></div>
      <p class="apagado chico" style="margin: 8px 0 0">
        <template v-if="cargandoRecorrido">Cargando el recorrido…</template>
        <template v-else>{{ recorridoTexto }}</template>
        <template v-if="e.lat == null"> Este equipo no ha mandado ubicación.</template>
        <span class="leyenda"><span><i class="ok"></i>inicio</span> <span><i class="mal"></i>fin</span> <span><i class="marca"></i>última posición</span> <span><i class="zona"></i>zona</span></span>
      </p>
    </section>

    <!-- Órdenes -->
    <section class="tarjeta" style="margin-top: 18px">
      <h3>Órdenes</h3>
      <template v-if="puedeOrdenar && e.estado !== 'retirado'">
        <p class="apagado chico">
          {{ e.conectado ? 'Está conectado: la orden le llega al instante.' : 'No está conectado: la orden le llega en su próximo reporte (vence en una hora).' }}
        </p>
        <div class="ordenes">
          <div class="orden">
            <strong>Hacer sonar</strong>
            <p class="apagado chico">A todo volumen, aunque esté en silencio, hasta que lo toquen.</p>
            <div class="en-linea">
              <input type="number" v-model="segundos" min="5" max="300" style="width: 90px" aria-label="Segundos" />
              <span class="apagado chico">segundos</span>
              <button class="boton chico" :disabled="!!enviando" @click="ordena('sonar')">{{ enviando === 'sonar' ? 'Enviando…' : 'Hacer sonar' }}</button>
            </div>
          </div>
          <div class="orden">
            <strong>Mostrar mensaje</strong>
            <input v-model="titulo" placeholder="Título (opcional)" maxlength="80" style="margin-top: 6px" />
            <textarea v-model="mensaje" placeholder="Devuelve este equipo a la oficina" maxlength="500" rows="2" style="margin-top: 6px; min-height: 0"></textarea>
            <button class="boton chico" style="margin-top: 6px" :disabled="!!enviando || !mensaje.trim()" @click="ordena('mensaje')">{{ enviando === 'mensaje' ? 'Enviando…' : 'Mostrar mensaje' }}</button>
          </div>
          <div class="orden">
            <strong>Reportar ya</strong>
            <p class="apagado chico">Que mande un reporte ahora, con la ubicación recién leída.</p>
            <button class="boton chico" :disabled="!!enviando" @click="ordena('reportar')">{{ enviando === 'reportar' ? 'Enviando…' : 'Reportar ya' }}</button>
          </div>
        </div>
        <p v-if="avisoOrden" class="exito" style="margin: 12px 0 0">{{ avisoOrden }}</p>
        <p v-if="errorOrden" class="aviso" style="margin-top: 10px">{{ errorOrden }}</p>
      </template>
      <p v-else-if="e.estado === 'retirado'" class="apagado chico">Un equipo retirado no recibe órdenes.</p>

      <h4 style="margin: 18px 0 6px">Últimas órdenes</h4>
      <p v-if="!ordenes.length" class="apagado chico">Ninguna todavía.</p>
      <table v-else class="tarjetas compacta">
        <thead><tr><th>Orden</th><th>Estado</th><th>Creada</th><th>Por</th><th>Detalle</th></tr></thead>
        <tbody>
          <tr v-for="o in ordenes" :key="o.id">
            <td data-t="Orden"><strong>{{ tiposOrden[o.tipo] || o.tipo }}</strong> <span class="apagado">{{ datosOrden(o) }}</span></td>
            <td data-t="Estado"><span class="nueva" :class="claseOrden(o.estado)">{{ estadosOrden[o.estado] || o.estado }}</span></td>
            <td data-t="Creada" class="apagado">{{ fecha(o.creado) }}</td>
            <td data-t="Por" class="apagado mono">{{ o.creado_por }}</td>
            <td data-t="Detalle" class="apagado">{{ o.detalle }}</td>
          </tr>
        </tbody>
      </table>
    </section>

    <!-- Fuentes y apps -->
    <section class="tarjeta" style="margin-top: 18px">
      <h3>Quién reporta</h3>
      <p class="apagado chico">El agente y cada app con el plugin que corre en este equipo. Cada una cuenta su contexto.</p>
      <p v-if="!fuentesVivas.length" class="apagado chico">Ninguna fuente activa.</p>
      <div class="fuentes">
        <div v-for="f in fuentesVivas" :key="f.id" class="fuente">
          <div class="en-linea">
            <span class="nueva" :class="f.tipo === 'agente' ? '' : 'gris'">{{ f.tipo }}</span>
            <code>{{ f.paquete }}</code>
            <span class="apagado chico">{{ f.version }}<template v-if="f.build"> ({{ f.build }})</template></span>
            <span class="apagado chico" style="margin-left: auto" :title="fecha(f.ultima_vez)">{{ hace(f.ultima_vez) }}</span>
          </div>
          <dl v-if="pares(f.contexto).length" class="datos contexto">
            <template v-for="[k, v] in pares(f.contexto)" :key="k">
              <dt>{{ k }}</dt><dd>{{ v }}</dd>
            </template>
          </dl>
        </div>
      </div>
      <p v-if="fuentesRevocadas.length" class="apagado chico" style="margin-top: 8px">
        Revocadas: <code v-for="f in fuentesRevocadas" :key="f.id" style="margin-right: 6px">{{ f.paquete }}</code>
      </p>

      <details class="apps" v-if="apps.length">
        <summary>Apps instaladas ({{ apps.length }}) <span class="apagado chico">· lista del {{ fecha(e.apps_t) }}</span></summary>
        <table class="compacta">
          <thead><tr><th>Paquete</th><th>Versión</th><th>Build</th></tr></thead>
          <tbody>
            <tr v-for="a in apps" :key="a.paquete">
              <td><code>{{ a.paquete }}</code><span v-if="a.nombre" class="apagado"> · {{ a.nombre }}</span></td>
              <td class="apagado">{{ a.version }}</td>
              <td class="apagado">{{ a.build }}</td>
            </tr>
          </tbody>
        </table>
      </details>
      <p v-else class="apagado chico" style="margin-top: 10px">El equipo no ha mandado la lista de apps instaladas.</p>
    </section>

    <!-- Unir y borrar -->
    <section v-if="puedeEditar" class="tarjeta" style="margin-top: 18px">
      <h3>Más</h3>
      <div class="en-linea" style="flex-wrap: wrap">
        <button class="boton suave chico" @click="abreUnir">Unir con otro equipo</button>
        <button v-if="esAdmin" class="boton suave chico peligro-suave" @click="confirmaBorrar = !confirmaBorrar">Borrar equipo</button>
      </div>

      <div v-if="abiertoUnir" class="subcaja">
        <p class="chico">
          Para cuando el mismo teléfono aparece dos veces (se reinstaló, cambió la llave de firma
          de una app). <strong>Se queda este</strong>; el otro se borra después de pasarle sus
          fuentes, su historial, sus órdenes y sus alertas. Lo que escribiste en este manda; lo
          vacío se llena con lo del otro.
        </p>
        <label>El otro equipo</label>
        <select v-model="unirCon" @change="confirmaUnir = false" style="max-width: 460px">
          <option value="">Elige…</option>
          <option v-for="o in otros" :key="o.id" :value="o.id">
            {{ o.nombre }}{{ o.etiqueta ? ` · ${o.etiqueta}` : '' }}{{ o.modelo ? ` · ${o.modelo}` : '' }} — {{ hace(o.ultima_vez) }}{{ o.estado !== 'activo' ? ` (${estados[o.estado].toLowerCase()})` : '' }}
          </option>
        </select>
        <p v-if="confirmaUnir && elegido" class="aviso" style="margin-top: 10px">
          «{{ elegido.nombre }}» deja de existir y todo lo suyo pasa a «{{ e.nombre }}». No se puede deshacer.
        </p>
        <p v-if="errorUnir" class="aviso">{{ errorUnir }}</p>
        <button class="boton chico" :class="{ peligro: confirmaUnir }" style="margin-top: 10px" :disabled="!unirCon || uniendo" @click="une">
          {{ uniendo ? 'Uniendo…' : confirmaUnir ? 'Sí, unirlos' : 'Unir' }}
        </button>
      </div>

      <div v-if="confirmaBorrar" class="subcaja peligro-caja">
        <p class="chico">
          <strong>Borrar se lleva todo:</strong> la ficha, el historial de reportes y recorridos, las
          órdenes y las alertas, y revoca sus credenciales. Es para lo que entró por error.
        </p>
        <p class="chico">
          Para un equipo que se dio de baja está el estado <strong>retirado</strong>: deja de vigilarse
          y de contar, pero la ficha y el historial se quedan.
        </p>
        <p v-if="errorBorrar" class="aviso">{{ errorBorrar }}</p>
        <div class="en-linea" style="flex-wrap: wrap">
          <button class="boton chico peligro" @click="borra">Sí, borrarlo con su historial</button>
          <button v-if="e.estado !== 'retirado'" class="boton suave chico" @click="retira">Mejor lo retiro</button>
          <button class="boton suave chico" @click="confirmaBorrar = false">Cancelar</button>
        </div>
      </div>
    </section>
  </template>
</template>
