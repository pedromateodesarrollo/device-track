/// Markdown mínimo para enseñar `docs/api.md`: títulos, párrafos, listas,
/// tablas, bloques de código, código en línea, negritas, cursivas, enlaces y
/// citas. Lo justo para ese archivo; no pretende ser CommonMark.
///
/// Todo el texto se escapa ANTES de convertirlo en HTML. El archivo es
/// nuestro, pero un renderizador que confía en lo que lee es una costumbre
/// que se acaba pagando.

const escapa = (t) =>
  String(t).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c])

/// `POST /v1/alta` → `post-v1-alta`; «Códigos de alta» → `codigos-de-alta`.
export function ancla(texto) {
  return texto
    .toLowerCase()
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
}

/// Lo de dentro de un párrafo, una celda o un ítem.
function enLinea(texto) {
  // El código en línea se aparta primero (dentro de `...` no se interpreta
  // nada) y se deja una marca en su lugar, para que una cursiva o una negrita
  // puedan envolverlo: *Credencial: el código (`dta_`)*.
  const codigos = []
  let h = String(texto).replace(/`([^`]+)`/g, (_, c) => {
    codigos.push(`<code>${escapa(c)}</code>`)
    return `\u0000${codigos.length - 1}\u0000`
  })
  h = escapa(h)
  h = h.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, t, url) => {
    // Solo destinos inocentes: nada de `javascript:`.
    const ok = /^(https?:\/\/|#|\/|\.{0,2}\/?[\w-])/.test(url) && !/^\s*javascript:/i.test(url)
    return ok ? `<a href="${url}">${t}</a>` : t
  })
  h = h.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
  h = h.replace(/(^|[\s(«])\*([^*\s][^*]*?)\*(?=[\s).,;:»]|$)/g, '$1<em>$2</em>')
  return h.replace(/\u0000(\d+)\u0000/g, (_, i) => codigos[Number(i)])
}

/// Parte una fila de tabla en celdas. Los `|` dentro de código no cortan.
function celdas(linea) {
  let s = linea.trim()
  if (s.startsWith('|')) s = s.slice(1)
  if (s.endsWith('|')) s = s.slice(0, -1)
  const r = []
  let actual = ''
  let enCodigo = false
  for (let i = 0; i < s.length; i++) {
    const c = s[i]
    if (c === '\\' && s[i + 1] === '|') { actual += '|'; i++; continue }
    if (c === '`') enCodigo = !enCodigo
    if (c === '|' && !enCodigo) { r.push(actual.trim()); actual = ''; continue }
    actual += c
  }
  r.push(actual.trim())
  return r
}

const esItem = (l) => /^\s{0,3}([*-]|\d+\.)\s+/.test(l)
const esSeparador = (l) => /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(l)

/// Devuelve el HTML y la lista de títulos (para el índice de la página).
export function renderMd(texto) {
  const lineas = String(texto).replace(/\r\n?/g, '\n').split('\n')
  const titulos = []
  const usados = new Map()
  const html = bloques(lineas, titulos, usados)
  return { html, titulos }
}

function bloques(lineas, titulos, usados) {
  const salida = []
  let i = 0
  while (i < lineas.length) {
    const l = lineas[i]

    if (!l.trim()) { i++; continue }

    // Bloque de código.
    const valla = l.match(/^\s*```\s*([\w-]*)/)
    if (valla) {
      const cuerpo = []
      i++
      while (i < lineas.length && !/^\s*```/.test(lineas[i])) cuerpo.push(lineas[i++])
      i++
      const clase = valla[1] ? ` class="lenguaje-${escapa(valla[1])}"` : ''
      salida.push(`<pre><code${clase}>${escapa(cuerpo.join('\n'))}</code></pre>`)
      continue
    }

    // Título.
    const t = l.match(/^(#{1,6})\s+(.*?)\s*#*\s*$/)
    if (t) {
      const nivel = t[1].length
      const plano = t[2].replace(/`/g, '')
      let id = ancla(plano) || 'seccion'
      const n = usados.get(id) || 0
      usados.set(id, n + 1)
      if (n) id = `${id}-${n}`
      titulos.push({ nivel, texto: plano, id })
      salida.push(`<h${nivel} id="${id}">${enLinea(t[2])}</h${nivel}>`)
      i++
      continue
    }

    // Línea horizontal.
    if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(l)) {
      salida.push('<hr />')
      i++
      continue
    }

    // Cita: se juntan las líneas con `>` y se renderizan como bloques.
    if (/^\s*>/.test(l)) {
      const dentro = []
      while (i < lineas.length && /^\s*>/.test(lineas[i])) dentro.push(lineas[i++].replace(/^\s*>\s?/, ''))
      salida.push(`<blockquote>${bloques(dentro, [], usados)}</blockquote>`)
      continue
    }

    // Tabla: una fila con `|` seguida de la fila separadora.
    if (l.includes('|') && i + 1 < lineas.length && esSeparador(lineas[i + 1])) {
      const cabeza = celdas(l)
      i += 2
      const filas = []
      while (i < lineas.length && lineas[i].includes('|') && lineas[i].trim()) filas.push(celdas(lineas[i++]))
      const conCabeza = cabeza.some((c) => c)
      const th = conCabeza ? `<thead><tr>${cabeza.map((c) => `<th>${enLinea(c)}</th>`).join('')}</tr></thead>` : ''
      const td = filas.map((f) => `<tr>${f.map((c) => `<td>${enLinea(c)}</td>`).join('')}</tr>`).join('')
      salida.push(`<div class="tabla-md"><table>${th}<tbody>${td}</tbody></table></div>`)
      continue
    }

    // Lista. Las líneas sangradas que siguen a un ítem son parte de él.
    if (esItem(l)) {
      const ordenada = /^\s*\d+\./.test(l)
      const items = []
      while (i < lineas.length) {
        const actual = lineas[i]
        if (esItem(actual)) {
          items.push(actual.replace(/^\s{0,3}([*-]|\d+\.)\s+/, ''))
          i++
        } else if (actual.trim() && /^\s{2,}/.test(actual) && items.length) {
          items[items.length - 1] += ' ' + actual.trim()
          i++
        } else {
          break
        }
      }
      const etiqueta = ordenada ? 'ol' : 'ul'
      salida.push(`<${etiqueta}>${items.map((x) => `<li>${enLinea(x)}</li>`).join('')}</${etiqueta}>`)
      continue
    }

    // Párrafo: hasta la línea en blanco o hasta que empiece otro bloque.
    const parrafo = []
    while (
      i < lineas.length &&
      lineas[i].trim() &&
      !/^\s*(```|#{1,6}\s|>)/.test(lineas[i]) &&
      !esItem(lineas[i]) &&
      !(lineas[i].includes('|') && i + 1 < lineas.length && esSeparador(lineas[i + 1]))
    ) {
      parrafo.push(lineas[i++].trim())
    }
    if (parrafo.length) salida.push(`<p>${enLinea(parrafo.join(' '))}</p>`)
    else i++
  }
  return salida.join('\n')
}
