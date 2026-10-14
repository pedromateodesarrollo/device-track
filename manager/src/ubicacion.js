// Por qué un equipo tiene (o no tiene) ubicación: el `ubicacion_estado` que
// manda cada fuente en su reporte (ver docs/api.md), dicho para una persona,
// con un «Qué hacer» cuando lo puede arreglar alguien con el teléfono en la
// mano. Lo usan la ficha del equipo (fila «Ubicación») y la lista (el aviso
// junto al nombre).

import { hace, distancia } from './api.js'

/// Los motivos que alguien puede arreglar desde el teléfono o el panel: son
/// los que se marcan en la lista de equipos. «Sin señal» no está: es el sitio
/// (una bodega), no una configuración.
const ARREGLABLES = new Set([
  'aproximada', 'simulada', 'no_pedida', 'sin_pedir', 'denegada', 'denegada_siempre',
  'servicio_apagado', 'sin_proveedor', 'sin_segundo_plano', 'ahorro_bateria',
])

/// Hay posición (buena o no tanto).
const CON_POSICION = new Set(['ok', 'aproximada', 'simulada', 'vieja'])

const PROVEEDORES = { gps: 'GPS', network: 'red (Wi-Fi y antenas)', fused: 'combinada', passive: 'de otra app' }

const AHORRO = {
  sin_cambio: 'no toca la ubicación',
  sin_gps_pantalla_apagada: 'sin GPS con la pantalla apagada',
  sin_ubicacion_pantalla_apagada: 'sin ubicación con la pantalla apagada',
  solo_al_frente: 'ubicación solo con la app delante',
  limitada: 'ubicación limitada con la pantalla apagada',
}

/// Una duración en segundos, para leerla: «40 s», «12 min», «3 h», «2 días».
function duracion(s) {
  if (s == null) return ''
  if (s < 90) return `${Math.round(s)} s`
  if (s < 5400) return `${Math.round(s / 60)} min`
  if (s < 172800) return `${Math.round(s / 3600)} h`
  return `${Math.round(s / 86400)} días`
}

const nombreApp = (u) => (u?.fuente_nombre || '').trim() || u?.fuente_paquete || 'la app'
const esAgente = (u) => u?.fuente_tipo === 'agente'

/// El permiso que hace falta para esa fuente: el agente lee con la app
/// cerrada (todo el tiempo); una app con el plugin, con la app delante.
const permitir = (u) => (esAgente(u) ? 'Permitir todo el tiempo' : 'Permitir solo mientras se usa la app')
const rutaPermiso = (u) => `Ajustes › Aplicaciones › ${nombreApp(u)} › Permisos › Ubicación › «${permitir(u)}»`

