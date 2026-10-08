import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../db.dart';
import '../http/servidor.dart';
import '../log.dart';

/// El WebSocket de los equipos: `GET /v1/ws` con su credencial (`dtd_`) en la
/// cabecera `Authorization`.
///
/// Sirve para dos cosas. Una, que una orden («suena», «muestra este aviso»)
/// llegue al instante y no en el siguiente reporte. Dos, saber qué equipos
/// están vivos ahora: mientras el socket está abierto el equipo figura
/// `conectado`, y al cerrarse queda la hora en que se vio por última vez.
///
/// La credencial va en la cabecera y no en la URL: una URL termina en el log
/// de cualquier proxy que haya en medio.
class Canal {
  Canal(this.bd);

  final Bd bd;

  /// Tope de sockets por equipo: uno o dos es lo normal (el agente y una app,
  /// o el viejo que todavía no se cerró al reconectar). Más es un equipo con
  /// un bucle.
  static const maxPorEquipo = 8;

  final Map<int, Set<WebSocket>> _porEquipo = {};
  final Map<int, int> _orgDe = {};

  /// Los sockets del agente de cada equipo (un subconjunto de [_porEquipo]).
  final Map<int, Set<WebSocket>> _agentes = {};

  /// Al conectar un equipo: entregarle lo que tenga pendiente y cerrar sus
  /// alertas de «sin reporte». Lo fija el hub.
  Future<void> Function(SesionEquipo e, WebSocket ws)? alConectar;

  int get total => _porEquipo.values.fold(0, (n, s) => n + s.length);
  bool conectado(int equipo) => _porEquipo[equipo]?.isNotEmpty ?? false;

  /// Si el agente de [equipo] tiene el socket abierto ahora.
  bool agenteConectado(int equipo) => _agentes[equipo]?.isNotEmpty ?? false;

  Future<bool> upgrade(HttpRequest pet) async {
    if (pet.uri.path != '/v1/ws') return false;
    final res = pet.response;
    if (!WebSocketTransformer.isUpgradeRequest(pet)) {
      res.statusCode = HttpStatus.badRequest;
      res.write('Esta ruta es un WebSocket');
      await res.close();
      return true;
    }
    final e = await equipoDeCredencial(bd, Servidor.credencialDe(pet));
    if (e == null) {
      res.statusCode = HttpStatus.unauthorized;
      res.write('Credencial de equipo inválida');
      await res.close();
      return true;
    }
    if ((_porEquipo[e.equipo]?.length ?? 0) >= maxPorEquipo) {
      res.statusCode = HttpStatus.tooManyRequests;
      res.write('Demasiadas conexiones de este equipo');
      await res.close();
      return true;
    }

    final WebSocket ws;
    try {
      // Sin compresión. dart:io contesta `permessage-deflate` con
      // `client_max_window_bits` aunque el cliente no lo haya ofrecido, y OkHttp
      // (el del agente y de cualquier app Android nativa) corta con 1010. Los
      // mensajes de aquí son de cien bytes: comprimir no compra nada.
      ws = await WebSocketTransformer.upgrade(pet, compression: CompressionOptions.compressionOff);
    } catch (err) {
      log.aviso('ws', 'upgrade falló: $err');
      return true;
    }
    // Ping de protocolo: detecta el teléfono que se fue sin cerrar (sin señal,
    // apagado) y mantiene abierto el camino a través de nginx y de NAT.
    ws.pingInterval = const Duration(seconds: 30);

    final primero = !conectado(e.equipo);
    _porEquipo.putIfAbsent(e.equipo, () => <WebSocket>{}).add(ws);
    if (e.tipo == 'agente') _agentes.putIfAbsent(e.equipo, () => <WebSocket>{}).add(ws);
    _orgDe[e.equipo] = e.org;
    if (primero) unawaited(_marca(e.equipo, conectado: true));

    var cerrado = false;
    void cierra() {
      if (cerrado) return;
      cerrado = true;
      final ag = _agentes[e.equipo];
      ag?.remove(ws);
      if (ag != null && ag.isEmpty) _agentes.remove(e.equipo);
      final set = _porEquipo[e.equipo];
      set?.remove(ws);
      if (set == null || set.isEmpty) {
        _porEquipo.remove(e.equipo);
        _orgDe.remove(e.equipo);
        unawaited(_marca(e.equipo, conectado: false));
      }
    }

    ws.listen(
      (m) {
        // Keepalive de aplicación, para clientes que no pueden mandar ping de
        // protocolo.
        if (m is String && m.contains('"ping"')) {
          try {
            ws.add('{"tipo":"pong"}');
          } catch (_) {}
        }
      },
      onDone: cierra,
      onError: (_) => cierra(),
      cancelOnError: true,
    );
    ws.add(jsonEncode({'tipo': 'hola', 'equipo': e.equipo}));
    final f = alConectar;
    if (f != null) {
      unawaited(f(e, ws).catchError((Object err) {
        log.aviso('ws', 'al conectar el equipo ${e.equipo}: $err');
      }));
    }
    return true;
  }

  /// Una orden: si el agente está conectado, solo a él (una app con el plugin
  /// en el mismo teléfono la haría otra vez); si no, a quien esté.
  int enviaOrden(int equipo, Map<String, Object?> mensaje) =>
      agenteConectado(equipo) ? _a(_agentes[equipo], mensaje) : envia(equipo, mensaje);

  /// Manda [mensaje] a todos los sockets de [equipo]. Devuelve a cuántos llegó.
  int envia(int equipo, Map<String, Object?> mensaje) => _a(_porEquipo[equipo], mensaje);

  int _a(Set<WebSocket>? set, Map<String, Object?> mensaje) {
    if (set == null || set.isEmpty) return 0;
    final frame = jsonEncode(mensaje, toEncodable: _aJson);
    var n = 0;
    for (final ws in set.toList()) {
      try {
        ws.add(frame);
        n++;
      } catch (_) {}
    }
    return n;
  }

  /// Manda [mensaje] a todos los equipos conectados de [org] (la configuración
  /// cambió). Devuelve a cuántos equipos.
  int enviaOrg(int org, Map<String, Object?> mensaje) {
    var n = 0;
    for (final equipo in _orgDe.entries.where((x) => x.value == org).map((x) => x.key).toList()) {
      if (envia(equipo, mensaje) > 0) n++;
    }
    return n;
  }

  Future<void> _marca(int equipo, {required bool conectado}) async {
    try {
      await bd.ejecuta(
        'update dt.equipo set conectado = @c, ultima_vez = now() where id = @e',
        {'c': conectado, 'e': equipo},
      );
    } catch (err) {
      log.aviso('ws', 'no se pudo marcar el equipo $equipo: $err');
    }
  }

  static Object? _aJson(Object? v) => v is DateTime ? v.toUtc().toIso8601String() : v.toString();
}
