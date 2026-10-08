import 'dart:convert';

import '../alertas.dart';
import '../db.dart';
import '../dominios.dart';
import '../ordenes.dart';
import '../seguridad.dart';
import '../ws/canal.dart';
import 'rutas_dominios.dart';
import 'servidor.dart';

/// Lo que usa quien administra: el panel, un script, un ERP.
///
/// Toda consulta filtra por la organización de la sesión (`p.s.org`); ninguna
/// toma un `org` del cuerpo. Un id de equipo de otra organización es, para
/// esta, un equipo que no existe. Y dentro de la organización, por los
/// dominios que la sesión alcanza (`enDominios`): un equipo de otro dominio
/// tampoco existe para quien no lo alcanza.
void registraRutasPanel(Servidor s, Canal canal, Ordenes ordenes, Alertas alertas) {
  // ------------------------------------------------------------- equipos

  s.ruta('GET', '/v1/resumen', (p) async {
    final r = await p.bd.fila(
      '''select count(*) filter (where estado <> 'retirado') as equipos,
                count(*) filter (where conectado) as conectados,
                count(*) filter (where estado = 'perdido') as perdidos,
                count(*) filter (where estado in ('activo', 'perdido') and not conectado
                                   and ultima_vez < now() - interval '24 hours') as sin_contacto_24h,
                (select count(*) from dt.alerta a join dt.equipo x on x.id = a.equipo
                  where a.org = @o and a.cerrada is null
                    and ${enDominios(p.s.dominios, 'x.dominio')}) as alertas
           from dt.equipo e where e.org = @o and ${enDominios(p.s.dominios, 'e.dominio')}''',
      {'o': p.s.org},
    );
    return Respuesta.ok(r);
  });

  s.ruta('GET', '/v1/equipos', (p) async {
    final q = p.consulta;
    final filtros = <String>['e.org = @o', enDominios(p.s.dominios, 'e.dominio')];
    final params = <String, Object?>{'o': p.s.org};
    final texto = (q['q'] ?? '').trim();
    if (texto.isNotEmpty) {
      filtros.add('''(e.nombre ilike @q or e.etiqueta ilike @q or e.serie ilike @q
                      or e.modelo ilike @q or e.asignado_a ilike @q or e.huella ilike @q)''');
      params['q'] = '%${texto.replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
    }
    if ((q['dominio'] ?? '').isNotEmpty) {
      final dominio = await buscaDominio(p, q['dominio']);
      if (dominio == null) return _dominioInvalido();
      filtros.add('e.dominio = @d');
      params['d'] = dominio;
    }
    if ((q['estado'] ?? '').isNotEmpty) {
      filtros.add('e.estado = @s');
      params['s'] = q['estado'];
    } else if (q['retirados'] != '1') {
      filtros.add("e.estado <> 'retirado'");
    }
    // La misma cuenta que «sin contacto 24 h» del resumen.
    if (q['sin_contacto'] == '1') {
      filtros.add('''e.estado in ('activo', 'perdido') and not e.conectado
                     and e.ultima_vez < now() - interval '24 hours' ''');
    }
    if (q['conectado'] == '1') filtros.add('e.conectado');
    if (q['conectado'] == '0') filtros.add('not e.conectado');
    if (q['alerta'] == '1') {
      filtros.add('exists (select 1 from dt.alerta a where a.equipo = e.id and a.cerrada is null)');
    }
    final r = await p.bd.filas(
      '''select ${_columnasEquipo('e')},
                (select count(*) from dt.alerta a where a.equipo = e.id and a.cerrada is null) as alertas,
                (select coalesce(jsonb_agg(jsonb_build_object(
                          'tipo', f.tipo, 'paquete', f.paquete, 'version', f.version,
                          'ultima_vez', f.ultima_vez, 'contexto', f.contexto)
                        order by f.ultima_vez desc), '[]'::jsonb)
                   from dt.fuente f where f.equipo = e.id and f.revocada is null) as fuentes
           from dt.equipo e
          where ${filtros.join(' and ')}
          order by lower(e.nombre), e.id
          limit 2000''',
      params,
    );
    return Respuesta.ok({'equipos': r});
  });

  s.ruta('GET', '/v1/equipos/:id', (p) async {
    final id = p.enteroParam('id');
    final e = await p.bd.fila(
      'select ${_columnasEquipo('e')}, e.huella, e.notas, e.apps, e.apps_t, e.primera_vez, e.alta '
      'from dt.equipo e where e.id = @i and e.org = @o and ${enDominios(p.s.dominios, 'e.dominio')}',
      {'i': id, 'o': p.s.org},
    );
    if (e == null) return _noEsta();
    final fuentes = await p.bd.filas(
      '''select id, tipo, paquete, version, build, contexto, creado, ultima_vez, revocada
           from dt.fuente where equipo = @i order by ultima_vez desc''',
      {'i': id},
    );
    final alertasAbiertas = await p.bd.filas(
      '''select a.id, a.tipo, a.abierta, a.detalle, r.nombre as regla
           from dt.alerta a join dt.regla r on r.id = a.regla
          where a.equipo = @i and a.cerrada is null order by a.abierta desc''',
      {'i': id},
    );
    final ultimas = await p.bd.filas(
      '''select id, tipo, datos, estado, detalle, creado, creado_por, enviada, actualizada, vence
           from dt.orden where equipo = @i order by creado desc limit 10''',
      {'i': id},
    );
    return Respuesta.ok({
      ...e,
      'fuentes': fuentes,
      'alertas_abiertas': alertasAbiertas,
      'ordenes': ultimas,
    });
  });

  s.ruta('PATCH', '/v1/equipos/:id', (p) async {
    final id = p.enteroParam('id');
    final cambios = <String>[];
    final params = <String, Object?>{'i': id, 'o': p.s.org};
    for (final campo in const ['nombre', 'etiqueta', 'serie', 'asignado_a', 'notas']) {
      if (!p.cuerpo.containsKey(campo)) continue;
      final v = p.texto(campo);
      if (v.length > (campo == 'notas' ? 2000 : 200)) {
        return Respuesta.falla(400, 'muy_largo', '«$campo» es demasiado largo');
      }
      if (campo == 'nombre' && v.isEmpty) {
        return Respuesta.falla(400, 'falta_nombre', 'El equipo necesita un nombre');
      }
      cambios.add('$campo = @$campo');
      params[campo] = v;
    }
    if (p.cuerpo.containsKey('estado')) {
      final estado = p.texto('estado');
      if (!const {'activo', 'guardado', 'perdido', 'retirado'}.contains(estado)) {
        return Respuesta.falla(400, 'estado_invalido', 'El estado es activo, guardado, perdido o retirado');
      }
      cambios.add('estado = @estado');
      params['estado'] = estado;
    }
    // Moverlo de dominio: solo a uno que la sesión alcance. Quien alcanza un
    // solo dominio no puede sacar un equipo del suyo.
    if (p.cuerpo.containsKey('dominio')) {
      final dominio = await buscaDominio(p, p.cuerpo['dominio']);
      if (dominio == null) return _dominioInvalido();
      cambios.add('dominio = @dominio');
      params['dominio'] = dominio;
    }
    if (cambios.isEmpty) return Respuesta.falla(400, 'sin_cambios', 'No vino nada que cambiar');
    final e = await p.bd.fila(
      'update dt.equipo set ${cambios.join(', ')} '
      'where id = @i and org = @o and ${enDominios(p.s.dominios, 'dt.equipo.dominio')} '
      'returning ${_columnasEquipo('dt.equipo')}',
      params,
    );
    if (e == null) return _noEsta();
    // Las alertas de reglas de otro dominio ya no son suyas.
    if (params.containsKey('dominio')) {
      await p.bd.ejecuta(
        '''update dt.alerta a set cerrada = now(), nota = 'el equipo cambió de dominio'
             from dt.regla r
            where r.id = a.regla and a.equipo = @i and a.cerrada is null
              and r.dominio is not null and r.dominio <> @d''',
        {'i': id, 'd': params['dominio']},
      );
    }
    // Un equipo que deja de vigilarse no se queda con alertas abiertas.
    if (const {'guardado', 'retirado'}.contains(e['estado'])) {
      await p.bd.ejecuta(
        '''update dt.alerta set cerrada = now(), nota = 'el equipo pasó a ${e['estado']}'
            where equipo = @i and cerrada is null''',
        {'i': id},
      );
    }
    return Respuesta.ok(e);
  }, permiso: 'editar');

  s.ruta('GET', '/v1/equipos/:id/recorrido', (p) async {
    final id = p.enteroParam('id');
    if (!await _alcanzaEquipo(p, id)) return _noEsta();
    final (desde, hasta) = _rango(p);
    final r = await p.bd.filas(
      '''select t, lat, lng, precision_m, motivo
           from dt.reporte
          where equipo = @i and lat is not null and t between @d and @h
          order by t limit 5000''',
      {'i': id, 'd': desde, 'h': hasta},
    );
    return Respuesta.ok({'desde': desde, 'hasta': hasta, 'puntos': r});
  });

  s.ruta('GET', '/v1/equipos/:id/reportes', (p) async {
    final id = p.enteroParam('id');
    if (!await _alcanzaEquipo(p, id)) return _noEsta();
    final (desde, hasta) = _rango(p);
    final limite = (int.tryParse(p.consulta['limite'] ?? '') ?? 500).clamp(1, 5000);
    final r = await p.bd.filas(
      '''select t, recibido, motivo, bateria, cargando, red_tipo, red_ssid,
                lat, lng, precision_m, almacenamiento_libre
           from dt.reporte
          where equipo = @i and t between @d and @h
          order by t desc limit @l''',
      {'i': id, 'd': desde, 'h': hasta, 'l': limite},
    );
    return Respuesta.ok({'desde': desde, 'hasta': hasta, 'reportes': r});
  });

  s.ruta('GET', '/v1/equipos/:id/ordenes', (p) async {
    final id = p.enteroParam('id');
    if (!await _alcanzaEquipo(p, id)) return _noEsta();
    final r = await p.bd.filas(
      '''select id, tipo, datos, estado, detalle, creado, creado_por, enviada, actualizada, vence
           from dt.orden where equipo = @i order by creado desc limit 100''',
      {'i': id},
    );
    return Respuesta.ok({'ordenes': r});
  });

  s.ruta('POST', '/v1/equipos/:id/ordenes', (p) async {
    final id = p.enteroParam('id');
    final e = await p.bd.fila(
      'select estado from dt.equipo where id = @i and org = @o and ${enDominios(p.s.dominios, 'dominio')}',
      {'i': id, 'o': p.s.org},
    );
    if (e == null) return _noEsta();
    if (e['estado'] == 'retirado') {
      return Respuesta.falla(409, 'equipo_retirado', 'El equipo está retirado');
    }
    final tipo = p.texto('tipo');
    if (!Ordenes.tipos.contains(tipo)) {
      return Respuesta.falla(400, 'tipo_invalido', 'La orden es sonar, mensaje o reportar');
    }
    final d = p.cuerpo['datos'] is Map ? (p.cuerpo['datos'] as Map).cast<String, Object?>() : const <String, Object?>{};
    final Map<String, Object?> datos;
    switch (tipo) {
      case 'sonar':
        final seg = d['segundos'] is num ? (d['segundos'] as num).toInt() : 30;
        datos = {'segundos': seg.clamp(5, 300)};
      case 'mensaje':
        final texto = d['texto']?.toString().trim() ?? '';
        if (texto.isEmpty || texto.length > 500) {
          return Respuesta.falla(400, 'falta_texto', 'El mensaje necesita texto (hasta 500 caracteres)');
        }
        final titulo = d['titulo']?.toString().trim() ?? '';
        datos = {'titulo': titulo.length > 80 ? titulo.substring(0, 80) : titulo, 'texto': texto};
      default:
        datos = const {};
    }
    final minutos = (p.entero('vence_min') ?? 60).clamp(1, 1440);
    final o = await ordenes.crea(
      org: p.s.org,
      equipo: id,
      tipo: tipo,
      datos: datos,
      vida: Duration(minutes: minutos),
      firma: p.s.firma,
    );
    return Respuesta.creado(o);
  }, permiso: 'ordenar');

  // Dos filas que eran el mismo equipo (llegó con otra huella: otra llave de
  // firma, un reseteo de fábrica) pasan a ser una. Se queda [id]; [con] se
  // borra después de pasarle todo.
  s.ruta('POST', '/v1/equipos/:id/unir', (p) async {
    final id = p.enteroParam('id');
    final con = p.entero('con') ?? 0;
    if (con == id) return Respuesta.falla(400, 'mismo_equipo', 'Es el mismo equipo');
    final hecho = await p.bd.transaccion((tx) async {
      final dos = await tx.filas(
        'select id from dt.equipo where org = @o and id = any(@ids) '
        'and ${enDominios(p.s.dominios, 'dominio')} for update',
        {'o': p.s.org, 'ids': [id, con]},
      );
      if (dos.length != 2) return false;
      await _une(tx, id, con);
      return true;
    });
    if (!hecho) return _noEsta();
    final e = await p.bd.fila(
      'select ${_columnasEquipo('e')} from dt.equipo e where e.id = @i',
      {'i': id},
    );
    return Respuesta.ok(e);
  }, permiso: 'editar');

  // Borrar es para lo que entró por error: se lleva el historial. Para un
  // equipo que se dejó de usar está `estado: retirado`.
  s.ruta('DELETE', '/v1/equipos/:id', (p) async {
    await p.bd.ejecuta(
      'delete from dt.equipo where id = @i and org = @o and ${enDominios(p.s.dominios, 'dominio')}',
      {'i': p.enteroParam('id'), 'o': p.s.org},
    );
    return Respuesta.vacio();
  }, permiso: 'admin');

  // ------------------------------------------------------- códigos de alta

  s.ruta('GET', '/v1/altas', (p) async {
    final r = await p.bd.filas(
      '''select a.id, a.nombre, a.prefijo, a.dominio, d.nombre as dominio_nombre,
                a.usos, a.usos_max, a.vence, a.creado, a.creado_por, a.anulada,
                (select count(*) from dt.equipo e where e.alta = a.id) as equipos
           from dt.alta a join dt.dominio d on d.id = a.dominio
          where a.org = @o and ${enDominios(p.s.dominios, 'a.dominio')}
          order by a.id desc''',
      {'o': p.s.org},
    );
    return Respuesta.ok({'altas': r});
  });

  s.ruta('POST', '/v1/altas', (p) async {
    final nombre = p.texto('nombre');
    if (nombre.isEmpty) {
      return Respuesta.falla(400, 'falta_nombre', 'Ponle nombre: «Terminales del almacén», «App de compras»');
    }
    final usosMax = p.entero('usos_max');
    if (usosMax != null && usosMax < 1) {
      return Respuesta.falla(400, 'usos_invalidos', 'usos_max es 1 o más (o nada, sin tope)');
    }
    DateTime? vence;
    final dias = p.entero('vence_dias');
    if (dias != null) {
      vence = DateTime.now().toUtc().add(Duration(days: dias.clamp(1, 3650)));
    } else if (p.texto('vence').isNotEmpty) {
      vence = DateTime.tryParse(p.texto('vence'))?.toUtc();
      if (vence == null) return Respuesta.falla(400, 'fecha_invalida', 'vence es una fecha ISO');
    }
    final (dominio, error) = await dominioDe(p, p.cuerpo);
    if (error != null) return error;
    final prefijo = Seguridad.hex(4);
    final secreto = Seguridad.token();
    final a = await p.bd.fila(
      '''insert into dt.alta (org, nombre, prefijo, clave_hash, dominio, usos_max, vence, creado_por)
         values (@o, @n, @p, @h, @d, @u, @v, @f)
         returning id, nombre, prefijo, dominio,
                   (select nombre from dt.dominio where id = @d) as dominio_nombre,
                   usos, usos_max, vence, creado''',
      {
        'o': p.s.org,
        'n': nombre,
        'p': prefijo,
        'h': Seguridad.hashToken(secreto),
        'd': dominio,
        'u': usosMax,
        'v': vence,
        'f': p.s.firma,
      },
    );
    final codigo = 'dta_${prefijo}_$secreto';
    return Respuesta.creado({
      ...a!,
      // Única vez que se ve completo. Se guarda hasheado.
      'codigo': codigo,
      // Lo que va en el QR: el agente lo escanea y ya sabe a qué hub hablar.
      'qr': textoQr(p.urlPublica, codigo),
    });
  }, permiso: 'editar');

  s.ruta('DELETE', '/v1/altas/:id', (p) async {
    await p.bd.ejecuta(
      'update dt.alta set anulada = now() '
      'where id = @i and org = @o and anulada is null and ${enDominios(p.s.dominios, 'dominio')}',
      {'i': p.enteroParam('id'), 'o': p.s.org},
    );
    return Respuesta.vacio();
  }, permiso: 'editar');

  // ----------------------------------------------------------------- zonas
  //
  // Una zona sin dominio es de toda la organización: la ven todos y solo la
  // toca quien alcanza toda la organización. Con dominio, solo quien lo alcanza.

  s.ruta('GET', '/v1/zonas', (p) async {
    final r = await p.bd.filas(
      '''select z.id, z.nombre, z.lat, z.lng, z.radio_m, z.dominio, d.nombre as dominio_nombre, z.creado
           from dt.zona z left join dt.dominio d on d.id = z.dominio
          where z.org = @o and ${enDominios(p.s.dominios, 'z.dominio', tambienDeOrg: true)}
          order by z.nombre''',
      {'o': p.s.org},
    );
    return Respuesta.ok({'zonas': r});
  });

  s.ruta('POST', '/v1/zonas', (p) async {
    final z = _leeZona(p);
    if (z is Respuesta) return z;
    final (dominio, error) = await dominioDe(p, p.cuerpo, deOrg: true);
    if (error != null) return error;
    final r = await p.bd.fila(
      '''insert into dt.zona (org, nombre, lat, lng, radio_m, dominio) values (@o, @n, @la, @lo, @r, @d)
         returning $_columnasZona''',
      {'o': p.s.org, 'd': dominio, ...(z as Map<String, Object?>)},
    );
    return Respuesta.creado(r);
  }, permiso: 'editar');

  s.ruta('PATCH', '/v1/zonas/:id', (p) async {
    final id = p.enteroParam('id');
    final z = _leeZona(p);
    if (z is Respuesta) return z;
    final actual = await p.bd.fila(
      'select dominio from dt.zona where id = @i and org = @o and ${enDominios(p.s.dominios, 'dominio')}',
      {'i': id, 'o': p.s.org},
    );
    if (actual == null) return _noEsta('Esa zona no existe');
    var dominio = actual['dominio'] as int?;
    if (p.cuerpo.containsKey('dominio')) {
      final (nuevo, error) = await dominioDe(p, p.cuerpo, deOrg: true);
      if (error != null) return error;
      // Una regla solo vigila zonas de toda la organización o de su dominio:
      // llevarse la zona a otro dominio la dejaría vigilando una ajena.
      if (nuevo != null && nuevo != dominio) {
        final ajena = await p.bd.fila(
          '''select 1 as n from dt.regla
              where org = @o and tipo = 'fuera_de_zona' and (parametros->>'zona')::bigint = @i
                and (dominio is null or dominio <> @d)
              limit 1''',
          {'o': p.s.org, 'i': id, 'd': nuevo},
        );
        if (ajena != null) {
          return Respuesta.falla(409, 'zona_en_uso',
              'Una regla de otro dominio (o de toda la organización) vigila esta zona: cámbiala primero');
        }
      }
      dominio = nuevo;
    }
    final r = await p.bd.fila(
      '''update dt.zona set nombre = @n, lat = @la, lng = @lo, radio_m = @r, dominio = @d
          where id = @i and org = @o returning $_columnasZona''',
      {'i': id, 'o': p.s.org, 'd': dominio, ...(z as Map<String, Object?>)},
    );
    return r == null ? _noEsta('Esa zona no existe') : Respuesta.ok(r);
  }, permiso: 'editar');

  s.ruta('DELETE', '/v1/zonas/:id', (p) async {
    final id = p.enteroParam('id');
    final zona = await p.bd.fila(
      'select id from dt.zona where id = @i and org = @o and ${enDominios(p.s.dominios, 'dominio')}',
      {'i': id, 'o': p.s.org},
    );
    if (zona == null) return Respuesta.vacio();
    final usada = await p.bd.fila(
      '''select count(*) as n from dt.regla
          where org = @o and tipo = 'fuera_de_zona' and (parametros->>'zona')::bigint = @i''',
      {'i': id, 'o': p.s.org},
    );
    if ((usada!['n'] as int) > 0) {
      return Respuesta.falla(409, 'zona_en_uso', 'Una regla vigila esta zona: bórrala o cámbiala primero');
    }
    await p.bd.ejecuta('delete from dt.zona where id = @i and org = @o', {'i': id, 'o': p.s.org});
    return Respuesta.vacio();
  }, permiso: 'editar');

  // ---------------------------------------------------------------- reglas
  //
  // Igual que las zonas: sin dominio vigila a todos los equipos de la
  // organización; esa la ve cualquiera (aplica también a los suyos) y solo la
  // toca quien alcanza toda la organización.

  s.ruta('GET', '/v1/reglas', (p) async {
    final r = await p.bd.filas(
      '''select r.id, r.nombre, r.tipo, r.dominio, d.nombre as dominio_nombre, r.parametros, r.activa, r.creado,
                (select count(*) from dt.alerta a join dt.equipo e on e.id = a.equipo
                  where a.regla = r.id and a.cerrada is null
                    and ${enDominios(p.s.dominios, 'e.dominio')}) as abiertas
           from dt.regla r left join dt.dominio d on d.id = r.dominio
          where r.org = @o and ${enDominios(p.s.dominios, 'r.dominio', tambienDeOrg: true)}
          order by r.id''',
      {'o': p.s.org},
    );
    return Respuesta.ok({'reglas': r});
  });

  s.ruta('POST', '/v1/reglas', (p) async {
    final leida = await _leeRegla(p, p.cuerpo);
    if (leida is Respuesta) return leida;
    final datos = leida as Map<String, Object?>;
    final r = await p.bd.fila(
      '''insert into dt.regla (org, nombre, tipo, dominio, parametros, activa)
         values (@o, @n, @t, @d, @pa, @a)
         returning $_columnasRegla''',
      {'o': p.s.org, ...datos},
    );
    return Respuesta.creado(r);
  }, permiso: 'editar');

  // Cambia solo lo que viene: `{activa: false}` apaga la regla y deja su
  // nombre, su dominio y sus parámetros como estaban.
  s.ruta('PATCH', '/v1/reglas/:id', (p) async {
    final id = p.enteroParam('id');
    final actual = await p.bd.fila(
      '''select nombre, tipo, dominio, parametros, activa from dt.regla
          where id = @i and org = @o and ${enDominios(p.s.dominios, 'dominio')}''',
      {'i': id, 'o': p.s.org},
    );
    if (actual == null) return _noEsta('Esa regla no existe');
    final cuerpo = {...actual, ...p.cuerpo, 'tipo': actual['tipo']};
    final leida = await _leeRegla(p, cuerpo);
    if (leida is Respuesta) return leida;
    final nueva = leida as Map<String, Object?>;
    final r = await p.bd.fila(
      '''update dt.regla set nombre = @n, dominio = @d, parametros = @pa, activa = @a
          where id = @i and org = @o
          returning $_columnasRegla''',
      {'i': id, 'o': p.s.org, ...nueva..remove('t')},
    );
    // Apagada o con otro dominio u otros parámetros, sus alertas abiertas ya
    // no dicen la verdad. Cambiarle el nombre no las toca.
    final cambio = nueva['d'] != actual['dominio'] ||
        nueva['a'] != actual['activa'] ||
        jsonEncode(nueva['pa']) != jsonEncode(actual['parametros']);
    if (cambio) {
      await p.bd.ejecuta(
        '''update dt.alerta set cerrada = now(), nota = 'la regla cambió'
            where regla = @i and cerrada is null''',
        {'i': id},
      );
    }
    return Respuesta.ok(r);
  }, permiso: 'editar');

  s.ruta('DELETE', '/v1/reglas/:id', (p) async {
    await p.bd.ejecuta(
      'delete from dt.regla where id = @i and org = @o and ${enDominios(p.s.dominios, 'dominio')}',
      {'i': p.enteroParam('id'), 'o': p.s.org},
    );
    return Respuesta.vacio();
  }, permiso: 'editar');

  // --------------------------------------------------------------- alertas

  s.ruta('GET', '/v1/alertas', (p) async {
    final q = p.consulta;
    final filtros = <String>['a.org = @o', enDominios(p.s.dominios, 'e.dominio')];
    final params = <String, Object?>{'o': p.s.org};
    if (q['todas'] != '1') filtros.add('a.cerrada is null');
    final equipo = int.tryParse(q['equipo'] ?? '');
    if (equipo != null) {
      filtros.add('a.equipo = @e');
      params['e'] = equipo;
    }
    params['l'] = (int.tryParse(q['limite'] ?? '') ?? 200).clamp(1, 2000);
    final r = await p.bd.filas(
      '''select a.id, a.tipo, a.abierta, a.cerrada, a.detalle, a.nota,
                a.regla, r.nombre as regla_nombre,
                a.equipo, e.nombre as equipo_nombre, e.etiqueta, e.dominio, d.nombre as dominio_nombre
           from dt.alerta a
           join dt.regla r on r.id = a.regla
           join dt.equipo e on e.id = a.equipo
           join dt.dominio d on d.id = e.dominio
          where ${filtros.join(' and ')}
          order by a.abierta desc limit @l''',
      params,
    );
    return Respuesta.ok({'alertas': r});
  });

  s.ruta('POST', '/v1/alertas/:id/cerrar', (p) async {
    final nota = p.texto('nota');
    final ok = await alertas.cierraAMano(
      p.s.org,
      p.enteroParam('id'),
      nota.length > 500 ? nota.substring(0, 500) : nota,
      dominios: p.s.dominios,
    );
    return ok ? Respuesta.ok({'ok': true}) : _noEsta('Esa alerta no existe o ya estaba cerrada');
  }, permiso: 'editar');

  // ---------------------------------------------------------- organización

  s.ruta('GET', '/v1/org', (p) async {
    final o = await p.bd.fila(
      '''select id, nombre, slug, intervalo_s, ubicacion, dias_historial, webhook_url,
                webhook_secreto <> '' as webhook_firmado, creado
           from dt.org where id = @o''',
      {'o': p.s.org},
    );
    // La URL de un webhook suele llevar su propio token (la de Slack, por
    // ejemplo): solo la ve quien administra.
    if (!p.s.esAdmin) o!.remove('webhook_url');
    return Respuesta.ok(o);
  });

  s.ruta('PATCH', '/v1/org', (p) async {
    final cambios = <String>[];
    final params = <String, Object?>{'o': p.s.org};
    if (p.cuerpo.containsKey('nombre')) {
      if (p.texto('nombre').isEmpty) return Respuesta.falla(400, 'falta_nombre', 'La organización necesita nombre');
      cambios.add('nombre = @n');
      params['n'] = p.texto('nombre');
    }
    if (p.cuerpo.containsKey('intervalo_s')) {
      final v = p.entero('intervalo_s');
      if (v == null || v < 60 || v > 86400) {
        return Respuesta.falla(400, 'intervalo_invalido', 'intervalo_s va de 60 a 86400 segundos');
      }
      cambios.add('intervalo_s = @i');
      params['i'] = v;
    }
    if (p.cuerpo.containsKey('ubicacion')) {
      if (p.cuerpo['ubicacion'] is! bool) return Respuesta.falla(400, 'ubicacion_invalida', 'ubicacion es true o false');
      cambios.add('ubicacion = @u');
      params['u'] = p.cuerpo['ubicacion'];
    }
    if (p.cuerpo.containsKey('dias_historial')) {
      final v = p.entero('dias_historial');
      if (v == null || v < 1 || v > 3650) {
        return Respuesta.falla(400, 'dias_invalidos', 'dias_historial va de 1 a 3650');
      }
      cambios.add('dias_historial = @d');
      params['d'] = v;
    }
    if (p.cuerpo.containsKey('webhook_url')) {
      final url = p.texto('webhook_url');
      final u = Uri.tryParse(url);
      if (url.isNotEmpty && (u == null || !(u.isScheme('https') || u.isScheme('http')) || u.host.isEmpty)) {
        return Respuesta.falla(400, 'url_invalida', 'El webhook es una URL http(s)');
      }
      cambios.add('webhook_url = @w');
      params['w'] = url;
    }
    if (cambios.isEmpty) return Respuesta.falla(400, 'sin_cambios', 'No vino nada que cambiar');
    final o = await p.bd.fila(
      '''update dt.org set ${cambios.join(', ')} where id = @o
         returning id, nombre, slug, intervalo_s, ubicacion, dias_historial, webhook_url,
                   webhook_secreto <> '' as webhook_firmado, creado''',
      params,
    );
    // Los equipos conectados se enteran ya; los demás, en su próximo reporte.
    canal.enviaOrg(p.s.org, {
      'tipo': 'config',
      'config': {'intervalo_s': o!['intervalo_s'], 'ubicacion': o['ubicacion']},
    });
    return Respuesta.ok(o);
  }, permiso: 'admin');

  // El secreto con que se firma el webhook. Se enseña una vez; generar otro
  // invalida el anterior.
  s.ruta('POST', '/v1/org/webhook/secreto', (p) async {
    final secreto = 'dtw_${Seguridad.token()}';
    await p.bd.ejecuta(
      'update dt.org set webhook_secreto = @s where id = @o',
      {'s': secreto, 'o': p.s.org},
    );
    return Respuesta.ok({'secreto': secreto});
  }, permiso: 'admin');

  s.ruta('POST', '/v1/org/webhook/prueba', (p) async {
    final o = await p.bd.fila('select webhook_url from dt.org where id = @o', {'o': p.s.org});
    if (((o?['webhook_url'] as String?) ?? '').isEmpty) {
      return Respuesta.falla(400, 'sin_webhook', 'Primero pon la URL del webhook');
    }
    final codigo = await alertas.pruebaWebhook(p.s.org);
    return Respuesta.ok({'estado_http': codigo});
  }, permiso: 'admin');
}

