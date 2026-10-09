import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../config.dart';
import '../db.dart';
import '../log.dart';
import '../seguridad.dart';

/// Quién hace la petición desde el panel o por API, ya resuelto.
///
/// Hay dos clases de llamante y conviene no confundirlos: una persona con
/// sesión en el panel, y un script con llave de API. Los dos pertenecen a una
/// organización, y **de esa organización sale el filtro de toda consulta**:
/// ninguna ruta acepta un `org` que venga del cuerpo.
///
/// Dentro de la organización, [dominios] acota todavía más: con lista, la
/// sesión solo alcanza los equipos (y sus zonas, reglas, alertas y códigos)
/// de esos dominios. Sale de la base, como el rol, y nunca del cuerpo.
class Sesion {
  const Sesion({
    required this.org,
    this.usuario,
    this.llave,
    this.rol = 'api',
    this.permisos = const {},
    this.dominios,
  });

  final int org;
  final int? usuario;
  final int? llave;
  final String rol;
  final Set<String> permisos;

  /// Los dominios que alcanza; null = toda la organización.
  final List<int>? dominios;

  bool get esUsuario => usuario != null;
  bool get acotada => dominios != null;

  /// Una llave con permiso `admin` vale lo mismo que una persona administradora.
  /// Administrar es de toda la organización: una sesión acotada nunca lo es,
  /// aunque la base dijera otra cosa.
  bool get esAdmin => !acotada && ((esUsuario && rol == 'admin') || permisos.contains('admin'));

  /// Si [dominio] está a su alcance.
  bool alcanza(int? dominio) => dominios == null || (dominio != null && dominios!.contains(dominio));

  /// Lo que cada rol puede. `editor` maneja los equipos pero no a las
  /// personas ni las llaves; `consulta` solo mira.
  static const _porRol = {
    'editor': {'leer', 'editar', 'ordenar'},
    'consulta': {'leer'},
  };

  bool puede(String permiso) {
    if (esAdmin) return true;
    if (esUsuario) return _porRol[rol]?.contains(permiso) ?? false;
    return permisos.contains(permiso);
  }

  /// Quién hizo algo, para dejarlo escrito (`usuario:3`, `llave:7`).
  String get firma => esUsuario ? 'usuario:$usuario' : 'llave:$llave';
}

/// Un equipo autenticado con su credencial (`dtd_`). Solo puede tocar lo
/// suyo: reportar y contestar sus órdenes.
class SesionEquipo {
  const SesionEquipo({required this.org, required this.equipo, required this.fuente, this.tipo = 'agente'});

  final int org;
  final int equipo;
  final int fuente;

  /// `agente` o `app`. Cuando un equipo tiene el agente conectado, las órdenes
  /// van solo a él: si no, un «mostrar mensaje» saldría dos veces.
  final String tipo;
}

/// Nivel de acceso que exige una ruta.
enum Acceso {
  /// Sin credencial: login, salud, el alta (que trae su propio código).
  publico,

  /// La credencial de un equipo (`dtd_`).
  equipo,

  /// Persona del panel o llave de API, con el permiso que pida la ruta.
  panel,

  /// Solo una persona (cambiar su clave, ver quién es).
  persona,
}

class Peticion {
  Peticion({
    required this.crudo,
    required this.params,
    required this.cuerpo,
    required this.sesion,
    required this.config,
    required this.bd,
    this.equipo,
    Map<String, String>? consulta,
    String? urlPublica,
  }) : _consulta = consulta,
       _urlPublica = urlPublica;

  /// La petición HTTP. Null en una llamada por dentro ([Servidor.interna]):
  /// la del asistente, que usa las mismas rutas con la sesión de la persona.
  final HttpRequest? crudo;
  final Map<String, String>? _consulta;
  final String? _urlPublica;
  final Map<String, String> params;
  final Map<String, Object?> cuerpo;
  final Sesion? sesion;

  /// El equipo que llama, en las rutas [Acceso.equipo].
  final SesionEquipo? equipo;
  SesionEquipo get e => equipo!;
  final Config config;
  final Bd bd;

