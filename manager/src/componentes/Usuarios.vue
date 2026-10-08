<script setup>
import { ref, computed, onMounted } from 'vue'
import { api, cargaDominios, nombresDominios, hace } from '../api.js'

const props = defineProps({ yo: Object })

const roles = {
  admin: 'Además de lo del editor: personas, llaves de API, dominios y la organización. Siempre ve toda la organización.',
  editor: 'Edita equipos, les manda órdenes, y maneja reglas, zonas y códigos de alta.',
  consulta: 'Solo mira: equipos, mapa, alertas y reglas.',
}
const rolCorto = { admin: 'Administrador', editor: 'Editor', consulta: 'Consulta' }

const usuarios = ref([])
const error = ref('')
const correo = ref('')
const nombre = ref('')
const rol = ref('editor')
// Los dominios a los que se limita a la persona. Ninguno = toda la
// organización. Un administrador nunca va limitado.
const elegidos = ref([])
const dominios = ref([])
// La fila cuyos dominios se están cambiando, con su borrador.
const editando = ref(null)
const borrador = ref([])
const enlace = ref(null)
const confirmando = ref(null)
const copiado = ref(false)

async function carga() {
  try {
    usuarios.value = (await api.get('/v1/usuarios')).usuarios
    error.value = ''
  } catch (e) {
    error.value = e.message
  }
}

// Con un único dominio no hay a qué limitar a nadie; la columna sale igual si
// alguien ya quedó limitado.
const variosDominios = computed(() => dominios.value.length > 1)
const verAlcance = computed(() => variosDominios.value || usuarios.value.some((u) => u.dominios?.length))

