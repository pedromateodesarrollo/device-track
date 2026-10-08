/// Lo común de los mapas: teselas de OpenStreetMap con su atribución, y los
/// colores. Los puntos son `circleMarker` y no el marcador de Leaflet: no
/// dependen de imágenes que el empaquetador tenga que encontrar, y el color
/// dice el estado.
import L from 'leaflet'

/// Santo Domingo, para cuando todavía no hay nada que enseñar.
export const CENTRO_INICIAL = [18.4861, -69.9312]

export function creaMapa(elemento, { centro = CENTRO_INICIAL, zoom = 12 } = {}) {
  const mapa = L.map(elemento, { zoomControl: true, attributionControl: true }).setView(centro, zoom)
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">colaboradores de OpenStreetMap</a>',
  }).addTo(mapa)
  mapa.attributionControl.setPrefix('<a href="https://leafletjs.com">Leaflet</a>')
  return mapa
}

/// Leídos de las variables CSS para que el mapa siga el tema claro/oscuro.
export function colores() {
  const css = getComputedStyle(document.documentElement)
  const v = (n, d) => css.getPropertyValue(n).trim() || d
  return {
    ok: v('--ok', '#16a34a'),
    mal: v('--mal', '#dc2626'),
    tibio: v('--tibio', '#ca8a04'),
    gris: v('--gris-mapa', '#6b7280'),
    apagado: v('--gris-mapa', '#6b7280'),
    marca: v('--marca', '#2563eb'),
    zona: v('--zona', '#7c3aed'),
  }
}

/// Un círculo de zona: borde punteado y relleno muy suave, para que no se
/// confunda con el círculo de precisión de un equipo.
export function circuloZona(z, opciones = {}) {
  const c = colores()
  return L.circle([z.lat, z.lng], {
    radius: z.radio_m,
    color: c.zona,
    weight: 2,
    dashArray: '6 6',
    fillColor: c.zona,
    fillOpacity: 0.06,
    ...opciones,
  })
}

/// Un panel encima de los demás puntos, para lo que no debe quedar tapado
/// (la última posición de un equipo debajo de su propio recorrido).
export function panelEncima(mapa, nombre = 'encima') {
  if (!mapa.getPane(nombre)) mapa.createPane(nombre).style.zIndex = 650
  return nombre
}

/// Escapa lo que se mete en el HTML de un popup: el nombre de un equipo lo
/// escribe una persona.
export function esc(t) {
  return String(t ?? '').replace(
    /[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c],
  )
}

export { L }
