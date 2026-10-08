<script setup>
import { ref, computed, onMounted } from 'vue'
import Landing from './componentes/Landing.vue'
import Docs from './componentes/Docs.vue'
import Panel from './componentes/Panel.vue'
import Activar from './componentes/Activar.vue'

// Todo va por el hash: no necesita nada del servidor, y el enlace de una
// invitación (`/#/activar/<token>`) no deja el token en el log de un proxy.
const ruta = ref(location.hash.slice(1) || '/')
onMounted(() => {
  window.addEventListener('hashchange', () => {
    ruta.value = location.hash.slice(1) || '/'
    if (!location.hash.includes('#', 1)) window.scrollTo(0, 0)
  })
})

const vista = computed(() => {
  if (ruta.value.startsWith('/docs')) return Docs
  if (ruta.value.startsWith('/panel')) return Panel
  if (ruta.value.startsWith('/activar/')) return Activar
  return Landing
})
const enDocs = computed(() => ruta.value.startsWith('/docs'))
const enPanel = computed(() => ruta.value.startsWith('/panel'))
</script>

<template>
  <header class="barra">
    <div class="contenedor" :class="{ ancho: enPanel }">
      <a href="/#/" class="logo">device<span>-track</span></a>
      <nav>
        <a href="/#/" :class="{ activo: !enDocs && !enPanel }">Inicio</a>
        <a href="/#/docs" :class="{ activo: enDocs }">Documentación</a>
        <a href="/#/panel" class="boton chico">Panel</a>
      </nav>
    </div>
  </header>

  <component :is="vista" :ruta="ruta" />

  <footer class="pie" v-if="!enPanel">
    <div class="contenedor">
      <span>device-track · software libre bajo Apache-2.0</span>
      <nav>
        <a href="https://github.com/pedromateodesarrollo/device-track">Código</a>
        <a href="/#/docs">Documentación</a>
        <a href="/#/panel">Panel</a>
      </nav>
    </div>
  </footer>
</template>
