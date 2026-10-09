<script setup>
// El chat con el asistente de IA de la organización. Las conversaciones son
// de cada persona. Lo que el asistente propone cambiar sale como tarjeta con
// «Confirmar» y «Descartar»: nada cambia hasta que la persona confirma.
import { ref, computed, onMounted, nextTick } from 'vue'
import { api, hace, explicaIa, preguntaAlAsistente } from '../api.js'
import { renderMd } from '../markdown.js'

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

async function envia(pregunta = texto.value) {
  const mensaje = pregunta.trim()
  if (!mensaje || enviando.value) return
  error.value = ''
  enviando.value = true
  avance.value = []
  texto.value = ''
  vista.value.push({ rol: 'persona', texto: mensaje })
  const respuesta = { rol: 'asistente', texto: '', herramientas: [], propuestas: [], escribiendo: true }
  vista.value.push(respuesta)
  const r = vista.value[vista.value.length - 1]
  await baja()
  try {
    await preguntaAlAsistente({ mensaje, conversacion: actual.value }, (e) => {
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
          <div v-if="m.rol === 'persona'" class="burbuja persona">{{ m.texto }}</div>
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
      <form class="entrada-chat" @submit.prevent="envia()">
        <textarea
          ref="elTexto"
          v-model="texto"
          rows="2"
          maxlength="8000"
          placeholder="Escribe tu pregunta… (Enter manda, Mayúsculas+Enter es otra línea)"
          :disabled="enviando"
          @keydown="tecla"
        ></textarea>
        <button class="boton" :disabled="enviando || !texto.trim()">{{ enviando ? '…' : 'Enviar' }}</button>
      </form>
    </section>
  </div>
</template>
