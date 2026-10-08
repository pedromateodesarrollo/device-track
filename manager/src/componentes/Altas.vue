<script setup>
import { ref, computed, onMounted } from 'vue'
import QRCode from 'qrcode'
import { api, puede, fecha, hace } from '../api.js'

const props = defineProps({ yo: Object })
const puedeEditar = computed(() => puede(props.yo, 'editar'))

const altas = ref([])
const grupos = ref([])
const error = ref('')
const nombre = ref('')
const grupo = ref('')
const usosMax = ref('')
const venceDias = ref('30')
const creado = ref(null)
const qr = ref('')
const copiado = ref('')
const confirmando = ref(null)
const verAnulados = ref(false)

async function carga() {
  try {
    altas.value = (await api.get('/v1/altas')).altas
    error.value = ''
  } catch (e) {
    error.value = e.message
  }
}

onMounted(() => {
  carga()
  api.get('/v1/grupos').then((d) => (grupos.value = d.grupos)).catch(() => {})
})

async function crea() {
  error.value = ''
  try {
    const a = await api.post('/v1/altas', {
      nombre: nombre.value.trim(),
      grupo: grupo.value.trim(),
      ...(usosMax.value ? { usos_max: Number(usosMax.value) } : {}),
      ...(venceDias.value ? { vence_dias: Number(venceDias.value) } : {}),
    })
    creado.value = a
    qr.value = await QRCode.toString(a.qr, { type: 'svg', margin: 0, errorCorrectionLevel: 'M' })
    nombre.value = ''
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

async function copia(que) {
  try {
    await navigator.clipboard.writeText(que === 'qr' ? creado.value.qr : creado.value.codigo)
    copiado.value = que
    setTimeout(() => (copiado.value = ''), 2000)
  } catch { /* está a la vista: se puede seleccionar */ }
}

async function anula(a) {
  if (confirmando.value !== a.id) {
    confirmando.value = a.id
    setTimeout(() => (confirmando.value === a.id ? (confirmando.value = null) : null), 4000)
    return
  }
  confirmando.value = null
  try {
    await api.del(`/v1/altas/${a.id}`)
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

const vencido = (a) => a.vence && new Date(a.vence) < new Date()
const agotado = (a) => a.usos_max != null && a.usos >= a.usos_max
const lista = computed(() => altas.value.filter((a) => verAnulados.value || !a.anulada))
const anulados = computed(() => altas.value.filter((a) => a.anulada).length)
</script>

<template>
  <div class="cabecera-seccion"><h2>Códigos de alta</h2></div>
  <p class="apagado" style="max-width: 760px">
    Un código de alta es lo que un equipo nuevo escanea para entrar en tu organización. Solo
    sirve para eso: no deja ver ni cambiar nada. Como va en un QR o dentro de una app, lleva
    tope de usos y vencimiento, y se puede anular sin tocar a los equipos que ya entraron.
  </p>
  <p v-if="error" class="aviso">{{ error }}</p>

  <div v-if="creado" class="exito codigo-creado">
    <div class="qr-alta" v-html="qr"></div>
    <div style="min-width: 0; flex: 1">
      <strong>{{ creado.nombre }}</strong> — guárdalo ahora: <strong>no se vuelve a mostrar</strong>.
      <p class="chico" style="margin: 6px 0 0">
        En cada equipo instala el agente desde
        <a href="https://apk.chalonasoft.com/i/devicetrack" target="_blank" rel="noopener">apk.chalonasoft.com/i/devicetrack</a>
        y escanea este QR (en una Zebra, con el lector). O pega el código en una app con el plugin.
        <template v-if="creado.grupo"> Los equipos entran en el grupo <strong>{{ creado.grupo }}</strong>.</template>
      </p>
      <div class="secreto">{{ creado.codigo }}</div>
      <div class="en-linea" style="margin-top: 10px; flex-wrap: wrap">
        <button class="boton chico" @click="copia('codigo')">{{ copiado === 'codigo' ? 'Copiado' : 'Copiar el código' }}</button>
        <button class="boton suave chico" @click="copia('qr')">{{ copiado === 'qr' ? 'Copiado' : 'Copiar el texto del QR' }}</button>
        <button class="boton suave chico" @click="creado = null">Ya lo guardé</button>
      </div>
    </div>
  </div>

  <div v-if="puedeEditar" class="tarjeta" style="margin-bottom: 20px">
    <h3>Crear un código</h3>
    <p class="apagado">
      Uno por tanda o por grupo: «Terminales del almacén», «Teléfonos de la ruta norte». Así se
      sabe cuál anular.
    </p>
    <form @submit.prevent="crea">
      <div class="rejilla-campos">
        <div><label>Nombre</label><input v-model="nombre" maxlength="200" placeholder="Terminales del almacén" required /></div>
        <div>
          <label>Grupo <span class="apagado">(opcional)</span></label>
          <input v-model="grupo" list="grupos-alta" maxlength="200" placeholder="Almacén" />
          <datalist id="grupos-alta"><option v-for="g in grupos" :key="g.grupo" :value="g.grupo" /></datalist>
        </div>
        <div><label>Tope de usos <span class="apagado">(vacío = sin tope)</span></label><input v-model="usosMax" type="number" min="1" placeholder="Sin tope" /></div>
        <div><label>Vence en días <span class="apagado">(vacío = no vence)</span></label><input v-model="venceDias" type="number" min="1" max="3650" placeholder="No vence" /></div>
      </div>
      <button class="boton" style="margin-top: 14px" :disabled="!nombre.trim()">Crear código</button>
    </form>
  </div>

  <div class="cabecera-seccion" style="margin-bottom: 8px">
    <h3 style="margin: 0">Códigos</h3>
    <label v-if="anulados" class="casilla" style="margin-left: auto"><input type="checkbox" v-model="verAnulados" /> Ver anulados ({{ anulados }})</label>
  </div>
  <p v-if="!lista.length" class="apagado">Todavía no hay códigos.</p>
  <table v-else class="tarjetas">
    <thead><tr><th>Nombre</th><th>Grupo</th><th>Usos</th><th>Vence</th><th>Equipos</th><th>Estado</th><th></th></tr></thead>
    <tbody>
      <tr v-for="a in lista" :key="a.id" :class="{ cerrada: a.anulada }">
        <td data-t="Nombre">
          <strong>{{ a.nombre }}</strong>
          <div class="mono">dta_{{ a.prefijo }}_…</div>
        </td>
        <td data-t="Grupo">{{ a.grupo || '—' }}</td>
        <td data-t="Usos">{{ a.usos }}<span class="apagado"> / {{ a.usos_max ?? '∞' }}</span></td>
        <td data-t="Vence" :title="fecha(a.vence)">{{ a.vence ? fecha(a.vence) : 'no vence' }}</td>
        <td data-t="Equipos">{{ a.equipos }}</td>
        <td data-t="Estado" class="chico">
          <span v-if="a.anulada" class="nueva gris">anulado</span>
          <span v-else-if="vencido(a)" class="nueva gris">vencido</span>
          <span v-else-if="agotado(a)" class="nueva gris">agotado</span>
          <span v-else class="nueva verde">vigente</span>
          <div class="apagado" :title="fecha(a.creado)">creado {{ hace(a.creado) }}</div>
        </td>
        <td style="white-space: nowrap; text-align: right">
          <button v-if="puedeEditar && !a.anulada" class="boton chico" :class="confirmando === a.id ? 'peligro' : 'suave'" @click="anula(a)">
            {{ confirmando === a.id ? '¿Anularlo?' : 'Anular' }}
          </button>
        </td>
      </tr>
    </tbody>
  </table>
  <p v-if="confirmando" class="apagado chico">Los equipos que ya entraron con él siguen igual; solo deja de servir para dar de alta nuevos.</p>
</template>
