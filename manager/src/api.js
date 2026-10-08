/// Cliente del API. Guarda el token en localStorage y convierte los errores del
/// hub en excepciones con el mensaje que ya viene escrito para la gente.

const CLAVE_TOKEN = 'device-track-token'

export const sesion = {
  get token() {
    try { return localStorage.getItem(CLAVE_TOKEN) || '' } catch { return '' }
  },
  set token(v) {
    try {
      if (v) localStorage.setItem(CLAVE_TOKEN, v)
      else localStorage.removeItem(CLAVE_TOKEN)
    } catch { /* navegación privada: la sesión dura lo que la pestaña */ }
  },
}

function falla(status, d) {
  // 401 con sesión guardada = el token caducó o el hub rotó su secreto (o
  // quitaron a la persona). El panel lo oye y vuelve a pedir la clave.
  if (status === 401 && sesion.token) {
    sesion.token = ''
    window.dispatchEvent(new Event('sesion-vencida'))
  }
  const e = new Error(d.mensaje || d.error || `Error ${status}`)
  e.codigo = d.error
  e.status = status
  return e
}

async function pide(metodo, ruta, cuerpo) {
  let r
  try {
    r = await fetch(ruta, {
      method: metodo,
      headers: {
        'content-type': 'application/json',
        ...(sesion.token ? { authorization: `Bearer ${sesion.token}` } : {}),
      },
      body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo),
    })
  } catch {
    throw new Error('No se pudo hablar con el hub. Revisa la conexión.')
  }
  if (r.status === 204) return null
  const d = await r.json().catch(() => ({}))
  if (!r.ok) throw falla(r.status, d)
  return d
}

/// Arma `?a=1&b=2` sin los valores vacíos.
export function consulta(params = {}) {
  const q = new URLSearchParams()
  for (const [k, v] of Object.entries(params)) {
    if (v !== '' && v != null && v !== false) q.set(k, v === true ? '1' : String(v))
  }
  const s = q.toString()
  return s ? `?${s}` : ''
}

export const api = {
  get: (r) => pide('GET', r),
  post: (r, c) => pide('POST', r, c ?? {}),
  patch: (r, c) => pide('PATCH', r, c),
  put: (r, c) => pide('PUT', r, c),
  del: (r) => pide('DELETE', r),
}

// ------------------------------------------------------------------ permisos

/// Lo que puede cada rol, igual que el hub (`Sesion.puede`): `admin` todo;
/// `editor` mira, edita y ordena; `consulta` solo mira. Ocultar un botón es
/// cortesía: quien decide es el hub.
const porRol = {
  editor: ['leer', 'editar', 'ordenar'],
  consulta: ['leer'],
}
export function puede(yo, permiso) {
  if (!yo) return false
  if (yo.rol === 'admin') return true
  return (porRol[yo.rol] || []).includes(permiso)
}

// ---------------------------------------------------------------- dominios

/// Una persona puede estar acotada a uno o varios dominios (`/v1/yo` los
/// trae). Lista vacía = toda la organización.
export const acotado = (yo) => (yo?.dominios?.length ?? 0) > 0

/// «Duralon» o «Duralon, JF»: lo que alcanza una sesión acotada.
export const alcanceTexto = (yo) => (yo?.dominios || []).map((d) => d.nombre).join(', ')

/// Si la sesión puede cambiar una zona o regla de ese dominio (`null` = de
/// toda la organización). Acotada, mira lo de toda la organización pero solo
/// toca lo de sus dominios. Como con `puede`, quien decide es el hub.
export const alcanza = (yo, dominio) =>
  !acotado(yo) || (dominio != null && yo.dominios.some((d) => d.id === dominio))

/// Los dominios que alcanza la sesión, para filtros y selectores. Con uno
/// solo no hay nada que elegir, y las pantallas no lo mencionan.
export const cargaDominios = () => api.get('/v1/dominios').then((d) => d.dominios)

/// Los nombres de una lista de ids de dominio, o «Toda la organización».
export function nombresDominios(ids, dominios) {
  if (!ids?.length) return 'Toda la organización'
  return ids.map((id) => dominios.find((d) => d.id === id)?.nombre || `#${id}`).join(', ')
}

// ---------------------------------------------------------------- formatos

/// Todo en la hora del navegador y a la dominicana: 7/10/2026 3:05 p. m.
const LOCAL = 'es-DO'

export function bytes(n) {
  if (n == null) return ''
  if (n < 1024) return `${n} B`
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(0)} KB`
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`
  return `${(n / 1024 ** 3).toFixed(1)} GB`
}

