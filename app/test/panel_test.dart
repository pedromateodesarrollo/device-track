// Cada forma de panel se dibuja con sus datos, y uno con error no tumba a
// los demás. El mapa no se prueba aquí: pide teselas por la red.
import 'package:device_track_panel/modelo/tablero.dart';
import 'package:device_track_panel/tema.dart';
import 'package:device_track_panel/vista/panel_tablero.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Panel _panel(String forma, Map<String, Object?>? datos, {String? error}) => Panel.deJson({
  'id': forma,
  'titulo': 'Panel $forma',
  'fuente': 'equipos',
  'forma': forma,
  'datos': ?datos,
  'error': ?error,
});

Future<void> _pinta(WidgetTester t, Widget w, {Brightness brillo = Brightness.light}) => t.pumpWidget(
  MaterialApp(
    theme: tema(brillo),
    home: Scaffold(body: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(16), child: w))),
  ),
);

void main() {
  testWidgets('la cifra enseña el número y el título; con alarma, en rojo', (t) async {
    final p = Panel.deJson({
      'id': 'perdidos',
      'titulo': 'Perdidos',
      'fuente': 'resumen',
      'forma': 'cifra',
      'datos': {'valor': 3, 'alarma': true, 'enlace': '#/panel/equipos?estado=perdido'},
    });
    await _pinta(t, PanelCifra(panel: p));
    expect(find.text('3'), findsOneWidget);
    expect(find.text('Perdidos'), findsOneWidget);
    expect(t.widget<Text>(find.text('3')).style?.color, Paleta.claro.mal);
  });

  testWidgets('barras: una fila por grupo con su valor', (t) async {
    await _pinta(
      t,
      PanelTarjeta(
        panel: _panel('barras', {
          'series': [
            {'etiqueta': 'Duralon', 'valor': 12},
            {'etiqueta': 'JF', 'valor': 4},
          ],
          'total': 16,
        }),
      ),
    );
    expect(find.text('Duralon'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('16'), findsOneWidget); // el total, junto al título
  });

  testWidgets('dona: el total al centro y el porcentaje de cada grupo', (t) async {
    await _pinta(
      t,
      PanelTarjeta(
        panel: _panel('dona', {
          'series': [
            {'etiqueta': 'activo', 'valor': 3},
            {'etiqueta': 'perdido', 'valor': 1},
          ],
          'total': 4,
        }),
      ),
      brillo: Brightness.dark,
    );
    expect(find.text('4'), findsWidgets);
    expect(find.textContaining('75 %', findRichText: true), findsOneWidget);
    expect(find.textContaining('25 %', findRichText: true), findsOneWidget);
  });

  testWidgets('tabla: cabecera, celdas legibles y cuántas faltan', (t) async {
    await _pinta(
      t,
      PanelTarjeta(
        panel: _panel('tabla', {
          'columnas': [
            {'id': 'nombre', 'titulo': 'Equipo'},
            {'id': 'bateria', 'titulo': 'Batería'},
          ],
          'filas': [
            {'id': 42, 'valores': ['TC51', 8]},
            {'id': 43, 'valores': ['TC56', null]},
          ],
          'total': 9,
        }),
      ),
    );
    expect(find.text('Equipo'), findsOneWidget);
    expect(find.text('TC51'), findsOneWidget);
    expect(find.text('8 %'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(find.text('2 de 9'), findsOneWidget);
  });

  testWidgets('un panel con error sale como tarjeta de error', (t) async {
    await _pinta(t, PanelTarjeta(panel: _panel('tabla', null, error: 'Ese dominio no existe')));
    expect(find.text('No sale: Ese dominio no existe'), findsOneWidget);
  });

  testWidgets('una tabla o unas barras vacías lo dicen', (t) async {
    await _pinta(
      t,
      Column(
        children: [
          PanelTarjeta(panel: _panel('barras', {'series': [], 'total': 0})),
          PanelTarjeta(panel: _panel('tabla', {'columnas': [], 'filas': [], 'total': 0})),
        ],
      ),
    );
    expect(find.text('Nada que contar.'), findsOneWidget);
    expect(find.text('Nada que enseñar.'), findsOneWidget);
  });
}