  Sesion get s => sesion!;
  Map<String, String> get consulta => _consulta ?? crudo?.uri.queryParameters ?? const {};

  String texto(String clave, {String porDefecto = ''}) {
    final v = cuerpo[clave];
    return v == null ? porDefecto : v.toString().trim();
  }

  int? entero(String clave) {
    final v = cuerpo[clave];
    if (v is int) return v;
    return int.tryParse(v?.toString() ?? '');
  }

  int enteroParam(String clave) => int.tryParse(params[clave] ?? '') ?? 0;

  /// IP de quien llama. Detrás de nginx, la que él dice en `X-Real-IP`.
  String get ip {
    final c = crudo;
    if (c == null) return 'interna';
    return c.headers.value('x-real-ip')?.trim() ??
        c.headers.value('x-forwarded-for')?.split(',').first.trim() ??
        c.connectionInfo?.remoteAddress.address ??
        '';
  }

  /// URL con la que el mundo llega al hub, sin barra final. Si no se fijó en
  /// la configuración, se arma con lo que dice el proxy.
  String get urlPublica {
    if (config.urlPublica.isNotEmpty) return config.urlPublica;
    final crudo = this.crudo;
    if (crudo == null) return _urlPublica ?? '';
    final proto = crudo.headers.value('x-forwarded-proto')?.split(',').first.trim() ??
        (crudo.requestedUri.scheme);
    final host = crudo.headers.value('x-forwarded-host')?.split(',').first.trim() ??
        crudo.headers.host ??
        'localhost';
    final puerto = crudo.headers.value('x-forwarded-host') == null &&
            crudo.headers.port != 80 &&
            crudo.headers.port != 443
        ? ':${crudo.headers.port}'
        : '';
    return '$proto://$host$puerto';
  }
}

class Respuesta {
  Respuesta(this.estado, this.cuerpo, {this.cabeceras = const {}});

  final int estado;
  final Object? cuerpo;
  final Map<String, String> cabeceras;

  static Respuesta ok(Object? cuerpo) => Respuesta(200, cuerpo);

  /// El manejador ya escribió y cerró la respuesta por su cuenta (una descarga
  /// que va en flujo, no en JSON). Sin esta señal, el ciclo intentaría cerrar
  /// dos veces la misma respuesta.
  static Respuesta yaEscrita() => Respuesta(0, null);
  static Respuesta creado(Object? cuerpo) => Respuesta(201, cuerpo);
  static Respuesta vacio() => Respuesta(204, null);

  /// El cuerpo de error es siempre `{error, mensaje}`: `error` es un código
  /// estable para que el cliente ramifique, `mensaje` es para la gente.
  static Respuesta falla(int estado, String error, [String mensaje = '']) =>
      Respuesta(estado, {'error': error, 'mensaje': mensaje});
}

typedef Manejador = FutureOr<Respuesta> Function(Peticion p);

class _Ruta {
  _Ruta(this.metodo, String patron, this.manejador, this.acceso, this.permiso)
    : partes = patron.split('/').where((s) => s.isNotEmpty).toList();

  final String metodo;
  final List<String> partes;
  final Manejador manejador;
  final Acceso acceso;

  /// Lo que pide una ruta [Acceso.panel]: `leer`, `editar`, `ordenar` o `admin`.
  final String permiso;

  Map<String, String>? casa(String metodoPet, List<String> ruta) {
    if (metodoPet != metodo || ruta.length != partes.length) return null;
    final params = <String, String>{};
    for (var i = 0; i < partes.length; i++) {
      final p = partes[i];
      if (p.startsWith(':')) {
        params[p.substring(1)] = ruta[i];
      } else if (p != ruta[i]) {
        return null;
      }
    }
    return params;
  }
}

/// Router y ciclo de petición. Sin framework: dart:io da el servidor HTTP y
/// esto son ciento y pico de líneas que cualquiera lee de una sentada.
class Servidor {
  Servidor(this.config, this.bd);

  final Config config;
  final Bd bd;
  final List<_Ruta> _rutas = [];

