<script setup>
// El chat con el asistente de IA de la organización. Las conversaciones son
// de cada persona. Lo que el asistente propone cambiar sale como tarjeta con
// «Confirmar» y «Descartar»: nada cambia hasta que la persona confirma.
//
// La voz (voz.js): si la organización la tiene (`yo.ia_voz`), se pregunta
// también con una nota de voz, y lo que se preguntó así se contesta en voz
// alta. Lo escrito se contesta solo escrito; «Escuchar» lee cualquier respuesta.
import { ref, computed, onMounted, onBeforeUnmount, nextTick } from 'vue'
import { api, hace, explicaIa, preguntaAlAsistente } from '../api.js'
import { renderMd } from '../markdown.js'
import { MAX_SEGUNDOS_NOTA, crearGrabadora, crearLocutor, duracion, puedeGrabar, transcribir } from '../voz.js'

const props = defineProps({ yo: Object, pregunta: String })

const conversaciones = ref([])
const actual = ref(null) // id
const titulo = ref('')
const vista = ref([]) // [{rol, texto, herramientas, propuestas: [ids]}]
const propuestas = ref({}) // id → propuesta
const texto = ref(props.pregunta || '')
const enviando = ref(false)
const avance = ref([]) // lo que va haciendo mientras contesta
const error = ref('')
const listaAbierta = ref(false)
const elMensajes = ref(null)
const elTexto = ref(null)

const conVoz = computed(() => !!props.yo?.ia_voz)
const puedeNota = computed(() => conVoz.value && puedeGrabar())
const grabadora = crearGrabadora({ alTope: () => terminaNota() })
const { estado: estadoNota, segundos: segundosNota } = grabadora
const escribiendoNota = ref(false)
const locutor = crearLocutor()
const { sonando, cargando: preparandoVoz } = locutor

const sugerencias = [
  '¿Qué equipos llevan más de un día sin reportar?',
  '¿Cuáles tienen la batería por debajo de 20 % ahora?',
  'Avísame por correo si una terminal baja de 15 % de batería',
  'Arma un tablero con los equipos por dominio y por estado',
]

async function cargaLista() {
  try {
    conversaciones.value = (await api.get('/v1/ia/conversaciones')).conversaciones
  } catch (e) {
    error.value = explicaIa(e)
  }
}

async function abre(id) {
  error.value = ''
  listaAbierta.value = false
  try {
    const c = await api.get(`/v1/ia/conversaciones/${id}`)
    actual.value = c.id
    titulo.value = c.titulo
    vista.value = c.vista
    propuestas.value = Object.fromEntries(c.propuestas.map((p) => [p.id, p]))
    await baja()
  } catch (e) {
    error.value = e.message
  }
}

function nueva() {
  actual.value = null
  titulo.value = ''
  vista.value = []
  propuestas.value = {}
  error.value = ''
  listaAbierta.value = false
  nextTick(() => elTexto.value?.focus())
}

async function borra(c) {
  try {
    await api.del(`/v1/ia/conversaciones/${c.id}`)
    if (actual.value === c.id) nueva()
    await cargaLista()
  } catch (e) {
    error.value = e.message
  }
}

async function baja() {
  await nextTick()
  const el = elMensajes.value
  if (el) el.scrollTop = el.scrollHeight
}

async function envia(pregunta = texto.value, { voz = false } = {}) {
  const mensaje = pregunta.trim()
  if (!mensaje || enviando.value) return
  error.value = ''
  enviando.value = true
  avance.value = []
  texto.value = ''
  locutor.callar()
  let fallo = false
  vista.value.push({ rol: 'persona', texto: mensaje, voz })
  const respuesta = { rol: 'asistente', texto: '', herramientas: [], propuestas: [], escribiendo: true }
  vista.value.push(respuesta)
  const r = vista.value[vista.value.length - 1]
  await baja()
  try {
    await preguntaAlAsistente({ mensaje, conversacion: actual.value, voz }, (e) => {
      switch (e.tipo) {
        case 'conversacion':
          if (actual.value !== e.id) {
            actual.value = e.id
            titulo.value = e.titulo
          }
          break
        case 'nota':
          avance.value.push({ nota: e.texto })
          break
        case 'herramienta':
          avance.value.push({ titulo: e.titulo })
          r.herramientas.push({ nombre: e.nombre, titulo: e.titulo })
          break
        case 'propuesta':
          propuestas.value[e.propuesta.id] = e.propuesta
          r.propuestas.push(e.propuesta.id)
          break
        case 'respuesta':
          r.texto = e.texto
          break
        case 'error':
          fallo = true
          error.value = explicaIa({ codigo: e.error, message: e.mensaje })
          // La pregunta no quedó en la conversación: se quita de la vista
          // y vuelve al campo para intentarlo otra vez.
          vista.value.splice(vista.value.length - 2, 2)
          texto.value = mensaje
          break
      }
      baja()
    })
  } catch (e) {
    fallo = true
    error.value = e.codigo === 'conversacion_larga' ? `${e.message}.` : explicaIa(e)
    vista.value.splice(vista.value.length - 2, 2)
    texto.value = mensaje
  } finally {
    r.escribiendo = false
    enviando.value = false
    avance.value = []
    cargaLista()
    baja()
  }
  // Lo que se preguntó con la voz se contesta en voz.
  if (voz && !fallo && r.texto) escucha(vista.value.indexOf(r), r.texto)
}

