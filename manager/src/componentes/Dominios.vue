<script setup>
import { ref, reactive, onMounted } from 'vue'
import { api } from '../api.js'

const dominios = ref([])
const error = ref('')
const nuevo = reactive({ nombre: '', slug: '', descripcion: '' })
const confirmando = ref(null)
// El 409 de un borrado va debajo de su fila: dice qué le queda dentro.
const problema = ref(null)
// La fila que se está editando, con su borrador.
const editando = ref(null)
const borrador = reactive({ nombre: '', descripcion: '' })

async function carga() {
  try {
    dominios.value = (await api.get('/v1/dominios')).dominios
    error.value = ''
  } catch (e) {
    error.value = e.message
  }
}

async function crea() {
  error.value = ''
  try {
    await api.post('/v1/dominios', {
      nombre: nuevo.nombre.trim(),
      descripcion: nuevo.descripcion.trim(),
      ...(nuevo.slug.trim() ? { slug: nuevo.slug.trim() } : {}),
    })
    Object.assign(nuevo, { nombre: '', slug: '', descripcion: '' })
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

function edita(d) {
  if (editando.value === d.id) { editando.value = null; return }
  editando.value = d.id
  problema.value = null
  Object.assign(borrador, { nombre: d.nombre, descripcion: d.descripcion || '' })
}

async function guarda(d) {
  try {
    await api.patch(`/v1/dominios/${d.id}`, { nombre: borrador.nombre.trim(), descripcion: borrador.descripcion.trim() })
    editando.value = null
    await carga()
  } catch (e) {
    problema.value = { id: d.id, mensaje: e.message }
  }
}

async function borra(d) {
  if (confirmando.value !== d.id) {
    confirmando.value = d.id
    problema.value = null
    setTimeout(() => (confirmando.value === d.id ? (confirmando.value = null) : null), 4000)
    return
  }
  confirmando.value = null
  try {
    await api.del(`/v1/dominios/${d.id}`)
    await carga()
  } catch (e) {
    problema.value = { id: d.id, mensaje: e.message }
  }
}

const esGeneral = (d) => d.slug === 'general'

onMounted(carga)
</script>

<template>
  <div class="cabecera-seccion"><h2>Dominios</h2></div>
  <p class="apagado" style="max-width: 760px">
    Un dominio agrupa equipos: una empresa, un almacén, una sucursal. A una persona o una llave
    se le puede limitar a uno o varios dominios: entonces solo ve y maneja esos equipos, con sus
    zonas, reglas, alertas y códigos de alta.
  </p>
  <p class="apagado chico" style="max-width: 760px">
    Cada equipo está en un dominio. El <strong>General</strong> lo tiene toda organización: ahí
    caen los equipos si no se dice otro, y no se puede borrar. A quién se limita se decide en
    <a href="#/panel/usuarios">Usuarios</a> y <a href="#/panel/llaves">Llaves de API</a>.
  </p>
  <p v-if="error" class="aviso">{{ error }}</p>

  <form class="tarjeta" style="margin: 18px 0" @submit.prevent="crea">
    <h3>Crear un dominio</h3>
    <div class="rejilla-campos">
      <div><label>Nombre</label><input v-model="nuevo.nombre" maxlength="200" placeholder="Duralon" required /></div>
      <div><label>Descripción <span class="apagado">(opcional)</span></label><input v-model="nuevo.descripcion" maxlength="500" placeholder="Terminales del almacén de repuestos" /></div>
      <div>
        <label>Identificador <span class="apagado">(opcional)</span></label>
        <input v-model="nuevo.slug" maxlength="60" placeholder="Sale del nombre" />
      </div>
    </div>
    <p class="apagado chico" style="margin: 8px 0 0">
      El identificador es como lo nombran los sistemas que se conectan por el API
      (<code>?dominio=duralon</code>). Después no se cambia.
    </p>
    <button class="boton" style="margin-top: 14px" :disabled="!nuevo.nombre.trim()">Crear</button>
  </form>

  <table v-if="dominios.length" class="tarjetas">
    <thead><tr><th>Dominio</th><th>Equipos</th><th></th></tr></thead>
    <tbody>
      <template v-for="d in dominios" :key="d.id">
        <tr>
          <td data-t="Dominio">
            <strong>{{ d.nombre }}</strong>
            <span v-if="esGeneral(d)" class="nueva gris">siempre está</span>
            <div class="apagado chico">
              <code>{{ d.slug }}</code>
              <span v-if="d.descripcion"> · {{ d.descripcion }}</span>
            </div>
          </td>
          <td data-t="Equipos">
            <a v-if="d.equipos" :href="`#/panel/equipos?dominio=${d.id}`">{{ d.equipos }}</a>
            <span v-else class="apagado">0</span>
          </td>
          <td style="white-space: nowrap; text-align: right">
            <button class="boton suave chico" @click="edita(d)">{{ editando === d.id ? 'Cancelar' : 'Editar' }}</button>
            <button
              v-if="!esGeneral(d)"
              class="boton chico"
              :class="confirmando === d.id ? 'peligro' : 'suave'"
              style="margin-left: 6px"
              @click="borra(d)"
            >
              {{ confirmando === d.id ? '¿Seguro?' : 'Borrar' }}
            </button>
          </td>
        </tr>
        <tr v-if="editando === d.id" class="fila-cierre">
          <td colspan="3">
            <form class="rejilla-campos" @submit.prevent="guarda(d)">
              <div><label style="margin-top: 0">Nombre</label><input v-model="borrador.nombre" maxlength="200" required /></div>
              <div><label style="margin-top: 0">Descripción</label><input v-model="borrador.descripcion" maxlength="500" /></div>
              <div style="display: flex; align-items: flex-end">
                <button class="boton chico" :disabled="!borrador.nombre.trim()">Guardar</button>
              </div>
            </form>
          </td>
        </tr>
        <tr v-if="problema?.id === d.id" class="fila-cierre">
          <td colspan="3"><p class="aviso" style="margin: 0">{{ problema.mensaje }}</p></td>
        </tr>
      </template>
    </tbody>
  </table>
  <p v-if="confirmando" class="apagado chico">
    Solo se borra si ya no le queda nada: ni equipos, ni códigos de alta vigentes, ni personas o
    llaves limitadas a él. Sus zonas y reglas se van con él.
  </p>
</template>