  /// Manejadores de upgrade (WebSocket). Se prueban antes del routing normal.
  final List<Future<bool> Function(HttpRequest)> upgrades = [];

  void ruta(
    String metodo,
    String patron,
    Manejador manejador, {
    Acceso acceso = Acceso.panel,
    String permiso = 'leer',
  }) => _rutas.add(_Ruta(metodo, patron, manejador, acceso, permiso));

  /// Llama una ruta del panel por dentro, con [sesion]: la misma ruta y la
  /// misma autorización que por HTTP (rol, permiso de la ruta, dominios).
  /// Es lo que usa el asistente de IA: hace lo que la persona podría hacer
  /// en la pantalla, ni más ni menos. Solo rutas del panel ([Acceso.panel], y
  /// [Acceso.persona] si la sesión es de una persona).
  ///
  /// [bd] la corre dentro de una transacción abierta: así se ensaya un
  /// cambio y se deshace (ver `ia/herramientas.dart`).
  Future<Respuesta> interna(
    String metodo,
    String ruta, {
    required Sesion sesion,
    Map<String, String> consulta = const {},
    Map<String, Object?> cuerpo = const {},
    String urlPublica = '',
    Bd? bd,
  }) async {
    final partes = ruta.split('/').where((s) => s.isNotEmpty).toList();
    for (final r in _rutas) {
      final params = r.casa(metodo, partes);
      if (params == null) continue;
      final vale = r.acceso == Acceso.panel || (r.acceso == Acceso.persona && sesion.esUsuario);
      if (!vale) {
        return Respuesta.falla(403, 'ruta_no_permitida', 'Esa ruta no se llama por dentro');
      }
      if (!sesion.puede(r.permiso)) {
        return Respuesta.falla(403, 'sin_permiso', 'Hace falta el permiso «${r.permiso}»');
      }
      try {
        return await r.manejador(Peticion(
          crudo: null,
          params: params,
          cuerpo: cuerpo,
          sesion: sesion,
          config: config,
          bd: bd ?? this.bd,
          consulta: consulta,
          urlPublica: urlPublica,
        ));
      } catch (e, t) {
        final ref = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
        log.error('interna', 'err:$ref $metodo $ruta → $e\n$t');
        return Respuesta.falla(500, 'error_interno', 'Error interno. Referencia: $ref');
      }
    }
    return Respuesta.falla(404, 'no_encontrado', 'Ruta desconocida');
  }

  Future<HttpServer> escuchar() async {
    final servidor = await HttpServer.bind(config.host, config.puerto, shared: true);
    servidor.listen(
      (pet) => _atiende(pet).catchError((Object e, StackTrace t) {
        log.error('http', 'fallo no atrapado: $e');
      }),
    );
    return servidor;
  }

  Future<void> _atiende(HttpRequest pet) async {
    _cors(pet);
    if (pet.method == 'OPTIONS') {
      pet.response.statusCode = HttpStatus.noContent;
      await pet.response.close();
      return;
    }

    for (final upgrade in upgrades) {
      if (await upgrade(pet)) return;
    }

    final ruta = pet.uri.pathSegments.where((s) => s.isNotEmpty).toList();

    // HEAD se atiende con el manejador de GET y sin cuerpo. Es lo que manda un
    // `curl -I` y lo que usa un navegador para comprobar una descarga; sin
    // esto, la misma URL que funciona da 404 al mirarla.
    final metodo = pet.method == 'HEAD' ? 'GET' : pet.method;

    for (final r in _rutas) {
      final params = r.casa(metodo, ruta);
      if (params == null) continue;
      await _corre(pet, r, params);
      return;
    }

    // Nada casó. Si la ruta empieza por `v1` es un 404 de API; si no, puede
    // ser el panel (una SPA con rutas propias del navegador).
    if (ruta.isNotEmpty && ruta.first == 'v1') {
      await _escribe(pet, Respuesta.falla(404, 'no_encontrado', 'Ruta desconocida'));
    } else {
      await _sirveManager(pet, ruta);
    }
  }

