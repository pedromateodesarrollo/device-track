import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'hub.dart';
import 'modelos.dart';

/// El WebSocket del equipo con el hub (`GET /v1/ws`, la credencial en la
/// cabecera, nunca en la URL). Mientras está abierto, el equipo figura
/// **conectado** en el panel y las órdenes le llegan al instante.
///
/// Se cae y vuelve solo, con espera creciente (por defecto de 5 s a 5 min,
/// como el agente), y hace ping cada [ping] para darse cuenta de una conexión
/// muerta: el teléfono que pasó de la Wi-Fi a los datos deja el socket viejo
/// colgado sin avisar.
///
/// Si el hub rechaza la credencial (401) avisa en [credencialRechazada] y NO
/// insiste con ella: reintentar no la arregla. Con una credencial nueva (otra
/// alta) [conectar] vuelve a intentar.
///
/// Lee [HubCliente.servidor] y [HubCliente.credencial] en cada intento, así
/// que sigue al cliente si este se da de alta otra vez.
class CanalEquipo {
  CanalEquipo(
    this.hub, {
    this.esperaMinima = const Duration(seconds: 5),
    this.esperaMaxima = const Duration(minutes: 5),
    this.ping = const Duration(seconds: 30),
  }) : _http = HttpClient()..connectionTimeout = const Duration(seconds: 20);

  final HubCliente hub;
  final Duration esperaMinima;
  final Duration esperaMaxima;
  final Duration ping;

  final HttpClient _http;
  WebSocket? _ws;
  bool _abriendo = false;
  bool _cerrado = true;
  int _reintentos = 0;
  Timer? _reconexion;
  String? _rechazada;

  final _mensajes = StreamController<Map<String, Object?>>.broadcast();
  final _ordenes = StreamController<Orden>.broadcast();
  final _configs = StreamController<ConfigEquipo>.broadcast();
  final _estado = StreamController<bool>.broadcast();
  final _rechazos = StreamController<String>.broadcast();

  /// Todo lo que manda el hub, crudo: `{tipo: hola|orden|config|pong, …}`.
  Stream<Map<String, Object?>> get mensajes => _mensajes.stream;

  /// Las órdenes (`{tipo: orden}`). Pueden repetirse: el hub las vuelve a
  /// mandar hasta el acuse.
  Stream<Orden> get ordenes => _ordenes.stream;

  /// La configuración nueva, cuando alguien la cambia en el panel.
  Stream<ConfigEquipo> get configs => _configs.stream;

  /// `true` al conectar, `false` al caerse o cerrar.
  Stream<bool> get estado => _estado.stream;

  /// El hub no aceptó la credencial (401): hay que dar de alta el equipo otra
  /// vez. Trae la credencial rechazada, para no repetir el alta si otro camino
  /// (un reporte) ya la reemplazó.
  Stream<String> get credencialRechazada => _rechazos.stream;

  bool get conectado => _ws != null;

  /// Conecta y se queda reconectando hasta [cerrar]. Idempotente.
  void conectar() {
    _cerrado = false;
    if (_ws == null && !_abriendo) {
      _reconexion?.cancel();
      unawaited(_abrir());
    }
  }

  /// Si está esperando para reintentar, reintenta ya. Para colgarlo de «la app
  /// volvió al frente»: el teléfono pudo pasar una hora dormido.
  void reconectarAhora() {
    if (_cerrado || _ws != null || _abriendo) return;
    _reconexion?.cancel();
    _reintentos = 0;
    unawaited(_abrir());
  }

  Future<void> _abrir() async {
    if (_cerrado || _abriendo || _ws != null) return;
    final credencial = hub.credencial ?? '';
    // Sin credencial, o con la que ya se rechazó: no hay a qué conectarse.
    if (credencial.isEmpty || credencial == _rechazada) return;
    _abriendo = true;
    try {
      final ws = await WebSocket.connect(
        hub.urlWs.toString(),
        headers: {HttpHeaders.authorizationHeader: 'Bearer $credencial'},
        // Los mensajes son de cien bytes: comprimir no compra nada.
        compression: CompressionOptions.compressionOff,
        customClient: _http,
      );
      _abriendo = false;
      if (_cerrado) {
        unawaited(ws.close(WebSocketStatus.normalClosure).catchError((_) {}));
        return;
      }
      ws.pingInterval = ping;
      _ws = ws;
      _estado.add(true);
      ws.listen(
        _alLlegar,
        onDone: () => _alCaer(ws),
        onError: (_) => _alCaer(ws),
        cancelOnError: true,
      );
    } on WebSocketException catch (e) {
      _abriendo = false;
      if (e.httpStatusCode == 401) {
        _rechazada = credencial;
        _rechazos.add(credencial);
        return;
      }
      _programa();
    } catch (_) {
      _abriendo = false;
      _programa();
    }
  }

  void _alLlegar(dynamic crudo) {
    if (crudo is! String) return;
    final Object? d;
    try {
      d = jsonDecode(crudo);
    } on FormatException {
      return;
    }
    if (d is! Map) return;
    final m = Map<String, Object?>.from(d);
    _mensajes.add(m);
    switch (m['tipo']) {
      case 'hola':
        // La espera vuelve a la corta cuando el hub habló, no al abrir: un
        // socket que se abre y se cae al instante (un proxy que corta) si no
        // reintentaría cada pocos segundos para siempre.
        _reintentos = 0;
      case 'orden':
        final o = Orden.desdeJson(m['orden']);
        if (o != null) _ordenes.add(o);
      case 'config':
        if (m['config'] is Map) _configs.add(ConfigEquipo.desdeJson(m['config']));
    }
  }

  void _alCaer(WebSocket ws) {
    if (!identical(ws, _ws)) return;
    _ws = null;
    _estado.add(false);
    _programa();
  }

  /// La espera del próximo intento: [esperaMinima], el doble cada vez, hasta
  /// [esperaMaxima].
  void _programa() {
    if (_cerrado) return;
    _reconexion?.cancel();
    final ms = min(
      esperaMaxima.inMilliseconds,
      esperaMinima.inMilliseconds * (1 << min(_reintentos, 20)),
    );
    _reintentos++;
    _reconexion = Timer(Duration(milliseconds: ms), () => unawaited(_abrir()));
  }

  /// Cierra y deja de reconectar, hasta el próximo [conectar].
  Future<void> cerrar() async {
    _cerrado = true;
    _reconexion?.cancel();
    final ws = _ws;
    _ws = null;
    if (ws != null) {
      _estado.add(false);
      try {
        await ws.close(WebSocketStatus.normalClosure).timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    await cerrar();
    _http.close(force: true);
    await _mensajes.close();
    await _ordenes.close();
    await _configs.close();
    await _estado.close();
    await _rechazos.close();
  }
}