async function invita() {
  try {
    const u = await api.post('/v1/usuarios', {
      correo: correo.value,
      nombre: nombre.value,
      rol: rol.value,
      dominios: rol.value === 'admin' ? [] : elegidos.value,
    })
    enlace.value = { correo: u.correo, enlace: u.enlace, envio: u.envio }
    correo.value = ''
    nombre.value = ''
    elegidos.value = []
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

async function reinvita(u) {
  try {
    const d = await api.post(`/v1/usuarios/${u.id}/invitacion`)
    enlace.value = { correo: u.correo, enlace: d.enlace, envio: d.envio }
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

async function cambiaRol(u, nuevo) {
  try {
    // Un administrador ve toda la organización: pasar a admin le quita los
    // límites que tuviera.
    await api.patch(`/v1/usuarios/${u.id}`, nuevo === 'admin' ? { rol: nuevo, dominios: [] } : { rol: nuevo })
    error.value = ''
  } catch (e) {
    error.value = e.message
  }
  await carga()
}

function editaDominios(u) {
  if (editando.value === u.id) { editando.value = null; return }
  editando.value = u.id
  borrador.value = [...(u.dominios || [])]
}

async function guardaDominios(u) {
  try {
    await api.patch(`/v1/usuarios/${u.id}`, { dominios: borrador.value })
    editando.value = null
    error.value = ''
  } catch (e) {
    error.value = e.message
  }
  await carga()
}

async function borra(u) {
  if (confirmando.value !== u.id) {
    confirmando.value = u.id
    setTimeout(() => (confirmando.value === u.id ? (confirmando.value = null) : null), 4000)
    return
  }
  try {
    await api.del(`/v1/usuarios/${u.id}`)
  } catch (e) {
    error.value = e.message
  }
  await carga()
}

async function copia() {
  try {
    await navigator.clipboard.writeText(enlace.value.enlace)
    copiado.value = true
    setTimeout(() => (copiado.value = false), 2000)
  } catch { /* el enlace está a la vista */ }
}

onMounted(() => {
  carga()
  cargaDominios().then((d) => (dominios.value = d)).catch(() => {})
})
</script>

<template>
  <div class="cabecera-seccion"><h2>Usuarios</h2></div>
  <p v-if="error" class="aviso">{{ error }}</p>

  <div v-if="enlace" class="exito">
    <!-- Con correo de salida (Organización), la invitación ya le llegó; el
         enlace se enseña igual, por si no le llega o hay que dárselo en mano. -->
    <template v-if="enlace.envio?.enviado">
      Le mandamos la invitación por correo a <strong>{{ enlace.correo }}</strong>. Por si no le
      llega, este es el enlace: sirve una vez y vence en 7 días.
    </template>
    <template v-else>
      <span v-if="enlace.envio" class="aviso" style="display: block; margin-bottom: 8px">
        El correo no salió ({{ enlace.envio.detalle || enlace.envio.error }}). Revisa el correo de
        salida en Organización; mientras, compártele el enlace.
      </span>
      Enlace para <strong>{{ enlace.correo }}</strong>. Mándaselo por donde quieras:
      con él pone su propia clave. Sirve una vez y vence en 7 días.
    </template>
    <div class="secreto">{{ enlace.enlace }}</div>
    <div style="display: flex; gap: 8px; margin-top: 10px">
      <button class="boton chico" @click="copia">{{ copiado ? 'Copiado' : 'Copiar' }}</button>
      <button class="boton suave chico" @click="enlace = null">Listo</button>
    </div>
  </div>

  <div class="tarjeta" style="margin-bottom: 20px">
    <h3>Invitar a alguien</h3>
    <p class="apagado">
      Si la organización tiene correo de salida (en Organización), le llega la invitación;
      si no, te da un enlace y tú se lo pasas. Tú nunca ves su clave.
    </p>
    <div class="rejilla-campos" style="max-width: 760px">
      <div><label>Correo</label><input v-model="correo" type="email" /></div>
      <div><label>Nombre</label><input v-model="nombre" /></div>
      <div>
        <label>Rol</label>
        <select v-model="rol">
          <option v-for="(t, k) in rolCorto" :key="k" :value="k">{{ t }}</option>
        </select>
      </div>
    </div>
    <p class="apagado chico" style="margin: 8px 0 0">{{ rolCorto[rol] }}: {{ roles[rol].charAt(0).toLowerCase() + roles[rol].slice(1) }}</p>
    <template v-if="variosDominios && rol !== 'admin'">
      <label>Qué equipos ve</label>
      <div class="casillas-dominios">
        <label v-for="d in dominios" :key="d.id" class="casilla">
          <input type="checkbox" :value="d.id" v-model="elegidos" /> {{ d.nombre }}
        </label>
      </div>
      <p class="apagado chico" style="margin: 6px 0 0">
        {{ elegidos.length ? 'Solo los de esos dominios, con sus zonas, reglas, alertas y códigos de alta.' : 'Sin marcar ninguno: toda la organización.' }}
      </p>
    </template>
    <button class="boton" style="margin-top: 14px" :disabled="!correo" @click="invita">Invitar</button>
  </div>

  <table class="tarjetas">
    <thead><tr><th>Correo</th><th>Nombre</th><th>Rol</th><th v-if="verAlcance">Ve</th><th>Estado</th><th></th></tr></thead>
    <tbody>
      <template v-for="u in usuarios" :key="u.id">
        <tr>
          <td data-t="Correo">{{ u.correo }}</td>
          <td data-t="Nombre">{{ u.nombre }}</td>
          <td data-t="Rol">
            <span v-if="u.id === props.yo.id" class="apagado" title="Tu propio rol lo cambia otro administrador">{{ rolCorto[u.rol] }} (tú)</span>
            <select v-else :value="u.rol" class="chico-select" @change="cambiaRol(u, $event.target.value)" :aria-label="`Rol de ${u.correo}`">
              <option v-for="(t, k) in rolCorto" :key="k" :value="k">{{ t }}</option>
            </select>
          </td>
          <td v-if="verAlcance" data-t="Ve" class="chico">{{ nombresDominios(u.dominios, dominios) }}</td>
          <td data-t="Estado" class="apagado" style="font-size: 13px">
            <template v-if="u.activo">entró {{ hace(u.ultimo_acceso) }}</template>
            <template v-else>invitado, sin entrar todavía</template>
          </td>
          <td style="white-space: nowrap; text-align: right">
            <button v-if="verAlcance && u.rol !== 'admin'" class="boton chico suave" style="margin-right: 6px" @click="editaDominios(u)">
              {{ editando === u.id ? 'Cancelar' : 'Dominios' }}
            </button>
            <button class="boton chico suave" @click="reinvita(u)">{{ u.activo ? 'Enlace para clave nueva' : 'Otro enlace' }}</button>
            <button
              v-if="u.id !== props.yo.id"
              class="boton chico"
              :class="confirmando === u.id ? 'peligro' : 'suave'"
              style="margin-left: 6px"
              @click="borra(u)"
            >
              {{ confirmando === u.id ? '¿Seguro?' : 'Quitar' }}
            </button>
          </td>
        </tr>
        <tr v-if="editando === u.id" class="fila-cierre">
          <td :colspan="verAlcance ? 6 : 5">
            <form @submit.prevent="guardaDominios(u)">
              <div class="casillas-dominios">
                <label v-for="d in dominios" :key="d.id" class="casilla">
                  <input type="checkbox" :value="d.id" v-model="borrador" /> {{ d.nombre }}
                </label>
              </div>
              <div class="en-linea" style="margin-top: 10px; flex-wrap: wrap">
                <button class="boton chico">Guardar</button>
                <span class="apagado chico">{{ borrador.length ? 'Solo verá los equipos de esos dominios.' : 'Sin marcar ninguno: toda la organización.' }}</span>
              </div>
            </form>
          </td>
        </tr>
      </template>
    </tbody>
  </table>
</template>