  Future<void> _corre(HttpRequest pet, _Ruta r, Map<String, String> params) async {
    Map<String, Object?> cuerpo = const {};
    if (pet.method != 'GET' && pet.method != 'DELETE') {
      try {
        cuerpo = await _leeJson(pet);
      } on FormatException catch (e) {
        await _escribe(pet, Respuesta.falla(400, 'json_invalido', e.message));
        return;
      }
    }

    Sesion? sesion;
    SesionEquipo? equipo;
    switch (r.acceso) {
      case Acceso.publico:
        break;
      case Acceso.equipo:
        equipo = await _autenticaEquipo(pet);
        if (equipo == null) {
          await _escribe(
            pet,
            Respuesta.falla(401, 'equipo_no_autenticado',
                'Falta la credencial del equipo o ya no vale: hay que darlo de alta de nuevo'),
          );
          return;
        }
      case Acceso.panel:
      case Acceso.persona:
        sesion = await _autentica(pet);
        if (sesion == null) {
          await _escribe(
            pet,
            Respuesta.falla(401, 'no_autenticado', 'Falta credencial o no es válida'),
          );
          return;
        }
        if (r.acceso == Acceso.persona && !sesion.esUsuario) {
          await _escribe(
            pet,
            Respuesta.falla(403, 'requiere_sesion', 'Esta ruta es para una persona del panel'),
          );
          return;
        }
        if (!sesion.puede(r.permiso)) {
          await _escribe(
            pet,
            Respuesta.falla(403, 'sin_permiso', 'Hace falta el permiso «${r.permiso}»'),
          );
          return;
        }
    }

    try {
      final resp = await r.manejador(
        Peticion(
          crudo: pet,
          params: params,
          cuerpo: cuerpo,
          sesion: sesion,
          equipo: equipo,
          config: config,
          bd: bd,
        ),
      );
      await _escribe(pet, resp);
    } catch (e, t) {
      // El texto de la excepción trae nombres de tabla y restricciones. Va al
      // log; al cliente solo una referencia con la que buscarlo.
      final ref = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      log.error('http', 'err:$ref ${pet.method} ${pet.uri.path} → $e\n$t');
      await _escribe(
        pet,
        Respuesta.falla(500, 'error_interno', 'Error interno. Referencia: $ref'),
      );
    }
  }

  Future<Map<String, Object?>> _leeJson(HttpRequest pet) async {
    final bytes = <int>[];
    await for (final trozo in pet) {
      bytes.addAll(trozo);
      // Un lote de reportes atrasados con la lista de apps cabe de sobra.
      if (bytes.length > 2 * 1024 * 1024) {
        throw const FormatException('Cuerpo demasiado grande');
      }
    }
    if (bytes.isEmpty) return const {};
    final decodificado = jsonDecode(utf8.decode(bytes));
    if (decodificado is! Map) {
      throw const FormatException('El cuerpo debe ser un objeto JSON');
    }
    return decodificado.cast<String, Object?>();
  }

  /// Lo que viene en `Authorization: Bearer …` (o `X-Api-Key`).
  static String credencialDe(HttpRequest pet) {
    final api = pet.headers.value('x-api-key')?.trim() ?? '';
    if (api.isNotEmpty) return api;
    final auth = pet.headers.value('authorization')?.trim() ?? '';
    return auth.toLowerCase().startsWith('bearer ') ? auth.substring(7).trim() : auth;
  }

