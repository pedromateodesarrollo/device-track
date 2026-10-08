<script setup>
import { computed, nextTick, onMounted, watch } from 'vue'
import texto from '../../../docs/api.md?raw'
import { renderMd } from '../markdown.js'

const props = defineProps({ ruta: String })

// Una sola fuente: el `docs/api.md` del repositorio, tal cual. Si el panel
// tuviera su copia, una de las dos mentiría a los tres meses.
const { html, titulos } = renderMd(texto)

// El índice de la izquierda: las secciones (##) y, dentro, los puntos (###).
const indice = computed(() => titulos.filter((t) => t.nivel === 2 || t.nivel === 3))

// `#/docs#codigos-de-alta`: el navegador no sabe bajar a un ancla que vive
// después de la ruta, así que se baja a mano.
async function baja() {
  const id = (props.ruta || '').split('#')[1]
  if (!id) return
  await nextTick()
  document.getElementById(id)?.scrollIntoView({ block: 'start' })
}
onMounted(baja)
watch(() => props.ruta, baja)
</script>

<template>
  <div class="contenedor docs">
    <aside class="docs-menu">
      <div class="grupo">En esta página</div>
      <a
        v-for="t in indice"
        :key="t.id"
        :href="`#/docs#${t.id}`"
        :class="{ sub: t.nivel === 3 }"
      >{{ t.texto }}</a>
    </aside>
    <main class="md" v-html="html"></main>
  </div>
</template>