/// Lo que se enseña de un equipo en una lista. [t] es el alias de la tabla.
String _columnasEquipo(String t) => [
      'id', 'nombre', 'etiqueta', 'serie', 'modelo', 'fabricante', 'android', 'dominio',
      'asignado_a', 'estado', 'conectado', 'ultima_vez', 'ultimo_reporte', 'ultimo_motivo',
      'bateria', 'cargando', 'red_tipo', 'red_ssid', 'lat', 'lng', 'precision_m', 'ubicacion_t',
      'almacenamiento_libre', 'almacenamiento_total',
    ].map((c) => '$t.$c').followedBy(['(select nombre from dt.dominio where id = $t.dominio) as dominio_nombre']).join(', ');

const _columnasZona = '''id, nombre, lat, lng, radio_m, dominio,
    (select nombre from dt.dominio where id = dt.zona.dominio) as dominio_nombre, creado''';

const _columnasRegla = '''id, nombre, tipo, dominio,
    (select nombre from dt.dominio where id = dt.regla.dominio) as dominio_nombre,
    parametros, activa, creado''';

/// Lo que va en el QR de un código de alta.
String textoQr(String urlPublica, String codigo) =>
    'devicetrack://alta?hub=${Uri.encodeQueryComponent(urlPublica)}&codigo=${Uri.encodeQueryComponent(codigo)}';