  /// Resuelve la credencial del panel. Dos formatos sobre la misma cabecera:
  /// `Bearer <jwt>` para personas y `Bearer dtk_<prefijo>_<secreto>` para
  /// scripts. Se distinguen por el prefijo, no por cabeceras distintas: así un
  /// cliente cualquiera usa una sola forma.
  Future<Sesion?> _autentica(HttpRequest pet) async {
    final credencial = credencialDe(pet);
    if (credencial.isEmpty) return null;
    if (credencial.startsWith('dtk_')) return _sesionDeLlave(credencial);
    // La credencial de un equipo o un código de alta no abren el panel.
    if (credencial.startsWith('dtd_') || credencial.startsWith('dta_')) return null;

    final carga = Seguridad.verificaJwt(credencial, config.secretoJwt);
    if (carga == null) return null;
    final usuario = carga['sub'];
    final org = carga['org'];
    if (usuario is! int || org is! int) return null;
    // El rol se lee de la base y no del JWT: bajar a alguien de admin a
    // consulta tiene que valer ya, no cuando venza su sesión de siete días.
    // Lo mismo con sus dominios: quitarle uno corta el acceso en el acto.
    final u = await bd.fila(
      'select rol, dominios from dt.usuario where id = @i and org = @o and clave_hash is not null',
      {'i': usuario, 'o': org},
    );
    if (u == null) return null;
    return Sesion(org: org, usuario: usuario, rol: u['rol'] as String, dominios: _alcance(u['dominios']));
  }

  Future<Sesion?> _sesionDeLlave(String credencial) async {
    final partes = Seguridad.partesCredencial(credencial);
    if (partes == null || partes[0] != 'dtk') return null;
    final fila = await bd.fila(
      '''select id, org, clave_hash, permisos, dominios
           from dt.llave
          where prefijo = @p and revocada is null''',
      {'p': partes[1]},
    );
    if (fila == null) return null;
    if (!Seguridad.tokenCoincide(partes[2], fila['clave_hash'] as String)) {
      return null;
    }
    // `ultimo_uso` sirve para saber qué llave se puede revocar sin romper nada.
    unawaited(
      bd.ejecuta('update dt.llave set ultimo_uso = now() where id = @i', {
        'i': fila['id'],
      }),
    );
    return Sesion(
      org: fila['org'] as int,
      llave: fila['id'] as int,
      rol: 'api',
      permisos: ((fila['permisos'] as List?) ?? const []).map((p) => p.toString()).toSet(),
      dominios: _alcance(fila['dominios']),
    );
  }

  /// La columna `dominios` como alcance: vacía es toda la organización.
  static List<int>? _alcance(Object? v) {
    final l = [for (final d in (v as List?) ?? const []) (d as num).toInt()];
    return l.isEmpty ? null : l;
  }

  /// La credencial de un equipo (`dtd_`). La usan el reporte, el acuse de
  /// las órdenes y el WebSocket.
  Future<SesionEquipo?> _autenticaEquipo(HttpRequest pet) =>
      equipoDeCredencial(bd, credencialDe(pet));

  void _cors(HttpRequest pet) {
    final origen = pet.headers.value('origin');
    final permitidos = config.origenesCors;
    if (permitidos.isEmpty) {
      pet.response.headers.set('access-control-allow-origin', '*');
    } else if (origen != null && permitidos.contains(origen)) {
      pet.response.headers
        ..set('access-control-allow-origin', origen)
        ..add('vary', 'Origin');
    }
    pet.response.headers
      ..set('access-control-allow-methods', 'GET,POST,PATCH,DELETE,OPTIONS')
      ..set('access-control-allow-headers', 'authorization,content-type,x-api-key')
      ..set('access-control-max-age', '86400');
  }

