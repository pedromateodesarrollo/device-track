import '../db.dart';
import '../dominios.dart';
import '../limitador.dart';
import '../log.dart';
import '../seguridad.dart';
import 'rutas_dominios.dart';
import 'servidor.dart';

/// Cuánto vale un enlace de invitación.
const vidaInvitacion = Duration(days: 7);

/// `admin` todo; `editor` equipos, órdenes, zonas, reglas y códigos de alta;
/// `consulta` solo mira.
const rolesValidos = {'admin', 'editor', 'consulta'};

/// Sesión, invitaciones y gestión de usuarios.
///
/// El hub tiene identidad propia —usuarios y claves suyos— porque un tercero
/// que lo instale no tiene de dónde sacarlas. Las personas entran por
/// invitación: el administrador pone el correo y comparte el enlace; la clave
/// la escribe la persona, y el administrador nunca la ve.
void registraRutasAuth(Servidor s) {
  final freno = Limitador(cupo: 10, ventana: const Duration(minutes: 1));

  s.ruta('GET', '/salud', (p) async {
    await p.bd.fila('select 1 as ok');
    return Respuesta.ok({'ok': true, 'servicio': 'device-track', 'registro': p.config.registro});
  }, acceso: Acceso.publico);

  // Alta de organización. Solo con APK_REGISTRO=abierto.
  s.ruta('POST', '/v1/auth/registro', (p) async {
    if (p.config.registro != 'abierto') {
      return Respuesta.falla(
        403,
        'registro_cerrado',
        'Este hub no acepta organizaciones nuevas por su cuenta; pídele una invitación a un administrador',
      );
    }
    if (!freno.cabe('registro:${p.ip}')) {
      return Respuesta.falla(429, 'demasiados_intentos', 'Espera un minuto');
    }
    final correo = p.texto('correo').toLowerCase();
    final clave = p.texto('clave');
    final organizacion = p.texto('organizacion');
    final problema = _revisaCorreo(correo) ?? _revisaClave(clave);
    if (problema != null) return problema;
    if (organizacion.isEmpty) {
      return Respuesta.falla(400, 'falta_organizacion', 'Ponle nombre a la organización');
    }
    if (await _correoOcupado(p.bd, correo)) {
      return Respuesta.falla(409, 'correo_en_uso', 'Ese correo ya tiene cuenta');
    }

    final creado = await p.bd.transaccion((tx) async {
      final org = await creaOrg(tx, organizacion);
      return await tx.fila(
        '''insert into dt.usuario (org, correo, clave_hash, nombre, rol)
           values (@o, @c, @h, @n, 'admin')
           returning id, org, correo, nombre, rol''',
        {
          'o': org,
          'c': correo,
          'h': Seguridad.hashClave(clave),
          'n': p.texto('nombre', porDefecto: correo.split('@').first),
        },
      );
    });

    log.info('auth', 'organización nueva: $organizacion');
    return Respuesta.creado(_conToken(creado!, p.config.secretoJwt));
  }, acceso: Acceso.publico);

  s.ruta('POST', '/v1/auth/login', (p) async {
    final correo = p.texto('correo').toLowerCase();
    if (!freno.cabe('login:${p.ip}') || !freno.cabe('login:$correo')) {
      return Respuesta.falla(429, 'demasiados_intentos', 'Espera un minuto');
    }
    final u = await p.bd.fila(
      'select id, org, correo, nombre, rol, clave_hash from dt.usuario where correo = @c',
      {'c': correo},
    );
    // Mismo error para «no existe», «clave mala» y «todavía no activó su
    // invitación»: la diferencia le diría a quien prueba correos cuáles están.
    const malas = 'Correo o clave incorrectos';
    final hash = u?['clave_hash'] as String?;
    if (u == null || hash == null || !Seguridad.verificaClave(p.texto('clave'), hash)) {
      return Respuesta.falla(401, 'credenciales_invalidas', malas);
    }
    freno.olvida('login:$correo');
    await p.bd.ejecuta(
      'update dt.usuario set ultimo_acceso = now() where id = @i',
      {'i': u['id']},
    );
    return Respuesta.ok(_conToken(u, p.config.secretoJwt));
  }, acceso: Acceso.publico);

  // Lo que la pantalla de activación puede enseñar antes de que la persona
  // ponga su clave: el correo y si el enlace sirve. Nada de la organización:
  // quien tiene el enlace todavía no ha demostrado nada.
  s.ruta('GET', '/v1/auth/invitacion/:token', (p) async {
    if (!freno.cabe('invitacion:${p.ip}')) {
      return Respuesta.falla(429, 'demasiados_intentos', 'Espera un minuto');
    }
    final u = await _porInvitacion(p.bd, p.params['token'] ?? '');
    if (u == null) {
      return Respuesta.falla(404, 'invitacion_invalida', 'Ese enlace no existe o ya se usó');
    }
    final vence = u['invitacion_vence'] as DateTime?;
    return Respuesta.ok({
      'correo': u['correo'],
      'vigente': vence != null && vence.isAfter(DateTime.now()),
    });
  }, acceso: Acceso.publico);

  s.ruta('POST', '/v1/auth/activar', (p) async {
    if (!freno.cabe('invitacion:${p.ip}')) {
      return Respuesta.falla(429, 'demasiados_intentos', 'Espera un minuto');
    }
    final clave = p.texto('clave');
    final problema = _revisaClave(clave);
    if (problema != null) return problema;
    final u = await _porInvitacion(p.bd, p.texto('token'));
    final vence = u?['invitacion_vence'] as DateTime?;
    if (u == null || vence == null || vence.isBefore(DateTime.now())) {
      return Respuesta.falla(
        410,
        'invitacion_vencida',
        'El enlace venció o ya se usó. Pide otro a quien te invitó.',
      );
    }
    final hecho = await p.bd.fila(
      '''update dt.usuario
            set clave_hash = @h, invitacion_hash = null, invitacion_vence = null,
                ultimo_acceso = now()
          where id = @i
          returning id, org, correo, nombre, rol''',
      {'h': Seguridad.hashClave(clave), 'i': u['id']},
    );
    log.info('auth', 'invitación aceptada: usuario ${u['id']}');
    return Respuesta.ok(_conToken(hecho!, p.config.secretoJwt));
  }, acceso: Acceso.publico);

  // `dominios` vacío = alcanza toda la organización.
  s.ruta('GET', '/v1/yo', (p) async {
    final dominios = p.s.dominios == null
        ? const <Map<String, Object?>>[]
        : await p.bd.filas(
            '''select id, nombre, slug from dt.dominio
                where org = @o and ${enDominios(p.s.dominios, 'id')} order by lower(nombre)''',
            {'o': p.s.org},
          );
    if (!p.s.esUsuario) {
      return Respuesta.ok({'org': p.s.org, 'llave': p.s.llave, 'rol': 'api', 'dominios': dominios});
    }
    final u = await p.bd.fila(
      '''select u.id, u.correo, u.nombre, u.rol, u.org, o.nombre as organizacion
           from dt.usuario u join dt.org o on o.id = u.org
          where u.id = @i''',
      {'i': p.s.usuario},
    );
    return u == null ? Respuesta.falla(404, 'no_encontrado', '') : Respuesta.ok({...u, 'dominios': dominios});
  });

  s.ruta('GET', '/v1/usuarios', (p) async {
    final r = await p.bd.filas(
      '''select id, correo, nombre, rol, dominios, creado, ultimo_acceso,
                clave_hash is not null as activo,
                invitacion_vence
           from dt.usuario where org = @o order by id''',
      {'o': p.s.org},
    );
    return Respuesta.ok({'usuarios': r});
  }, permiso: 'admin');

  // Invitar: la persona queda dada de alta sin clave, y lo que se devuelve es
  // el enlace (una sola vez: se guarda hasheado). El hub no manda correos;
  // el enlace lo comparte quien invita, por donde quiera.
  s.ruta('POST', '/v1/usuarios', (p) async {
    final correo = p.texto('correo').toLowerCase();
    final problema = _revisaCorreo(correo);
    if (problema != null) return problema;
    final rol = p.texto('rol', porDefecto: 'editor');
    if (!rolesValidos.contains(rol)) {
      return Respuesta.falla(400, 'rol_invalido', 'El rol es admin, editor o consulta');
    }
    final (dominios, error) = await dominiosDe(p, p.cuerpo['dominios']);
    if (error != null) return error;
    if (rol == 'admin' && dominios.isNotEmpty) return _adminSinDominios();
    if (await _correoOcupado(p.bd, correo)) {
      return Respuesta.falla(409, 'correo_en_uso', 'Ese correo ya tiene cuenta');
    }
    final u = await p.bd.fila(
      '''insert into dt.usuario (org, correo, nombre, rol, dominios)
         values (@o, @c, @n, @r, @d)
         returning id, correo, nombre, rol, dominios, creado''',
      {
        'o': p.s.org,
        'c': correo,
        'n': p.texto('nombre', porDefecto: correo.split('@').first),
        'r': rol,
        'd': dominios,
      },
    );
    final token = await nuevaInvitacion(p.bd, u!['id'] as int);
    return Respuesta.creado({...u, 'enlace': enlaceInvitacion(p.urlPublica, token)});
  }, permiso: 'admin');

  // Otro enlace para la misma persona (el anterior venció o se perdió). Sirve
  // también para que alguien que olvidó su clave la ponga de nuevo.
  s.ruta('POST', '/v1/usuarios/:id/invitacion', (p) async {
    final id = p.enteroParam('id');
    final u = await p.bd.fila(
      'select id from dt.usuario where id = @i and org = @o',
      {'i': id, 'o': p.s.org},
    );
    if (u == null) return Respuesta.falla(404, 'no_encontrado', '');
    final token = await nuevaInvitacion(p.bd, id);
    return Respuesta.ok({'enlace': enlaceInvitacion(p.urlPublica, token)});
  }, permiso: 'admin');

  // Cambia solo lo que viene: `rol`, `nombre`, `dominios`.
  s.ruta('PATCH', '/v1/usuarios/:id', (p) async {
    final id = p.enteroParam('id');
    final actual = await p.bd.fila(
      'select rol, dominios from dt.usuario where id = @i and org = @o',
      {'i': id, 'o': p.s.org},
    );
    if (actual == null) return Respuesta.falla(404, 'no_encontrado', '');
    final rol = p.cuerpo.containsKey('rol') ? p.texto('rol') : actual['rol'] as String;
    if (!rolesValidos.contains(rol)) {
      return Respuesta.falla(400, 'rol_invalido', 'El rol es admin, editor o consulta');
    }
    var dominios = [for (final d in actual['dominios'] as List) (d as num).toInt()];
    if (p.cuerpo.containsKey('dominios')) {
      final (pedidos, error) = await dominiosDe(p, p.cuerpo['dominios']);
      if (error != null) return error;
      dominios = pedidos;
    }
    if (id == p.s.usuario && (rol != 'admin' || dominios.isNotEmpty)) {
      return Respuesta.falla(400, 'no_te_bajes',
          'No te quites a ti mismo el rol de administrador: pídeselo a otro admin');
    }
    if (rol == 'admin' && dominios.isNotEmpty) return _adminSinDominios();
    final u = await p.bd.fila(
      '''update dt.usuario set rol = @r, dominios = @d, nombre = coalesce(nullif(@n, ''), nombre)
          where id = @i and org = @o
          returning id, correo, nombre, rol, dominios''',
      {'r': rol, 'd': dominios, 'n': p.texto('nombre'), 'i': id, 'o': p.s.org},
    );
    return u == null ? Respuesta.falla(404, 'no_encontrado', '') : Respuesta.ok(u);
  }, permiso: 'admin');

  s.ruta('POST', '/v1/usuarios/:id/clave', (p) async {
    final id = p.enteroParam('id');
    // Cada quien cambia la suya, y tiene que saber la de ahora. Un admin no
    // pone claves ajenas: genera otro enlace de invitación.
    if (id != p.s.usuario) {
      return Respuesta.falla(403, 'solo_la_tuya',
          'Solo puedes cambiar tu propia clave. A otra persona, mándale un enlace nuevo.');
    }
    final clave = p.texto('clave');
    final problema = _revisaClave(clave);
    if (problema != null) return problema;
    final u = await p.bd.fila(
      'select clave_hash from dt.usuario where id = @i',
      {'i': id},
    );
    final hash = u?['clave_hash'] as String?;
    if (hash == null || !Seguridad.verificaClave(p.texto('actual'), hash)) {
      return Respuesta.falla(400, 'clave_actual_mala', 'La clave actual no es esa');
    }
    await p.bd.ejecuta(
      'update dt.usuario set clave_hash = @h where id = @i',
      {'h': Seguridad.hashClave(clave), 'i': id},
    );
    return Respuesta.ok({'ok': true});
  }, acceso: Acceso.persona);

  s.ruta('DELETE', '/v1/usuarios/:id', (p) async {
    final id = p.enteroParam('id');
    if (id == p.s.usuario) {
      return Respuesta.falla(400, 'no_te_borres', 'No puedes borrar tu propio usuario');
    }
    await p.bd.ejecuta(
      'delete from dt.usuario where id = @i and org = @o',
      {'i': id, 'o': p.s.org},
    );
    return Respuesta.vacio();
  }, permiso: 'admin');
}