Respuesta _noEsta([String mensaje = 'Ese equipo no existe']) => Respuesta.falla(404, 'no_encontrado', mensaje);

Respuesta _dominioInvalido() =>
    Respuesta.falla(400, 'dominio_invalido', 'Ese dominio no existe o no lo alcanzas');

/// Si el equipo es de la organización y de un dominio que la sesión alcanza.
Future<bool> _alcanzaEquipo(Peticion p, int equipo) async =>
    await p.bd.fila(
      'select 1 as ok from dt.equipo where id = @i and org = @o and ${enDominios(p.s.dominios, 'dominio')}',
      {'i': equipo, 'o': p.s.org},
    ) !=
    null;

/// `desde` y `hasta` de la consulta; por defecto, las últimas 24 horas.
(DateTime, DateTime) _rango(Peticion p) {
  final ahora = DateTime.now().toUtc();
  final hasta = DateTime.tryParse(p.consulta['hasta'] ?? '')?.toUtc() ?? ahora;
  final desde = DateTime.tryParse(p.consulta['desde'] ?? '')?.toUtc() ??
      hasta.subtract(const Duration(hours: 24));
  return (desde, hasta);
}

Object _leeZona(Peticion p) {
  final nombre = p.texto('nombre');
  final lat = (p.cuerpo['lat'] as num?)?.toDouble();
  final lng = (p.cuerpo['lng'] as num?)?.toDouble();
  final radio = p.entero('radio_m');
  if (nombre.isEmpty) return Respuesta.falla(400, 'falta_nombre', 'Ponle nombre a la zona');
  if (lat == null || lat < -90 || lat > 90 || lng == null || lng < -180 || lng > 180) {
    return Respuesta.falla(400, 'punto_invalido', 'lat y lng son el centro de la zona');
  }
  if (radio == null || radio < 10 || radio > 100000) {
    return Respuesta.falla(400, 'radio_invalido', 'radio_m va de 10 a 100000 metros');
  }
  return {'n': nombre, 'la': lat, 'lo': lng, 'r': radio};
}

