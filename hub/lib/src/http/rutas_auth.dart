import 'dart:async';

import '../correo.dart';
import '../db.dart';
import '../dominios.dart';
import '../ia/config.dart';
import '../limitador.dart';
import '../log.dart';
import '../seguridad.dart';
import 'rutas_dominios.dart';
import 'servidor.dart';

/// Cuánto vale un enlace de invitación.
const vidaInvitacion = Duration(days: 7);

/// Cuánto vale el enlace de «¿Olvidaste tu clave?»: lo pide la persona y lo
/// usa en el momento, así que una hora basta y deja poca ventana a quien lea
/// su correo después.
const vidaRecuperacion = Duration(hours: 1);

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
  // «¿Olvidaste tu clave?» manda un correo a quien diga el formulario: por IP
  // frena a quien prueba correos, y por correo, a quien quiere llenarle el
  // buzón a alguien.
  final frenoRecuperarIp = Limitador(cupo: 5, ventana: const Duration(minutes: 1));
  final frenoRecuperarCorreo = Limitador(cupo: 3, ventana: const Duration(hours: 1));

  // `recuperar`: si alguna organización tiene correo de salida, la entrada
  // enseña «¿Olvidaste tu clave?». Sin un correo por donde mandar el enlace no
  // hay recuperación posible, y no se ofrece. Tampoco sin DT_URL_PUBLICA: el
  // enlace no puede armarse con el Host de la petición, que lo escribe quien
  // la manda (pediría la clave de otro y el token llegaría a su página).
  s.ruta('GET', '/salud', (p) async {
    await p.bd.fila('select 1 as ok');
    return Respuesta.ok({
      'ok': true,
      'servicio': 'device-track',
      'registro': p.config.registro,
      'recuperar': p.config.urlPublica.isNotEmpty && await _hayCorreoDeSalida(p.bd),
    });
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

  // «¿Olvidaste tu clave?»: si el correo tiene cuenta y su organización tiene
  // correo de salida, le llega un enlace para poner una clave nueva (el mismo
  // de la invitación, que vence en una hora). La respuesta es siempre la misma
  // y el correo sale después de contestar: ni el contenido ni lo que tarda
  // dicen si el correo tiene cuenta. La clave de antes sigue valiendo hasta
  // que se use el enlace.
  s.ruta('POST', '/v1/auth/recuperar', (p) async {
    final correo = p.texto('correo').toLowerCase();
    if (!frenoRecuperarIp.cabe('recuperar:${p.ip}') || !frenoRecuperarCorreo.cabe('recuperar:$correo')) {
      return Respuesta.falla(429, 'demasiados_intentos', 'Ya pediste varios enlaces: espera un rato y revisa tu correo');
    }
    final problema = _revisaCorreo(correo);
    if (problema != null) return problema;
    final u = await p.bd.fila(
      '''select u.id, u.correo, u.nombre, o.nombre as organizacion, o.correo as correo_org
           from dt.usuario u join dt.org o on o.id = u.org
          where u.correo = @c''',
      {'c': correo},
    );
    final c = ConfigCorreo.deJson(u?['correo_org']);
    if (u != null && c != null && c.completa && p.config.urlPublica.isNotEmpty) {
      log.info('auth', 'recuperación pedida: usuario ${u['id']}');
      unawaited(_mandaRecuperacion(
        p.bd,
        c,
        usuario: u['id'] as int,
        para: '${u['correo']}',
        nombre: '${u['nombre']}',
        org: '${u['organizacion']}',
        urlPublica: p.config.urlPublica,
      ));
    }
    return Respuesta.ok({'pedido': true});
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
        'El enlace venció o ya se usó. Pide otro: en la entrada, «¿Olvidaste tu clave?», o a quien administra.',
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
      '''select u.id, u.correo, u.nombre, u.rol, u.org, o.nombre as organizacion, o.ia
           from dt.usuario u join dt.org o on o.id = u.org
          where u.id = @i''',
      {'i': p.s.usuario},
    );
    if (u == null) return Respuesta.falla(404, 'no_encontrado', '');
    // Si la organización tiene asistente: el panel enseña el chat y deja
    // cambiar los tableros. Las credenciales no salen de aquí.
    final ia = ConfigIa.deJson(u.remove('ia'))?.disponible ?? false;
    return Respuesta.ok({...u, 'dominios': dominios, 'ia': ia});
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
  // el enlace (una sola vez: se guarda hasheado). Si la organización tiene
  // correo de salida (migración 0003), además se lo manda; si no, el enlace lo
  // comparte quien invita, por donde quiera. `envio` dice cuál de las dos.
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
    final enlace = enlaceInvitacion(p.urlPublica, token);
    return Respuesta.creado({
      ...u,
      'enlace': enlace,
      'envio': await _mandaInvitacion(p, correo, '${u['nombre']}', enlace),
    });
  }, permiso: 'admin');

  // Otro enlace para la misma persona (el anterior venció o se perdió). Sirve
  // también para que alguien que olvidó su clave la ponga de nuevo.
  s.ruta('POST', '/v1/usuarios/:id/invitacion', (p) async {
    final id = p.enteroParam('id');
    final u = await p.bd.fila(
      'select id, correo, nombre from dt.usuario where id = @i and org = @o',
      {'i': id, 'o': p.s.org},
    );
    if (u == null) return Respuesta.falla(404, 'no_encontrado', '');
    final token = await nuevaInvitacion(p.bd, id);
    final enlace = enlaceInvitacion(p.urlPublica, token);
    return Respuesta.ok({
      'enlace': enlace,
      'envio': await _mandaInvitacion(p, '${u['correo']}', '${u['nombre']}', enlace),
    });
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
/// Invalida cualquier enlace anterior de esa persona. El de «¿Olvidaste tu
/// clave?» es el mismo, con [vida] de una hora.
Future<String> nuevaInvitacion(Bd bd, int usuario, {Duration vida = vidaInvitacion}) async {
  final token = Seguridad.token();
  await bd.ejecuta(
    '''update dt.usuario set invitacion_hash = @h, invitacion_vence = @v
        where id = @i''',
    {
      'h': Seguridad.hashToken(token),
      'v': DateTime.now().toUtc().add(vida),
      'i': usuario,
    },
  );
  return token;
}

/// Manda el enlace de invitación por el correo de salida de la organización.
/// Devuelve `null` si no hay correo configurado (el enlace se comparte a
/// mano), `{enviado: true, para}` o `{enviado: false, error, detalle}`: que no
/// salga el correo no deshace la invitación, el enlace sigue sirviendo.
Future<Map<String, Object?>?> _mandaInvitacion(Peticion p, String para, String nombre, String enlace) async {
  final o = await p.bd.fila('select nombre, correo from dt.org where id = @o', {'o': p.s.org});
  final c = ConfigCorreo.deJson(o?['correo']);
  if (c == null || !c.completa) return null;
  final org = '${o?['nombre'] ?? ''}';
  final dias = vidaInvitacion.inDays;
  try {
    await enviaCorreo(
      c,
      para: para,
      asunto: 'Te invitaron al panel de device-track de $org',
      texto: 'Hola, $nombre:\n\n'
          'Te invitaron al panel de device-track de $org, donde se ven los equipos, '
          'dónde están y si siguen vivos.\n\n'
          'Para entrar, pon tu clave aquí (el enlace sirve una vez y vence en $dias días):\n'
          '$enlace\n\n'
          'Si no esperabas este correo, ignóralo.',
      html: '<div style="font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;'
          'max-width:560px;margin:0 auto;padding:16px;color:#1f2328">'
          '<p>Hola, ${_html(nombre)}:</p>'
          '<p>Te invitaron al panel de <strong>device-track</strong> de ${_html(org)}, '
          'donde se ven los equipos, dónde están y si siguen vivos.</p>'
          '<p style="margin:24px 0"><a href="${_html(enlace)}" style="background:#3b82f6;'
          'color:#fff;padding:12px 20px;border-radius:8px;text-decoration:none">'
          'Poner mi clave</a></p>'
          '<p style="font-size:13px;color:#57606a">El enlace sirve una vez y vence en $dias días. '
          'Si no esperabas este correo, ignóralo.</p></div>',
    );
    return {'enviado': true, 'para': para};
  } on CorreoError catch (e) {
    log.aviso('correo', 'invitación a $para no salió: ${e.codigo} ${e.detalle}');
    return {'enviado': false, 'error': e.codigo, 'detalle': e.detalle};
  }
}

/// El enlace y el correo de «¿Olvidaste tu clave?». Corre después de
/// contestar, para que la respuesta tarde lo mismo tenga o no cuenta el
/// correo; si no sale, queda en el log y la persona puede pedir otro.
Future<void> _mandaRecuperacion(
  Bd bd,
  ConfigCorreo c, {
  required int usuario,
  required String para,
  required String nombre,
  required String org,
  required String urlPublica,
}) async {
  final minutos = vidaRecuperacion.inMinutes;
  try {
    final enlace = enlaceInvitacion(urlPublica, await nuevaInvitacion(bd, usuario, vida: vidaRecuperacion));
    await enviaCorreo(
      c,
      para: para,
      asunto: 'Clave nueva para el panel de device-track',
      texto: 'Hola, $nombre:\n\n'
          'Pediste poner una clave nueva para el panel de device-track de $org.\n\n'
          'Ponla aquí (el enlace sirve una vez y vence en $minutos minutos):\n'
          '$enlace\n\n'
          'Si no lo pediste tú, ignora este correo: tu clave sigue igual.',
      html: '<div style="font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;'
          'max-width:560px;margin:0 auto;padding:16px;color:#1f2328">'
          '<p>Hola, ${_html(nombre)}:</p>'
          '<p>Pediste poner una clave nueva para el panel de <strong>device-track</strong> '
          'de ${_html(org)}.</p>'
          '<p style="margin:24px 0"><a href="${_html(enlace)}" style="background:#3b82f6;'
          'color:#fff;padding:12px 20px;border-radius:8px;text-decoration:none">'
          'Poner mi clave nueva</a></p>'
          '<p style="font-size:13px;color:#57606a">El enlace sirve una vez y vence en $minutos minutos. '
          'Si no lo pediste tú, ignora este correo: tu clave sigue igual.</p></div>',
    );
  } on CorreoError catch (e) {
    log.aviso('correo', 'recuperación a $para no salió: ${e.codigo} ${e.detalle}');
  } catch (e) {
    log.aviso('correo', 'recuperación a $para no salió: $e');
  }
}

/// Si alguna organización tiene correo de salida: sin él no hay por dónde
/// mandar el enlace de «¿Olvidaste tu clave?».
Future<bool> _hayCorreoDeSalida(Bd bd) async {
  final filas = await bd.filas("select correo from dt.org where correo <> '{}'::jsonb");
  return filas.any((f) => ConfigCorreo.deJson(f['correo'])?.completa ?? false);
}

String _html(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

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
