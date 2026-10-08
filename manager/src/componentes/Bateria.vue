<script setup>
import { computed } from 'vue'

// Una pila chica con su nivel y un rayo si está cargando. Roja por debajo
// del 20 %, amarilla por debajo del 40 %.
const props = defineProps({ nivel: Number, cargando: Boolean })
const color = computed(() => {
  if (props.nivel == null) return 'var(--texto-2)'
  if (props.nivel < 20) return 'var(--mal)'
  if (props.nivel < 40) return 'var(--tibio)'
  return 'var(--ok)'
})
const ancho = computed(() => Math.max(1, Math.round(((props.nivel ?? 0) / 100) * 16)))
</script>

<template>
  <span class="bateria" :title="nivel == null ? 'Sin dato' : `${nivel} %${cargando ? ', cargando' : ''}`">
    <template v-if="nivel != null">
      <svg width="24" height="12" viewBox="0 0 24 12" aria-hidden="true">
        <rect x="0.5" y="0.5" width="20" height="11" rx="2.5" fill="none" stroke="currentColor" opacity=".55" />
        <rect x="21" y="3.5" width="2.5" height="5" rx="1" fill="currentColor" opacity=".55" />
        <rect x="2.5" y="2.5" :width="ancho" height="7" rx="1" :fill="color" />
        <path v-if="cargando" d="M11.5 1.5 L7.5 6.6 H10.3 L9.2 10.5 L13.6 5.2 H10.8 Z" fill="var(--texto)" stroke="var(--fondo)" stroke-width=".6" />
      </svg>
      <span>{{ nivel }} %</span>
      <span v-if="cargando" class="sr">cargando</span>
    </template>
    <span v-else class="apagado">—</span>
  </span>
</template>
