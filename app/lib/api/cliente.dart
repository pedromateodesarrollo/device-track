/// El cliente del API del hub. Pone el token, convierte los errores en
/// [HubError] con el mensaje que el hub ya escribió para la gente (`{error,
/// mensaje}`), y avisa cuando la sesión vence.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../modelo/chat.dart';

typedef Json = Map<String, Object?>;

/// El hub de siempre. device-track es auto-hospedable: en la entrada se puede
/// poner otro.
const hubPorDefecto = 'https://devicetrack.chalonasoft.com';

class HubError implements Exception {
  const HubError(this.mensaje, {this.codigo = '', this.estado = 0});

  /// Para la persona: lo que dijo el hub, o qué pasó con la red.
  final String mensaje;

  /// El código estable del hub (`sin_permiso`, `conversacion_larga`…), para
  /// decidir qué ofrecer.
  final String codigo;

  /// El código HTTP; 0 si ni siquiera hubo respuesta.
  final int estado;

  @override
  String toString() => mensaje;
}

const _sinConexion = 'No se pudo hablar con el hub. Revisa la conexión.';

/// `devicetrack.miempresa.com` → `https://devicetrack.miempresa.com`, sin la
/// barra final. Null si no es una dirección.
String? normalizaHub(String crudo) {
  var s = crudo.trim();
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.isEmpty) return null;
  if (!s.contains('://')) s = 'https://$s';
  final u = Uri.tryParse(s);
  if (u == null || u.host.isEmpty || !(u.isScheme('https') || u.isScheme('http'))) return null;
  // Lo que venga después de la dirección (un `#/panel` copiado del
  // navegador) no es parte del hub; una ruta sí (un hub detrás de un proxy en
  // `/devicetrack`), sin la barra final.
  var ruta = u.path;
  while (ruta.endsWith('/')) {
    ruta = ruta.substring(0, ruta.length - 1);
  }
  return '${u.scheme}://${u.authority}$ruta';
}

class HubCliente {
  HubCliente({required this.hub, this.token, http.Client? cliente, this.alVencer})
    : _http = cliente ?? http.Client();

  /// Sin la barra final: `https://devicetrack.chalonasoft.com`.
  final String hub;
  final String? token;

  /// Un 401 con sesión: el token caducó, el hub rotó su secreto o quitaron a
  /// la persona. La app vuelve a la entrada.
  final void Function()? alVencer;
  final http.Client _http;

  static const espera = Duration(seconds: 25);

  Uri url(String ruta, [Map<String, String> consulta = const {}]) {
    final u = Uri.parse('$hub$ruta');
    return consulta.isEmpty ? u : u.replace(queryParameters: consulta);
  }

  Map<String, String> get _cabeceras => {
    'content-type': 'application/json',
    'accept': 'application/json',
    if (token != null) 'authorization': 'Bearer $token',
  };

  Future<Json> get(String ruta, {Map<String, String> consulta = const {}}) => pide('GET', ruta, consulta: consulta);
  Future<Json> post(String ruta, [Json cuerpo = const {}]) => pide('POST', ruta, cuerpo: cuerpo);
  Future<Json> patch(String ruta, Json cuerpo) => pide('PATCH', ruta, cuerpo: cuerpo);
  Future<Json> borra(String ruta) => pide('DELETE', ruta);

  /// La respuesta como objeto; `{}` si el hub contestó 204.
  Future<Json> pide(String metodo, String ruta, {Json? cuerpo, Map<String, String> consulta = const {}}) async {
    final req = http.Request(metodo, url(ruta, consulta))..headers.addAll(_cabeceras);
    if (cuerpo != null && metodo != 'GET' && metodo != 'DELETE') req.body = jsonEncode(cuerpo);
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req).timeout(espera)).timeout(espera);
    } on TimeoutException {
      throw const HubError('El hub tardó demasiado en contestar.', codigo: 'sin_respuesta');
    } catch (_) {
      throw const HubError(_sinConexion, codigo: 'sin_conexion');
    }
    if (res.statusCode == 204) return {};
    final ok = res.statusCode >= 200 && res.statusCode < 300;
    final d = _json(res.bodyBytes);
    if (!ok) throw _falla(res.statusCode, d);
    if (d == null) {
      throw HubError('El hub contestó algo que no se entiende (HTTP ${res.statusCode}). ¿Es la dirección de un hub?',
          estado: res.statusCode);
    }
    return d;
  }

  /// Pregunta al asistente. Con 200 el cuerpo es NDJSON y llega mientras el
  /// hub consulta: se devuelven los eventos a medida que llegan. Si no, es un
  /// error normal (`ia_no_disponible`, `conversacion_larga`) y se lanza.
  Future<Stream<EventoChat>> chat(Json cuerpo) async {
    final req = http.Request('POST', url('/v1/ia/chat'))
      ..headers.addAll({..._cabeceras, 'accept': 'application/x-ndjson'})
      ..body = jsonEncode(cuerpo);
    final http.StreamedResponse res;
    try {
      // El primer evento sale antes de preguntarle al modelo: si en este rato
      // no hay ni cabeceras, algo va mal.
      res = await _http.send(req).timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw const HubError('El hub tardó demasiado en contestar.', codigo: 'sin_respuesta');
    } catch (_) {
      throw const HubError(_sinConexion, codigo: 'sin_conexion');
    }
    if (res.statusCode != 200) {
      List<int> error;
      try {
        error = await res.stream.toBytes().timeout(espera);
      } catch (_) {
        error = const [];
      }
      throw _falla(res.statusCode, _json(error));
    }
    // Una vuelta del modelo con varias consultas puede tardar, pero cuatro
    // minutos sin una sola línea es una conexión muerta.
    return eventosDe(res.stream).timeout(
      const Duration(minutes: 4),
      onTimeout: (s) {
        s.add(const EventoError(codigo: 'sin_respuesta', mensaje: 'El hub dejó de contestar.'));
        s.close();
      },
    );
  }

  HubError _falla(int estado, Json? d) {
    if (estado == 401 && token != null) alVencer?.call();
    final mensaje = d?['mensaje'];
    final codigo = '${d?['error'] ?? ''}';
    return HubError(
      mensaje is String && mensaje.isNotEmpty ? mensaje : (codigo.isNotEmpty ? codigo : 'Error $estado'),
      codigo: codigo,
      estado: estado,
    );
  }

  static Json? _json(List<int> bytes) {
    if (bytes.isEmpty) return null;
    try {
      // Con `allowMalformed`, un error que llegó en otra codificación (un
      // proxy) se lee igual: pierde una tilde, no el mensaje.
      final d = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return d is Map ? d.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }

  void cierra() => _http.close();
}
