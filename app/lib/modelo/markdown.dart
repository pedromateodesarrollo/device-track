/// Markdown mínimo para las respuestas del asistente: títulos, párrafos,
/// listas (también anidadas), tablas, bloques de código, citas, líneas, y
/// dentro del texto negritas, cursivas, código y enlaces. Lo mismo que el
/// panel web (`manager/src/markdown.js`); no pretende ser CommonMark.
///
/// No se usa un paquete a propósito: el texto lo escribe un modelo que cita
/// nombres que escribió cualquiera de la organización (el de un equipo, una
/// nota), y aquí se decide qué se vuelve tocable. Un enlace es texto con
/// subrayado; qué hace al tocarlo lo decide la pantalla.
///
/// Dos pasos: [bloquesMarkdown] parte el texto (Dart puro, con su prueba) y
/// `vista/markdown.dart` lo dibuja con los colores del tema.
library;

sealed class Bloque {
  const Bloque();
}

class Titulo extends Bloque {
  const Titulo(this.nivel, this.texto);
  final int nivel;
  final String texto;
}

class Parrafo extends Bloque {
  const Parrafo(this.texto);

  /// Con sus saltos de línea: en un chat, un renglón nuevo es un renglón
  /// nuevo.
  final String texto;
}

class ItemLista {
  const ItemLista(this.texto, {this.nivel = 0, this.numero});
  final String texto;

  /// 0 el de afuera; cada dos espacios de sangría, uno más.
  final int nivel;

  /// El número, en una lista ordenada.
  final int? numero;
}

class Lista extends Bloque {
  const Lista(this.items);
  final List<ItemLista> items;
}

class Tabla extends Bloque {
  const Tabla(this.cabecera, this.filas);
  final List<String> cabecera;
  final List<List<String>> filas;

  int get columnas => [cabecera.length, for (final f in filas) f.length].reduce((a, b) => a > b ? a : b);
}

class Codigo extends Bloque {
  const Codigo(this.texto);
  final String texto;
}

class Cita extends Bloque {
  const Cita(this.bloques);
  final List<Bloque> bloques;
}

class Linea extends Bloque {
  const Linea();
}

final _valla = RegExp(r'^\s*```');
final _titulo = RegExp(r'^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$');
final _linea = RegExp(r'^\s{0,3}([-*_])(\s*\1){2,}\s*$');
final _item = RegExp(r'^(\s*)([-*+]|(\d+)[.)])\s+(.*)$');
final _separador = RegExp(r'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$');
final _cita = RegExp(r'^\s{0,3}>\s?');

bool _esTabla(List<String> l, int i) => l[i].contains('|') && i + 1 < l.length && _separador.hasMatch(l[i + 1]);

List<Bloque> bloquesMarkdown(String texto) =>
    _bloques(texto.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n'));

List<Bloque> _bloques(List<String> l) {
  final r = <Bloque>[];
  var i = 0;
  while (i < l.length) {
    final linea = l[i];
    if (linea.trim().isEmpty) {
      i++;
      continue;
    }

    if (_valla.hasMatch(linea)) {
      final cuerpo = <String>[];
      i++;
      while (i < l.length && !_valla.hasMatch(l[i])) {
        cuerpo.add(l[i++]);
      }
      i++; // la valla de cierre (o el final)
      r.add(Codigo(cuerpo.join('\n')));
      continue;
    }

    final t = _titulo.firstMatch(linea);
    if (t != null) {
      r.add(Titulo(t.group(1)!.length, t.group(2)!));
      i++;
      continue;
    }

    if (_linea.hasMatch(linea)) {
      r.add(const Linea());
      i++;
      continue;
    }

    if (_cita.hasMatch(linea)) {
      final dentro = <String>[];
      while (i < l.length && _cita.hasMatch(l[i])) {
        dentro.add(l[i++].replaceFirst(_cita, ''));
      }
      r.add(Cita(_bloques(dentro)));
      continue;
    }

    if (_esTabla(l, i)) {
      final cabecera = celdas(linea);
      i += 2;
      final filas = <List<String>>[];
      while (i < l.length && l[i].contains('|') && l[i].trim().isNotEmpty) {
        filas.add(celdas(l[i++]));
      }
      r.add(Tabla(cabecera, filas));
      continue;
    }

    if (_item.hasMatch(linea)) {
      final items = <ItemLista>[];
      while (i < l.length) {
        final m = _item.firstMatch(l[i]);
        if (m != null) {
          items.add(ItemLista(m.group(4)!, nivel: m.group(1)!.length ~/ 2, numero: int.tryParse(m.group(3) ?? '')));
          i++;
        } else if (l[i].trim().isNotEmpty && l[i].startsWith('  ') && items.isNotEmpty) {
          // Un renglón sangrado que sigue a un ítem es parte de él.
          final u = items.removeLast();
          items.add(ItemLista('${u.texto} ${l[i].trim()}', nivel: u.nivel, numero: u.numero));
          i++;
        } else {
          break;
        }
      }
      r.add(Lista(items));
      continue;
    }

    // Párrafo: hasta la línea en blanco o hasta que empiece otro bloque.
    final parrafo = <String>[];
    while (i < l.length &&
        l[i].trim().isNotEmpty &&
        !_valla.hasMatch(l[i]) &&
        !_titulo.hasMatch(l[i]) &&
        !_cita.hasMatch(l[i]) &&
        !_item.hasMatch(l[i]) &&
        !_esTabla(l, i)) {
      parrafo.add(l[i++].trim());
    }
    if (parrafo.isEmpty) {
      i++; // nada que lo reclame: se salta antes que quedarse dando vueltas
    } else {
      r.add(Parrafo(parrafo.join('\n')));
    }
  }
  return r;
}

/// Parte una fila de tabla en celdas. Los `|` dentro de código no cortan, y
/// `\|` es un `|` escrito.
List<String> celdas(String linea) {
  var s = linea.trim();
  if (s.startsWith('|')) s = s.substring(1);
  if (s.endsWith('|') && !s.endsWith(r'\|')) s = s.substring(0, s.length - 1);
  final r = <String>[];
  final actual = StringBuffer();
  var enCodigo = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == r'\' && i + 1 < s.length && s[i + 1] == '|') {
      actual.write('|');
      i++;
      continue;
    }
    if (c == '`') enCodigo = !enCodigo;
    if (c == '|' && !enCodigo) {
      r.add(actual.toString().trim());
      actual.clear();
      continue;
    }
    actual.write(c);
  }
  r.add(actual.toString().trim());
  return r;
}