  Future<void> _escribe(HttpRequest pet, Respuesta r) async {
    if (r.estado == 0) return; // ya la escribió el manejador
    final res = pet.response;
    res.statusCode = r.estado;
    r.cabeceras.forEach(res.headers.set);
    if (r.cuerpo == null || pet.method == 'HEAD') {
      await res.close();
      return;
    }
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(r.cuerpo, toEncodable: _aJson));
    await res.close();
  }

  /// Sirve el panel compilado. Cualquier ruta que no sea un archivo existente
  /// devuelve `index.html`, que es lo que necesita una SPA.
  Future<void> _sirveManager(HttpRequest pet, List<String> ruta) async {
    final base = Directory(config.rutaManager);
    if (!base.existsSync()) {
      await _escribe(
        pet,
        Respuesta.falla(404, 'sin_manager', 'Este hub sirve solo la API'),
      );
      return;
    }
    // Sin `..`: un segmento con salto de carpeta serviría cualquier archivo
    // del servidor.
    final limpio = ruta.where((s) => s != '..' && s != '.').toList();
    var archivo = File([base.path, ...limpio].join(Platform.pathSeparator));
    final existe = limpio.isNotEmpty && archivo.existsSync();

    if (!existe) {
      // Un archivo con extensión que no está es un 404, no la portada.
      //
      // Devolver `index.html` en su lugar rompe de la peor manera: el
      // navegador que tenía cacheada una versión anterior pide su `.js`, le
      // llega HTML, se niega a ejecutarlo y la página queda muerta sin un solo
      // error que explique nada. El respaldo a `index.html` es para las rutas
      // del navegador, que no llevan extensión.
      if (limpio.isNotEmpty && limpio.last.contains('.')) {
        await _escribe(pet, Respuesta.falla(404, 'no_encontrado', ''));
        return;
      }
      archivo = File('${base.path}${Platform.pathSeparator}index.html');
      if (!archivo.existsSync()) {
        await _escribe(pet, Respuesta.falla(404, 'no_encontrado', ''));
        return;
      }
    }

    // Los archivos de `assets/` llevan el hash del contenido en el nombre: si
    // cambian, cambia la URL. Se pueden cachear para siempre. `index.html` es
    // lo contrario: es el que dice qué hash toca hoy, y cachearlo es lo que
    // deja a un navegador pidiendo archivos que ya no existen.
    final enAssets = limpio.isNotEmpty && limpio.first == 'assets';
    pet.response.headers
      ..contentType = _tipo(archivo.path)
      ..set(
        'cache-control',
        enAssets && existe ? 'public, max-age=31536000, immutable' : 'no-cache',
      );
    await pet.response.addStream(archivo.openRead());
    await pet.response.close();
  }

  /// Postgres devuelve `DateTime` y `Uint8List` donde JSON quiere texto. Se
  /// traduce aquí, en la salida, y no en cada consulta: una ruta nueva no
  /// tiene que acordarse de convertir sus fechas.
  static Object? _aJson(Object? v) {
    if (v is DateTime) return v.toUtc().toIso8601String();
    if (v is Uint8List) return base64.encode(v);
    return v.toString();
  }

  ContentType _tipo(String ruta) {
    final p = ruta.toLowerCase();
    if (p.endsWith('.html')) return ContentType.html;
    if (p.endsWith('.js')) return ContentType('application', 'javascript', charset: 'utf-8');
    if (p.endsWith('.css')) return ContentType('text', 'css', charset: 'utf-8');
    if (p.endsWith('.json')) return ContentType.json;
    if (p.endsWith('.svg')) return ContentType('image', 'svg+xml');
    if (p.endsWith('.png')) return ContentType('image', 'png');
    if (p.endsWith('.jpg') || p.endsWith('.jpeg')) return ContentType('image', 'jpeg');
    if (p.endsWith('.ico')) return ContentType('image', 'x-icon');
    if (p.endsWith('.webp')) return ContentType('image', 'webp');
    if (p.endsWith('.woff2')) return ContentType('font', 'woff2');
    if (p.endsWith('.txt')) return ContentType('text', 'plain', charset: 'utf-8');
    return ContentType.binary;
  }
}

/// Resuelve una credencial de equipo (`dtd_<prefijo>_<secreto>`). Fuera de la
/// clase porque el WebSocket la usa también.
Future<SesionEquipo?> equipoDeCredencial(Bd bd, String credencial) async {
  final partes = Seguridad.partesCredencial(credencial);
  if (partes == null || partes[0] != 'dtd') return null;
  final f = await bd.fila(
    '''select f.id, f.equipo, f.clave_hash, f.tipo, e.org
         from dt.fuente f join dt.equipo e on e.id = f.equipo
        where f.prefijo = @p and f.revocada is null''',
    {'p': partes[1]},
  );
  if (f == null || !Seguridad.tokenCoincide(partes[2], f['clave_hash'] as String)) {
    return null;
  }
  return SesionEquipo(
    org: f['org'] as int,
    equipo: f['equipo'] as int,
    fuente: f['id'] as int,
    tipo: f['tipo'] as String,
  );
}
