<script setup>
import { onMounted, ref } from 'vue'
import QRCode from 'qrcode'
import { api, acotado, alcanceTexto } from '../api.js'

const props = defineProps({ yo: Object })

// El panel en Android (device-track/app), que se instala y se actualiza desde
// apk-server. El QR es para abrir el enlace con el teléfono desde aquí.
const enlaceApp = 'https://apk.chalonasoft.com/i/devicetrack-panel'
const qrApp = ref('')
onMounted(async () => {
  qrApp.value = await QRCode.toString(enlaceApp, { type: 'svg', margin: 0, errorCorrectionLevel: 'M' })
})

const roles = {
  admin: 'administrador (todo, incluidas personas, llaves, dominios y organización)',
  editor: 'editor (edita equipos, manda órdenes, reglas y códigos de alta)',
  consulta: 'consulta (solo mira)',
}

const actual = ref('')
const nueva = ref('')
const otra = ref('')
const error = ref('')
const listo = ref(false)

async function cambia() {
  error.value = ''
  listo.value = false
  if (nueva.value !== otra.value) {
    error.value = 'Las dos claves nuevas no coinciden'
    return
  }
  try {
    await api.post(`/v1/usuarios/${props.yo.id}/clave`, { actual: actual.value, clave: nueva.value })
    actual.value = nueva.value = otra.value = ''
    listo.value = true
  } catch (e) {
    error.value = e.message
  }
}
</script>

<template>
  <div class="cabecera-seccion"><h2>Mi cuenta</h2></div>
  <p class="apagado">{{ props.yo.nombre }} · {{ props.yo.correo }} · {{ props.yo.organizacion }}</p>
  <p class="apagado chico">Tu rol: <strong>{{ roles[props.yo.rol] || props.yo.rol }}</strong></p>
  <p v-if="acotado(props.yo)" class="apagado chico">
    Ves solo los equipos de <strong>{{ alcanceTexto(props.yo) }}</strong>, con sus zonas, reglas,
    alertas y códigos de alta. Para ver más, pídeselo a quien administra.
  </p>
  <div class="tarjeta codigo-creado" style="margin: 18px 0; max-width: 760px">
    <div class="qr-alta qr-app" v-html="qrApp"></div>
    <div style="min-width: 0; flex: 1">
      <h3>El panel en tu teléfono</h3>
      <p>
        Los equipos, las alertas, los tableros y el asistente, en una app de Android que se
        actualiza sola. Para instalarla, abre
        <a class="enlace-app" :href="enlaceApp" target="_blank" rel="noopener">apk.chalonasoft.com/i/devicetrack-panel</a>
        en el teléfono<span class="solo-ancho"> o escanea el código</span>. Se entra con este mismo
        correo y clave.
      </p>
    </div>
  </div>
  <form class="caja" @submit.prevent="cambia">
    <h3 style="margin-top: 18px">Cambiar la clave</h3>
    <label>Clave actual</label>
    <input v-model="actual" type="password" autocomplete="current-password" required />
    <label>Clave nueva</label>
    <input v-model="nueva" type="password" autocomplete="new-password" minlength="10" required />
    <label>Otra vez</label>
    <input v-model="otra" type="password" autocomplete="new-password" minlength="10" required />
    <p v-if="error" class="aviso" style="margin-top: 12px">{{ error }}</p>
    <p v-if="listo" class="apagado" style="margin-top: 12px">Listo: la clave cambió.</p>
    <button class="boton" style="margin-top: 16px">Cambiar</button>
  </form>
</template>
