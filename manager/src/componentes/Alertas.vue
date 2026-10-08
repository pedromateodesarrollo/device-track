<script setup>
import { ref, computed, onMounted, watch } from 'vue'
import { api, puede, hace, fecha, detalleAlerta, tiposRegla } from '../api.js'

const props = defineProps({ yo: Object })
const emit = defineEmits(['cambio'])

const alertas = ref([])
const todas = ref(false)
const error = ref('')
const cargando = ref(true)
const cerrando = ref(null)
const nota = ref('')
const puedeCerrar = computed(() => puede(props.yo, 'editar'))

async function carga() {
  try {
    alertas.value = (await api.get(`/v1/alertas${todas.value ? '?todas=1' : ''}`)).alertas
    error.value = ''
  } catch (e) {
    error.value = e.message
  } finally {
    cargando.value = false
  }
}
onMounted(carga)
watch(todas, carga)

function abreCierre(a) {
  cerrando.value = cerrando.value === a.id ? null : a.id
  nota.value = ''
}

async function cierra(a) {
  try {
    await api.post(`/v1/alertas/${a.id}/cerrar`, { nota: nota.value })
    cerrando.value = null
    nota.value = ''
    await carga()
    emit('cambio')
  } catch (e) {
    error.value = e.message
  }
}

const nombreRegla = (a) => a.regla_nombre || tiposRegla[a.tipo]?.nombre || a.tipo
</script>

<template>
  <div class="cabecera-seccion">
    <h2>Alertas</h2>
    <label class="casilla" style="margin-left: auto"><input type="checkbox" v-model="todas" /> Ver también las cerradas</label>
  </div>
  <p v-if="error" class="aviso">{{ error }}</p>
  <p v-if="cargando" class="apagado">Cargando…</p>
  <div v-else-if="!alertas.length" class="vacio">
    <template v-if="todas">Todavía no ha habido ninguna alerta.</template>
    <template v-else>Ninguna alerta abierta. Las reglas que vigilan a los equipos están en <a href="#/panel/reglas">Reglas y zonas</a>.</template>
  </div>

  <table v-else class="tarjetas">
    <thead><tr><th>Equipo</th><th>Regla</th><th>Qué pasa</th><th>Desde</th><th></th></tr></thead>
    <tbody>
      <template v-for="a in alertas" :key="a.id">
        <tr :class="{ cerrada: a.cerrada }">
          <td data-t="Equipo">
            <span class="punto" :class="a.cerrada ? '' : 'mal'" style="display: inline-block; margin-right: 6px"></span>
            <a :href="`#/panel/equipos/${a.equipo}`"><strong>{{ a.equipo_nombre }}</strong></a>
            <div class="apagado chico">{{ [a.etiqueta, a.grupo].filter(Boolean).join(' · ') }}</div>
          </td>
          <td data-t="Regla">
            {{ nombreRegla(a) }}
            <div v-if="a.regla_nombre && a.regla_nombre !== tiposRegla[a.tipo]?.nombre" class="apagado chico">{{ tiposRegla[a.tipo]?.nombre }}</div>
          </td>
          <td data-t="Qué pasa">{{ detalleAlerta(a) }}</td>
          <td data-t="Desde" :title="fecha(a.abierta)">
            {{ hace(a.abierta) }}
            <div v-if="a.cerrada" class="apagado chico">
              cerrada {{ fecha(a.cerrada) }}<template v-if="a.nota"> · «{{ a.nota }}»</template>
            </div>
          </td>
          <td style="white-space: nowrap; text-align: right">
            <button v-if="!a.cerrada && puedeCerrar" class="boton suave chico" @click="abreCierre(a)">
              {{ cerrando === a.id ? 'Cancelar' : 'Cerrar' }}
            </button>
          </td>
        </tr>
        <tr v-if="cerrando === a.id" class="fila-cierre">
          <td colspan="5">
            <form class="en-linea" style="flex-wrap: wrap" @submit.prevent="cierra(a)">
              <input v-model="nota" maxlength="500" placeholder="Nota: lo encontramos, se le cambió la batería…" style="flex: 1; min-width: 220px" />
              <button class="boton chico">Cerrar la alerta</button>
            </form>
            <p class="apagado chico" style="margin: 6px 0 0">
              Cerrar no apaga la regla: si lo que la abrió sigue pasando, se vuelve a abrir en el próximo reporte.
            </p>
          </td>
        </tr>
      </template>
    </tbody>
  </table>
</template>
