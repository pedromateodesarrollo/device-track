<script setup>
import { ref, onMounted, onUnmounted } from 'vue'
import { api, hace, detalleAlerta, tiposRegla } from '../api.js'

defineProps({ yo: Object })

const r = ref(null)
const alertas = ref([])
const error = ref('')
let reloj = null

async function carga() {
  try {
    const [resumen, a] = await Promise.all([api.get('/v1/resumen'), api.get('/v1/alertas?limite=8')])
    r.value = resumen
    alertas.value = a.alertas
    error.value = ''
  } catch (e) {
    error.value = e.message
  }
}

onMounted(() => {
  carga()
  // Lo de esta pantalla cambia solo (un equipo se conecta, una alerta se
  // cierra): se refresca cada medio minuto mientras se mira.
  reloj = setInterval(carga, 30000)
})
onUnmounted(() => clearInterval(reloj))

const tarjetas = [
  ['equipos', 'Equipos', '#/panel/equipos?todos=1', 'sin contar los retirados'],
  ['conectados', 'Conectados ahora', '#/panel/equipos?conectado=1', 'con el canal abierto'],
  ['perdidos', 'Perdidos', '#/panel/equipos?estado=perdido', 'marcados como perdidos'],
  ['sin_contacto_24h', 'Sin contacto 24 h', '#/panel/equipos?conectado=sin24', 'activos o perdidos, callados'],
  ['alertas', 'Alertas abiertas', '#/panel/alertas', 'por revisar'],
]
</script>

<template>
  <div class="cabecera-seccion"><h2>Resumen</h2></div>
  <p v-if="error" class="aviso">{{ error }}</p>

  <div v-if="r" class="cifras">
    <a
      v-for="[k, titulo, enlace, nota] in tarjetas"
      :key="k"
      :href="enlace"
      class="cifra"
      :class="{ alarma: (k === 'alertas' || k === 'perdidos' || k === 'sin_contacto_24h') && r[k] > 0 }"
    >
      <span class="numero">{{ r[k] ?? 0 }}</span>
      <span class="titulo">{{ titulo }}</span>
      <span class="nota">{{ nota }}</span>
    </a>
  </div>

  <div class="cabecera-seccion" style="margin-top: 30px">
    <h3 style="margin: 0">Alertas abiertas</h3>
    <a v-if="alertas.length" href="#/panel/alertas" class="boton suave chico">Ver todas</a>
  </div>
  <p v-if="r && !alertas.length" class="apagado">Nada que mirar: ninguna alerta abierta.</p>
  <ul class="lista-alertas">
    <li v-for="a in alertas" :key="a.id">
      <span class="punto mal"></span>
      <div>
        <a :href="`#/panel/equipos/${a.equipo}`"><strong>{{ a.equipo_nombre }}</strong></a>
        <span v-if="a.etiqueta" class="apagado"> · {{ a.etiqueta }}</span>
        <div class="apagado" style="font-size: 14px">
          {{ a.regla_nombre || tiposRegla[a.tipo]?.nombre || a.tipo }}: {{ detalleAlerta(a) }}
        </div>
      </div>
      <span class="apagado cuando">{{ hace(a.abierta) }}</span>
    </li>
  </ul>
</template>
