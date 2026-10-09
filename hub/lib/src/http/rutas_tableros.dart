import 'dart:convert';

import '../ia/config.dart';
import '../ia/tableros.dart';
import 'servidor.dart';

/// Los tableros de la portada (migración 0007).
///
/// Quien no tiene uno propio ve el Resumen de siempre ([tableroInicial], id
/// 0). Con el asistente de IA encendido en la organización, cada persona arma
/// los suyos (o le pide al asistente que lo haga): copiar el Resumen y
/// cambiarlo, agregar otros. Sin IA se pueden renombrar, ordenar, quitar
/// paneles y borrar, pero no agregar ni cambiar paneles.
///
/// Los paneles se calculan con la sesión de quien mira: uno compartido le
/// enseña a cada quien solo lo que alcanza.
void registraRutasTableros(Servidor s) {
  const maxTableros = 30;

  Future<bool> conIa(Peticion p) async =>
      ConfigIa.deJson((await p.bd.fila('select ia from dt.org where id = @o', {'o': p.s.org}))?['ia'])?.disponible ??
      false;

  Respuesta sinIa() => Respuesta.falla(409, 'ia_no_disponible',
      'Armar y cambiar tableros es con el asistente de IA, y esta organización no lo tiene encendido');

  /// Un tablero que la persona ve: suyo, o compartido en su organización.
  Future<Map<String, Object?>?> ve(Peticion p, int id) async {
    if (id == 0) return {...tableroInicial};
    final t = await p.bd.fila(
      '''select t.id, t.nombre, t.compartido, t.orden, t.paneles, t.actualizado,
                t.usuario = @u as propio, u.nombre as de
           from dt.tablero t join dt.usuario u on u.id = t.usuario
          where t.id = @i and t.org = @o and (t.usuario = @u or t.compartido)''',
      {'i': id, 'o': p.s.org, 'u': p.s.usuario},
    );
    return t;
  }

  /// Uno propio, para cambiarlo.
  Future<Map<String, Object?>?> propio(Peticion p, int id) => p.bd.fila(
    '''select id, nombre, compartido, orden, paneles from dt.tablero
        where id = @i and org = @o and usuario = @u''',
    {'i': id, 'o': p.s.org, 'u': p.s.usuario},
  );

  List<Map<String, Object?>> panelesDe(Map<String, Object?> t) =>
      [for (final x in (t['paneles'] as List?) ?? const []) (x as Map).cast<String, Object?>()];

  /// Valida el panel y lo prueba con los datos de quien lo arma: si falla,
  /// no se guarda (y el asistente lee por qué).
  Future<(Map<String, Object?>?, Respuesta?)> pruebaPanel(Peticion p, Map<String, Object?> crudo, {String? id}) async {
    final (panel, error) = validaPanel(crudo, id: id);
    if (error != null) return (null, Respuesta.falla(400, 'panel_invalido', error));
    final datos = (await datosDePaneles(s, p.s, [panel!])).single;
    if (datos['error'] != null) {
      return (null, Respuesta.falla(400, 'panel_invalido', 'El panel no sale: ${datos['error']}'));
    }
    return (panel, null);
  }

  Future<Map<String, Object?>> guarda(Peticion p, int id, List<Map<String, Object?>> paneles) async =>
      (await p.bd.fila(
        '''update dt.tablero set paneles = @p::jsonb, actualizado = now()
            where id = @i and org = @o and usuario = @u
            returning id, nombre, compartido, orden, paneles, actualizado''',
        {'p': jsonEncode(paneles), 'i': id, 'o': p.s.org, 'u': p.s.usuario},
      ))!;

  s.ruta('GET', '/v1/tableros', (p) async {
    final propios = await p.bd.filas(
      '''select id, nombre, compartido, orden, paneles, actualizado, true as propio
           from dt.tablero where org = @o and usuario = @u order by orden, id''',
      {'o': p.s.org, 'u': p.s.usuario},
    );
    final ajenos = await p.bd.filas(
      '''select t.id, t.nombre, t.compartido, t.orden, t.paneles, t.actualizado, false as propio, u.nombre as de
           from dt.tablero t join dt.usuario u on u.id = t.usuario
          where t.org = @o and t.usuario <> @u and t.compartido order by lower(t.nombre), t.id''',
      {'o': p.s.org, 'u': p.s.usuario},
    );
    return Respuesta.ok({
      'tableros': [if (propios.isEmpty) tableroInicial, ...propios, ...ajenos],
      'ia': await conIa(p),
    });
  }, acceso: Acceso.persona);

  s.ruta('GET', '/v1/tableros/:id', (p) async {
    final t = await ve(p, p.enteroParam('id'));
    return t == null ? Respuesta.falla(404, 'no_encontrado', 'Ese tablero no existe') : Respuesta.ok(t);
  }, acceso: Acceso.persona);

  s.ruta('GET', '/v1/tableros/:id/datos', (p) async {
    final t = await ve(p, p.enteroParam('id'));
    if (t == null) return Respuesta.falla(404, 'no_encontrado', 'Ese tablero no existe');
    final datos = await datosDePaneles(s, p.s, panelesDe(t));
    return Respuesta.ok({...t, 'paneles': datos});
  }, acceso: Acceso.persona);

  s.ruta('POST', '/v1/tableros', (p) async {
    if (!await conIa(p)) return sinIa();
    final nombre = p.texto('nombre');
    if (nombre.isEmpty || nombre.length > 80) {
      return Respuesta.falla(400, 'falta_nombre', 'Ponle nombre al tablero (hasta 80 letras)');
    }
    final cuenta = await p.bd.fila(
      'select count(*)::int as n, coalesce(max(orden), -1)::int as ultimo from dt.tablero where org = @o and usuario = @u',
      {'o': p.s.org, 'u': p.s.usuario},
    );
    if ((cuenta!['n'] as int) >= maxTableros) {
      return Respuesta.falla(409, 'demasiados_tableros', 'Hasta $maxTableros tableros por persona');
    }
    final paneles = <Map<String, Object?>>[
      if (p.cuerpo['desde_resumen'] == true) ...panelesDe(tableroInicial),
    ];
    for (final crudo in (p.cuerpo['paneles'] as List?) ?? const []) {
      if (crudo is! Map) return Respuesta.falla(400, 'panel_invalido', 'Cada panel es un objeto');
      final (panel, error) = await pruebaPanel(p, crudo.cast<String, Object?>());
      if (error != null) return error;
      paneles.add(panel!);
    }
    if (paneles.length > maxPaneles) {
      return Respuesta.falla(400, 'demasiados_paneles', 'Hasta $maxPaneles paneles por tablero');
    }
    final t = await p.bd.fila(
      '''insert into dt.tablero (org, usuario, nombre, compartido, orden, paneles)
         values (@o, @u, @n, @c, @or, @p::jsonb)
         returning id, nombre, compartido, orden, paneles, actualizado, true as propio''',
      {
        'o': p.s.org,
        'u': p.s.usuario,
        'n': nombre,
        'c': p.cuerpo['compartido'] == true,
        'or': (cuenta['ultimo'] as int) + 1,
        'p': jsonEncode(paneles),
      },
    );
    return Respuesta.creado(t);
  }, acceso: Acceso.persona);

  // Renombrar y compartir: también sin IA.
  s.ruta('PATCH', '/v1/tableros/:id', (p) async {
    final id = p.enteroParam('id');
    final t = await propio(p, id);
    if (t == null) return Respuesta.falla(404, 'no_encontrado', 'Ese tablero no existe o no es tuyo');
    final nombre = p.cuerpo.containsKey('nombre') ? p.texto('nombre') : t['nombre'] as String;
    if (nombre.isEmpty || nombre.length > 80) {
      return Respuesta.falla(400, 'falta_nombre', 'Ponle nombre al tablero (hasta 80 letras)');
    }
    final compartido = p.cuerpo['compartido'] is bool ? p.cuerpo['compartido'] as bool : t['compartido'] as bool;
    final r = await p.bd.fila(
      '''update dt.tablero set nombre = @n, compartido = @c, actualizado = now()
          where id = @i returning id, nombre, compartido, orden, paneles, actualizado, true as propio''',
      {'n': nombre, 'c': compartido, 'i': id},
    );
    return Respuesta.ok(r);
  }, acceso: Acceso.persona);

  s.ruta('DELETE', '/v1/tableros/:id', (p) async {
    await p.bd.ejecuta(
      'delete from dt.tablero where id = @i and org = @o and usuario = @u',
      {'i': p.enteroParam('id'), 'o': p.s.org, 'u': p.s.usuario},
    );
    return Respuesta.vacio();
  }, acceso: Acceso.persona);

  // El orden de las pestañas: `{ids: [3, 1, 2]}` con los propios.
  s.ruta('POST', '/v1/tableros/orden', (p) async {
    final ids = [for (final x in (p.cuerpo['ids'] as List?) ?? const []) if (x is num) x.toInt()];
    await p.bd.transaccion((tx) async {
      for (final (i, id) in ids.indexed) {
        await tx.ejecuta(
          'update dt.tablero set orden = @n where id = @i and org = @o and usuario = @u',
          {'n': i, 'i': id, 'o': p.s.org, 'u': p.s.usuario},
        );
      }
    });
    return Respuesta.ok({'ok': true});
  }, acceso: Acceso.persona);

  s.ruta('POST', '/v1/tableros/:id/paneles', (p) async {
    if (!await conIa(p)) return sinIa();
    final id = p.enteroParam('id');
    final t = await propio(p, id);
    if (t == null) return Respuesta.falla(404, 'no_encontrado', 'Ese tablero no existe o no es tuyo');
    final paneles = panelesDe(t);
    if (paneles.length >= maxPaneles) {
      return Respuesta.falla(409, 'demasiados_paneles', 'Hasta $maxPaneles paneles por tablero');
    }
    final crudo = {...p.cuerpo}..remove('posicion');
    final (panel, error) = await pruebaPanel(p, crudo);
    if (error != null) return error;
    if (paneles.any((x) => x['id'] == panel!['id'])) panel!['id'] = '${panel['id']}-${paneles.length}';
    final pos = (p.entero('posicion') ?? paneles.length).clamp(0, paneles.length);
    paneles.insert(pos, panel!);
    return Respuesta.creado(await guarda(p, id, paneles));
  }, acceso: Acceso.persona);

  s.ruta('PUT', '/v1/tableros/:id/paneles/:panel', (p) async {
    if (!await conIa(p)) return sinIa();
    final id = p.enteroParam('id');
    final t = await propio(p, id);
    if (t == null) return Respuesta.falla(404, 'no_encontrado', 'Ese tablero no existe o no es tuyo');
    final paneles = panelesDe(t);
    final i = paneles.indexWhere((x) => x['id'] == p.params['panel']);
    if (i < 0) return Respuesta.falla(404, 'no_encontrado', 'Ese panel no está en el tablero');
    final crudo = {...p.cuerpo}..remove('posicion');
    final (panel, error) = await pruebaPanel(p, crudo, id: p.params['panel']);
    if (error != null) return error;
    paneles.removeAt(i);
    paneles.insert((p.entero('posicion') ?? i).clamp(0, paneles.length), panel!);
    return Respuesta.ok(await guarda(p, id, paneles));
  }, acceso: Acceso.persona);

  // Quitar un panel: también sin IA.
  s.ruta('DELETE', '/v1/tableros/:id/paneles/:panel', (p) async {
    final id = p.enteroParam('id');
    final t = await propio(p, id);
    if (t == null) return Respuesta.falla(404, 'no_encontrado', 'Ese tablero no existe o no es tuyo');
    final paneles = panelesDe(t)..removeWhere((x) => x['id'] == p.params['panel']);
    return Respuesta.ok(await guarda(p, id, paneles));
  }, acceso: Acceso.persona);
}