const _tiposRegla = {'sin_reporte', 'bateria_baja', 'fuera_de_zona', 'apagado'};

/// Valida una regla. [cuerpo] es lo que llegó (POST) o la regla actual con lo
/// que llegó encima (PATCH).
Future<Object> _leeRegla(Peticion p, Map<String, Object?> cuerpo) async {
  String texto(String k) => cuerpo[k]?.toString().trim() ?? '';
  final tipo = texto('tipo');
  if (!_tiposRegla.contains(tipo)) {
    return Respuesta.falla(400, 'tipo_invalido', 'La regla es ${_tiposRegla.join(', ')}');
  }
  final (dominio, error) = await dominioDe(p, cuerpo, deOrg: true);
  if (error != null) return error;
  final crudos = cuerpo['parametros'] is Map
      ? (cuerpo['parametros'] as Map).cast<String, Object?>()
      : const <String, Object?>{};
  int? n(String k) => crudos[k] is num ? (crudos[k] as num).toInt() : int.tryParse(crudos[k]?.toString() ?? '');
  final Map<String, Object?> parametros;
  switch (tipo) {
    case 'sin_reporte':
      final m = n('minutos') ?? 60;
      if (m < 5 || m > 10080) return Respuesta.falla(400, 'parametro_invalido', 'minutos va de 5 a 10080 (una semana)');
      parametros = {'minutos': m};
    case 'bateria_baja':
      final pct = n('porcentaje') ?? 15;
      if (pct < 1 || pct > 99) return Respuesta.falla(400, 'parametro_invalido', 'porcentaje va de 1 a 99');
      parametros = {'porcentaje': pct};
    case 'fuera_de_zona':
      final z = n('zona');
      // De toda la organización o del mismo dominio que la regla: una regla
      // de Duralon no vigila el almacén de otro cliente.
      final existe = z == null
          ? null
          : await p.bd.fila(
              '''select id from dt.zona
                  where id = @z and org = @o and (dominio is null or dominio = @d::bigint)''',
              {'z': z, 'o': p.s.org, 'd': dominio},
            );
      if (existe == null) {
        return Respuesta.falla(400, 'zona_invalida',
            'parametros.zona es el id de una zona de toda la organización o del mismo dominio que la regla');
      }
      parametros = {'zona': z};
    default:
      parametros = const {};
  }
  return {
    'n': texto('nombre'),
    't': tipo,
    'd': dominio,
    'pa': parametros,
    'a': cuerpo['activa'] is bool ? cuerpo['activa'] : true,
  };
}

