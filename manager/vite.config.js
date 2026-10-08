import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// El panel lo sirve el propio hub desde la carpeta que apunte DT_MANAGER.
//
// `base` absoluta, como en apk-server: el hub va en la raíz de su dominio y
// los enlaces de invitación (`/#/activar/<token>`) salen de ahí.
export default defineConfig({
  plugins: [vue()],
  base: '/',
  build: { outDir: 'dist', emptyOutDir: true },
  server: {
    // La documentación vive en `../docs/api.md`, fuera de la raíz de Vite.
    fs: { allow: ['..'] },
    // En desarrollo el API está en el hub local.
    proxy: {
      '/v1': { target: 'http://localhost:3141', ws: true },
      '/salud': 'http://localhost:3141',
    },
  },
})
