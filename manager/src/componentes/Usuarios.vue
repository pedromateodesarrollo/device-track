<script setup>
import { ref, onMounted } from 'vue'
import { api, hace } from '../api.js'

const props = defineProps({ yo: Object })

const roles = {
  admin: 'Además de lo del editor: personas, llaves de API y la organización.',
  editor: 'Edita equipos, les manda órdenes, y maneja reglas, zonas y códigos de alta.',
  consulta: 'Solo mira: equipos, mapa, alertas y reglas.',
}
const rolCorto = { admin: 'Administrador', editor: 'Editor', consulta: 'Consulta' }

const usuarios = ref([])
const error = ref('')
const correo = ref('')
const nombre = ref('')
const rol = ref('editor')
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

async function invita() {
  try {
    const u = await api.post('/v1/usuarios', { correo: correo.value, nombre: nombre.value, rol: rol.value })
    enlace.value = { correo: u.correo, enlace: u.enlace }
    correo.value = ''
    nombre.value = ''
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

async function reinvita(u) {
  try {
    const d = await api.post(`/v1/usuarios/${u.id}/invitacion`)
    enlace.value = { correo: u.correo, enlace: d.enlace }
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

async function cambiaRol(u, nuevo) {
  try {
    await api.patch(`/v1/usuarios/${u.id}`, { rol: nuevo })
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

onMounted(carga)
</script>

<template>
  <div class="cabecera-seccion"><h2>Usuarios</h2></div>
  <p v-if="error" class="aviso">{{ error }}</p>

  <div v-if="enlace" class="exito">
    Enlace para <strong>{{ enlace.correo }}</strong>. Mándaselo por donde quieras:
    con él pone su propia clave. Sirve una vez y vence en 7 días.
    <div class="secreto">{{ enlace.enlace }}</div>
    <div style="display: flex; gap: 8px; margin-top: 10px">
      <button class="boton chico" @click="copia">{{ copiado ? 'Copiado' : 'Copiar' }}</button>
      <button class="boton suave chico" @click="enlace = null">Listo</button>
    </div>
  </div>

  <div class="tarjeta" style="margin-bottom: 20px">
    <h3>Invitar a alguien</h3>
    <p class="apagado">
      El hub no manda correos: te da un enlace y tú se lo pasas. Tú nunca ves
      su clave.
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
    <button class="boton" style="margin-top: 14px" :disabled="!correo" @click="invita">Crear enlace</button>
  </div>

  <table class="tarjetas">
    <thead><tr><th>Correo</th><th>Nombre</th><th>Rol</th><th>Estado</th><th></th></tr></thead>
    <tbody>
      <tr v-for="u in usuarios" :key="u.id">
        <td data-t="Correo">{{ u.correo }}</td>
        <td data-t="Nombre">{{ u.nombre }}</td>
        <td data-t="Rol">
          <span v-if="u.id === props.yo.id" class="apagado" title="Tu propio rol lo cambia otro administrador">{{ rolCorto[u.rol] }} (tú)</span>
          <select v-else :value="u.rol" class="chico-select" @change="cambiaRol(u, $event.target.value)" :aria-label="`Rol de ${u.correo}`">
            <option v-for="(t, k) in rolCorto" :key="k" :value="k">{{ t }}</option>
          </select>
        </td>
        <td data-t="Estado" class="apagado" style="font-size: 13px">
          <template v-if="u.activo">entró {{ hace(u.ultimo_acceso) }}</template>
          <template v-else>invitado, sin entrar todavía</template>
        </td>
        <td style="white-space: nowrap; text-align: right">
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
    </tbody>
  </table>
</template>
