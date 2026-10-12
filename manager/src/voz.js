// La voz del asistente en el navegador: grabar una nota, que el hub la
// escriba y leer las respuestas en voz alta (Asistente.vue).
//
// El hub es el que oye y habla (`hub/lib/src/ia/voz.dart`):
//   POST /v1/ia/voz/transcribir {audio, mime} → {texto}
//   POST /v1/ia/voz/hablar {texto, parte}     → {audio (WAV en base64), mime, parte, partes}
// Solo se ofrece si `/v1/yo` dice `ia_voz` (el asistente de la organización
// es de Gemini).
import { ref, shallowRef } from 'vue'
import { api } from './api.js'

/** Lo más que dura una nota: a los 3 minutos se manda sola. */
export const MAX_SEGUNDOS_NOTA = 180

// Lo que graban los navegadores y Gemini oye (probado el 2026-10-10: Chromium
// graba webm y mp4 con Opus; Safari, mp4 con AAC; Firefox, ogg).
const TIPOS = ['audio/webm;codecs=opus', 'audio/mp4', 'audio/ogg;codecs=opus', 'audio/webm']

/** ¿Este navegador puede grabar? Sin HTTPS no hay micrófono. */
export function puedeGrabar() {
  return (
    typeof window !== 'undefined' &&
    window.isSecureContext !== false &&
    !!navigator.mediaDevices?.getUserMedia &&
    typeof window.MediaRecorder !== 'undefined'
  )
}

/** `75` → `1:15`. */
export function duracion(segundos) {
  const s = Math.max(0, Math.floor(Number(segundos) || 0))
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

/**
 * Una grabadora de notas de voz.
 *
 * `estado` es 'quieta', 'pidiendo' (esperando el permiso) o 'grabando';
 * `segundos`, lo que va. `empezar()` lanza con un texto para la persona si no
 * hay permiso o micrófono. `terminar()` devuelve `{audio (base64), mime,
 * segundos}`; `cancelar()` la tira. Al llegar a `maxSegundos` llama `alTope`.
 */
export function crearGrabadora({ maxSegundos = MAX_SEGUNDOS_NOTA, alTope } = {}) {
  const estado = ref('quieta')
  const segundos = ref(0)
  let flujo = null
  let rec = null
  let partes = []
  let reloj = null
  let inicio = 0

  async function empezar() {
    if (estado.value !== 'quieta') return
    estado.value = 'pidiendo'
    try {
      flujo = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
      })
    } catch (e) {
      estado.value = 'quieta'
      throw new Error(
        e?.name === 'NotAllowedError' || e?.name === 'SecurityError'
          ? 'El navegador no dio permiso para usar el micrófono. Actívalo en el candado de la barra de direcciones.'
          : 'No se encontró un micrófono en este equipo.',
      )
    }
    const tipo = TIPOS.find((t) => window.MediaRecorder.isTypeSupported?.(t)) || ''
    // 32 kbps de Opus: la voz se entiende igual y tres minutos son ~0,7 MB
    // (el hub acepta hasta 1,4 MB).
    rec = new window.MediaRecorder(flujo, tipo ? { mimeType: tipo, audioBitsPerSecond: 32000 } : undefined)
    partes = []
    rec.ondataavailable = (e) => {
      if (e.data?.size) partes.push(e.data)
    }
    rec.start(1000)
    inicio = Date.now()
    segundos.value = 0
    estado.value = 'grabando'
    reloj = setInterval(() => {
      segundos.value = Math.floor((Date.now() - inicio) / 1000)
      if (segundos.value >= maxSegundos) alTope?.()
    }, 250)
  }

  function soltar() {
    clearInterval(reloj)
    reloj = null
    flujo?.getTracks().forEach((t) => t.stop())
    flujo = null
    estado.value = 'quieta'
  }

  async function terminar() {
    if (estado.value !== 'grabando' || !rec) return null
    const r = rec
    rec = null
    const parado = new Promise((ok) => (r.onstop = ok))
    r.stop()
    await parado
    const seg = Math.max(1, Math.round((Date.now() - inicio) / 1000))
    soltar()
    const blob = new Blob(partes, { type: r.mimeType || 'audio/webm' })
    partes = []
    return { audio: await aBase64(blob), mime: blob.type, segundos: seg }
  }

  function cancelar() {
    if (rec && rec.state !== 'inactive') {
      rec.onstop = null
      try {
        rec.stop()
      } catch {
        // ya estaba parada
      }
    }
    rec = null
    partes = []
    soltar()
  }

  return { estado, segundos, empezar, terminar, cancelar }
}

