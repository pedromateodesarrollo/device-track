// El «Último usuario» y la «Aplicación» de un equipo salen de sus fuentes,
// igual que en la lista del panel web (Equipos.vue).
import 'package:device_track_panel/modelo/equipo.dart';
import 'package:flutter_test/flutter_test.dart';

Json _equipo(List<Json> fuentes, {Json extra = const {}}) => {'id': 1, 'nombre': 'TC51', 'fuentes': fuentes, ...extra};

void main() {
  group('último usuario', () {
    test('de la fuente más reciente que lo dice, con el almacén y si ya cerró la sesión', () {
      final e = _equipo([
        // El agente reportó más tarde, pero no sabe quién tiene el equipo.
        {'tipo': 'agente', 'paquete': 'com.chalonasoft.devicetrack', 'ultima_vez': '2026-10-09T15:00:00Z', 'contexto': {}},
        {
          'tipo': 'app',
          'paquete': 'com.chalona.wms_app',
          'nombre': 'WMS',
          'ultima_vez': '2026-10-09T14:00:00Z',
          'contexto': {'usuario': ' Ana Pérez ', 'almacen': 'A1 · Repuestos', 'sesion': false},
        },
        {
          'tipo': 'app',
          'paquete': 'com.chalona.orc',
          'ultima_vez': '2026-10-08T14:00:00Z',
          'contexto': {'usuario': 'Luis', 'lugar': 'Oficina', 'sesion': true},
        },
      ]);
      final u = ultimoUsuario(e)!;
      expect(u.nombre, 'Ana Pérez');
      expect(u.donde, 'A1 · Repuestos');
      expect(u.sinSesion, isTrue);
      expect(u.debajo, 'A1 · Repuestos · sin sesión');
    });

    test('el lugar si no hay almacén; nadie si ninguna fuente lo dice', () {
      final conLugar = ultimoUsuario(_equipo([
        {'ultima_vez': '2026-10-09T10:00:00Z', 'contexto': {'usuario': 'Luis', 'lugar': 'Oficina', 'sesion': true}},
      ]))!;
      expect((conLugar.donde, conLugar.sinSesion, conLugar.debajo), ('Oficina', false, 'Oficina'));
      expect(ultimoUsuario(_equipo([{'ultima_vez': '2026-10-09T10:00:00Z', 'contexto': {'usuario': ''}}])), isNull);
      expect(ultimoUsuario(_equipo([])), isNull);
      expect(ultimoUsuario({'id': 3}), isNull);
    });

    test('ordena por la hora aunque el hub las mande en otro orden', () {
      final u = ultimoUsuario(_equipo([
        {'ultima_vez': '2026-10-01T10:00:00Z', 'contexto': {'usuario': 'Viejo'}},
        {'ultima_vez': '2026-10-09T10:00:00Z', 'contexto': {'usuario': 'Nuevo'}},
      ]))!;
      expect(u.nombre, 'Nuevo');
    });
  });

  group('aplicación', () {
    test('la fuente más reciente, con su versión y las demás debajo', () {
      final a = aplicacion(_equipo([
        {'tipo': 'agente', 'paquete': 'com.chalonasoft.devicetrack', 'nombre': 'device-track', 'version': '0.1.3', 'ultima_vez': '2026-10-09T09:00:00Z'},
        {'tipo': 'app', 'paquete': 'com.chalona.wms_app', 'nombre': 'WMS Duralon', 'version': '1.62.0', 'ultima_vez': '2026-10-09T12:00:00Z'},
      ]))!;
      expect(a.nombre, 'WMS Duralon');
      expect(a.debajo, '1.62.0 · también device-track');
    });

    test('sin nombre, el paquete; con tres o más, «y N más»', () {
      final a = aplicacion(_equipo([
        {'tipo': 'app', 'paquete': 'com.ejemplo.inventario', 'nombre': '', 'ultima_vez': '2026-10-09T12:00:00Z'},
        {'tipo': 'agente', 'paquete': 'com.chalonasoft.devicetrack', 'ultima_vez': '2026-10-09T11:00:00Z'},
        {'tipo': 'app', 'paquete': 'com.otra', 'ultima_vez': '2026-10-09T10:00:00Z'},
      ]))!;
      expect(a.nombre, 'com.ejemplo.inventario');
      expect(a.debajo, 'y 2 más');
      expect(aplicacion(_equipo([])), isNull);
    });
  });

  test('red y color de un equipo', () {
    expect(redDe({'red_tipo': 'wifi', 'red_ssid': 'Almacén'}), 'Wi-Fi · Almacén');
    expect(redDe({'red_tipo': 'datos'}), 'Datos');
    expect(redDe({}), '');
    expect(colorEquipo({'estado': 'activo', 'alertas': 1}), ColorEquipo.mal);
    expect(colorEquipo({'estado': 'perdido'}), ColorEquipo.mal);
    expect(colorEquipo({'estado': 'activo', 'conectado': true}), ColorEquipo.ok);
    expect(colorEquipo({'estado': 'guardado', 'conectado': true}), ColorEquipo.apagado);
    expect(colorEquipo({'estado': 'activo'}), ColorEquipo.gris);
  });

  test('los filtros se vuelven la consulta de /v1/equipos', () {
    const f = FiltrosEquipos(q: ' tc51 ', dominio: '3', estado: 'activo', conectado: 'sin24', alerta: true, retirados: true);
    // Con un estado elegido, «retirados» no aplica (el hub tampoco lo mira).
    expect(f.consulta, {'q': 'tc51', 'dominio': '3', 'estado': 'activo', 'sin_contacto': '1', 'alerta': '1'});
    expect(const FiltrosEquipos(conectado: '0', retirados: true).consulta, {'conectado': '0', 'retirados': '1'});
    expect(const FiltrosEquipos().vacios, isTrue);
    expect(FiltrosEquipos.deConsulta({'estado': 'inventado', 'conectado': 'x'}).vacios, isTrue);
  });

  test('ordenar: lo que no tiene valor va al final', () {
    final l = <Json>[
      {'id': 1, 'nombre': 'b', 'bateria': 50},
      {'id': 2, 'nombre': 'a'},
      {'id': 3, 'nombre': 'c', 'bateria': 10},
    ];
    expect(ordena(l, OrdenEquipos.nombre).map((e) => e['id']), [2, 1, 3]);
    expect(ordena(l, OrdenEquipos.bateria).map((e) => e['id']), [3, 1, 2]);
  });
}
