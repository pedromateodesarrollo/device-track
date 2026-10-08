import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Un hub de mentira en un puerto local, con las rutas del equipo: el alta,
/// el reporte, el acuse de las órdenes y el WebSocket. Anota lo que le llega
/// y contesta lo que diga la prueba.
class HubFalso {
  late HttpServer _srv;

  /// El código de alta que acepta.
  String codigo = 'dta_alta0001_secreto';

  /// La credencial que da en el alta y la única que acepta después.
  String credencial = 'dtd_equi0001_secreto';
  int altasHechas = 0;

  Map<String, Object?> config = {'intervalo_s': 600, 'ubicacion': true};

  /// Las órdenes que devuelve en cada reporte (hasta que se acusen).
  final ordenes = <Map<String, Object?>>[];

  /// Si no es null, el próximo reporte contesta con este código HTTP.
  int? fallaReporte;

  final altas = <Map<String, dynamic>>[];
  final reportes = <Map<String, dynamic>>[];
  final acuses = <({int id, String estado, String detalle})>[];
  final cabeceras = <String>[];
  final sockets = <WebSocket>[];
  int rechazosWs = 0;

  String get url => 'http://127.0.0.1:${_srv.port}';

  Future<void> arranca() async {
    _srv = await HttpServer.bind('127.0.0.1', 0);
    _srv.listen(_atiende);
  }

  Future<void> _atiende(HttpRequest r) async {
    final auth = r.headers.value('authorization') ?? '';
    final cred = auth.startsWith('Bearer ') ? auth.substring(7) : '';
    cabeceras.add('${r.method} ${r.uri.path} $cred');

    if (r.uri.path == '/v1/ws') {
      if (cred != credencial) {
        rechazosWs++;
        return _responde(r, 401, {'error': 'equipo_no_autenticado', 'mensaje': 'No'});
      }
      final ws = await WebSocketTransformer.upgrade(r);
      sockets.add(ws);
      ws.add(jsonEncode({'tipo': 'hola', 'equipo': 42}));
      ws.listen((_) {}, onDone: () => sockets.remove(ws));
      return;
    }

    final crudo = await utf8.decodeStream(r);
    final cuerpo = crudo.isEmpty ? <String, dynamic>{} : jsonDecode(crudo) as Map<String, dynamic>;

    if (r.method == 'POST' && r.uri.path == '/v1/alta') {
      if (cred != codigo) {
        return _responde(r, 401, {'error': 'codigo_invalido', 'mensaje': 'Ese código de alta no existe'});
      }
      altas.add(cuerpo);
      altasHechas++;
      return _responde(r, 201, {
        'equipo': {'id': 42, 'nombre': 'TC51 · 4f2a'},
        'credencial': credencial,
        'config': config,
        'ws': '${url.replaceFirst('http', 'ws')}/v1/ws',
      });
    }

    if (cred != credencial) {
      return _responde(r, 401, {
        'error': 'equipo_no_autenticado',
        'mensaje': 'Falta la credencial del equipo o ya no vale',
      });
    }

    if (r.method == 'POST' && r.uri.path == '/v1/reporte') {
      final falla = fallaReporte;
      if (falla != null) {
        fallaReporte = null;
        r.response.statusCode = falla;
        r.response.write('<html>Bad gateway</html>');
        await r.response.close();
        return;
      }
      reportes.add(cuerpo);
      return _responde(r, 200, {'config': config, 'ordenes': ordenes});
    }

    final m = RegExp(r'^/v1/ordenes/(\d+)/estado$').firstMatch(r.uri.path);
    if (r.method == 'POST' && m != null) {
      final id = int.parse(m.group(1)!);
      acuses.add((id: id, estado: cuerpo['estado'] as String, detalle: (cuerpo['detalle'] ?? '') as String));
      if (cuerpo['estado'] != 'recibida') ordenes.removeWhere((o) => o['id'] == id);
      return _responde(r, 200, {'id': id, 'estado': cuerpo['estado']});
    }

    return _responde(r, 404, {'error': 'no_encontrado', 'mensaje': 'No existe'});
  }

  Future<void> _responde(HttpRequest r, int status, Object cuerpo) async {
    r.response.statusCode = status;
    r.response.headers.contentType = ContentType.json;
    r.response.write(jsonEncode(cuerpo));
    await r.response.close();
  }

  /// Manda [m] por todos los sockets abiertos.
  void manda(Map<String, Object?> m) {
    for (final s in sockets) {
      s.add(jsonEncode(m));
    }
  }

  /// Corta todos los sockets, como un hub que se reinicia.
  Future<void> cortaSockets() async {
    for (final s in sockets.toList()) {
      await s.close();
    }
  }

  Future<void> cierra() => _srv.close(force: true);
}

/// Espera a que [condicion] se cumpla, o falla a los [plazo].
Future<void> hasta(bool Function() condicion, {Duration plazo = const Duration(seconds: 5)}) async {
  final fin = DateTime.now().add(plazo);
  while (!condicion()) {
    if (DateTime.now().isAfter(fin)) throw TimeoutException('No se cumplió a tiempo');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