// ---------------------------------------------------------------- en línea

/// Un trozo de texto con su estilo.
class Trozo {
  const Trozo(this.texto, {this.negrita = false, this.cursiva = false, this.codigo = false, this.enlace});
  final String texto;
  final bool negrita;
  final bool cursiva;
  final bool codigo;

  /// A dónde apunta, si es un enlace.
  final String? enlace;

  @override
  String toString() =>
      '${negrita ? 'N' : ''}${cursiva ? 'C' : ''}${codigo ? '`' : ''}${enlace != null ? '→$enlace' : ''}«$texto»';
}

final _enlace = RegExp(r'^\[([^\]]+)\]\(([^)\s]+)\)');
bool _letra(String c) => RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(c);

/// Lo de dentro de un párrafo, una celda o un ítem. Una marca sin pareja
/// (un `*` suelto, un `**` que no cierra) se queda como texto: el modelo a
/// veces escribe «5 * 3», y un nombre de equipo puede llevar `_`.
List<Trozo> trozos(String texto) {
  final r = <Trozo>[];
  final b = StringBuffer();
  var negrita = false;
  var cursiva = false;
  String? marcaCursiva;

  void corta() {
    if (b.isEmpty) return;
    r.add(Trozo(b.toString(), negrita: negrita, cursiva: cursiva));
    b.clear();
  }

  var i = 0;
  while (i < texto.length) {
    final c = texto[i];
    final resto = texto.substring(i);

    if (c == '`') {
      final fin = texto.indexOf('`', i + 1);
      if (fin > i + 1) {
        corta();
        r.add(Trozo(texto.substring(i + 1, fin), negrita: negrita, cursiva: cursiva, codigo: true));
        i = fin + 1;
        continue;
      }
    }

    if (c == '[') {
      final m = _enlace.firstMatch(resto);
      if (m != null) {
        corta();
        r.add(Trozo(m.group(1)!, negrita: negrita, cursiva: cursiva, enlace: m.group(2)));
        i += m.group(0)!.length;
        continue;
      }
    }

    if (resto.startsWith('**') || resto.startsWith('__')) {
      final marca = resto.substring(0, 2);
      if (negrita || texto.indexOf(marca, i + 2) > i + 2) {
        corta();
        negrita = !negrita;
        i += 2;
        continue;
      }
    }

    if (c == '*' || c == '_') {
      final antes = i > 0 ? texto[i - 1] : ' ';
      final despues = i + 1 < texto.length ? texto[i + 1] : ' ';
      // Cierra pegada a lo de antes («*así*», no «* así»), y con `_` sin una
      // letra detrás.
      if (cursiva && c == marcaCursiva && antes.trim().isNotEmpty && !(c == '_' && _letra(despues))) {
        corta();
        cursiva = false;
        marcaCursiva = null;
        i++;
        continue;
      }
      // Abre si lo que sigue no es espacio, hay con qué cerrar y (con `_`) no
      // está pegado a una letra: `id_equipo` no es una cursiva.
      final abre = !cursiva &&
          despues.trim().isNotEmpty &&
          !(c == '_' && _letra(antes)) &&
          _hayCierre(texto, i + 1, c);
      if (abre) {
        corta();
        cursiva = true;
        marcaCursiva = c;
        i++;
        continue;
      }
    }

    b.write(c);
    i++;
  }
  corta();
  return r;
}

/// Si después de [desde] hay un [marca] que pueda cerrar una cursiva: pegado
/// a lo de antes y no doble.
bool _hayCierre(String texto, int desde, String marca) {
  for (var j = desde + 1; j < texto.length; j++) {
    if (texto[j] != marca) continue;
    final doble = (j + 1 < texto.length && texto[j + 1] == marca) || texto[j - 1] == marca;
    if (doble) continue;
    if (texto[j - 1].trim().isEmpty) continue;
    if (marca == '_' && j + 1 < texto.length && _letra(texto[j + 1])) continue;
    return true;
  }
  return false;
}

/// El texto sin marcas, para lo que necesita una versión plana (el título de
/// una notificación, la medida de una celda).
String textoPlano(String texto) => trozos(texto).map((t) => t.texto).join();