/// Crea una organización con un slug libre y su dominio General. Devuelve
/// su id.
Future<int> creaOrg(Bd bd, String nombre) async {
  final org = await bd.fila(
    'insert into dt.org (nombre, slug) values (@n, @s) returning id',
    {'n': nombre, 's': await _slugLibre(bd, nombre)},
  );
  final id = org!['id'] as int;
  await dominioGeneral(bd, id);
  return id;
}

/// Administrar es de toda la organización: quien queda limitado a unos
/// dominios es `editor` o `consulta`.
Respuesta _adminSinDominios() => Respuesta.falla(400, 'admin_sin_dominios',
    'Un administrador alcanza toda la organización: para limitarlo a unos dominios, hazlo editor o consulta');

/// Genera el enlace de un solo uso de [usuario] y lo deja guardado (hasheado).
/// Invalida cualquier enlace anterior de esa persona.
Future<String> nuevaInvitacion(Bd bd, int usuario) async {
  final token = Seguridad.token();
  await bd.ejecuta(
    '''update dt.usuario set invitacion_hash = @h, invitacion_vence = @v
        where id = @i''',
    {
      'h': Seguridad.hashToken(token),
      'v': DateTime.now().toUtc().add(vidaInvitacion),
      'i': usuario,
    },
  );
  return token;
}

