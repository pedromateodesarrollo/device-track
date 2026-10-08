import 'dart:async';
import 'dart:io';

import 'package:device_track_flutter/device_track_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'hub_falso.dart';

/// El lado Android, de mentira: lo que diría el equipo y lo que guardaría.
class NativoFalso {
  final almacen = <String, Object?>{};
  final cola = <Map<Object?, Object?>>[];
  final atendidas = <int>{};
  final llamadas = <MethodCall>[];
  String huella = 'a1b2c3d4e5f6';
  String firma = 'firma-1';
  Map<String, Object?>? ubicacion;

  /// Si no es null, `sonar` espera a que se complete (o a `detenerSonar`).
  Completer<void>? sonarEspera;

  int get sonados => llamadas.where((c) => c.method == 'sonar').length;

  Future<Object?> atiende(MethodCall c) async {
    llamadas.add(c);
    final args = c.arguments is Map ? (c.arguments as Map).cast<String, Object?>() : const <String, Object?>{};
    switch (c.method) {
      case 'equipo':
        return {'huella': huella, 'modelo': 'TC51', 'fabricante': 'Zebra', 'android': 30};
      case 'fuente':
        return {'tipo': 'app', 'paquete': 'com.ejemplo.app', 'nombre': 'Ejemplo', 'version': '1.0.0', 'build': 1};
      case 'estado':
        return {
          'bateria': 77,
          'cargando': true,
          'red': {'tipo': 'wifi', 'ssid': 'Almacén'},
          'almacenamiento': {'libre': 10, 'total': 20},
        };
      case 'ubicacion':
        return ubicacion;
      case 'firma':
        return firma;
      case 'apps':
        return [
          {'paquete': 'com.ejemplo.app', 'version': '1.0.0', 'build': 1, 'nombre': 'Ejemplo'},
        ];
      case 'sonar':
        final espera = sonarEspera;
        if (espera != null) {
          await espera.future;
          return {'tocado': true, 'segundos': 4};
        }
        return {'tocado': false, 'segundos': args['segundos']};
      case 'detenerSonar':
        sonarEspera?.complete();
        return null;
      case 'almacen':
        return {...almacen, 'pendientes': cola.length};
      case 'guardar':
        almacen.addAll(args);
        return null;
      case 'colaAgregar':
        cola.add(args['reporte']! as Map<Object?, Object?>);
        return cola.length;
      case 'colaPendientes':
        return cola;
      case 'colaVaciar':
        cola.clear();
        return null;
      case 'yaAtendida':
        return !atendidas.add(args['id']! as int);
    }
    throw MissingPluginException();
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test contesta 400 a todo HTTP; aquí el hub falso es de verdad.
  HttpOverrides.global = null;
  const canal = MethodChannel('device_track');

  late HubFalso hub;
  late NativoFalso nativo;
  DeviceTrack? dt;

  DeviceTrack nuevo({
    String? servidor,
    AlOrden? alOrden,
    Duration frenoAlFrente = const Duration(minutes: 2),
  }) =>
      dt = DeviceTrack(
        servidor: servidor ?? hub.url,
        codigo: hub.codigo,
        contexto: () => {'empresa': 7, 'sesion': true},
        alOrden: alOrden,
        frenoAlFrente: frenoAlFrente,
      );

  /// Lo que quedaría guardado de un alta anterior en este mismo equipo.
  void yaDadoDeAlta({String? credencial, String? huella, String? servidor}) {
    nativo.almacen.addAll({
      'hub': servidor ?? hub.url,
      'credencial': credencial ?? hub.credencial,
      'equipo_id': 42,
      'equipo_nombre': 'TC51 · 4f2a',
      'huella_alta': huella ?? nativo.huella,
      'firma_apps': nativo.firma,
      'intervalo_s': 600,
      'ubicacion': true,
    });
  }

  List<String> acuses(int id) => [
        for (final a in hub.acuses)
          if (a.id == id) a.detalle.isEmpty ? a.estado : '${a.estado}: ${a.detalle}',
      ];

  setUp(() async {
    hub = HubFalso();
    await hub.arranca();
    nativo = NativoFalso();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(canal, nativo.atiende);
  });

  tearDown(() async {
    await dt?.dispose();
    dt = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(canal, null);
    await hub.cierra();
  });

  test('la primera vez se da de alta sola, guarda la credencial, reporta y se conecta', () async {
    final d = nuevo();
    await d.iniciar();

    expect(hub.altas.single, {
      'huella': 'a1b2c3d4e5f6',
      'fuente': {'tipo': 'app', 'paquete': 'com.ejemplo.app', 'nombre': 'Ejemplo', 'version': '1.0.0', 'build': 1},
      'equipo': {'modelo': 'TC51', 'fabricante': 'Zebra', 'android': 30},
    });
    expect(nativo.almacen['credencial'], hub.credencial);
    expect(nativo.almacen['hub'], hub.url);
    expect(nativo.almacen['huella_alta'], 'a1b2c3d4e5f6');
    expect(nativo.almacen['equipo_id'], 42);

    final r = hub.reportes.single;
    expect(r['motivo'], 'abrir');
    expect(r['bateria'], 77);
    expect(r['red'], {'tipo': 'wifi', 'ssid': 'Almacén'});
    expect(r['contexto'], {'empresa': 7, 'sesion': true});
    expect(r['apps'], hasLength(1), reason: 'la primera vez va la lista de apps');
    expect(r['fuente'], {'tipo': 'app', 'paquete': 'com.ejemplo.app', 'nombre': 'Ejemplo', 'version': '1.0.0', 'build': 1});
    expect(r['equipo'], {'android': 30});
    expect(r.containsKey('ubicacion'), isFalse, reason: 'sin permiso no hay ubicación');
    expect(nativo.almacen['firma_apps'], 'firma-1');

    final e = d.estado.value;
    expect(e.dadoDeAlta, isTrue);
    expect(e.equipoId, 42);
    expect(e.equipoNombre, 'TC51 · 4f2a');
    expect(e.ultimoReporte, isNotNull);
    expect(e.ultimoError, isNull);

    await hasta(() => d.estado.value.conectado && hub.sockets.length == 1);

    // La lista de apps no cambió: no va otra vez.
    expect(await d.reportar(), isTrue);
    expect(hub.reportes.last['motivo'], 'manual');
    expect(hub.reportes.last.containsKey('apps'), isFalse);
  });

  test('con la credencial guardada no gasta otro uso del código', () async {
    yaDadoDeAlta();
    nativo.ubicacion = {'lat': 18.47, 'lng': -69.9, 'precision_m': 9.0, 't': '2026-10-08T09:00:00.000Z'};
    final d = nuevo();
    await d.iniciar();
    expect(hub.altas, isEmpty);
    expect(hub.reportes.single.containsKey('apps'), isFalse);
    expect(hub.reportes.single['ubicacion'], {'lat': 18.47, 'lng': -69.9, 'precision_m': 9.0, 't': '2026-10-08T09:00:00.000Z'});
    expect(d.estado.value.equipoId, 42);
  });

  test('credencial de otro teléfono (una copia de seguridad) o de otro hub: alta nueva', () async {
    yaDadoDeAlta(huella: 'la-de-otro-telefono');
    nativo.cola.add({'t': '2026-10-01T08:00:00.000Z', 'motivo': 'periodico', 'bateria': 12});
    await nuevo().iniciar();
    expect(hub.altas, hasLength(1));
    expect(nativo.almacen['huella_alta'], nativo.huella);
    expect(hub.reportes.single.containsKey('reportes'), isFalse,
        reason: 'los reportes guardados eran del otro teléfono');
    await dt!.dispose();

    nativo.almacen.clear();
    yaDadoDeAlta(servidor: 'https://otro-hub.ejemplo.com');
    dt = null;
    await nuevo().iniciar();
    expect(hub.altas, hasLength(2));
  });

  test('reporte con cola: lo que no sale se guarda y va en el siguiente', () async {
    final d = nuevo();
    await d.iniciar();
    expect(hub.reportes, hasLength(1));

    hub.fallaReporte = 503;
    expect(await d.reportar(), isFalse);
    expect(nativo.cola, hasLength(1));
    expect(d.estado.value.pendientes, 1);
    expect(d.estado.value.ultimoError, 'http_503');
    final guardado = nativo.cola.single;
    expect(guardado['motivo'], 'manual');
    expect(guardado['bateria'], 77);
    expect(guardado.containsKey('contexto'), isFalse);

    expect(await d.reportar(), isTrue);
    final r = hub.reportes.last;
    expect(r['reportes'], [
      {...guardado.cast<String, Object?>()},
    ]);
    expect(nativo.cola, isEmpty);
    expect(d.estado.value.pendientes, 0);
    expect(d.estado.value.ultimoError, isNull);
  });

  test('un 401 vuelve a dar de alta con el código y reenvía el reporte', () async {
    yaDadoDeAlta(credencial: 'dtd_vieja001_secreto');
    final d = nuevo();
    await d.iniciar();

    expect(hub.cabeceras.where((c) => c.startsWith('POST')).take(3), [
      'POST /v1/reporte dtd_vieja001_secreto',
      'POST /v1/alta ${hub.codigo}',
      'POST /v1/reporte ${hub.credencial}',
    ]);
    await hasta(() => d.estado.value.conectado);
    expect(hub.altas, hasLength(1), reason: 'el WebSocket también vio el 401, pero el alta es una');
    expect(hub.reportes.single['apps'], hasLength(1), reason: 'tras el alta la lista de apps va otra vez');
    expect(nativo.almacen['credencial'], hub.credencial);
    expect(nativo.cola, isEmpty);
    expect(d.estado.value.dadoDeAlta, isTrue);
    expect(d.estado.value.ultimoError, isNull);
  });

  test('el WebSocket rechazado (401) también da de alta otra vez y se conecta', () async {
    yaDadoDeAlta();
    hub.rechazaWsUnaVez = true;
    final d = nuevo();
    await d.iniciar();
    await hasta(() => d.estado.value.conectado);
    expect(hub.rechazosWs, 1);
    expect(hub.altas, hasLength(1));
    expect(nativo.almacen['credencial'], hub.credencial);
  });

  test('una orden repetida no se repite: se vuelve a acusar «hecha»', () async {
    hub.ordenes.add({
      'id': 7,
      'tipo': 'sonar',
      'datos': {'segundos': 10},
    });
    final d = nuevo();
    await d.iniciar();
    await hasta(() => acuses(7).length == 2);
    expect(acuses(7), ['recibida', 'hecha: sonó 10 s']);
    expect(nativo.llamadas.firstWhere((c) => c.method == 'sonar').arguments, {'segundos': 10});

    // El hub la manda otra vez (el acuse se le perdió).
    await hasta(() => d.estado.value.conectado);
    hub.manda({
      'tipo': 'orden',
      'orden': {'id': 7, 'tipo': 'sonar', 'datos': {'segundos': 10}},
    });
    await hasta(() => acuses(7).length == 3);
    expect(acuses(7).last, 'hecha: ya atendida');
    expect(nativo.sonados, 1);
  });

  test('sonar: «sonando» mientras suena; detenerSonar la deja «tocada»', () async {
    nativo.sonarEspera = Completer<void>();
    final d = nuevo();
    await d.iniciar();
    await hasta(() => d.estado.value.conectado);
    hub.manda({
      'tipo': 'orden',
      'orden': {'id': 11, 'tipo': 'sonar', 'datos': {'segundos': 30}},
    });
    await hasta(() => d.estado.value.sonando);
    // Repetida mientras suena: solo se le dice otra vez «recibida».
    hub.manda({
      'tipo': 'orden',
      'orden': {'id': 11, 'tipo': 'sonar', 'datos': {'segundos': 30}},
    });
    await hasta(() => acuses(11).length == 2);
    await d.detenerSonar();
    await hasta(() => acuses(11).length == 3);
    expect(acuses(11), ['recibida', 'recibida', 'hecha: la tocaron a los 4 s']);
    expect(d.estado.value.sonando, isFalse);
    expect(nativo.sonados, 1);
  });

  test('órdenes: «reportar» reporta ya, «mensaje» va a alOrden, lo demás no_soportada', () async {
    final mensajes = <Orden>[];
    final d = nuevo(alOrden: (o) async {
      mensajes.add(o);
      return true;
    });
    await d.iniciar();
    await hasta(() => d.estado.value.conectado);

    hub.manda({'tipo': 'orden', 'orden': {'id': 8, 'tipo': 'reportar'}});
    await hasta(() => acuses(8).length == 2);
    expect(acuses(8), ['recibida', 'hecha']);
    expect(hub.reportes.last['motivo'], 'orden');

    hub.manda({
      'tipo': 'orden',
      'orden': {'id': 9, 'tipo': 'mensaje', 'datos': {'titulo': 'Aviso', 'texto': 'Devuélvelo a la oficina'}},
    });
    await hasta(() => acuses(9).length == 2);
    expect(acuses(9), ['recibida', 'hecha: mostrado']);
    expect(mensajes.single.texto('texto'), 'Devuélvelo a la oficina');

    hub.manda({'tipo': 'orden', 'orden': {'id': 10, 'tipo': 'bloquear'}});
    await hasta(() => acuses(10).length == 2);
    expect(acuses(10), ['recibida', 'fallida: no_soportada']);
  });

  test('«mensaje» sin alOrden, o si devuelve false: no_soportada', () async {
    final d = nuevo();
    await d.iniciar();
    await hasta(() => d.estado.value.conectado);
    hub.manda({'tipo': 'orden', 'orden': {'id': 12, 'tipo': 'mensaje', 'datos': {'texto': 'Hola'}}});
    await hasta(() => acuses(12).length == 2);
    expect(acuses(12), ['recibida', 'fallida: no_soportada']);
    await d.dispose();

    final e = nuevo(alOrden: (_) async => false);
    await e.iniciar();
    await hasta(() => e.estado.value.conectado);
    hub.manda({'tipo': 'orden', 'orden': {'id': 13, 'tipo': 'mensaje', 'datos': {'texto': 'Hola'}}});
    await hasta(() => acuses(13).length == 2);
    expect(acuses(13), ['recibida', 'fallida: no_soportada']);
  });

  test('la config del WebSocket se guarda', () async {
    final d = nuevo();
    await d.iniciar();
    await hasta(() => d.estado.value.conectado);
    hub.manda({'tipo': 'config', 'config': {'intervalo_s': 300, 'ubicacion': false}});
    await hasta(() => d.estado.value.config.intervaloS == 300);
    expect(d.estado.value.config.ubicacion, isFalse);
    expect(nativo.almacen['intervalo_s'], 300);
    expect(nativo.almacen['ubicacion'], false);
  });

  test('en segundo plano cierra el WebSocket; al volver lo abre, y reporta solo pasado el freno', () async {
    final d = nuevo();
    await d.iniciar();
    await hasta(() => d.estado.value.conectado);

    d.didChangeAppLifecycleState(AppLifecycleState.inactive);
    d.didChangeAppLifecycleState(AppLifecycleState.hidden);
    d.didChangeAppLifecycleState(AppLifecycleState.paused);
    await hasta(() => !d.estado.value.conectado && hub.sockets.isEmpty);

    d.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await hasta(() => d.estado.value.conectado && hub.sockets.length == 1);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(hub.reportes, hasLength(1), reason: 'hace menos de 2 minutos que reportó');
  });

  test('al volver al frente pasado el freno, reporta «abrir»', () async {
    final d = nuevo(frenoAlFrente: Duration.zero);
    await d.iniciar();
    d.didChangeAppLifecycleState(AppLifecycleState.paused);
    d.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await hasta(() => hub.reportes.length == 2);
    expect(hub.reportes.last['motivo'], 'abrir');
  });

  test('sin red no revienta; con credencial, el reporte queda en la cola', () async {
    final d = nuevo(servidor: 'http://127.0.0.1:1');
    await d.iniciar();
    expect(d.estado.value.dadoDeAlta, isFalse);
    expect(d.estado.value.ultimoError, 'sin_red');
    expect(nativo.cola, isEmpty, reason: 'sin alta no hay a nombre de quién guardar');
    await d.dispose();

    yaDadoDeAlta(servidor: 'http://127.0.0.1:1');
    final e = nuevo(servidor: 'http://127.0.0.1:1');
    await e.iniciar();
    expect(e.estado.value.ultimoError, 'sin_red');
    expect(nativo.cola, hasLength(1));
    expect(e.estado.value.pendientes, 1);
  });

  test('un código que el hub no acepta queda en el estado, sin reventar', () async {
    final d = DeviceTrack(servidor: hub.url, codigo: 'dta_otro0001_x');
    dt = d;
    await d.iniciar();
    expect(d.estado.value.ultimoError, 'codigo_invalido');
    expect(d.estado.value.dadoDeAlta, isFalse);
    expect(await d.reportar(), isFalse);
  });

  test('sin el plugin (no es Android) se queda quieto', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(canal, null);
    final d = nuevo();
    await d.iniciar();
    expect(d.estado.value.ultimoError, 'sin_plugin');
    expect(await d.reportar(), isFalse);
    expect(hub.cabeceras, isEmpty);
  });
}