/// Qué dice cada motivo y qué hacer. `u` es el estado (con su fuente).
function textos(u) {
  const app = nombreApp(u)
  switch (u.motivo) {
    case 'ok':
      return { texto: 'Llega bien.' }
    case 'aproximada':
      return {
        texto: `${app} solo tiene ubicación aproximada (a varios kilómetros), no la precisa.`,
        queHacer: `Ajustes › Aplicaciones › ${app} › Permisos › Ubicación › activar «Usar ubicación precisa».`,
      }
    case 'simulada':
      return {
        texto: 'La posición es falsa: en el teléfono hay una app de ubicación simulada activa.',
        queHacer: 'Ajustes › Sistema › Opciones de desarrollador › «Seleccionar app de ubicación simulada» › Ninguna.',
      }
    case 'vieja':
      return { texto: `No consiguió una posición nueva; mandó la última que tenía el teléfono${u.edad_s ? `, de hace ${duracion(u.edad_s)}` : ''}.` }
    case 'no_pedida':
      return {
        texto: 'La organización no pide la ubicación.',
        queHacer: 'Organización › marcar «Pedir la ubicación a los equipos» (quien administra).',
      }
    case 'no_declarada':
      return { texto: `${app} no está hecha para pedir la ubicación (no declara el permiso): hace falta otra versión de la app, o el agente.` }
    case 'sin_pedir':
      return {
        texto: `${app} todavía no ha pedido el permiso de ubicación.`,
        queHacer: esAgente(u)
          ? 'Abrir el agente en el teléfono y tocar «Revisar permisos».'
          : `Entrar a ${app} con un usuario: al entrar pide el permiso; contestar «Mientras se usa la app». O directo: ${rutaPermiso(u)}.`,
      }
    case 'denegada':
      return {
        texto: `Le negaron el permiso de ubicación a ${app}.`,
        queHacer: `${rutaPermiso(u)}.`,
      }
    case 'denegada_siempre':
      return {
        texto: `Le negaron el permiso de ubicación a ${app} y marcaron «No volver a preguntar»: la app ya no puede pedirlo, solo se da en Ajustes.`,
        queHacer: `${rutaPermiso(u)}.`,
      }
    case 'servicio_apagado':
      return {
        texto: 'La ubicación del teléfono está apagada.',
        queHacer: 'Bajar la barra de arriba y tocar «Ubicación», o Ajustes › Ubicación › «Usar ubicación».',
      }
    case 'sin_proveedor':
      return {
        texto: u.red_existe === false && u.google_play === false
          ? 'El GPS está apagado y el teléfono no tiene servicios de Google: no tiene con qué ubicarse.'
          : 'La ubicación está encendida, pero sin GPS ni ubicación por red: no tiene con qué ubicarse.',
        queHacer: 'Ajustes › Ubicación › Servicios de ubicación: activar el GPS y la precisión de ubicación (en teléfonos viejos, modo «Alta precisión»).',
      }
    case 'sin_segundo_plano':
      return {
        texto: `Con la app cerrada no la puede leer: ${app} tiene «Permitir solo mientras se usa la app» y le hace falta «Permitir todo el tiempo».`,
        queHacer: `Ajustes › Aplicaciones › ${app} › Permisos › Ubicación › «Permitir todo el tiempo».`,
      }
    case 'ahorro_bateria':
      return {
        texto: u.reposo
          ? 'El teléfono estaba en reposo (ahorro de batería de Android) y no dejó leer la ubicación.'
          : `El ahorro de batería no deja leer la ubicación${u.ahorro_ubicacion && AHORRO[u.ahorro_ubicacion] ? ` (${AHORRO[u.ahorro_ubicacion]})` : ''}.`,
        queHacer: `Apagar el ahorro de batería, y en Ajustes › Aplicaciones › ${app} › Batería › «Sin restricciones».`,
      }
    case 'sin_senal': {
      const pistas = []
      if (u.gps === false) pistas.push('el GPS está apagado')
      if (u.google_play === false) pistas.push('no tiene servicios de Google (sin ellos casi no hay ubicación por red)')
      else if (u.wifi === false && u.escaneo_wifi === false) pistas.push('el Wi-Fi está apagado (ayuda a ubicarse bajo techo)')
      if (u.avion) pistas.push('está en modo avión')
      return {
        texto: `Todo está permitido y encendido, pero no llegó ninguna posición${u.espera_s ? ` en ${duracion(u.espera_s)}` : ''}: sin señal de GPS (bajo techo, en una bodega) y sin ubicación por Wi-Fi o antenas${pistas.length ? `; además, ${pistas.join(', ')}` : ''}.`
          + (u.ultima_edad_s != null ? ` La última que tenía el teléfono es de hace ${duracion(u.ultima_edad_s)}.` : ''),
        queHacer: 'Si hace falta saber dónde está: llevarlo a un sitio abierto o junto a una ventana y pedir «Reportar ya». Con el Wi-Fi encendido se ubica mejor bajo techo.',
      }
    }
    case 'error':
      return { texto: `El equipo no pudo leer la ubicación${u.error ? ` (${u.error})` : ''}.` }
    default:
      return { texto: `El equipo dice «${u.motivo}».` }
  }
}

