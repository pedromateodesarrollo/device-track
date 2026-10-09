<script setup>
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import { api, sesion, acotado, alcanceTexto } from '../api.js'
import Tableros from './Tableros.vue'
import Asistente from './Asistente.vue'
import Equipos from './Equipos.vue'
import EquipoDetalle from './EquipoDetalle.vue'
import MapaEquipos from './MapaEquipos.vue'
import Alertas from './Alertas.vue'
import Reglas from './Reglas.vue'
import Altas from './Altas.vue'
import Organizacion from './Organizacion.vue'
import Dominios from './Dominios.vue'
import Usuarios from './Usuarios.vue'
import Llaves from './Llaves.vue'
import Cuenta from './Cuenta.vue'

const props = defineProps({ ruta: String })

const yo = ref(null)
const cargando = ref(true)
const correo = ref('')
const clave = ref('')
const error = ref('')
const enviando = ref(false)
// «¿Olvidaste tu clave?»: solo si el hub tiene por dónde mandar el enlace
// (`recuperar` de /salud, alguna organización con correo de salida).
const recuperable = ref(false)
const recuperando = ref(false)
const pedido = ref(false)
const menuAbierto = ref(false)
const alertasAbiertas = ref(0)

// `#/panel`, `#/panel/equipos`, `#/panel/equipos/<id>`, `#/panel/mapa`…
// Una lista puede llevar sus filtros: `#/panel/equipos?estado=perdido`.
const camino = computed(() => (props.ruta || '').split('#')[0].split('?')[0])
const filtros = computed(() => Object.fromEntries(new URLSearchParams((props.ruta || '').split('?')[1] || '')))
const partes = computed(() => camino.value.split('/').filter(Boolean).slice(1))
const seccion = computed(() => partes.value[0] || 'inicio')
const equipo = computed(() => (seccion.value === 'equipos' && partes.value[1] ? Number(partes.value[1]) : 0))

const secciones = computed(() => [
  ['inicio', 'Inicio'],
  // El chat, solo si la organización tiene el asistente encendido.
  ...(yo.value?.ia ? [['asistente', 'Asistente']] : []),
  ['equipos', 'Equipos'],
  ['mapa', 'Mapa'],
  ['alertas', 'Alertas'],
  ['reglas', 'Reglas y zonas'],
  ['altas', 'Códigos de alta'],
  ...(yo.value?.rol === 'admin'
    ? [['org', 'Organización'], ['dominios', 'Dominios'], ['usuarios', 'Usuarios'], ['llaves', 'Llaves de API']]
    : []),
  ['cuenta', 'Mi cuenta'],
])
// Una persona limitada a unos dominios lo ve escrito arriba: sabe que mira
// una parte, no toda la organización.
const alcance = computed(() => (acotado(yo.value) ? alcanceTexto(yo.value) : ''))
const tituloActual = computed(() => secciones.value.find(([id]) => id === seccion.value)?.[1] || 'Menú')

async function cuentaAlertas() {
  try {
    alertasAbiertas.value = (await api.get('/v1/resumen')).alertas ?? 0
  } catch { /* el número es un adorno: si falla, no se enseña */ }
}

const alVencer = () => {
  yo.value = null
  error.value = 'La sesión venció. Entra de nuevo.'
}
onUnmounted(() => window.removeEventListener('sesion-vencida', alVencer))

onMounted(async () => {
  window.addEventListener('sesion-vencida', alVencer)
  if (sesion.token) {
    try {
      yo.value = await api.get('/v1/yo')
    } catch {
      sesion.token = ''
    }
  }
  cargando.value = false
  if (yo.value) cuentaAlertas()
  else {
    try {
      recuperable.value = (await api.get('/salud')).recuperar === true
    } catch { /* sin /salud, sin recuperación: la entrada funciona igual */ }
  }
})

// Al cambiar de pantalla: se cierra el menú del teléfono y se refresca el
// número de alertas (se pudo haber cerrado una).
watch(() => props.ruta, () => {
  menuAbierto.value = false
  if (yo.value) cuentaAlertas()
})

async function entra() {
  error.value = ''
  enviando.value = true
  try {
    const d = await api.post('/v1/auth/login', { correo: correo.value, clave: clave.value })
    sesion.token = d.token
    yo.value = await api.get('/v1/yo')
    cuentaAlertas()
  } catch (e) {
    error.value = e.message
  } finally {
    enviando.value = false
  }
}

async function recupera() {
  error.value = ''
  enviando.value = true
  try {
    await api.post('/v1/auth/recuperar', { correo: correo.value })
    pedido.value = true
  } catch (e) {
    error.value = e.message
  } finally {
    enviando.value = false
  }
}

function vuelveAEntrar() {
  recuperando.value = false
  pedido.value = false
  error.value = ''
}

function ve(id) {
  location.hash = id === 'inicio' ? '#/panel' : `#/panel/${id}`
  menuAbierto.value = false
}

function sale() {
  sesion.token = ''
  yo.value = null
  location.hash = '#/panel'
}
</script>

