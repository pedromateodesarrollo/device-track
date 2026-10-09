// Los datos de cada forma de panel tal como los manda `GET
// /v1/tableros/:id/datos` (hub/lib/src/ia/tableros.dart), y a dónde llevan
// sus enlaces.
import 'package:device_track_panel/modelo/tablero.dart';
import 'package:flutter_test/flutter_test.dart';

Panel _panel(String forma, Map<String, Object?> datos, {String fuente = 'equipos', int ancho = 1}) =>
    Panel.deJson({'id': 'p', 'titulo': 'T', 'fuente': fuente, 'forma': forma, 'ancho': ancho, 'datos': datos});

void main() {
  test('cifra: valor, alarma y enlace', () {
    final p = _panel('cifra', {'valor': 3, 'enlace': '#/panel/equipos?estado=perdido', 'alarma': true}, fuente: 'resumen');
    final d = p.datos as DatosCifra;
    expect((d.valor, d.alarma, d.enlace), (3, true, '#/panel/equipos?estado=perdido'));
    expect(p.error, isNull);
    // Una cifra de equipos o alertas no trae enlace ni alarma.
    final sola = _panel('cifra', {'valor': '12'}).datos as DatosCifra;
    expect((sola.valor, sola.alarma, sola.enlace), (12, false, null));
  });

  test('barras y dona: series, total, máximo y suma', () {
    for (final forma in ['barras', 'dona']) {
      final d = _panel(forma, {
        'series': [
          {'etiqueta': 'activo', 'valor': 7},
          {'etiqueta': 'perdido', 'valor': 2},
          {'etiqueta': 'Sin dato', 'valor': 1},
        ],
        'total': 10,
      }).datos as DatosSeries;
      expect(d.series.map((s) => s.etiqueta), ['activo', 'perdido', 'Sin dato']);
      expect((d.total, d.maximo, d.suma), (10, 7, 10));
    }
  });

  test('tabla: columnas, filas con el equipo y las celdas legibles', () {
    final p = _panel('tabla', {
      'columnas': [
        {'id': 'nombre', 'titulo': 'Equipo'},
        {'id': 'bateria', 'titulo': 'Batería'},
        {'id': 'ultima_vez', 'titulo': 'Última vez'},
        {'id': 'conectado', 'titulo': 'Conectado'},
      ],
      'filas': [
        {'id': 42, 'valores': ['TC51', 15, '2026-10-09T14:00:00Z', 'Conectado']},
        {'id': null, 'valores': ['Sin id', null, null, null]},
      ],
      'total': 30,
    }, ancho: 2);
    final d = p.datos as DatosTabla;
    expect(p.ancho, 2);
    expect(d.columnas.map((c) => c.titulo), ['Equipo', 'Batería', 'Última vez', 'Conectado']);
    expect(d.filas.first.id, 42);
    expect(d.filas.last.id, isNull);
    expect(d.total, 30);

    final ahora = DateTime.parse('2026-10-09T14:05:00Z');
    expect(DatosTabla.celda('bateria', 15), '15 %');
    expect(DatosTabla.celda('ultima_vez', '2026-10-09T14:00:00Z', ahora: ahora), 'hace 5 min');
    expect(DatosTabla.celda('abierta', '2026-10-08T13:00:00Z', ahora: ahora), 'ayer');
    expect(DatosTabla.celda('nombre', null), '—');
    expect(DatosTabla.celda('nombre', '  '), '—');
    expect(DatosTabla.celda('conectado', true), 'sí');
    expect(DatosTabla.celda('alertas', 2.0), '2');
  });

  test('mapa: solo los puntos con coordenadas', () {
    final d = _panel('mapa', {
      'puntos': [
        {'id': 1, 'nombre': 'A', 'lat': 18.47, 'lng': -69.9, 'estado': 'activo', 'conectado': true, 'bateria': 80, 'alertas': 0},
        {'id': 2, 'nombre': 'B', 'lat': '18.5', 'lng': '-69.8', 'estado': 'perdido', 'alertas': 1},
        {'id': 3, 'nombre': 'C', 'lat': null, 'lng': null},
      ],
      'total': 5,
    }).datos as DatosMapa;
    expect(d.puntos.map((p) => p.id), [1, 2]);
    expect(d.puntos[1].lat, 18.5);
    expect(d.puntos[1].comoEquipo, {'estado': 'perdido', 'conectado': false, 'alertas': 1});
    expect(d.total, 5);
  });

  test('un panel con error no trae datos, y una forma desconocida tampoco tumba el tablero', () {
    final conError = Panel.deJson({'id': 'x', 'titulo': 'X', 'fuente': 'alertas', 'forma': 'tabla', 'error': 'Sin permiso'});
    expect((conError.datos, conError.error), (null, 'Sin permiso'));
    final nueva = _panel('radar', {'algo': 1});
    expect(nueva.datos, isNull);
    expect(nueva.error, contains('actualízala'));
    final mala = _panel('barras', {'series': 'no es una lista'});
    expect(mala.datos, isNull);
    expect(mala.error, isNotNull);
  });

  test('el tablero 0 es el Resumen y cada uno empieza su pregunta al asistente', () {
    final resumen = Tablero.deJson({'id': 0, 'nombre': 'Resumen', 'paneles': []});
    expect(resumen.esResumen, isTrue);
    expect(resumen.preguntaAsistente, 'Quiero personalizar mi Resumen: ');
    final propio = Tablero.deJson({'id': 4, 'nombre': 'Batería', 'propio': true, 'compartido': true});
    expect(propio.preguntaAsistente, 'Quiero cambiar mi tablero «Batería»: ');
    expect(propio.compartido, isTrue);
    final ajeno = Tablero.deJson({'id': 5, 'nombre': 'Almacén', 'propio': false, 'de': 'Ana'});
    expect(ajeno.de, 'Ana');
    expect(ajeno.preguntaAsistente, 'Quiero un tablero nuevo con ');
  });

  group('destinoDeEnlace', () {
    test('las cifras del Resumen', () {
      final perdidos = destinoDeEnlace('#/panel/equipos?estado=perdido') as DestinoEquipos;
      expect(perdidos.filtros.estado, 'perdido');
      final conectados = destinoDeEnlace('#/panel/equipos?conectado=1') as DestinoEquipos;
      expect(conectados.filtros.consulta, {'conectado': '1'});
      final sin24 = destinoDeEnlace('#/panel/equipos?conectado=sin24') as DestinoEquipos;
      expect(sin24.filtros.consulta, {'sin_contacto': '1'});
      final todos = destinoDeEnlace('#/panel/equipos?todos=1') as DestinoEquipos;
      expect(todos.filtros.vacios, isTrue);
      expect(destinoDeEnlace('#/panel/alertas'), isA<DestinoAlertas>());
    });

    test('un equipo, con o sin el hub delante', () {
      expect((destinoDeEnlace('#/panel/equipos/42') as DestinoEquipo).id, 42);
      expect((destinoDeEnlace('https://devicetrack.chalonasoft.com/#/panel/equipos/7') as DestinoEquipo).id, 7);
    });

    test('lo que no es una pantalla de la app', () {
      expect(destinoDeEnlace('#/panel/llaves'), isNull);
      expect(destinoDeEnlace('https://www.openstreetmap.org'), isNull);
      expect(destinoDeEnlace('#/panel/equipos/abc'), isNull);
      expect(destinoDeEnlace(null), isNull);
    });
  });
}