String enlaceInvitacion(String urlPublica, String token) =>
    '$urlPublica/#/activar/$token';

Future<Map<String, Object?>?> _porInvitacion(Bd bd, String token) {
  if (token.isEmpty) return Future.value(null);
  return bd.fila(
    'select id, correo, invitacion_vence from dt.usuario where invitacion_hash = @h',
    {'h': Seguridad.hashToken(token)},
  );
}

Future<bool> _correoOcupado(Bd bd, String correo) async =>
    await bd.fila('select id from dt.usuario where correo = @c', {'c': correo}) != null;

Respuesta? _revisaCorreo(String correo) {
  if (!correo.contains('@') || correo.length < 5) {
    return Respuesta.falla(400, 'correo_invalido', 'Revisa el correo');
  }
  return null;
}

Respuesta? _revisaClave(String clave) {
  if (clave.length < 10) {
    return Respuesta.falla(400, 'clave_corta', 'La clave necesita 10 caracteres o más');
  }
  return null;
}

Map<String, Object?> _conToken(Map<String, Object?> u, String secreto) => {
      'token': Seguridad.firmaJwt(
        {'sub': u['id'], 'org': u['org'], 'rol': u['rol']},
        secreto,
      ),
      'usuario': {
        'id': u['id'],
        'correo': u['correo'],
        'nombre': u['nombre'],
        'rol': u['rol'],
        'org': u['org'],
      },
    };

Future<String> _slugLibre(Bd bd, String nombre) async {
  final base = nombre
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final raiz = base.isEmpty ? 'org' : base;
  for (var i = 0; i < 50; i++) {
    final intento = i == 0 ? raiz : '$raiz-$i';
    final ocupado = await bd.fila('select id from dt.org where slug = @s', {'s': intento});
    if (ocupado == null) return intento;
  }
  return '$raiz-${DateTime.now().millisecondsSinceEpoch}';
}