// ── La nota de voz ──

async function empiezaNota() {
  if (enviando.value || escribiendoNota.value) return
  error.value = ''
  locutor.callar()
  // En el toque: Safari solo deja sonar un audio que se tocó durante un gesto,
  // y la respuesta llega segundos después.
  locutor.desbloquear()
  try {
    await grabadora.empezar()
  } catch (e) {
    error.value = e.message
  }
}

async function terminaNota() {
  if (estadoNota.value !== 'grabando') return
  const nota = await grabadora.terminar()
  if (!nota) return
  escribiendoNota.value = true
  let dicho = ''
  try {
    dicho = await transcribir(nota)
  } catch (e) {
    error.value = explicaIa(e)
  } finally {
    escribiendoNota.value = false
  }
  if (dicho) envia(dicho, { voz: true })
}

function escucha(i, t) {
  if (sonando.value === i) locutor.callar()
  else locutor.decir(i, t)
}

function tecla(ev) {
  // Enter manda; Mayúsculas+Enter, otra línea.
  if (ev.key === 'Enter' && !ev.shiftKey && !ev.isComposing) {
    ev.preventDefault()
    envia()
  }
}

async function resuelve(p, accion) {
  p.ocupada = true
  try {
    const r = await api.post(`/v1/ia/propuestas/${p.id}/${accion}`)
    Object.assign(p, { estado: r.estado, resultado: r.resultado })
  } catch (e) {
    p.error = e.message
  } finally {
    p.ocupada = false
  }
}

// Los argumentos de una propuesta, legibles: sin ids técnicos de más.
const nombresArg = {
  tipo: 'Tipo', nombre: 'Nombre', dominio: 'Dominio', parametros: 'Parámetros', activa: 'Activa',
  avisar: 'Avisar por correo a', lat: 'Latitud', lng: 'Longitud', radio_m: 'Radio (m)', id: 'Id',
  etiqueta: 'Etiqueta', serie: 'Serie', asignado_a: 'Asignado a', notas: 'Notas', estado: 'Estado',
  texto: 'Texto', titulo: 'Título', segundos: 'Segundos', nota: 'Nota', correo: 'Correo', rol: 'Rol',
  dominios: 'Dominios',
}
function argumentos(p) {
  return Object.entries(p.args || {}).map(([k, v]) => [
    nombresArg[k] || k,
    Array.isArray(v) ? (v.length ? v.join(', ') : '—') : v && typeof v === 'object'
      ? Object.entries(v).map(([a, b]) => `${a}: ${b}`).join(', ')
      : v === true ? 'sí' : v === false ? 'no' : String(v),
  ])
}
const estados = { hecha: 'Hecho', fallida: 'Falló', descartada: 'Descartada' }
const md = (t) => renderMd(t || '').html

const sinConversacion = computed(() => !vista.value.length)

onBeforeUnmount(() => {
  grabadora.cancelar()
  locutor.callar()
})

onMounted(async () => {
  await cargaLista()
  nextTick(() => elTexto.value?.focus())
})
</script>