function aBase64(blob) {
  return new Promise((ok, mal) => {
    const fr = new FileReader()
    fr.onload = () => ok(String(fr.result).split(',')[1] || '')
    fr.onerror = () => mal(fr.error)
    fr.readAsDataURL(blob)
  })
}

/** Lo que dice la nota (`terminar()` de la grabadora). Lanza si no se entendió. */
export async function transcribir(nota) {
  const r = await api.post('/v1/ia/voz/transcribir', { audio: nota.audio, mime: nota.mime })
  return String(r?.texto || '').trim()
}

/**
 * Lee respuestas en voz alta, una a la vez.
 *
 * `decir(clave, texto)` pide la primera parte, la toca y, mientras suena, pide
 * la siguiente (una por delante: cada parte cuesta). `sonando` es la clave de
 * lo que suena (o se está preparando) y `cargando`, si se espera la primera
 * parte. `callar()` corta todo. `error` dice por qué no se pudo.
 *
 * `desbloquear()` va en el toque de la persona (el del micrófono): Safari solo
 * deja sonar un `<audio>` que se tocó durante un gesto, y la respuesta llega
 * segundos después. Se reusa siempre el mismo elemento.
 */
export function crearLocutor() {
  const sonando = shallowRef(null)
  const cargando = ref(false)
  const error = ref('')
  let audio = null
  let url = null
  let turno = 0
  let detener = null

  const elemento = () => (audio ??= new Audio())

  function liberar() {
    if (url) URL.revokeObjectURL(url)
    url = null
  }

  function desbloquear() {
    const a = elemento()
    if (sonando.value != null) return
    const silencio = URL.createObjectURL(wavSilencio())
    a.muted = true
    a.src = silencio
    a.play()
      .catch(() => {})
      .finally(() => {
        if (a.src === silencio) a.pause()
        a.muted = false
        URL.revokeObjectURL(silencio)
      })
  }

  function callar() {
    turno++
    detener?.()
    audio?.pause()
    liberar()
    sonando.value = null
    cargando.value = false
  }

  function parte(texto, i) {
    const p = api.post('/v1/ia/voz/hablar', { texto, parte: i }).then((r) => r || {})
    // Si se calla antes de llegar, nadie la espera: que no quede como error suelto.
    p.catch(() => {})
    return p
  }

  function tocar(p) {
    return new Promise((ok, mal) => {
      const a = elemento()
      const bin = atob(p.audio || '')
      const bytes = new Uint8Array(bin.length)
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
      liberar()
      url = URL.createObjectURL(new Blob([bytes], { type: p.mime || 'audio/wav' }))
      const limpiar = () => {
        a.onended = a.onerror = null
        detener = null
      }
      const fin = () => {
        limpiar()
        ok()
      }
      const falla = () => {
        limpiar()
        mal(new Error('Este navegador no pudo reproducir la voz.'))
      }
      a.onended = fin
      a.onerror = falla
      detener = fin
      a.muted = false
      a.src = url
      a.play().catch(falla)
    })
  }

  async function decir(clave, texto) {
    callar()
    const mio = turno
    sonando.value = clave
    cargando.value = true
    error.value = ''
    try {
      let siguiente = parte(texto, 0)
      for (let i = 0; ; i++) {
        const p = await siguiente
        if (mio !== turno) return
        const hay = i + 1 < Number(p.partes || 0)
        siguiente = hay ? parte(texto, i + 1) : null
        cargando.value = false
        await tocar(p)
        if (mio !== turno || !hay) break
      }
    } catch (e) {
      if (mio === turno) error.value = e.message || 'No se pudo leer en voz alta.'
    } finally {
      if (mio === turno) {
        sonando.value = null
        cargando.value = false
        liberar()
      }
    }
  }

  return { sonando, cargando, error, decir, callar, desbloquear }
}

/** Un WAV de silencio de 50 ms, para desbloquear el audio en Safari. */
function wavSilencio() {
  const muestras = 400
  const b = new DataView(new ArrayBuffer(44 + muestras * 2))
  const ascii = (en, s) => [...s].forEach((c, i) => b.setUint8(en + i, c.charCodeAt(0)))
  ascii(0, 'RIFF')
  b.setUint32(4, 36 + muestras * 2, true)
  ascii(8, 'WAVE')
  ascii(12, 'fmt ')
  b.setUint32(16, 16, true)
  b.setUint16(20, 1, true)
  b.setUint16(22, 1, true)
  b.setUint32(24, 8000, true)
  b.setUint32(28, 16000, true)
  b.setUint16(32, 2, true)
  b.setUint16(34, 16, true)
  ascii(36, 'data')
  b.setUint32(40, muestras * 2, true)
  return new Blob([b.buffer], { type: 'audio/wav' })
}