/// Pasa todo lo de [con] a [id] y borra [con]. Dentro de una transacción.
Future<void> _une(Bd tx, int id, int con) async {
  // Fuentes: si las dos tienen la misma app, se queda la que reportó último.
  await tx.ejecuta(
    '''delete from dt.fuente f where f.equipo = @id and exists (
         select 1 from dt.fuente g where g.equipo = @con and g.paquete = f.paquete and g.ultima_vez > f.ultima_vez)''',
    {'id': id, 'con': con},
  );
  await tx.ejecuta(
    '''delete from dt.fuente g where g.equipo = @con and exists (
         select 1 from dt.fuente f where f.equipo = @id and f.paquete = g.paquete)''',
    {'id': id, 'con': con},
  );
  await tx.ejecuta('update dt.fuente set equipo = @id where equipo = @con', {'id': id, 'con': con});
  await tx.ejecuta('update dt.reporte set equipo = @id where equipo = @con', {'id': id, 'con': con});
  await tx.ejecuta('update dt.orden set equipo = @id where equipo = @con', {'id': id, 'con': con});
  // Una alerta abierta de la misma regla en los dos: se cierra la de [con].
  await tx.ejecuta(
    '''update dt.alerta g set cerrada = now(), nota = 'equipos unidos'
        where g.equipo = @con and g.cerrada is null and exists (
          select 1 from dt.alerta f where f.equipo = @id and f.regla = g.regla and f.cerrada is null)''',
    {'id': id, 'con': con},
  );
  await tx.ejecuta('update dt.alerta set equipo = @id where equipo = @con', {'id': id, 'con': con});
  // La ficha: lo que escribió una persona en [id] manda; lo vacío se llena
  // con lo de [con]. El último estado, el del reporte más nuevo.
  final c = await tx.fila('select * from dt.equipo where id = @con', {'con': con});
  await tx.ejecuta('delete from dt.equipo where id = @con', {'con': con});
  await tx.ejecuta(
    '''update dt.equipo d set
          etiqueta = case when d.etiqueta = '' then @etiqueta else d.etiqueta end,
          serie = case when d.serie = '' then @serie else d.serie end,
          huella = coalesce(d.huella, @huella),
          asignado_a = case when d.asignado_a = '' then @asignado else d.asignado_a end,
          notas = case when d.notas = '' then @notas
                       when @notas = '' then d.notas
                       else d.notas || E'\\n' || @notas end,
          primera_vez = least(d.primera_vez, @primera),
          ultima_vez = greatest(d.ultima_vez, @ultima),
          conectado = d.conectado or @conectado
        where d.id = @id''',
    {
      'id': id,
      'etiqueta': c!['etiqueta'],
      'serie': c['serie'],
      'huella': c['huella'],
      'asignado': c['asignado_a'],
      'notas': c['notas'],
      'primera': c['primera_vez'],
      'ultima': c['ultima_vez'],
      'conectado': c['conectado'],
    },
  );
  final r = c['ultimo_reporte'] as DateTime?;
  if (r != null) {
    await tx.ejecuta(
      '''update dt.equipo d set
            ultimo_reporte = @r, ultimo_motivo = @m, bateria = @b, cargando = @c,
            red_tipo = @rt, red_ssid = @rs,
            almacenamiento_libre = @al, almacenamiento_total = @at
          where d.id = @id and (d.ultimo_reporte is null or d.ultimo_reporte < @r)''',
      {
        'id': id,
        'r': r,
        'm': c['ultimo_motivo'],
        'b': c['bateria'],
        'c': c['cargando'],
        'rt': c['red_tipo'],
        'rs': c['red_ssid'],
        'al': c['almacenamiento_libre'],
        'at': c['almacenamiento_total'],
      },
    );
  }
  final u = c['ubicacion_t'] as DateTime?;
  if (u != null) {
    await tx.ejecuta(
      '''update dt.equipo d set lat = @la, lng = @lo, precision_m = @p, ubicacion_t = @u
          where d.id = @id and (d.ubicacion_t is null or d.ubicacion_t < @u)''',
      {'id': id, 'la': c['lat'], 'lo': c['lng'], 'p': c['precision_m'], 'u': u},
    );
  }
}