<template>
  <div class="asistente">
    <aside class="conversaciones" :class="{ abierta: listaAbierta }">
      <button class="boton chico" style="width: 100%" @click="nueva">Conversación nueva</button>
      <p v-if="!conversaciones.length" class="apagado chico" style="margin-top: 12px">Todavía no hay conversaciones.</p>
      <ul>
        <li v-for="c in conversaciones" :key="c.id" :class="{ activa: c.id === actual }">
          <button class="titulo-conv" @click="abre(c.id)">
            {{ c.titulo || 'Sin título' }}
            <span class="apagado chico">{{ hace(c.actualizado) }}</span>
          </button>
          <button class="borrar-conv" title="Borrar la conversación" @click="borra(c)">×</button>
        </li>
      </ul>
    </aside>

    <section class="chat">
      <div class="cabecera-seccion" style="margin-bottom: 8px">
        <h2 style="font-size: 22px">{{ titulo || 'Asistente' }}</h2>
        <button class="boton suave chico ver-conversaciones" @click="listaAbierta = !listaAbierta">
          {{ listaAbierta ? 'Cerrar' : 'Conversaciones' }}
        </button>
      </div>

      <div ref="elMensajes" class="mensajes">
        <div v-if="sinConversacion" class="vacio">
          <p class="apagado">
            Pregúntale por tus equipos, pídele un reporte, que te avise de algo o que te arme un tablero.
            Ve y hace solo lo que tú puedes; lo que cambie algo te lo propone y lo confirmas tú.
          </p>
          <div class="sugerencias">
            <button v-for="s in sugerencias" :key="s" class="boton suave chico" @click="envia(s)">{{ s }}</button>
          </div>
        </div>

        <template v-for="(m, i) in vista" :key="i">
          <div v-if="m.rol === 'persona'" class="burbuja persona"><span v-if="m.voz" class="marca-voz" title="Por nota de voz">🎙 </span>{{ m.texto }}</div>
          <div v-else class="burbuja asistente-msg">
            <p v-if="m.herramientas?.length" class="consultas">
              Consultó: {{ [...new Set(m.herramientas.map((h) => h.titulo))].join(' · ') }}
            </p>
            <div v-if="m.escribiendo && !m.texto" class="avance">
              <p v-for="(a, j) in avance" :key="j" :class="{ apagado: !a.nota }">
                {{ a.nota || `${a.titulo}…` }}
              </p>
              <p class="apagado">Pensando…</p>
            </div>
            <div v-if="m.texto" class="md" v-html="md(m.texto)"></div>
            <button
              v-if="conVoz && m.texto && !m.escribiendo"
              type="button"
              class="boton suave chico escuchar"
              @click="escucha(i, m.texto)"
            >
              {{ sonando === i ? (preparandoVoz ? 'Preparando la voz…' : 'Callar') : 'Escuchar' }}
            </button>

            <div v-for="id in m.propuestas || []" :key="id" class="propuesta">
              <template v-if="propuestas[id]">
                <strong>{{ propuestas[id].resumen }}</strong>
                <dl>
                  <template v-for="[k, v] in argumentos(propuestas[id])" :key="k">
                    <dt>{{ k }}</dt><dd>{{ v }}</dd>
                  </template>
                </dl>
                <p v-if="propuestas[id].error" class="aviso">{{ propuestas[id].error }}</p>
                <div v-if="propuestas[id].estado === 'pendiente' && !propuestas[id].vencida" class="en-linea">
                  <button class="boton chico" :disabled="propuestas[id].ocupada" @click="resuelve(propuestas[id], 'confirmar')">Confirmar</button>
                  <button class="boton suave chico" :disabled="propuestas[id].ocupada" @click="resuelve(propuestas[id], 'descartar')">Descartar</button>
                </div>
                <p v-else-if="propuestas[id].estado === 'pendiente'" class="apagado chico">Venció: pídesela de nuevo.</p>
                <p v-else class="chico" :class="{ aviso: propuestas[id].estado === 'fallida' }">
                  {{ estados[propuestas[id].estado] }}<template v-if="propuestas[id].estado === 'fallida' && propuestas[id].resultado?.mensaje">: {{ propuestas[id].resultado.mensaje }}</template>
                </p>
              </template>
            </div>
          </div>
        </template>
      </div>

      <p v-if="error" class="aviso" style="margin: 8px 0 0">{{ error }}</p>
      <p v-if="locutor.error.value" class="aviso" style="margin: 8px 0 0">{{ locutor.error.value }}</p>
      <div v-if="estadoNota === 'grabando' || escribiendoNota" class="entrada-chat grabando-nota" role="status">
        <template v-if="estadoNota === 'grabando'">
          <span class="punto-rojo" aria-hidden="true"></span>
          <span class="tiempo-nota">{{ duracion(segundosNota) }} <span class="apagado chico">/ {{ duracion(MAX_SEGUNDOS_NOTA) }}</span></span>
          <span class="apagado chico" style="flex: 1">Grabando… habla y toca «Enviar» al terminar.</span>
          <button type="button" class="boton suave" @click="grabadora.cancelar()">Cancelar</button>
          <button type="button" class="boton" @click="terminaNota">Enviar</button>
        </template>
        <span v-else class="apagado">Escribiendo lo que dijiste…</span>
      </div>
      <form v-else class="entrada-chat" @submit.prevent="envia()">
        <textarea
          ref="elTexto"
          v-model="texto"
          rows="2"
          maxlength="8000"
          placeholder="Escribe tu pregunta… (Enter manda, Mayúsculas+Enter es otra línea)"
          :disabled="enviando"
          @keydown="tecla"
        ></textarea>
        <button
          v-if="puedeNota && !texto.trim()"
          type="button"
          class="boton microfono"
          :disabled="enviando || estadoNota === 'pidiendo'"
          title="Preguntar con una nota de voz"
          aria-label="Preguntar con una nota de voz"
          @click="empiezaNota"
        >
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 14a3 3 0 0 0 3-3V5a3 3 0 0 0-6 0v6a3 3 0 0 0 3 3Zm5-3a5 5 0 0 1-10 0H5a7 7 0 0 0 6 6.92V21h2v-3.08A7 7 0 0 0 19 11h-2Z" /></svg>
        </button>
        <button v-else class="boton" :disabled="enviando || !texto.trim()">{{ enviando ? '…' : 'Enviar' }}</button>
      </form>
    </section>
  </div>
</template>