/// Lo demás que el equipo contó, en frases cortas.
function datos(u) {
  const d = []
  if (u.permiso) {
    d.push({ precisa: 'Permiso: precisa', aproximada: 'Permiso: solo aproximada', ninguno: 'Sin permiso' }[u.permiso] || `Permiso: ${u.permiso}`)
  }
  if (u.segundo_plano != null && u.permiso && u.permiso !== 'ninguno') {
    d.push(u.segundo_plano ? 'todo el tiempo' : 'solo con la app abierta')
  }
  if (u.servicio === false) d.push('ubicación del teléfono apagada')
  if (u.servicio !== false && u.gps === false) d.push('GPS apagado')
  if (u.servicio !== false && u.red === false) d.push(u.red_existe === false ? 'sin ubicación por red' : 'ubicación por red apagada')
  if (u.google_play === false) d.push('sin servicios de Google')
  if (u.ahorro) d.push(`ahorro de batería${u.ahorro_ubicacion && AHORRO[u.ahorro_ubicacion] ? ` (${AHORRO[u.ahorro_ubicacion]})` : ''}`)
  if (u.sin_optimizar === false && esAgente(u)) d.push('con optimización de batería')
  if (u.avion) d.push('modo avión')
  if (u.proveedor) d.push(`por ${PROVEEDORES[u.proveedor] || u.proveedor}`)
  if (u.precision_m != null && CON_POSICION.has(u.motivo)) d.push(`± ${distancia(u.precision_m)}`)
  if (u.edad_s != null && CON_POSICION.has(u.motivo) && u.edad_s >= 60) d.push(`leída hace ${duracion(u.edad_s)}`)
  return d
}

/// Todo lo que la fila «Ubicación» necesita de un equipo (de `GET
/// /v1/equipos/:id` o de la lista): `motivo` (null = versión vieja), `texto`,
/// `queHacer`, `arreglable`, `datos`, `quien` (qué app lo dijo y cuándo),
/// `vieja` (la posición guardada es de mucho antes del último reporte) y
/// `porFuente` (cuando sus fuentes dicen cosas distintas).
export function explicaUbicacion(e) {
  const u = e?.ubicacion_estado
  const r = {
    motivo: u?.motivo ?? null,
    texto: '',
    queHacer: '',
    arreglable: false,
    datos: [],
    quien: '',
    vieja: '',
    porFuente: [],
  }
  // La posición guardada es de mucho antes del último reporte: el equipo
  // sigue vivo pero ya no la consigue.
  if (e?.lat != null && e.ubicacion_t && e.ultimo_reporte) {
    const atras = (new Date(e.ultimo_reporte) - new Date(e.ubicacion_t)) / 1000
    if (atras > 30 * 60) r.vieja = `La última posición es de ${hace(e.ubicacion_t)}; desde entonces reporta sin ella.`
  }
  if (!u) {
    r.texto = 'El equipo aún no informa el motivo (versión vieja).'
    return r
  }
  const t = textos(u)
  r.texto = t.texto
  r.queHacer = t.queHacer || ''
  r.arreglable = ARREGLABLES.has(u.motivo)
  r.datos = datos(u)
  r.quien = `Lo dijo ${nombreApp(u)}${u.t ? ` ${hace(u.t)}` : ''}.`
  const fuentes = (Array.isArray(e.fuentes) ? e.fuentes : []).filter((f) => f.ubicacion_estado && !f.revocada)
  if (fuentes.length > 1 && new Set(fuentes.map((f) => f.ubicacion_estado.motivo)).size > 1) {
    r.porFuente = fuentes.map((f) => {
      const uf = { ...f.ubicacion_estado, fuente_nombre: f.nombre, fuente_paquete: f.paquete, fuente_tipo: f.tipo }
      return { app: nombreApp(uf), texto: textos(uf).texto, cuando: hace(f.ubicacion_estado_t) }
    })
  }
  return r
}

/// Para la lista: el aviso discreto junto al nombre, solo si falta ubicación
/// (o no sirve) por algo que se puede arreglar. Null si no hay que avisar.
export function avisoUbicacion(e) {
  const u = e?.ubicacion_estado
  if (!u || !ARREGLABLES.has(u.motivo)) return null
  // La organización no la pide: no es cosa de este equipo.
  if (u.motivo === 'no_pedida') return null
  return `Ubicación: ${textos(u).texto}`
}
