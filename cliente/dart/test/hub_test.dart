import 'dart:async';

import 'package:device_track/device_track.dart';
import 'package:test/test.dart';

import 'hub_falso.dart';

void main() {
  late HubFalso falso;

  setUp(() async {
    falso = HubFalso();
    await falso.arranca();
  });
  tearDown(() => falso.cierra());

  group('HubCliente', () {
    test('alta: el código va en la cabecera y la credencial queda puesta', () async {
      final hub = HubCliente(servidor: '${falso.url}/');
      final a = await hub.alta(
        codigo: ' ${falso.codigo} ',
        huella: 'a1b2c3d4',
        fuente: const Fuente(
            tipo: TipoFuente.app, paquete: 'com.ejemplo.inventario', nombre: 'Inventario', version: '1.2.0', build: 12),
        equipo: const DatosEquipo(modelo: 'TC51', fabricante: 'Zebra', android: 27, serie: 'S123'),
      );
      expect(a.credencial, falso.credencial);
      expect(a.equipoId, 42);
      expect(a.equipoNombre, 'TC51 · 4f2a');
      expect(a.config, const ConfigEquipo(intervaloS: 600, ubicacion: true));
      expect(a.ws, endsWith('/v1/ws'));
      expect(hub.credencial, falso.credencial);
      expect(hub.dadoDeAlta, isTrue);
      expect(falso.cabeceras.single, 'POST /v1/alta ${falso.codigo}');
      expect(falso.altas.single, {
        'huella': 'a1b2c3d4',
        'fuente': {
          'tipo': 'app',
          'paquete': 'com.ejemplo.inventario',
          'nombre': 'Inventario',
          'version': '1.2.0',
          'build': 12,
        },
        'equipo': {'modelo': 'TC51', 'fabricante': 'Zebra', 'android': 27, 'serie': 'S123'},
      });
      hub.cerrar();
    });

    test('alta con un código que no existe: ErrorHub 401 con el código del hub', () async {
      final hub = HubCliente(servidor: falso.url);
      final f = hub.alta(
        codigo: 'dta_otro0001_x',
        huella: 'h',
        fuente: const Fuente(tipo: TipoFuente.app, paquete: 'com.ejemplo'),
      );
      await expectLater(
        f,
        throwsA(isA<ErrorHub>()
            .having((e) => e.status, 'status', 401)
            .having((e) => e.codigo, 'codigo', 'codigo_invalido')
            .having((e) => e.noAutorizado, 'noAutorizado', isTrue)
            .having((e) => e.reintentable, 'reintentable', isFalse)),
      );
      expect(hub.dadoDeAlta, isFalse);
      hub.cerrar();
    });

    test('reporte: los atrasados van en «reportes» y vuelven config y órdenes tipadas', () async {
      falso.config = {'intervalo_s': 300, 'ubicacion': false};
      falso.ordenes.add({'id': 7, 'tipo': 'sonar', 'datos': {'segundos': 30}});
      final hub = HubCliente(servidor: falso.url, credencial: falso.credencial);
      final t1 = DateTime.utc(2026, 10, 8, 9, 0);
      final t2 = DateTime.utc(2026, 10, 8, 9, 10);
      final r = await hub.reporte(Reporte(
        t: t2,
        motivo: MotivoReporte.abrir,
        bateria: 81,
        cargando: false,
        red: const Red(tipo: 'wifi', ssid: 'Almacén'),
        ubicacion: Ubicacion(lat: 18.47, lng: -69.9, precisionM: 12, t: t2),
        almacenamiento: const Almacenamiento(libre: 1000, total: 4000),
        apps: const [AppInstalada(paquete: 'com.ejemplo', version: '1.0', build: 3)],
        contexto: const {'empresa': 7},
        atrasados: [Reporte(t: t1, bateria: 90)],
        fuente: const Fuente(tipo: TipoFuente.app, paquete: 'com.ejemplo', version: '1.0', build: 3),
        android: 34,
      ));

      expect(r.config, const ConfigEquipo(intervaloS: 300, ubicacion: false));
      expect(r.ordenes.single.id, 7);
      expect(r.ordenes.single.tipo, 'sonar');
      expect(r.ordenes.single.entero('segundos'), 30);

      expect(falso.reportes.single, {
        't': '2026-10-08T09:10:00.000Z',
        'motivo': 'abrir',
        'bateria': 81,
        'cargando': false,
        'red': {'tipo': 'wifi', 'ssid': 'Almacén'},
        'ubicacion': {'lat': 18.47, 'lng': -69.9, 'precision_m': 12.0, 't': '2026-10-08T09:10:00.000Z'},
        'almacenamiento': {'libre': 1000, 'total': 4000},
        'apps': [
          {'paquete': 'com.ejemplo', 'version': '1.0', 'build': 3},
        ],
        'contexto': {'empresa': 7},
        'reportes': [
          {'t': '2026-10-08T09:00:00.000Z', 'motivo': 'periodico', 'bateria': 90},
        ],
        'fuente': {'tipo': 'app', 'paquete': 'com.ejemplo', 'version': '1.0', 'build': 3},
        'equipo': {'android': 34},
      });
      hub.cerrar();
    });

    test('sin credencial no llega al hub: ErrorHub 401 sin_credencial', () async {
      final hub = HubCliente(servidor: falso.url);
      await expectLater(
        hub.reporte(Reporte()),
        throwsA(isA<ErrorHub>().having((e) => e.codigo, 'codigo', 'sin_credencial')),
      );
      expect(falso.cabeceras, isEmpty);
      hub.cerrar();
    });

    test('credencial vieja: ErrorHub 401 noAutorizado', () async {
      final hub = HubCliente(servidor: falso.url, credencial: 'dtd_vieja001_x');
      await expectLater(
        hub.reporte(Reporte()),
        throwsA(isA<ErrorHub>()
            .having((e) => e.noAutorizado, 'noAutorizado', isTrue)
            .having((e) => e.codigo, 'codigo', 'equipo_no_autenticado')),
      );
      hub.cerrar();
    });

    test('un 502 de nginx (sin JSON) es ErrorHub reintentable', () async {
      falso.fallaReporte = 502;
      final hub = HubCliente(servidor: falso.url, credencial: falso.credencial);
      await expectLater(
        hub.reporte(Reporte()),
        throwsA(isA<ErrorHub>()
            .having((e) => e.status, 'status', 502)
            .having((e) => e.codigo, 'codigo', 'http_502')
            .having((e) => e.reintentable, 'reintentable', isTrue)),
      );
      hub.cerrar();
    });

    test('sin red: SinRespuesta, no otra cosa', () async {
      final hub = HubCliente(servidor: 'http://127.0.0.1:1', credencial: 'dtd_x_y');
      await expectLater(hub.reporte(Reporte()), throwsA(isA<SinRespuesta>()));
      hub.cerrar();
    });

    test('estadoOrden manda el estado y el detalle', () async {
      final hub = HubCliente(servidor: falso.url, credencial: falso.credencial);
      await hub.estadoOrden(7, EstadoOrden.recibida);
      await hub.estadoOrden(7, EstadoOrden.fallida, detalle: 'no_soportada');
      expect(falso.acuses, [
        (id: 7, estado: 'recibida', detalle: ''),
        (id: 7, estado: 'fallida', detalle: 'no_soportada'),
      ]);
      hub.cerrar();
    });

    test('urlWs sale del servidor', () {
      expect(HubCliente(servidor: 'https://dt.ejemplo.com/').urlWs.toString(), 'wss://dt.ejemplo.com/v1/ws');
      expect(HubCliente(servidor: 'http://10.0.0.2:3140').urlWs.toString(), 'ws://10.0.0.2:3140/v1/ws');
    });
  });

  group('modelos', () {
    test('Reporte: leer lo escrito da lo mismo', () {
      final r = Reporte(
        t: DateTime.utc(2026, 10, 8, 9),
        motivo: MotivoReporte.orden,
        bateria: 5,
        cargando: true,
        red: const Red(tipo: 'datos'),
        almacenamiento: const Almacenamiento(libre: 1, total: 2),
        atrasados: [Reporte(t: DateTime.utc(2026, 10, 8, 8), motivo: MotivoReporte.abrir)],
        android: 30,
      );
      expect(Reporte.desdeJson(r.toJson()).toJson(), r.toJson());
    });

    test('paraCola se queda con lo leído y suelta apps, contexto y atrasados', () {
      final r = Reporte(
        bateria: 50,
        apps: const [AppInstalada(paquete: 'a')],
        contexto: const {'x': 1},
        atrasados: [Reporte()],
      );
      final c = r.paraCola.toJson();
      expect(c['bateria'], 50);
      expect(c.containsKey('apps'), isFalse);
      expect(c.containsKey('contexto'), isFalse);
      expect(c.containsKey('reportes'), isFalse);
      expect(c['t'], r.toJson()['t']);
    });

    test('lo que no cuadra no revienta', () {
      expect(Orden.desdeJson({'tipo': 'sonar'}), isNull);
      expect(Orden.desdeJson('basura'), isNull);
      expect(ConfigEquipo.desdeJson({'intervalo_s': 5}).intervaloS, 60);
      expect(ConfigEquipo.desdeJson(null), ConfigEquipo.porDefecto);
      expect(RespuestaReporte.desdeJson({'ordenes': [1, {'id': 3, 'tipo': 'x'}]}).ordenes.single.id, 3);
      expect(Reporte.desdeJson({'motivo': 'inventado'}).motivo, MotivoReporte.periodico);
      expect(() => Alta.desdeJson({'equipo': {'id': 1}}), throwsFormatException);
    });
  });

  group('CanalEquipo', () {
    late HubCliente hub;
    late CanalEquipo canal;

    setUp(() {
      hub = HubCliente(servidor: falso.url, credencial: falso.credencial);
      canal = CanalEquipo(hub, esperaMinima: const Duration(milliseconds: 50), esperaMaxima: const Duration(milliseconds: 200));
    });
    tearDown(() async {
      await canal.dispose();
      hub.cerrar();
    });

    test('conecta con la credencial en la cabecera y entrega órdenes y config', () async {
      final ordenes = <Orden>[];
      final configs = <ConfigEquipo>[];
      canal.ordenes.listen(ordenes.add);
      canal.configs.listen(configs.add);
      canal.conectar();
      await hasta(() => canal.conectado && falso.sockets.isNotEmpty);
      expect(falso.cabeceras.last, 'GET /v1/ws ${falso.credencial}');

      falso.manda({'tipo': 'orden', 'orden': {'id': 9, 'tipo': 'mensaje', 'datos': {'titulo': 'Hola', 'texto': 'Ven'}}});
      falso.manda({'tipo': 'config', 'config': {'intervalo_s': 120, 'ubicacion': false}});
      falso.manda({'tipo': 'orden', 'orden': {'tipo': 'sin id'}});
      await hasta(() => ordenes.isNotEmpty && configs.isNotEmpty);
      expect(ordenes.single.id, 9);
      expect(ordenes.single.texto('titulo'), 'Hola');
      expect(configs.single, const ConfigEquipo(intervaloS: 120, ubicacion: false));
    });

    test('se cae y vuelve solo', () async {
      final estados = <bool>[];
      canal.estado.listen(estados.add);
      canal.conectar();
      await hasta(() => falso.sockets.length == 1);
      await falso.cortaSockets();
      await hasta(() => estados.length >= 3 && canal.conectado);
      expect(estados.take(3), [true, false, true]);
    });

    test('credencial rechazada: avisa una vez y no insiste; con otra credencial, conecta', () async {
      hub.credencial = 'dtd_vieja001_x';
      final rechazos = <String>[];
      canal.credencialRechazada.listen(rechazos.add);
      canal.conectar();
      await hasta(() => rechazos.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(falso.rechazosWs, 1, reason: 'con la misma credencial no vuelve a probar');
      expect(rechazos.single, 'dtd_vieja001_x');

      canal.reconectarAhora();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(falso.rechazosWs, 1);

      hub.credencial = falso.credencial;
      canal.conectar();
      await hasta(() => canal.conectado);
    });

    test('cerrar no reconecta', () async {
      canal.conectar();
      await hasta(() => canal.conectado);
      await canal.cerrar();
      expect(canal.conectado, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(falso.sockets, isEmpty);
      expect(canal.conectado, isFalse);
    });

    test('sin hub sigue intentando, sin reventar', () async {
      final h = HubCliente(servidor: 'http://127.0.0.1:1', credencial: 'dtd_x_y');
      final c = CanalEquipo(h, esperaMinima: const Duration(milliseconds: 20));
      final errores = <Object>[];
      await runZonedGuarded(() async {
        c.conectar();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }, (e, _) => errores.add(e));
      expect(errores, isEmpty);
      expect(c.conectado, isFalse);
      await c.dispose();
      h.cerrar();
    });
  });
}
