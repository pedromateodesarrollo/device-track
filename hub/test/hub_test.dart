@Tags(['bd'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_track_hub/hub.dart';
import 'package:device_track_hub/src/http/rutas_auth.dart';
import 'package:device_track_hub/src/seguridad.dart';
import 'package:test/test.dart';

import 'smtp_falso.dart';

/// El hub de punta a punta contra un Postgres de verdad.
///
/// Necesita `DT_PRUEBA_DATABASE_URL` apuntando a una base DESECHABLE: la
/// prueba borra el esquema `dt` al empezar. Sin la variable, se salta.
///
///   docker run -d --name dt-bd -e POSTGRES_PASSWORD=dt -p 127.0.0.1:55433:5432 postgres:16-alpine
///   DT_PRUEBA_DATABASE_URL='postgres://postgres:dt@127.0.0.1:55433/postgres?sslmode=disable' dart test
void main() {
  final url = Platform.environment['DT_PRUEBA_DATABASE_URL'] ?? '';
  if (url.isEmpty) {
    test('hub contra Postgres', () {}, skip: 'Falta DT_PRUEBA_DATABASE_URL');
    return;
  }

  late Hub hub;
  late String base;
  late int org;
  late String admin; // JWT de una persona administradora
  late String consulta; // JWT de una persona que solo mira

  Future<(int, Map<String, dynamic>)> pide(
    String metodo,
    String ruta, {
    Object? json,
    String? token,
  }) async {
    final c = HttpClient();
    try {
      final r = await c.openUrl(metodo, Uri.parse('$base$ruta'));
      if (token != null) r.headers.set('authorization', 'Bearer $token');
      if (json != null) {
        r.headers.contentType = ContentType.json;
        r.write(jsonEncode(json));
      }
      final res = await r.close();
      final texto = await utf8.decodeStream(res);
      final d = texto.isEmpty ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(texto) as Map);
      return (res.statusCode, d);
    } finally {
      c.close();
    }
  }

  Future<String> persona(String correo, String rol, {List<int> dominios = const []}) async {
    await hub.bd.ejecuta(
      '''insert into dt.usuario (org, correo, clave_hash, nombre, rol, dominios)
         values (@o, @c, @h, @c, @r, @d)''',
      {
        'o': org,
        'c': correo,
        'h': Seguridad.hashClave('clave-de-prueba', iteraciones: 1000),
        'r': rol,
        'd': dominios,
      },
    );
    final (st, d) = await pide('POST', '/v1/auth/login', json: {'correo': correo, 'clave': 'clave-de-prueba'});
    expect(st, 200, reason: '$d');
    return d['token'] as String;
  }

  Future<String> codigo({int? usos, Object? dominio, String? token}) async {
    final (st, d) = await pide('POST', '/v1/altas',
        json: {'nombre': 'Terminales', 'dominio': ?dominio, 'usos_max': ?usos}, token: token ?? admin);
    expect(st, 201, reason: '$d');
    expect(d['qr'], startsWith('devicetrack://alta?hub='));
    return d['codigo'] as String;
  }

  Future<Map<String, dynamic>> dominio(String nombre) async {
    final (st, d) = await pide('POST', '/v1/dominios', json: {'nombre': nombre}, token: admin);
    expect(st, 201, reason: '$d');
    return d;
  }

  Future<Map<String, dynamic>> alta(String codigo, String huella,
      {String tipo = 'agente', String paquete = 'com.chalonasoft.devicetrack', String? nombre}) async {
    final (st, d) = await pide('POST', '/v1/alta',
        json: {
          'huella': huella,
          'fuente': {'tipo': tipo, 'paquete': paquete, 'version': '0.1.0', 'build': 1, 'nombre': ?nombre},
          'equipo': {'modelo': 'TC51', 'fabricante': 'Zebra', 'android': 30},
        },
        token: codigo);
    expect(st, 201, reason: '$d');
    return d;
  }

  setUpAll(() async {
    final bd = await Bd.abrir(url);
    await bd.ejecuta('drop schema if exists dt cascade');
    await bd.cerrar();
    hub = await Hub.arranca(
      Config.desdeEntorno({
        'DT_DATABASE_URL': url,
        'DT_HOST': '127.0.0.1',
        'DT_PUERTO': '0',
        'DT_MANAGER': '/no/existe',
        'DT_SECRETO_JWT': 'secreto-de-prueba',
        'DT_URL_PUBLICA': 'http://127.0.0.1',
      }),
      relojes: false,
    );
    base = 'http://127.0.0.1:${hub.puerto}';
    org = await creaOrg(hub.bd, 'Prueba');
    admin = await persona('admin@prueba.do', 'admin');
    consulta = await persona('mira@prueba.do', 'consulta');
  });

  tearDownAll(() async => hub.detiene());

  test('alta: el agente y una app en el mismo teléfono son un solo equipo', () async {
    final almacen = await dominio('Almacén A13');
    expect(almacen['slug'], 'almacen-a13');
    final c = await codigo(dominio: 'almacen-a13');
    final a = await alta(c, 'huella-0001');
    expect((a['credencial'] as String), startsWith('dtd_'));
    expect(a['config']['intervalo_s'], 600);
    final b = await alta(c, 'huella-0001', tipo: 'app', paquete: 'com.chalona.wms_app');
    expect(b['equipo']['id'], a['equipo']['id']);

    final (st, d) = await pide('GET', '/v1/equipos/${a['equipo']['id']}', token: admin);
    expect(st, 200);
    expect(d['dominio'], almacen['id']);
    expect(d['dominio_nombre'], 'Almacén A13');
    expect((d['fuentes'] as List).map((f) => f['paquete']).toSet(),
        {'com.chalonasoft.devicetrack', 'com.chalona.wms_app'});

    // Darse de alta otra vez desde la misma fuente cambia su credencial: la
    // vieja ya no vale.
    final otra = await alta(c, 'huella-0001');
    var (st2, _) = await pide('POST', '/v1/reporte', json: {'bateria': 50}, token: a['credencial'] as String);
    expect(st2, 401);
    (st2, _) = await pide('POST', '/v1/reporte', json: {'bateria': 50}, token: otra['credencial'] as String);
    expect(st2, 200);
  });

  test('la aplicación que reporta: su nombre, o el de la lista de apps', () async {
    final c = await codigo();
    // Una app de antes de `fuente.nombre`: el nombre sale de la lista de apps.
    final vieja = await alta(c, 'huella-nombre-app', tipo: 'app', paquete: 'com.ejemplo.inventario');
    final cred = vieja['credencial'] as String;
    var (st, d) = await pide('POST', '/v1/reporte',
        json: {
          'apps': [
            {'paquete': 'com.ejemplo.inventario', 'version': '1.0.0', 'build': 1, 'nombre': 'Inventario viejo'},
          ],
        },
        token: cred);
    expect(st, 200, reason: '$d');
    Future<Map<String, dynamic>> fuente() async {
      final (_, l) = await pide('GET', '/v1/equipos?q=huella-nombre-app', token: admin);
      return Map<String, dynamic>.from((l['equipos'] as List).single['fuentes'].single as Map);
    }

    expect((await fuente())['nombre'], 'Inventario viejo');

    // La que lo manda gana, y un reporte sin él no lo borra.
    (st, d) = await pide('POST', '/v1/reporte',
        json: {'fuente': {'tipo': 'app', 'paquete': 'com.ejemplo.inventario', 'nombre': 'Inventario', 'version': '2.0.0'}},
        token: cred);
    expect(st, 200, reason: '$d');
    await pide('POST', '/v1/reporte', json: {'fuente': {'version': '2.0.1'}}, token: cred);
    final f = await fuente();
    expect(f['nombre'], 'Inventario');
    expect(f['version'], '2.0.1');

    // En el alta también, y en la ficha.
    final ag = await alta(c, 'huella-nombre-app', nombre: 'device-track');
    final (_, e) = await pide('GET', '/v1/equipos/${ag['equipo']['id']}', token: admin);
    expect({for (final x in e['fuentes'] as List) x['paquete']: x['nombre']},
        {'com.chalonasoft.devicetrack': 'device-track', 'com.ejemplo.inventario': 'Inventario'});
  });

  test('códigos de alta: tope de usos, anulado, y no abren el panel', () async {
    final c = await codigo(usos: 1);
    await alta(c, 'huella-tope-1');
    var (st, d) = await pide('POST', '/v1/alta',
        json: {'huella': 'huella-tope-2', 'fuente': {'tipo': 'agente', 'paquete': 'x.y'}}, token: c);
    expect(st, 410);
    expect(d['error'], 'codigo_agotado');
    (st, _) = await pide('GET', '/v1/equipos', token: c);
    expect(st, 401);

    final c2 = await codigo();
    final (_, lista) = await pide('GET', '/v1/altas', token: admin);
    final id = (lista['altas'] as List).first['id'];
    (st, _) = await pide('DELETE', '/v1/altas/$id', token: admin);
    expect(st, 204);
    (st, d) = await pide('POST', '/v1/alta',
        json: {'huella': 'h', 'fuente': {'tipo': 'agente', 'paquete': 'x.y'}}, token: c2);
    expect(d['error'], 'codigo_anulado');
  });

  test('reporte: estado, historial atrasado, apps y contexto', () async {
    final a = await alta(await codigo(), 'huella-reporte');
    final cred = a['credencial'] as String;
    final id = a['equipo']['id'];
    final ahora = DateTime.now().toUtc();
    var (st, d) = await pide('POST', '/v1/reporte',
        json: {
          'motivo': 'periodico',
          'bateria': 77,
          'cargando': false,
          'red': {'tipo': 'wifi', 'ssid': 'Almacen'},
          'ubicacion': {'lat': 18.4861, 'lng': -69.9312, 'precision_m': 12},
          'almacenamiento': {'libre': 1000, 'total': 4000},
          'apps': [
            {'paquete': 'com.chalona.wms_app', 'version': '1.57.0', 'build': 86},
          ],
          'contexto': {'usuario': 'Juan', 'almacen': 'A13'},
          // Lo que guardó sin red: más viejo que el de ahora.
          'reportes': [
            {'t': ahora.subtract(const Duration(hours: 2)).toIso8601String(), 'bateria': 99,
             'ubicacion': {'lat': 18.5, 'lng': -69.9, 'precision_m': 20}},
            {'t': ahora.add(const Duration(days: 3)).toIso8601String(), 'bateria': 1},
          ],
        },
        token: cred);
    expect(st, 200, reason: '$d');
    expect(d['ordenes'], isEmpty);

    (st, d) = await pide('GET', '/v1/equipos/$id', token: admin);
    // El de «dentro de tres días» se tomó como de ahora, y a igual hora manda
    // el reporte de ahora; el atrasado no tapa a ninguno.
    expect(d['bateria'], 77);
    expect(d['red_ssid'], 'Almacen');
    expect(d['lat'], closeTo(18.4861, 0.0001));
    expect((d['apps'] as List).single['build'], 86);
    expect((d['fuentes'] as List).single['contexto']['usuario'], 'Juan');

    (st, d) = await pide('GET', '/v1/equipos/$id/reportes?desde=${Uri.encodeQueryComponent(ahora.subtract(const Duration(days: 1)).toIso8601String())}',
        token: admin);
    expect((d['reportes'] as List).length, 3);
    (st, d) = await pide('GET', '/v1/equipos/$id/recorrido', token: admin);
    expect((d['puntos'] as List).length, 2);
  });

  test('alertas: batería baja, fuera de zona, apagado y sin reporte', () async {
    final vigilados = await dominio('Vigilados');
    final a = await alta(await codigo(dominio: vigilados['id']), 'huella-alertas');
    final cred = a['credencial'] as String;
    final id = a['equipo']['id'];

    final (st, z) = await pide('POST', '/v1/zonas',
        json: {'nombre': 'Almacén', 'lat': 18.4861, 'lng': -69.9312, 'radio_m': 200}, token: admin);
    expect(st, 201, reason: '$z');
    for (final regla in [
      {'tipo': 'bateria_baja', 'parametros': {'porcentaje': 20}},
      {'tipo': 'fuera_de_zona', 'parametros': {'zona': z['id']}, 'dominio': 'vigilados'},
      {'tipo': 'apagado'},
      {'tipo': 'sin_reporte', 'parametros': {'minutos': 30}, 'dominio': 'vigilados'},
    ]) {
      final (st, d) = await pide('POST', '/v1/reglas', json: regla, token: admin);
      expect(st, 201, reason: '$d');
    }

    Future<Set<String>> abiertas() async {
      // Las alertas se evalúan después de contestar el reporte.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final (_, d) = await pide('GET', '/v1/alertas?equipo=$id', token: admin);
      return (d['alertas'] as List).map((x) => x['tipo'] as String).toSet();
    }

    await pide('POST', '/v1/reporte',
        json: {'bateria': 10, 'cargando': false, 'ubicacion': {'lat': 18.60, 'lng': -69.93, 'precision_m': 10}},
        token: cred);
    expect(await abiertas(), {'bateria_baja', 'fuera_de_zona'});

    await pide('POST', '/v1/reporte',
        json: {'bateria': 11, 'cargando': true, 'ubicacion': {'lat': 18.4862, 'lng': -69.9313, 'precision_m': 10}},
        token: cred);
    expect(await abiertas(), isEmpty);

    await pide('POST', '/v1/reporte', json: {'motivo': 'apagando'}, token: cred);
    expect(await abiertas(), {'apagado'});
    await pide('POST', '/v1/reporte', json: {'motivo': 'encendido'}, token: cred);
    expect(await abiertas(), isEmpty);

    await hub.bd.ejecuta(
      "update dt.equipo set ultima_vez = now() - interval '2 hours' where id = @i",
      {'i': id},
    );
    expect(await hub.alertas.revisaSinReporte(), greaterThanOrEqualTo(1));
    expect(await abiertas(), {'sin_reporte'});
    await pide('POST', '/v1/reporte', json: {}, token: cred);
    expect(await abiertas(), isEmpty);

    // Retirado no da alertas.
    await pide('PATCH', '/v1/equipos/$id', json: {'estado': 'retirado'}, token: admin);
    await pide('POST', '/v1/reporte', json: {'bateria': 3, 'cargando': false}, token: cred);
    expect(await abiertas(), isEmpty);
  });

  test('órdenes: por el reporte y por el WebSocket', () async {
    final a = await alta(await codigo(), 'huella-ordenes');
    final cred = a['credencial'] as String;
    final id = a['equipo']['id'];

    var (st, o) = await pide('POST', '/v1/equipos/$id/ordenes',
        json: {'tipo': 'sonar', 'datos': {'segundos': 999}}, token: admin);
    expect(st, 201, reason: '$o');
    expect(o['estado'], 'pendiente');
    expect(o['datos']['segundos'], 300);

    var (_, r) = await pide('POST', '/v1/reporte', json: {}, token: cred);
    expect((r['ordenes'] as List).single['id'], o['id']);
    // Sin acuse se vuelve a entregar.
    (_, r) = await pide('POST', '/v1/reporte', json: {}, token: cred);
    expect((r['ordenes'] as List).single['id'], o['id']);
    (st, _) = await pide('POST', '/v1/ordenes/${o['id']}/estado', json: {'estado': 'hecha'}, token: cred);
    expect(st, 200);
    (_, r) = await pide('POST', '/v1/reporte', json: {}, token: cred);
    expect(r['ordenes'], isEmpty);

    // Conectado: la orden llega al instante.
    final ws = await WebSocket.connect('${base.replaceFirst('http', 'ws')}/v1/ws',
        headers: {'authorization': 'Bearer $cred'});
    final llegan = StreamController<Map<String, dynamic>>();
    ws.listen((m) => llegan.add(Map<String, dynamic>.from(jsonDecode(m as String) as Map)));
    final cola = StreamIterator(llegan.stream);
    expect(await cola.moveNext(), isTrue);
    expect(cola.current['tipo'], 'hola');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    var (_, e) = await pide('GET', '/v1/equipos/$id', token: admin);
    expect(e['conectado'], isTrue);

    (st, o) = await pide('POST', '/v1/equipos/$id/ordenes',
        json: {'tipo': 'mensaje', 'datos': {'titulo': 'Hola', 'texto': 'Devuélvelo a la oficina'}}, token: admin);
    expect(o['estado'], 'enviada');
    expect(await cola.moveNext().timeout(const Duration(seconds: 5)), isTrue);
    expect(cola.current['tipo'], 'orden');
    expect(cola.current['orden']['datos']['texto'], 'Devuélvelo a la oficina');

    // La configuración nueva llega a los conectados.
    await pide('PATCH', '/v1/org', json: {'intervalo_s': 300}, token: admin);
    expect(await cola.moveNext().timeout(const Duration(seconds: 5)), isTrue);
    expect(cola.current['tipo'], 'config');
    expect(cola.current['config']['intervalo_s'], 300);

    await ws.close();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    (_, e) = await pide('GET', '/v1/equipos/$id', token: admin);
    expect(e['conectado'], isFalse);
  });

  test('con el agente conectado, la orden va solo a él y no a la app', () async {
    final c = await codigo();
    final ag = await alta(c, 'huella-dos-fuentes');
    final app = await alta(c, 'huella-dos-fuentes', tipo: 'app', paquete: 'com.chalona.wms_app');
    final id = ag['equipo']['id'];

    Future<StreamIterator<Map<String, dynamic>>> conecta(String cred) async {
      final ws = await WebSocket.connect('${base.replaceFirst('http', 'ws')}/v1/ws',
          headers: {'authorization': 'Bearer $cred'});
      final s = StreamController<Map<String, dynamic>>();
      ws.listen((m) => s.add(Map<String, dynamic>.from(jsonDecode(m as String) as Map)), onDone: s.close);
      final it = StreamIterator(s.stream);
      expect(await it.moveNext(), isTrue); // hola
      return it;
    }

    final wsAgente = await conecta(ag['credencial'] as String);
    final wsApp = await conecta(app['credencial'] as String);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await pide('POST', '/v1/equipos/$id/ordenes', json: {'tipo': 'mensaje', 'datos': {'texto': 'una sola vez'}}, token: admin);
    expect(await wsAgente.moveNext().timeout(const Duration(seconds: 5)), isTrue);
    expect(wsAgente.current['tipo'], 'orden');
    expect(await wsApp.moveNext().timeout(const Duration(milliseconds: 800), onTimeout: () => false), isFalse);
    // Y en la respuesta del reporte de la app tampoco viene.
    final (_, r) = await pide('POST', '/v1/reporte', json: {}, token: app['credencial'] as String);
    expect(r['ordenes'], isEmpty);
    await wsAgente.cancel();
    await wsApp.cancel();
  });

  test('permisos: consulta mira, el equipo no entra al panel, la llave hace lo suyo', () async {
    final a = await alta(await codigo(), 'huella-permisos');
    final id = a['equipo']['id'];
    var (st, _) = await pide('GET', '/v1/equipos', token: consulta);
    expect(st, 200);
    (st, _) = await pide('PATCH', '/v1/equipos/$id', json: {'nombre': 'x'}, token: consulta);
    expect(st, 403);
    (st, _) = await pide('POST', '/v1/equipos/$id/ordenes', json: {'tipo': 'reportar'}, token: consulta);
    expect(st, 403);
    (st, _) = await pide('GET', '/v1/equipos', token: a['credencial'] as String);
    expect(st, 401);
    (st, _) = await pide('POST', '/v1/reporte', json: {}, token: admin);
    expect(st, 401);

    final (_, l) = await pide('POST', '/v1/llaves', json: {'nombre': 'ERP', 'permisos': ['leer']}, token: admin);
    final llave = l['llave'] as String;
    expect(llave, startsWith('dtk_'));
    (st, _) = await pide('GET', '/v1/equipos/$id', token: llave);
    expect(st, 200);
    (st, _) = await pide('POST', '/v1/equipos/$id/ordenes', json: {'tipo': 'reportar'}, token: llave);
    expect(st, 403);
    (st, _) = await pide('POST', '/v1/llaves', json: {'nombre': 'otra'}, token: llave);
    expect(st, 403);
  });

  test('PATCH de una regla cambia solo lo que viene', () async {
    final g1 = await dominio('G1');
    var (st, r) = await pide('POST', '/v1/reglas',
        json: {'tipo': 'bateria_baja', 'nombre': 'Batería', 'dominio': g1['id'], 'parametros': {'porcentaje': 25}},
        token: admin);
    expect(st, 201);
    (st, r) = await pide('PATCH', '/v1/reglas/${r['id']}', json: {'activa': false}, token: admin);
    expect(st, 200, reason: '$r');
    expect(r['activa'], isFalse);
    expect(r['nombre'], 'Batería');
    expect(r['dominio'], g1['id']);
    expect(r['dominio_nombre'], 'G1');
    expect(r['parametros']['porcentaje'], 25);
    (st, r) = await pide('PATCH', '/v1/reglas/${r['id']}', json: {'nombre': 'Otra'}, token: admin);
    expect(r['activa'], isFalse);
    expect(r['nombre'], 'Otra');

    // Y la URL del webhook solo la ve quien administra.
    await pide('PATCH', '/v1/org', json: {'webhook_url': 'https://ejemplo.com/token-secreto'}, token: admin);
    final (_, o) = await pide('GET', '/v1/org', token: consulta);
    expect(o.containsKey('webhook_url'), isFalse);
    await pide('PATCH', '/v1/org', json: {'webhook_url': ''}, token: admin);
  });

  test('unir dos filas que eran el mismo equipo', () async {
    final c = await codigo();
    final a = await alta(c, 'huella-unir-a');
    final b = await alta(c, 'huella-unir-b', tipo: 'app', paquete: 'com.otra.firma');
    await pide('POST', '/v1/reporte', json: {'bateria': 40}, token: b['credencial'] as String);
    await pide('PATCH', '/v1/equipos/${a['equipo']['id']}', json: {'etiqueta': 'ACT-0042'}, token: admin);

    final (st, d) = await pide('POST', '/v1/equipos/${a['equipo']['id']}/unir',
        json: {'con': b['equipo']['id']}, token: admin);
    expect(st, 200, reason: '$d');
    expect(d['etiqueta'], 'ACT-0042');
    expect(d['bateria'], 40);
    final (st2, _) = await pide('GET', '/v1/equipos/${b['equipo']['id']}', token: admin);
    expect(st2, 404);
    // La credencial de la fuente que vino de [b] sigue sirviendo.
    final (st3, _) = await pide('POST', '/v1/reporte', json: {}, token: b['credencial'] as String);
    expect(st3, 200);
  });

  test('webhook firmado al abrir una alerta', () async {
    final recibido = Completer<(String, String, String)>();
    final srv = await HttpServer.bind('127.0.0.1', 0);
    srv.listen((r) async {
      final cuerpo = await utf8.decodeStream(r);
      if (!recibido.isCompleted) {
        recibido.complete((r.headers.value('x-device-track-evento')!, r.headers.value('x-device-track-firma')!, cuerpo));
      }
      r.response.statusCode = 204;
      await r.response.close();
    });
    await pide('PATCH', '/v1/org', json: {'webhook_url': 'http://127.0.0.1:${srv.port}/avisos'}, token: admin);
    final (_, s) = await pide('POST', '/v1/org/webhook/secreto', token: admin);
    final secreto = s['secreto'] as String;

    final a = await alta(await codigo(), 'huella-webhook');
    await pide('POST', '/v1/reporte', json: {'bateria': 5, 'cargando': false}, token: a['credencial'] as String);
    final (evento, firma, cuerpo) = await recibido.future.timeout(const Duration(seconds: 5));
    expect(evento, 'alerta_abierta');
    expect(firma, 'sha256=${Hmac(sha256, utf8.encode(secreto)).convert(utf8.encode(cuerpo))}');
    expect(jsonDecode(cuerpo)['equipo']['id'], a['equipo']['id']);
    expect(jsonDecode(cuerpo)['equipo']['dominio']['slug'], 'general');
    await srv.close(force: true);
  });

  test('sin ubicación en la organización, no se guarda', () async {
    await pide('PATCH', '/v1/org', json: {'ubicacion': false}, token: admin);
    final a = await alta(await codigo(), 'huella-sin-gps');
    expect(a['config']['ubicacion'], isFalse);
    await pide('POST', '/v1/reporte',
        json: {'ubicacion': {'lat': 18.0, 'lng': -70.0, 'precision_m': 5}}, token: a['credencial'] as String);
    final (_, d) = await pide('GET', '/v1/equipos/${a['equipo']['id']}', token: admin);
    expect(d['lat'], isNull);
    await pide('PATCH', '/v1/org', json: {'ubicacion': true}, token: admin);
  });

  test('dominios: quien está limitado a uno ve y maneja solo lo suyo', () async {
    final duralon = await dominio('Duralon');
    final jf = await dominio('JF');
    final d1 = await alta(await codigo(dominio: 'duralon'), 'huella-duralon-1');
    final j1 = await alta(await codigo(dominio: 'jf'), 'huella-jf-1');
    final idD = d1['equipo']['id'];
    final idJ = j1['equipo']['id'];
    final encargado = await persona('encargado@duralon.do', 'editor', dominios: [duralon['id'] as int]);

    // Solo ve lo suyo, y lo ajeno no existe.
    var (st, d) = await pide('GET', '/v1/equipos', token: encargado);
    expect((d['equipos'] as List).map((e) => e['id']).toList(), [idD]);
    (st, d) = await pide('GET', '/v1/resumen', token: encargado);
    expect(d['equipos'], 1);
    (st, d) = await pide('GET', '/v1/dominios', token: encargado);
    expect((d['dominios'] as List).map((x) => x['slug']).toList(), ['duralon']);
    (st, d) = await pide('GET', '/v1/yo', token: encargado);
    expect((d['dominios'] as List).single['nombre'], 'Duralon');
    (st, d) = await pide('GET', '/v1/yo', token: admin);
    expect(d['dominios'], isEmpty);
    for (final (metodo, ruta, json) in [
      ('GET', '/v1/equipos/$idJ', null),
      ('GET', '/v1/equipos/$idJ/recorrido', null),
      ('GET', '/v1/equipos/$idJ/reportes', null),
      ('GET', '/v1/equipos/$idJ/ordenes', null),
      ('PATCH', '/v1/equipos/$idJ', {'nombre': 'mío'}),
      ('POST', '/v1/equipos/$idJ/ordenes', {'tipo': 'sonar'}),
      ('POST', '/v1/equipos/$idD/unir', {'con': idJ}),
    ]) {
      (st, d) = await pide(metodo, ruta, json: json, token: encargado);
      expect(st, 404, reason: '$metodo $ruta → $d');
    }
    (st, d) = await pide('GET', '/v1/equipos?dominio=jf', token: encargado);
    expect(st, 400);
    expect(d['error'], 'dominio_invalido');

    // Lo que crea cae en su dominio, y no puede sacar un equipo de él.
    (st, d) = await pide('POST', '/v1/altas', json: {'nombre': 'Mías'}, token: encargado);
    expect(st, 201, reason: '$d');
    expect(d['dominio'], duralon['id']);
    (st, d) = await pide('POST', '/v1/altas', json: {'nombre': 'Ajenas', 'dominio': 'jf'}, token: encargado);
    expect(d['error'], 'dominio_invalido');
    (st, d) = await pide('PATCH', '/v1/equipos/$idD', json: {'dominio': 'jf'}, token: encargado);
    expect(d['error'], 'dominio_invalido');
    (st, d) = await pide('GET', '/v1/altas', token: encargado);
    expect((d['altas'] as List).every((a) => a['dominio'] == duralon['id']), isTrue);

    // Administrar no es para quien está limitado.
    (st, d) = await pide('GET', '/v1/usuarios', token: encargado);
    expect(st, 403);
    (st, d) = await pide('POST', '/v1/dominios', json: {'nombre': 'Otro'}, token: encargado);
    expect(st, 403);

    // Zonas: ve las de toda la organización, no las de otro dominio; solo
    // toca las suyas.
    final (_, zOrg) = await pide('POST', '/v1/zonas',
        json: {'nombre': 'Ciudad', 'lat': 18.5, 'lng': -69.9, 'radio_m': 50000}, token: admin);
    expect(zOrg['dominio'], isNull);
    final (_, zJf) = await pide('POST', '/v1/zonas',
        json: {'nombre': 'Almacén JF', 'lat': 18.4, 'lng': -69.8, 'radio_m': 300, 'dominio': 'jf'}, token: admin);
    (st, d) = await pide('GET', '/v1/zonas', token: encargado);
    final ids = (d['zonas'] as List).map((z) => z['id']).toSet();
    expect(ids.contains(zOrg['id']), isTrue);
    expect(ids.contains(zJf['id']), isFalse);
    (st, d) = await pide('PATCH', '/v1/zonas/${zOrg['id']}',
        json: {'nombre': 'x', 'lat': 18.5, 'lng': -69.9, 'radio_m': 10}, token: encargado);
    expect(st, 404);
    (st, d) = await pide('POST', '/v1/zonas',
        json: {'nombre': 'Planta', 'lat': 18.45, 'lng': -69.95, 'radio_m': 400}, token: encargado);
    expect(st, 201, reason: '$d');
    expect(d['dominio'], duralon['id']);

    // Una regla suya no vigila una zona de otro dominio.
    (st, d) = await pide('POST', '/v1/reglas',
        json: {'tipo': 'fuera_de_zona', 'parametros': {'zona': zJf['id']}}, token: encargado);
    expect(d['error'], 'zona_invalida');
    (st, d) = await pide('POST', '/v1/reglas',
        json: {'tipo': 'fuera_de_zona', 'parametros': {'zona': zOrg['id']}, 'activa': false}, token: encargado);
    expect(st, 201, reason: '$d');
    expect(d['dominio'], duralon['id']);
    (st, d) = await pide('GET', '/v1/reglas', token: encargado);
    expect((d['reglas'] as List).every((r) => r['dominio'] == null || r['dominio'] == duralon['id']), isTrue);

    // Alertas: las de un equipo ajeno ni se ven ni se cierran. (La regla de
    // batería baja de toda la organización viene de la prueba de alertas.)
    for (final cred in [d1['credencial'], j1['credencial']]) {
      await pide('POST', '/v1/reporte', json: {'bateria': 5, 'cargando': false}, token: cred as String);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    (st, d) = await pide('GET', '/v1/alertas', token: encargado);
    expect((d['alertas'] as List).map((a) => a['equipo']).toSet(), {idD});
    expect((d['alertas'] as List).first['dominio_nombre'], 'Duralon');
    final (_, todas) = await pide('GET', '/v1/alertas?equipo=$idJ', token: admin);
    final ajena = (todas['alertas'] as List).first['id'];
    (st, d) = await pide('POST', '/v1/alertas/$ajena/cerrar', json: {}, token: encargado);
    expect(st, 404);

    // Una llave limitada a JF ve solo lo de JF; admin no se limita.
    (st, d) = await pide('POST', '/v1/llaves',
        json: {'nombre': 'ERP de JF', 'permisos': ['leer'], 'dominios': ['jf']}, token: admin);
    expect(st, 201, reason: '$d');
    expect(d['dominios'], [jf['id']]);
    (st, d) = await pide('GET', '/v1/equipos', token: d['llave'] as String);
    expect((d['equipos'] as List).map((e) => e['id']).toList(), [idJ]);
    (st, d) = await pide('POST', '/v1/llaves',
        json: {'nombre': 'mala', 'permisos': ['admin'], 'dominios': ['jf']}, token: admin);
    expect(d['error'], 'admin_sin_dominios');
    (st, d) = await pide('POST', '/v1/usuarios',
        json: {'correo': 'jefe@jf.do', 'rol': 'admin', 'dominios': ['jf']}, token: admin);
    expect(d['error'], 'admin_sin_dominios');
    (st, d) = await pide('POST', '/v1/usuarios',
        json: {'correo': 'jefe@jf.do', 'rol': 'consulta', 'dominios': ['no-existe']}, token: admin);
    expect(d['error'], 'dominio_invalido');

    // Quitarle el dominio a la persona vale en el acto, sin esperar a que
    // venza su sesión.
    final (_, lista) = await pide('GET', '/v1/usuarios', token: admin);
    final idEncargado = (lista['usuarios'] as List).firstWhere((u) => u['correo'] == 'encargado@duralon.do')['id'];
    (st, d) = await pide('PATCH', '/v1/usuarios/$idEncargado', json: {'dominios': ['jf']}, token: admin);
    expect(st, 200, reason: '$d');
    expect(d['rol'], 'editor');
    (st, d) = await pide('GET', '/v1/equipos', token: encargado);
    expect((d['equipos'] as List).map((e) => e['id']).toList(), [idJ]);

    // Borrar: el General nunca; uno con equipos o con gente, tampoco.
    final (_, doms) = await pide('GET', '/v1/dominios', token: admin);
    final general = (doms['dominios'] as List).first;
    expect(general['slug'], 'general');
    (st, d) = await pide('DELETE', '/v1/dominios/${general['id']}', token: admin);
    expect(d['error'], 'dominio_general');
    (st, d) = await pide('DELETE', '/v1/dominios/${jf['id']}', token: admin);
    expect(st, 409);
    expect(d['error'], 'dominio_en_uso');
    expect(d['mensaje'], contains('1 equipo'));
    final vacio = await dominio('Vacío');
    (st, _) = await pide('DELETE', '/v1/dominios/${vacio['id']}', token: admin);
    expect(st, 204);

    // Mover un equipo de dominio cierra las alertas de reglas del dominio
    // que deja.
    final (_, rJf) = await pide('POST', '/v1/reglas',
        json: {'tipo': 'apagado', 'dominio': 'jf'}, token: admin);
    await pide('POST', '/v1/reporte', json: {'motivo': 'apagando'}, token: j1['credencial'] as String);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    (st, d) = await pide('PATCH', '/v1/equipos/$idJ', json: {'dominio': 'duralon'}, token: admin);
    expect(st, 200, reason: '$d');
    expect(d['dominio_nombre'], 'Duralon');
    final (_, despues) = await pide('GET', '/v1/alertas?equipo=$idJ', token: admin);
    expect((despues['alertas'] as List).where((a) => a['regla'] == rJf['id']), isEmpty);
  });

  test('correo de salida: la clave no vuelve, y la invitación sale por él', () async {
    final smtp = await SmtpFalso.arranca();
    try {
      // Sin correo de salida, invitar es solo el enlace.
      var (st, d) = await pide('POST', '/v1/usuarios',
          json: {'correo': 'sin-correo@prueba.do', 'rol': 'consulta'}, token: admin);
      expect(st, 201, reason: '$d');
      expect(d['envio'], isNull);
      expect(d['correo'], 'sin-correo@prueba.do');
      expect(d['enlace'], contains('/#/activar/'));

      final config = {
        'host': '127.0.0.1',
        'puerto': smtp.puerto,
        'seguridad': 'ninguna',
        'remitente': 'Avisos@Prueba.do',
        'usuario': 'avisos',
        'clave': 'secreto-smtp',
        'nombre': 'device-track de Prueba',
      };
      (st, d) = await pide('PUT', '/v1/org/correo', json: {...config, 'host': 'smtp mal'}, token: admin);
      expect(st, 400);
      expect(d['error'], 'host_invalido');
      (st, d) = await pide('PUT', '/v1/org/correo', json: {...config, 'seguridad': 'ssl3'}, token: admin);
      expect(d['error'], 'seguridad_invalida');
      (st, _) = await pide('PUT', '/v1/org/correo', json: config, token: consulta);
      expect(st, 403);

      (st, d) = await pide('PUT', '/v1/org/correo', json: config, token: admin);
      expect(st, 200, reason: '$d');
      expect(d['remitente'], 'avisos@prueba.do');
      expect(d['clave_puesta'], isTrue);
      expect(jsonEncode(d), isNot(contains('secreto-smtp')));
      // Guardar sin clave deja la que estaba.
      (st, d) = await pide('PUT', '/v1/org/correo',
          json: {...config, 'clave': '', 'nombre': 'Avisos de Prueba'}, token: admin);
      expect(d['clave_puesta'], isTrue);
      (st, d) = await pide('GET', '/v1/org', token: admin);
      expect(d['correo']['configurado'], isTrue);
      expect(d['correo']['nombre'], 'Avisos de Prueba');
      expect(jsonEncode(d), isNot(contains('secreto-smtp')));
      (st, d) = await pide('GET', '/v1/org', token: consulta);
      expect(d.containsKey('correo'), isFalse);

      // La prueba va a quien la pide.
      (st, d) = await pide('POST', '/v1/org/correo/prueba', token: admin);
      expect(st, 200, reason: '$d');
      expect(d['para'], 'admin@prueba.do');
      expect(smtp.ordenes, contains('RCPT TO:<admin@prueba.do>'));

      (st, d) = await pide('POST', '/v1/usuarios',
          json: {'correo': 'nueva@prueba.do', 'nombre': 'Nueva', 'rol': 'consulta'}, token: admin);
      expect(st, 201, reason: '$d');
      expect(d['envio'], {'enviado': true, 'para': 'nueva@prueba.do'});
      expect(d['correo'], 'nueva@prueba.do');
      final enlace = d['enlace'] as String;
      final nueva = d['id'];
      expect(SmtpFalso.parte(smtp.mensajes.last, 'text/html'), contains(enlace));
      expect(SmtpFalso.parte(smtp.mensajes.last, 'text/plain'), contains(enlace));
      final auth = smtp.ordenes.lastWhere((o) => o.startsWith('AUTH PLAIN '));
      expect(utf8.decode(base64.decode(auth.substring(11))), '\u0000avisos\u0000secreto-smtp');

      // Si el servidor rechaza, la invitación queda y el enlace sirve igual.
      smtp.rechazaAuth = true;
      (st, d) = await pide('POST', '/v1/usuarios/$nueva/invitacion', token: admin);
      expect(st, 200, reason: '$d');
      expect(d['envio']['enviado'], isFalse);
      expect(d['envio']['error'], 'correo_autenticacion');
      expect(d['enlace'], contains('/#/activar/'));

      (st, d) = await pide('PUT', '/v1/org/correo', json: {'quitar': true}, token: admin);
      expect(d['configurado'], isFalse);
      (st, d) = await pide('GET', '/v1/org', token: admin);
      expect(d['correo']['configurado'], isFalse);
    } finally {
      await smtp.cierra();
    }
  });
}
