<script setup>
import { ref, computed, onMounted } from 'vue'
import { api, cargaDominios, nombresDominios, hace } from '../api.js'

const llaves = ref([])
const error = ref('')
const creada = ref(null)
const nombre = ref('')
const permisos = ref(['leer'])
// Los dominios a los que se limita la llave. Ninguno = toda la organización.
// Una llave con `admin` nunca va limitada.
const elegidos = ref([])
const dominios = ref([])
const variosDominios = computed(() => dominios.value.length > 1)
const verAlcance = computed(() => variosDominios.value || llaves.value.some((l) => l.dominios?.length))
const conAdmin = computed(() => permisos.value.includes('admin'))
const confirmando = ref(null)
const copiado = ref(false)

const todos = [
  ['leer', 'Ver equipos, recorridos, alertas, zonas y reglas'],
  ['editar', 'Cambiar la ficha de un equipo, zonas, reglas y códigos de alta'],
  ['ordenar', 'Mandarle órdenes a un equipo (sonar, mensaje, reportar)'],
  ['admin', 'Todo y en toda la organización, incluidas personas, otras llaves y dominios. Para automatizar la administración; no se reparte'],
]

async function carga() {
  try {
    llaves.value = (await api.get('/v1/llaves')).llaves
    error.value = ''
  } catch (e) {
    error.value = e.message
  }
}

async function crea() {
  try {
    creada.value = await api.post('/v1/llaves', {
      nombre: nombre.value,
      permisos: permisos.value,
      dominios: conAdmin.value ? [] : elegidos.value,
    })
    nombre.value = ''
    permisos.value = ['leer']
    elegidos.value = []
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

async function revoca(l) {
  if (confirmando.value !== l.id) {
    confirmando.value = l.id
    setTimeout(() => (confirmando.value === l.id ? (confirmando.value = null) : null), 4000)
    return
  }
  try {
    await api.del(`/v1/llaves/${l.id}`)
  } catch (e) {
    error.value = e.message
  }
  confirmando.value = null
  await carga()
}

async function copia() {
  try {
    await navigator.clipboard.writeText(creada.value.llave)
    copiado.value = true
    setTimeout(() => (copiado.value = false), 2000)
  } catch { /* está a la vista */ }
}

onMounted(() => {
  carga()
  cargaDominios().then((d) => (dominios.value = d)).catch(() => {})
})
</script>

<template>
  <div class="cabecera-seccion"><h2>Llaves de API</h2></div>
  <p v-if="error" class="aviso">{{ error }}</p>

  <div v-if="creada" class="exito">
    <strong>{{ creada.nombre }}</strong> — cópiala ahora: no se vuelve a enseñar.
    <div class="secreto">{{ creada.llave }}</div>
    <div style="display: flex; gap: 8px; margin-top: 10px">
      <button class="boton chico" @click="copia">{{ copiado ? 'Copiada' : 'Copiar' }}</button>
      <button class="boton suave chico" @click="creada = null">Ya la copié</button>
    </div>
  </div>

  <div class="tarjeta" style="margin-bottom: 20px">
    <h3>Crear una llave</h3>
    <p class="apagado">
      Una por sistema: el ERP que pinta el inventario, el script que manda a
      sonar. Así se sabe cuál revocar sin dejar mudos a los demás. La llave que
      solo lee no debería poder mandar órdenes. Guárdala fuera del repositorio
      (un archivo con permisos 600 o un secreto del CI).
      <template v-if="variosDominios">
        La de un sistema que solo maneja unos equipos (el de un cliente, el de un almacén) se
        limita a sus dominios. Los dominios de una llave no se cambian después: se crea otra y se
        revoca esta.
      </template>
    </p>
    <label>Nombre</label>
    <input v-model="nombre" placeholder="Inventario del ERP" style="max-width: 420px" />

    <label>Permisos</label>
    <div v-for="[id, texto] in todos" :key="id" style="margin-bottom: 4px">
      <label style="display: flex; gap: 8px; align-items: center; font-weight: 400; margin: 0">
        <input type="checkbox" :value="id" v-model="permisos" style="width: auto" />
        <span>{{ texto }} <code class="apagado">{{ id }}</code></span>
      </label>
    </div>

    <template v-if="variosDominios">
      <label>Qué equipos maneja</label>
      <p v-if="conAdmin" class="apagado chico" style="margin: 0">Con <code>admin</code>, toda la organización.</p>
      <template v-else>
        <div class="casillas-dominios">
          <label v-for="d in dominios" :key="d.id" class="casilla">
            <input type="checkbox" :value="d.id" v-model="elegidos" /> {{ d.nombre }}
          </label>
        </div>
        <p class="apagado chico" style="margin: 6px 0 0">
          {{ elegidos.length ? 'Solo los de esos dominios, con sus zonas, reglas, alertas y códigos de alta.' : 'Sin marcar ninguno: toda la organización.' }}
        </p>
      </template>
    </template>
    <button class="boton" style="margin-top: 14px" :disabled="!nombre || !permisos.length" @click="crea">Crear</button>
  </div>

  <table v-if="llaves.length" class="tarjetas">
    <thead>
      <tr><th>Nombre</th><th>Prefijo</th><th>Permisos</th><th v-if="verAlcance">Maneja</th><th>Último uso</th><th></th></tr>
    </thead>
    <tbody>
      <tr v-for="l in llaves" :key="l.id" :style="l.revocada ? 'opacity:.45' : ''">
        <td data-t="Nombre">{{ l.nombre }}</td>
        <td data-t="Prefijo"><code>dtk_{{ l.prefijo }}_…</code></td>
        <td data-t="Permisos" class="apagado" style="font-size: 13px">{{ (l.permisos || []).join(', ') }}</td>
        <td v-if="verAlcance" data-t="Maneja" class="chico">{{ nombresDominios(l.dominios, dominios) }}</td>
        <td data-t="Último uso" class="apagado" style="font-size: 13px">{{ hace(l.ultimo_uso) }}</td>
        <td style="text-align: right">
          <span v-if="l.revocada" class="apagado">revocada</span>
          <button v-else class="boton chico" :class="confirmando === l.id ? 'peligro' : 'suave'" @click="revoca(l)">
            {{ confirmando === l.id ? '¿Seguro?' : 'Revocar' }}
          </button>
        </td>
      </tr>
    </tbody>
  </table>
  <p v-else class="apagado">Todavía no hay llaves.</p>
</template>