/// «hace 5 min», «ayer», o la fecha si es de hace más de una semana.
export function hace(s) {
  if (!s) return 'nunca'
  const t = new Date(s)
  const seg = (Date.now() - t.getTime()) / 1000
  if (seg < 60) return 'ahora'
  if (seg < 3600) return `hace ${Math.floor(seg / 60)} min`
  if (seg < 86400) return `hace ${Math.floor(seg / 3600)} h`
  if (seg < 172800) return 'ayer'
  if (seg < 604800) return `hace ${Math.floor(seg / 86400)} días`
  return t.toLocaleDateString(LOCAL)
}

export const fecha = (s) =>
  s ? new Date(s).toLocaleString(LOCAL, { dateStyle: 'short', timeStyle: 'short' }) : ''

export const dia = (s) => (s ? new Date(s).toLocaleDateString(LOCAL, { dateStyle: 'medium' }) : '')

export const hora = (s) => (s ? new Date(s).toLocaleTimeString(LOCAL, { timeStyle: 'short' }) : '')

/// 850 m, 1.2 km.
export function distancia(m) {
  if (m == null) return ''
  if (m < 1000) return `${Math.round(m)} m`
  return `${(m / 1000).toFixed(m < 10000 ? 1 : 0)} km`
}

/// La fecha de hoy como la quiere un `<input type="date">` (en hora local).
export function hoyIso() {
  const d = new Date()
  const dos = (n) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${dos(d.getMonth() + 1)}-${dos(d.getDate())}`
}

// ---------------------------------------------------------------- dominio

export const estados = {
  activo: 'Activo',
  guardado: 'Guardado',
  perdido: 'Perdido',
  retirado: 'Retirado',
}

export const redes = { wifi: 'Wi-Fi', datos: 'Datos', ninguna: 'Sin red', otra: 'Otra' }

export const motivos = {
  periodico: 'periódico',
  encendido: 'al encender',
  apagando: 'al apagarse',
  orden: 'por una orden',
  abrir: 'al abrir la app',
  manual: 'a mano',
}

export const tiposRegla = {
  sin_reporte: {
    nombre: 'Sin reporte',
    explica: 'Se abre cuando el equipo pasa ese tiempo sin dar señales (ni reporte ni conexión). Se cierra sola en cuanto vuelve a reportar.',
  },
  bateria_baja: {
    nombre: 'Batería baja',
    explica: 'Se abre cuando reporta por debajo del porcentaje y no está cargando. Se cierra al ponerlo a cargar o cuando sube.',
  },
  fuera_de_zona: {
    nombre: 'Fuera de zona',
    explica: 'Se abre cuando su ubicación queda fuera del círculo, descontando el error del GPS. Se cierra cuando vuelve a entrar.',
  },
  apagado: {
    nombre: 'Apagado',
    explica: 'Se abre cuando el equipo avisa que se está apagando. Se cierra cuando vuelve a encender.',
  },
}

export const estadosOrden = {
  pendiente: 'pendiente',
  enviada: 'enviada',
  recibida: 'recibida',
  hecha: 'hecha',
  fallida: 'falló',
  vencida: 'vencida',
}

export const tiposOrden = { sonar: 'Sonar', mensaje: 'Mensaje', reportar: 'Reportar ya' }

/// Lo que dice una alerta, en una línea que se entienda sin abrir nada.
export function detalleAlerta(a) {
  const d = a.detalle || {}
  switch (a.tipo) {
    case 'bateria_baja':
      return `${d.bateria ?? '?'} % (umbral ${d.porcentaje ?? '?'} %)`
    case 'fuera_de_zona':
      return `a ${distancia(d.distancia_m)} de ${d.zona || 'la zona'}` +
        (d.radio_m ? ` (radio ${distancia(d.radio_m)})` : '')
    case 'sin_reporte':
      return d.ultima_vez
        ? `sin contacto desde ${fecha(d.ultima_vez)}`
        : `sin contacto en ${d.minutos ?? '?'} min`
    case 'apagado':
      return 'avisó que se estaba apagando'
    default:
      return ''
  }
}

/// Color de un equipo en el mapa y en las listas: rojo si tiene algo que
/// mirar, verde si está conectado ahora, gris si no.
export function colorEquipo(e) {
  if (e.estado === 'perdido' || (e.alertas ?? 0) > 0) return 'mal'
  if (e.estado === 'guardado' || e.estado === 'retirado') return 'apagado'
  if (e.conectado) return 'ok'
  return 'gris'
}