<template>
  <div v-if="cargando" class="contenedor" style="padding: 60px 22px">
    <p class="apagado">Cargando…</p>
  </div>

  <div v-else-if="!yo" class="contenedor" style="padding: 56px 22px; max-width: 460px">
    <h1 style="font-size: 28px">{{ recuperando ? '¿Olvidaste tu clave?' : 'Entrar' }}</h1>
    <p v-if="!recuperando" class="apagado">
      Con la cuenta de tu organización. Si todavía no tienes, pídele una
      invitación a quien administra este hub.
    </p>
    <div v-if="recuperando && pedido" class="caja">
      <p style="margin: 0">
        Si <strong>{{ correo }}</strong> tiene cuenta, te llegó un enlace para poner una clave
        nueva. Vence en 1 hora.
      </p>
      <p class="apagado chico" style="margin: 10px 0 0">
        Si no llega, mira en el correo no deseado o pídele uno a quien administra.
      </p>
      <button class="boton suave" style="margin-top: 18px" @click="vuelveAEntrar">Volver a entrar</button>
    </div>
    <form v-else-if="recuperando" class="caja" @submit.prevent="recupera">
      <p class="apagado" style="margin: 0 0 6px">
        Te mandamos un enlace a tu correo para poner una clave nueva. Tu clave de ahora sigue
        valiendo hasta que la cambies.
      </p>
      <label>Correo</label>
      <input v-model="correo" type="email" autocomplete="username" required />
      <p v-if="error" class="aviso" style="margin-top: 12px">{{ error }}</p>
      <div class="en-linea" style="margin-top: 18px; flex-wrap: wrap">
        <button class="boton" :disabled="enviando">{{ enviando ? 'Un momento…' : 'Mandar el enlace' }}</button>
        <button type="button" class="boton suave" @click="vuelveAEntrar">Volver</button>
      </div>
    </form>
    <form v-else class="caja" @submit.prevent="entra">
      <label>Correo</label>
      <input v-model="correo" type="email" autocomplete="username" required />
      <label>Clave</label>
      <input v-model="clave" type="password" autocomplete="current-password" required />
      <p v-if="error" class="aviso" style="margin-top: 12px">{{ error }}</p>
      <button class="boton" style="margin-top: 18px" :disabled="enviando">
        {{ enviando ? 'Un momento…' : 'Entrar' }}
      </button>
      <p v-if="recuperable" style="margin: 14px 0 0">
        <a href="#" @click.prevent="recuperando = true; error = ''">¿Olvidaste tu clave?</a>
      </p>
    </form>
  </div>

  <div v-else class="app">
    <button class="menu-movil" :aria-expanded="menuAbierto" @click="menuAbierto = !menuAbierto">
      <span class="hamburguesa" aria-hidden="true"></span>
      <span>{{ tituloActual }}</span>
      <span v-if="alertasAbiertas" class="cuenta-alertas">{{ alertasAbiertas }}</span>
      <span class="apagado" style="margin-left: auto; font-size: 13px">{{ menuAbierto ? 'Cerrar' : 'Menú' }}</span>
    </button>

    <aside class="lateral" :class="{ abierto: menuAbierto }">
      <button
        v-for="[id, titulo] in secciones"
        :key="id"
        :class="{ activo: seccion === id }"
        @click="ve(id)"
      >
        {{ titulo }}
        <span v-if="id === 'alertas' && alertasAbiertas" class="cuenta-alertas">{{ alertasAbiertas }}</span>
      </button>
      <hr style="border: 0; border-top: 1px solid var(--borde); margin: 14px 0" />
      <button @click="sale">Salir</button>
    </aside>

    <main class="contenido">
      <p class="apagado" style="font-size: 14px; margin-bottom: 14px">
        {{ yo.organizacion }}<template v-if="alcance">
          · <span title="Solo ves los equipos de estos dominios">solo {{ alcance }}</span></template>
        · {{ yo.correo }} ({{ yo.rol }})
      </p>
      <EquipoDetalle v-if="equipo" :key="equipo" :id="equipo" :yo="yo" />
      <Equipos v-else-if="seccion === 'equipos'" :key="JSON.stringify(filtros)" :yo="yo" :filtros="filtros" />
      <MapaEquipos v-else-if="seccion === 'mapa'" :yo="yo" />
      <Alertas v-else-if="seccion === 'alertas'" :yo="yo" @cambio="cuentaAlertas" />
      <Reglas v-else-if="seccion === 'reglas'" :yo="yo" />
      <Altas v-else-if="seccion === 'altas'" :yo="yo" />
      <Organizacion v-else-if="seccion === 'org'" :yo="yo" />
      <Dominios v-else-if="seccion === 'dominios'" />
      <Usuarios v-else-if="seccion === 'usuarios'" :yo="yo" />
      <Llaves v-else-if="seccion === 'llaves'" />
      <Cuenta v-else-if="seccion === 'cuenta'" :yo="yo" />
      <Asistente v-else-if="seccion === 'asistente'" :key="filtros.pregunta || ''" :yo="yo" :pregunta="filtros.pregunta || ''" />
      <Tableros v-else :yo="yo" />
    </main>
  </div>
</template>
