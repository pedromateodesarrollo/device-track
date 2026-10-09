import 'dart:convert';
import 'dart:io';

import '../correo.dart';
import '../ia/asistente.dart';
import '../ia/config.dart';
import '../ia/proveedor.dart';
import '../log.dart';
import 'servidor.dart';

/// El chat del asistente de IA (migración 0007): las conversaciones son de
/// cada persona, y lo que el asistente propone cambiar lo confirma ella.
///
/// `POST /v1/ia/chat` contesta en NDJSON (una línea JSON por evento) para que
/// la pantalla vea avanzar las consultas: `conversacion`, `nota`,
/// `herramienta`, `propuesta`, `respuesta`, `fin` o `error`.
void registraRutasAsistente(Servidor s, {Uri? base}) {
  final asistente = Asistente(s, base: base);
  const maxVista = 80; // 40 preguntas: más, y conviene empezar otra

  Future<ConfigIa?> config(Peticion p) async {
    final c = ConfigIa.deJson((await p.bd.fila('select ia from dt.org where id = @o', {'o': p.s.org}))?['ia']);
    return (c?.disponible ?? false) ? c : null;
  }

  Respuesta sinIa() => Respuesta.falla(409, 'ia_no_disponible',
      'Esta organización no tiene el asistente encendido: quien administra lo configura en Organización → Asistente IA');

  s.ruta('POST', '/v1/ia/chat', (p) async {
    final c = await config(p);
    if (c == null) return sinIa();
    final mensaje = p.texto('mensaje');
    if (mensaje.isEmpty || mensaje.length > 8000) {
      return Respuesta.falla(400, 'falta_mensaje', 'Escribe la pregunta (hasta 8000 letras)');
    }
    final desfase = (p.entero('desfase_min') ?? 0).clamp(-14 * 60, 14 * 60);

    // La conversación: la que dice, si es suya y del mismo modelo; si no, una
    // nueva. Lo que pensó un modelo no le sirve a otro.
    var conv = p.entero('conversacion') == null
        ? null
        : await p.bd.fila(
            '''select id, titulo, proveedor, modelo, mensajes, vista, pendientes from dt.ia_conversacion
                where id = @i and org = @o and usuario = @u''',
            {'i': p.entero('conversacion'), 'o': p.s.org, 'u': p.s.usuario},
          );
    if (conv != null && (conv['proveedor'] != c.proveedor || conv['modelo'] != c.modelo)) conv = null;
    if (conv != null && ((conv['vista'] as List?)?.length ?? 0) >= maxVista) {
      return Respuesta.falla(409, 'conversacion_larga', 'Esta conversación ya es muy larga: empieza una nueva');
    }
    conv ??= await p.bd.fila(
      '''insert into dt.ia_conversacion (org, usuario, titulo, proveedor, modelo)
         values (@o, @u, @t, @p, @m)
         returning id, titulo, proveedor, modelo, mensajes, vista, pendientes''',
      {
        'o': p.s.org,
        'u': p.s.usuario,
        't': mensaje.length > 70 ? '${mensaje.substring(0, 70)}…' : mensaje,
        'p': c.proveedor,
        'm': c.modelo,
      },
    );
    final id = conv!['id'] as int;

    final yo = await p.bd.fila(
      '''select u.nombre, u.correo, u.rol, o.nombre as organizacion, o.correo as correo_org
           from dt.usuario u join dt.org o on o.id = u.org where u.id = @u''',
      {'u': p.s.usuario},
    );
    final dominios = p.s.dominios == null
        ? const <String>[]
        : [
            for (final d in await p.bd.filas(
              'select nombre from dt.dominio where org = @o and id = any(@d) order by lower(nombre)',
              {'o': p.s.org, 'd': p.s.dominios},
            ))
              '${d['nombre']}',
          ];
    final persona = Persona(
      nombre: '${yo!['nombre']}',
      correo: '${yo['correo']}',
      rol: '${yo['rol']}',
      organizacion: '${yo['organizacion']}',
      dominios: dominios,
      correoDeSalida: ConfigCorreo.deJson(yo['correo_org'])?.completa ?? false,
    );
    final pendientes = [for (final x in (conv['pendientes'] as List?) ?? const []) (x as Map).cast<String, Object?>()];
    final texto = '${contextoDePregunta(ahoraUtc: DateTime.now().toUtc(), desfaseMin: desfase, pendientes: pendientes)}\n$mensaje';

    // Desde aquí, NDJSON. nginx no debe juntar las líneas.
    final res = p.crudo!.response
      ..statusCode = 200
      ..headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8')
      ..headers.set('cache-control', 'no-cache')
      ..headers.set('x-accel-buffering', 'no');
    // Las líneas van en fila: dos `flush` a la vez son un error de dart:io.
    var abierta = true;
    var cola = Future<void>.value();
    Future<void> emite(Map<String, Object?> e) => cola = cola.then((_) async {
      if (!abierta) return;
      try {
        res.write('${jsonEncode(e, toEncodable: (v) => v is DateTime ? v.toUtc().toIso8601String() : v.toString())}\n');
        await res.flush();
      } catch (_) {
        abierta = false; // se fue: se termina igual y se guarda
      }
    });

    await emite({'tipo': 'conversacion', 'id': id, 'titulo': conv['titulo']});
    try {
      final r = await asistente.pregunta(
        config: c,
        sesion: p.s,
        persona: persona,
        conversacion: id,
        mensajes: [for (final m in (conv['mensajes'] as List?) ?? const []) (m as Map).cast<String, Object?>()],
        texto: texto,
        emite: (e) => emite(e),
        urlPublica: p.urlPublica,
      );
      final ahora = DateTime.now().toUtc().toIso8601String();
      final vista = [
        {'rol': 'persona', 'texto': mensaje, 't': ahora},
        {
          'rol': 'asistente',
          'texto': r.texto,
          'herramientas': r.herramientas,
          'propuestas': [for (final x in r.propuestas) x['id']],
          't': ahora,
        },
      ];
      await p.bd.ejecuta(
        '''update dt.ia_conversacion
              set mensajes = @m::jsonb, vista = vista || @v::jsonb, pendientes = '[]'::jsonb, actualizado = now()
            where id = @i''',
        {'m': jsonEncode(r.mensajes), 'v': jsonEncode(vista), 'i': id},
      );
      await emite({'tipo': 'respuesta', 'texto': r.texto});
      await emite({
        'tipo': 'fin',
        'conversacion': id,
        'uso': {'entrada': r.uso.entrada, 'salida': r.uso.salida},
      });
    } on IaError catch (e) {
      // La pregunta no queda: la conversación sigue como estaba.
      await emite({'tipo': 'error', 'error': e.codigo, 'mensaje': e.detalle});
    } catch (e, t) {
      final ref = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      log.error('asistente', 'err:$ref conversación $id → $e\n$t');
      await emite({'tipo': 'error', 'error': 'error_interno', 'mensaje': 'Error interno. Referencia: $ref'});
    }
    await cola;
    try {
      await res.close();
    } catch (_) {}
    return Respuesta.yaEscrita();
  }, acceso: Acceso.persona);

  s.ruta('GET', '/v1/ia/conversaciones', (p) async {
    final r = await p.bd.filas(
      '''select id, titulo, proveedor, modelo, creado, actualizado,
                jsonb_array_length(vista) / 2 as preguntas
           from dt.ia_conversacion where org = @o and usuario = @u
          order by actualizado desc limit 50''',
      {'o': p.s.org, 'u': p.s.usuario},
    );
    return Respuesta.ok({'conversaciones': r, 'ia': await config(p) != null});
  }, acceso: Acceso.persona);

  s.ruta('GET', '/v1/ia/conversaciones/:id', (p) async {
    final c = await p.bd.fila(
      '''select id, titulo, proveedor, modelo, vista, creado, actualizado from dt.ia_conversacion
          where id = @i and org = @o and usuario = @u''',
      {'i': p.enteroParam('id'), 'o': p.s.org, 'u': p.s.usuario},
    );
    if (c == null) return Respuesta.falla(404, 'no_encontrado', 'Esa conversación no existe');
    final propuestas = await p.bd.filas(
      '''select id, herramienta, args, resumen, estado, resultado, creado, resuelta, vence < now() as vencida
           from dt.ia_propuesta where conversacion = @c order by id''',
      {'c': c['id']},
    );
    return Respuesta.ok({...c, 'propuestas': propuestas});
  }, acceso: Acceso.persona);

  s.ruta('DELETE', '/v1/ia/conversaciones/:id', (p) async {
    await p.bd.ejecuta(
      'delete from dt.ia_conversacion where id = @i and org = @o and usuario = @u',
      {'i': p.enteroParam('id'), 'o': p.s.org, 'u': p.s.usuario},
    );
    return Respuesta.vacio();
  }, acceso: Acceso.persona);

  /// Toma la propuesta para resolverla: solo una vez, solo su dueña, y solo
  /// si no venció.
  Future<(Map<String, Object?>?, Respuesta?)> toma(Peticion p) async {
    final pr = await p.bd.fila(
      '''select id, conversacion, herramienta, args, resumen, estado, vence < now() as vencida
           from dt.ia_propuesta where id = @i and org = @o and usuario = @u''',
      {'i': p.enteroParam('id'), 'o': p.s.org, 'u': p.s.usuario},
    );
    if (pr == null) return (null, Respuesta.falla(404, 'no_encontrado', 'Esa propuesta no existe'));
    if (pr['estado'] != 'pendiente') {
      return (null, Respuesta.falla(409, 'propuesta_resuelta', 'Esa propuesta ya se resolvió (${pr['estado']})'));
    }
    if (pr['vencida'] == true) {
      return (null, Respuesta.falla(409, 'propuesta_vencida', 'Esa propuesta venció: pídesela de nuevo al asistente'));
    }
    return (pr, null);
  }

  Future<void> anota(Peticion p, Map<String, Object?> pr, String estado, Object? resultado) async {
    final mensaje = resultado is Map ? resultado['mensaje'] ?? resultado['error'] : null;
    await p.bd.ejecuta(
      '''update dt.ia_propuesta set estado = @e, resultado = @r::jsonb, resuelta = now() where id = @i''',
      {'e': estado, 'r': jsonEncode(resultado, toEncodable: (v) => v.toString()), 'i': pr['id']},
    );
    // El asistente se entera con la pregunta siguiente.
    await p.bd.ejecuta(
      '''update dt.ia_conversacion set pendientes = pendientes || @n::jsonb where id = @c''',
      {
        'c': pr['conversacion'],
        'n': jsonEncode([
          {'resumen': pr['resumen'], 'estado': estado, 'mensaje': ?mensaje},
        ]),
      },
    );
  }

  // Se ejecuta con la sesión de quien confirma, ahora: si entre tanto le
  // quitaron el permiso o el equipo cambió de dominio, no se hace.
  s.ruta('POST', '/v1/ia/propuestas/:id/confirmar', (p) async {
    final (pr, error) = await toma(p);
    if (error != null) return error;
    final args = (pr!['args'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
    final r = await asistente.ejecuta('${pr['herramienta']}', args, p.s, urlPublica: p.urlPublica);
    final fallo = r is Map && r['error'] != null;
    await anota(p, pr, fallo ? 'fallida' : 'hecha', r);
    return Respuesta.ok({'id': pr['id'], 'estado': fallo ? 'fallida' : 'hecha', 'resultado': r});
  }, acceso: Acceso.persona);

  s.ruta('POST', '/v1/ia/propuestas/:id/descartar', (p) async {
    final (pr, error) = await toma(p);
    if (error != null) return error;
    await anota(p, pr!, 'descartada', null);
    return Respuesta.ok({'id': pr['id'], 'estado': 'descartada'});
  }, acceso: Acceso.persona);
}
