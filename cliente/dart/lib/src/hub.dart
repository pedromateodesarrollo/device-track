import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'errores.dart';
import 'modelos.dart';

/// Las tres llamadas del equipo al hub: el alta, el reporte y el acuse de una
/// orden. Solo el protocolo: no guarda nada en disco ni decide cuándo
/// reportar; eso es de quien lo usa (en Flutter, `DeviceTrack`).
///
/// Lanza [ErrorHub] si el hub contestó con un error y [SinRespuesta] si no
/// contestó. Nada más.
///
/// ```dart
/// final hub = HubCliente(servidor: 'https://devicetrack.ejemplo.com');
/// final alta = await hub.alta(
///   codigo: 'dta_…',
///   huella: 'un-id-estable-del-equipo',
///   fuente: const Fuente(tipo: TipoFuente.app, paquete: 'com.ejemplo.inventario'),
/// );
/// guardar(alta.credencial); // hub.credencial ya quedó puesta
/// final r = await hub.reporte(Reporte(motivo: MotivoReporte.abrir, bateria: 80));
/// for (final o in r.ordenes) { … await hub.estadoOrden(o.id, EstadoOrden.hecha); }
/// ```
class HubCliente {
  HubCliente({
    required String servidor,
    this.credencial,
    this.plazo = const Duration(seconds: 30),
    HttpClient? http,
  })  : servidor = servidor.trim().replaceAll(RegExp(r'/+$'), ''),
        _http = http ?? (HttpClient()..connectionTimeout = const Duration(seconds: 20));

  /// `https://devicetrack.ejemplo.com`, sin la barra final.
  final String servidor;

  /// La credencial del equipo (`dtd_…`). La pone [alta]; quien la tenga
  /// guardada de antes la pasa al crear el cliente.
  String? credencial;

  /// Cuánto se espera cada respuesta.
  final Duration plazo;

  final HttpClient _http;

  bool get dadoDeAlta => (credencial ?? '').isNotEmpty;

  /// `wss://…/v1/ws` (o `ws://` si el hub es `http://`).
  Uri get urlWs {
    final base = Uri.parse(servidor);
    return base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', path: '${base.path}/v1/ws');
  }

  /// `POST /v1/alta` con el código de alta (`dta_…`) en la cabecera. Deja la
  /// credencial nueva en [credencial] y la devuelve en [Alta.credencial].
  ///
  /// Darse de alta otra vez desde la misma app revoca la credencial anterior.
  /// Si en la organización ya hay un equipo con esa [huella] (o esa serie),
  /// el hub le suma esta fuente y devuelve el mismo equipo. Gasta un uso del
  /// código.
  Future<Alta> alta({
    required String codigo,
    required String huella,
    required Fuente fuente,
    DatosEquipo? equipo,
  }) async {
    final r = await _post('/v1/alta', codigo.trim(), {
      'huella': huella,
      'fuente': fuente.toJson(),
      if (equipo != null) 'equipo': equipo.toJson(),
    });
    final Alta a;
    try {
      a = Alta.desdeJson(r);
    } on FormatException catch (e) {
      throw SinRespuesta(e.message, e);
    }
    credencial = a.credencial;
    return a;
  }

  /// `POST /v1/reporte`. Devuelve la configuración vigente y las órdenes que
  /// estén esperando.
  Future<RespuestaReporte> reporte(Reporte reporte) async =>
      RespuestaReporte.desdeJson(await _post('/v1/reporte', _credencial(), reporte.toJson()));

  /// `POST /v1/ordenes/:id/estado`: qué pasó con una orden. [detalle] dice por
  /// qué falló (`no_soportada`) o cómo terminó (`la tocaron a los 12 s`).
  Future<void> estadoOrden(int id, EstadoOrden estado, {String detalle = ''}) async {
    await _post('/v1/ordenes/$id/estado', _credencial(), {
      'estado': estado.name,
      if (detalle.isNotEmpty) 'detalle': detalle,
    });
  }

  /// Sin credencial es como si el hub la hubiera rechazado: hay que darse de
  /// alta.
  String _credencial() {
    final c = credencial ?? '';
    if (c.isEmpty) {
      throw const ErrorHub(401, 'sin_credencial', 'El equipo no está dado de alta');
    }
    return c;
  }

  Future<Map<String, Object?>> _post(String ruta, String credencial, Map<String, Object?> cuerpo) async {
    final int status;
    final String texto;
    try {
      final req = await _http.postUrl(Uri.parse('$servidor$ruta')).timeout(plazo);
      req.headers.contentType = ContentType.json;
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $credencial');
      req.add(utf8.encode(jsonEncode(cuerpo)));
      final res = await req.close().timeout(plazo);
      status = res.statusCode;
      texto = await utf8.decodeStream(res).timeout(plazo);
    } on TimeoutException catch (e) {
      throw SinRespuesta('El hub no contestó a tiempo', e);
    } on IOException catch (e) {
      throw SinRespuesta('Sin conexión con el hub', e);
    } on FormatException catch (e) {
      throw SinRespuesta('El hub contestó algo ilegible', e);
    }

    Object? json;
    try {
      json = texto.isEmpty ? null : jsonDecode(texto);
    } on FormatException {
      json = null;
    }
    final mapa = json is Map ? Map<String, Object?>.from(json) : null;
    if (status >= 400) {
      throw ErrorHub(
        status,
        mapa?['error']?.toString() ?? 'http_$status',
        mapa?['mensaje']?.toString() ?? 'HTTP $status',
      );
    }
    if (mapa == null) {
      throw SinRespuesta('El hub contestó algo que no es JSON (HTTP $status)');
    }
    return mapa;
  }

  /// Cierra las conexiones. Después de esto el cliente no sirve.
  void cerrar() => _http.close(force: true);
}
