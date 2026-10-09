// El Markdown de las respuestas del asistente: lo que escribe el modelo
// (tablas, listas, negritas) y lo que no debe romperse (un «5 * 3», un
// nombre de equipo con `_`).
import 'package:device_track_panel/modelo/markdown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('títulos, párrafos, listas y tablas', () {
    final b = bloquesMarkdown('''
## Equipos sin batería

Hay **2** equipos.

- TC51 · 4f2a
  sigue en el almacén
- TC56
  1. cargar

| Equipo | Batería |
|---|--:|
| TC51 | 8 % |
| TC56 | 12 % |

```
dato crudo
```
---
> una cita''');
    expect(b.map((x) => x.runtimeType), [Titulo, Parrafo, Lista, Tabla, Codigo, Linea, Cita]);
    expect((b[0] as Titulo).nivel, 2);
    final lista = b[2] as Lista;
    expect(lista.items.map((i) => (i.texto, i.nivel, i.numero)), [
      ('TC51 · 4f2a sigue en el almacén', 0, null),
      ('TC56', 0, null),
      ('cargar', 1, 1),
    ]);
    final t = b[3] as Tabla;
    expect(t.cabecera, ['Equipo', 'Batería']);
    expect(t.filas, [
      ['TC51', '8 %'],
      ['TC56', '12 %'],
    ]);
    expect((b[4] as Codigo).texto, 'dato crudo');
  });

  test('una fila de tabla con `|` dentro de código o escrito no se parte', () {
    expect(celdas(r'| `a|b` | c \| d |'), ['`a|b`', 'c | d']);
  });

  test('negritas, cursivas, código y enlaces dentro del texto', () {
    final t = trozos('Hay **2 perdidos** y *uno* con `id_equipo` [aquí](#/panel/equipos?estado=perdido).');
    expect(t.where((x) => x.negrita).map((x) => x.texto), ['2 perdidos']);
    expect(t.where((x) => x.cursiva).map((x) => x.texto), ['uno']);
    expect(t.where((x) => x.codigo).map((x) => x.texto), ['id_equipo']);
    final enlace = t.singleWhere((x) => x.enlace != null);
    expect((enlace.texto, enlace.enlace), ('aquí', '#/panel/equipos?estado=perdido'));
  });

  test('una marca sin pareja se queda como texto', () {
    expect(textoPlano('5 * 3 = 15'), '5 * 3 = 15');
    expect(textoPlano('terminal_almacen_1'), 'terminal_almacen_1');
    expect(textoPlano('**sin cerrar'), '**sin cerrar');
  });
}
