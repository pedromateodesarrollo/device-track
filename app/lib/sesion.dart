/// La sesión: a qué hub se habla, con qué token, y quién es la persona
/// (`GET /v1/yo`). El hub y el token se guardan en el teléfono; la clave,
/// nunca.
///
/// Es una sola, para toda la app ([sesion]): la raíz la escucha y cambia de
/// pantalla cuando se entra, se sale o se vence.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/cliente.dart';
import 'modelo/yo.dart';

final sesion = Sesion();

enum EstadoSesion {
  /// Leyendo lo guardado.
  arrancando,

  /// Sin token: la pantalla de entrada.
  fuera,

  /// Con token, preguntando quién es.
  cargando,

  /// Con token, pero el hub no contestó: se ofrece reintentar.
  sinRespuesta,

  dentro,
}

class Sesion extends ChangeNotifier {
  static const _claveHub = 'hub';
  static const _claveToken = 'token';

  EstadoSesion estado = EstadoSesion.arrancando;

  /// Sin la barra final.
  String hub = hubPorDefecto;
  String? _token;
  Yo? yo;

  /// Por qué se volvió a la entrada («tu sesión venció»), o qué pasó al
  /// preguntar quién es.
  String? aviso;

  HubCliente _api = HubCliente(hub: hubPorDefecto);

  /// El cliente con el hub y el token de ahora.
  HubCliente get api => _api;

  bool get dentro => estado == EstadoSesion.dentro && yo != null;

  /// Si la persona puede [permiso] (`leer`, `editar`, `ordenar`, `admin`).
  bool puede(String permiso) => yo?.puede(permiso) ?? false;

  Future<void> arranca() async {
    final p = await SharedPreferences.getInstance();
    hub = p.getString(_claveHub) ?? hubPorDefecto;
    _token = p.getString(_claveToken);
    _rehaceCliente();
    if (_token == null) {
      _cambia(EstadoSesion.fuera);
      return;
    }
    await cargaYo();
  }

  /// `POST /v1/auth/login`. Lanza [HubError] con el mensaje del hub
  /// («Correo o clave incorrectos»).
  Future<void> entra({required String hub, required String correo, required String clave}) async {
    final api = HubCliente(hub: hub);
    try {
      final r = await api.post('/v1/auth/login', {'correo': correo.trim(), 'clave': clave});
      final token = r['token'];
      if (token is! String || token.isEmpty) {
        throw const HubError('El hub no devolvió una sesión. ¿Es la dirección de un hub de device-track?');
      }
      this.hub = hub;
      _token = token;
      aviso = null;
      final p = await SharedPreferences.getInstance();
      await p.setString(_claveHub, hub);
      await p.setString(_claveToken, token);
      _rehaceCliente();
    } finally {
      api.cierra();
    }
    await cargaYo();
  }

  /// Quién es la persona. Un 401 aquí vence la sesión (lo hace el cliente).
  Future<void> cargaYo() async {
    _cambia(EstadoSesion.cargando);
    try {
      yo = Yo.deJson(await _api.get('/v1/yo'));
      aviso = null;
      _cambia(EstadoSesion.dentro);
    } on HubError catch (e) {
      if (estado == EstadoSesion.fuera) return; // venció: ya se cambió
      aviso = e.mensaje;
      _cambia(EstadoSesion.sinRespuesta);
    }
  }

  /// Vuelve a preguntar `/v1/yo` sin cambiar de pantalla: el rol, los
  /// dominios o el asistente pudieron cambiar desde que se entró.
  Future<void> refrescaYo() async {
    if (!dentro) return;
    try {
      yo = Yo.deJson(await _api.get('/v1/yo'));
      notifyListeners();
    } on HubError {
      // Se queda lo que había; un 401 ya sacó a la persona.
    }
  }

  /// El token dejó de valer: caducó, el hub rotó su secreto o quitaron a la
  /// persona.
  void _vencida() {
    if (_token == null) return;
    _olvida('Tu sesión venció o ya no es válida. Entra otra vez.');
  }

  Future<void> sale() => _olvida(null);

  Future<void> _olvida(String? porque) async {
    _token = null;
    yo = null;
    aviso = porque;
    _rehaceCliente();
    _cambia(EstadoSesion.fuera);
    final p = await SharedPreferences.getInstance();
    await p.remove(_claveToken);
  }

  void _rehaceCliente() {
    _api.cierra();
    _api = HubCliente(hub: hub, token: _token, alVencer: _vencida);
  }

  void _cambia(EstadoSesion e) {
    estado = e;
    notifyListeners();
  }
}
