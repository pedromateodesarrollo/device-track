import 'dart:async';
import 'dart:convert';

import '../alertas.dart';
import '../limitador.dart';
import '../ordenes.dart';
import '../seguridad.dart';
import 'servidor.dart';

/// Lo que usa el equipo: el alta, el reporte y el acuse de las órdenes.
///
/// Todo lo que llega de aquí lo escribe un teléfono, y un teléfono puede
/// mandar cualquier cosa: cada campo se valida y se acota, y lo que no cuadra
/// se ignora en vez de romper el reporte entero (un equipo que manda una
/// batería de 140 % igual tiene que quedar registrado como vivo).
void registraRutasDispositivo(Servidor s, Ordenes ordenes, Alertas alertas) {
  final freno = Limitador(cupo: 30, ventana: const Duration(minutes: 1));
  // Un equipo reporta cada diez minutos, y al abrir la app o recibir una
  // orden. Veinte por minuto ya es un equipo con un bucle (o una credencial
  // robada llenando el historial).
  final frenoReporte = Limitador(cupo: 20, ventana: const Duration(minutes: 1));

  s.ruta('POST', '/v1/alta', (p) async {
    if (!freno.cabe('alta:${p.ip}')) {
      return Respuesta.falla(429, 'demasiados_intentos', 'Espera un minuto');
    }
    final codigo = Servidor.credencialDe(p.crudo).isNotEmpty
        ? Servidor.credencialDe(p.crudo)
        : p.texto('codigo');
    final partes = Seguridad.partesCredencial(codigo);
    if (partes == null || partes[0] != 'dta') {
      return Respuesta.falla(401, 'codigo_invalido', 'Falta el código de alta (dta_…) o está mal escrito');
    }
    final huella = _texto(p.cuerpo['huella'], 200);
    if (huella.isEmpty) {
      return Respuesta.falla(400, 'falta_huella', 'El equipo tiene que decir su huella (ANDROID_ID)');
    }
    final fuente = _mapa(p.cuerpo['fuente']);
    final tipo = _texto(fuente['tipo'], 10);
    final paquete = _texto(fuente['paquete'], 200);
    if (!const {'agente', 'app'}.contains(tipo)) {
      return Respuesta.falla(400, 'fuente_invalida', 'fuente.tipo es «agente» o «app»');
    }
    if (!RegExp(r'^[A-Za-z0-9_.]{1,200}$').hasMatch(paquete)) {
      return Respuesta.falla(400, 'fuente_invalida', 'fuente.paquete es el applicationId de quien reporta');
    }
    final eq = _mapa(p.cuerpo['equipo']);
    final serie = _texto(eq['serie'], 100);

    final resultado = await p.bd.transaccion((tx) async {
      // `for update`: dos equipos dando de alta a la vez con un código de un
      // solo uso no pueden entrar los dos.
      final alta = await tx.fila(
        '''select a.id, a.org, a.clave_hash, a.dominio, a.usos, a.usos_max, a.vence, a.anulada,
                  o.intervalo_s, o.ubicacion
             from dt.alta a join dt.org o on o.id = a.org
            where a.prefijo = @p for update of a''',
        {'p': partes[1]},
      );
      if (alta == null || !Seguridad.tokenCoincide(partes[2], alta['clave_hash'] as String)) {
        return Respuesta.falla(401, 'codigo_invalido', 'Ese código de alta no existe');
      }
      if (alta['anulada'] != null) {
        return Respuesta.falla(410, 'codigo_anulado', 'Ese código de alta se anuló');
      }
      final vence = alta['vence'] as DateTime?;
      if (vence != null && vence.isBefore(DateTime.now())) {
        return Respuesta.falla(410, 'codigo_vencido', 'Ese código de alta venció');
      }
      final max = alta['usos_max'] as int?;
      if (max != null && (alta['usos'] as int) >= max) {
        return Respuesta.falla(410, 'codigo_agotado', 'Ese código de alta ya se usó todas las veces que permitía');
      }
      final org = alta['org'] as int;

      // El mismo equipo puede llegar por otra fuente (el agente después de
      // la app) o reinstalado: se le reconoce por la huella o por la serie.
      var equipo = await tx.fila(
        'select id, nombre from dt.equipo where org = @o and huella = @h',
        {'o': org, 'h': huella},
      );
      if (equipo == null && serie.isNotEmpty) {
        equipo = await tx.fila(
          'select id, nombre from dt.equipo where org = @o and serie = @s and huella is null',
          {'o': org, 's': serie},
        );
      }
      final modelo = _texto(eq['modelo'], 100);
      final fabricante = _texto(eq['fabricante'], 100);
      final android = _entero(eq['android'], 1, 100);
      if (equipo == null) {
        final sugerido = _texto(eq['nombre'], 100);
        final corto = huella.length > 4 ? huella.substring(huella.length - 4) : huella;
        equipo = await tx.fila(
          '''insert into dt.equipo (org, nombre, serie, huella, modelo, fabricante, android, dominio, alta)
             values (@o, @n, @s, @h, @m, @f, @a, @g, @al)
             returning id, nombre''',
          {
            'o': org,
            'n': sugerido.isNotEmpty ? sugerido : [if (modelo.isNotEmpty) modelo, corto].join(' · '),
            's': serie,
            'h': huella,
            'm': modelo,
            'f': fabricante,
            'a': android,
            'g': alta['dominio'],
            'al': alta['id'],
          },
        );
      } else {
        // Lo que el equipo dice de sí se actualiza; lo que escribió una
        // persona (nombre, dominio, etiqueta) no se toca. Un equipo retirado
        // que vuelve a darse de alta es que lo volvieron a poner en uso.
        await tx.ejecuta(
          '''update dt.equipo
                set huella = coalesce(huella, @h),
                    serie = case when serie = '' then @s else serie end,
                    modelo = coalesce(nullif(@m, ''), modelo),
                    fabricante = coalesce(nullif(@f, ''), fabricante),
                    android = coalesce(@a, android),
                    estado = case when estado = 'retirado' then 'activo' else estado end,
                    ultima_vez = now()
              where id = @e''',
          {'h': huella, 's': serie, 'm': modelo, 'f': fabricante, 'a': android, 'e': equipo['id']},
        );
      }

      // Una credencial por fuente. Darse de alta otra vez desde la misma
      // fuente (la app se reinstaló) la reemplaza: la vieja deja de valer.
      final prefijo = Seguridad.hex(4);
      final secreto = Seguridad.token();
      await tx.ejecuta(
        '''insert into dt.fuente (equipo, tipo, paquete, version, build, prefijo, clave_hash)
           values (@e, @t, @p, @v, @b, @pre, @h)
           on conflict (equipo, paquete) do update
              set tipo = excluded.tipo, version = excluded.version, build = excluded.build,
                  prefijo = excluded.prefijo, clave_hash = excluded.clave_hash,
                  revocada = null, ultima_vez = now()''',
        {
          'e': equipo!['id'],
          't': tipo,
          'p': paquete,
          'v': _texto(fuente['version'], 50),
          'b': _entero(fuente['build'], 0, 1 << 31),
          'pre': prefijo,
          'h': Seguridad.hashToken(secreto),
        },
      );
      await tx.ejecuta('update dt.alta set usos = usos + 1 where id = @i', {'i': alta['id']});
      return Respuesta.creado({
        'equipo': {'id': equipo['id'], 'nombre': equipo['nombre']},
        'credencial': 'dtd_${prefijo}_$secreto',
        'config': {'intervalo_s': alta['intervalo_s'], 'ubicacion': alta['ubicacion']},
        'ws': '${p.urlPublica.replaceFirst(RegExp('^http'), 'ws')}/v1/ws',
      });
    });
    return resultado;
  }, acceso: Acceso.publico);

  s.ruta('POST', '/v1/reporte', (p) async {
    final e = p.e;
    if (!frenoReporte.cabe('reporte:${e.fuente}')) {
      return Respuesta.falla(429, 'demasiados_reportes', 'Este equipo está reportando demasiado seguido');
    }
    final org = await p.bd.fila(
      'select intervalo_s, ubicacion from dt.org where id = @o',
      {'o': e.org},
    );
    final conUbicacion = org!['ubicacion'] == true;

    // El reporte de ahora y los atrasados, todos con la misma forma.
    final crudos = <Map<String, Object?>>[
      for (final r in (p.cuerpo['reportes'] is List ? p.cuerpo['reportes'] as List : const []).take(500))
        if (r is Map) r.cast<String, Object?>(),
      p.cuerpo,
    ];
    final reportes = [
      for (final (i, r) in crudos.indexed) {..._leeReporte(r, conUbicacion), '_orden': i},
    ];
    // Por hora; a igual hora, el de ahora va último (es el que manda).
    reportes.sort((a, b) {
      final c = (a['t'] as DateTime).compareTo(b['t'] as DateTime);
      return c != 0 ? c : (a['_orden'] as int).compareTo(b['_orden'] as int);
    });
    final ultimo = reportes.last;
    Map<String, Object?>? ultimaUbicacion;
    for (final r in reportes) {
      if (r['lat'] != null) ultimaUbicacion = r;
    }

    await p.bd.transaccion((tx) async {
      for (final r in reportes) {
        await tx.ejecuta(
          '''insert into dt.reporte (equipo, fuente, t, motivo, bateria, cargando, red_tipo, red_ssid,
                                     lat, lng, precision_m, almacenamiento_libre)
             values (@e, @f, @t, @m, @b, @c, @rt, @rs, @la, @lo, @pr, @al)''',
          {
            'e': e.equipo,
            'f': e.fuente,
            't': r['t'],
            'm': r['motivo'],
            'b': r['bateria'],
            'c': r['cargando'],
            'rt': r['red_tipo'],
            'rs': r['red_ssid'],
            'la': r['lat'],
            'lo': r['lng'],
            'pr': r['precision_m'],
            'al': r['almacenamiento_libre'],
          },
        );
      }

      // El estado del equipo es el del reporte más nuevo, salvo que ya
      // hubiera uno más nuevo (llegó primero el de otra fuente). Cada campo
      // solo se pisa si el reporte lo trae: el plugin de una app puede no
      // saber la batería y eso no la borra.
      await tx.ejecuta(
        '''update dt.equipo set
              ultima_vez = now(),
              ultimo_reporte = greatest(ultimo_reporte, @t),
              ultimo_motivo = case when ultimo_reporte is null or ultimo_reporte <= @t then @m else ultimo_motivo end,
              bateria = case when @b::int is not null and (ultimo_reporte is null or ultimo_reporte <= @t) then @b else bateria end,
              cargando = case when @c::bool is not null and (ultimo_reporte is null or ultimo_reporte <= @t) then @c else cargando end,
              red_tipo = case when @rt::text is not null and (ultimo_reporte is null or ultimo_reporte <= @t) then @rt else red_tipo end,
              red_ssid = case when @rt::text is not null and (ultimo_reporte is null or ultimo_reporte <= @t) then @rs else red_ssid end,
              almacenamiento_libre = coalesce(@al, almacenamiento_libre),
              almacenamiento_total = coalesce(@at, almacenamiento_total),
              android = coalesce(@an, android)
            where id = @e''',
        {
          'e': e.equipo,
          't': ultimo['t'],
          'm': ultimo['motivo'],
          'b': ultimo['bateria'],
          'c': ultimo['cargando'],
          'rt': ultimo['red_tipo'],
          'rs': ultimo['red_ssid'],
          'al': ultimo['almacenamiento_libre'],
          'at': ultimo['almacenamiento_total'],
          'an': _entero(_mapa(p.cuerpo['equipo'])['android'], 1, 100),
        },
      );
      if (ultimaUbicacion != null) {
        await tx.ejecuta(
          '''update dt.equipo set lat = @la, lng = @lo, precision_m = @pr, ubicacion_t = @t
              where id = @e and (ubicacion_t is null or ubicacion_t <= @t)''',
          {
            'e': e.equipo,
            'la': ultimaUbicacion['lat'],
            'lo': ultimaUbicacion['lng'],
            'pr': ultimaUbicacion['precision_m'],
            't': ultimaUbicacion['ubicacion_t'],
          },
        );
      }
      final apps = _apps(p.cuerpo['apps']);
      if (apps != null) {
        // Una lista de objetos no tiene tipo que el driver adivine: va como
        // texto JSON y Postgres la convierte.
        await tx.ejecuta(
          'update dt.equipo set apps = @a::jsonb, apps_t = now() where id = @e',
          {'a': jsonEncode(apps), 'e': e.equipo},
        );
      }

      final fuente = _mapa(p.cuerpo['fuente']);
      final contexto = p.cuerpo['contexto'];
      final contextoOk = contexto is Map && jsonEncode(contexto).length <= 4096;
      await tx.ejecuta(
        '''update dt.fuente set
              ultima_vez = now(),
              version = coalesce(nullif(@v, ''), version),
              build = coalesce(@b, build),
              contexto = case when @hayc then @c else contexto end
            where id = @f''',
        {
          'f': e.fuente,
          'v': _texto(fuente['version'], 50),
          'b': _entero(fuente['build'], 0, 1 << 31),
          'hayc': contextoOk,
          'c': contextoOk ? contexto : const <String, Object?>{},
        },
      );
    });

    unawaited(alertas
        .alReportar(e.equipo, motivo: ultimo['motivo'] as String?, conUbicacion: ultimaUbicacion != null)
        .catchError((Object err) {}));

    return Respuesta.ok({
      'config': {'intervalo_s': org['intervalo_s'], 'ubicacion': conUbicacion},
      'ordenes': await ordenes.paraReporte(p.bd, e.equipo, e.tipo),
    });
  }, acceso: Acceso.equipo);

  s.ruta('POST', '/v1/ordenes/:id/estado', (p) async {
    final estado = p.texto('estado');
    if (!const {'recibida', 'hecha', 'fallida'}.contains(estado)) {
      return Respuesta.falla(400, 'estado_invalido', 'El estado es recibida, hecha o fallida');
    }
    // `hecha` y `fallida` son finales: un «recibida» que llega tarde no los
    // deshace.
    final o = await p.bd.fila(
      '''update dt.orden set estado = @s, detalle = @d, actualizada = now()
          where id = @i and equipo = @e
            and (estado in ('pendiente', 'enviada', 'vencida') or (estado = 'recibida' and @s <> 'recibida'))
          returning id, estado''',
      {'s': estado, 'd': _texto(p.cuerpo['detalle'], 500), 'i': p.enteroParam('id'), 'e': p.e.equipo},
    );
    if (o == null) {
      final existe = await p.bd.fila(
        'select estado from dt.orden where id = @i and equipo = @e',
        {'i': p.enteroParam('id'), 'e': p.e.equipo},
      );
      if (existe == null) return Respuesta.falla(404, 'no_encontrado', 'Esa orden no es de este equipo');
      return Respuesta.ok({'id': p.enteroParam('id'), 'estado': existe['estado']});
    }
    return Respuesta.ok(o);
  }, acceso: Acceso.equipo);
}

const _motivos = {'periodico', 'encendido', 'apagando', 'orden', 'abrir', 'manual'};
const _redes = {'wifi', 'datos', 'ninguna', 'otra'};

/// Un reporte del equipo, validado. Lo que no cuadra queda en null.
Map<String, Object?> _leeReporte(Map<String, Object?> r, bool conUbicacion) {
  final ahora = DateTime.now().toUtc();
  var t = DateTime.tryParse(r['t']?.toString() ?? '')?.toUtc() ?? ahora;
  // Un reloj adelantado no puede dejar reportes «del futuro» que tapen a los
  // de verdad.
  if (t.isAfter(ahora.add(const Duration(minutes: 5)))) t = ahora;
  final motivo = r['motivo']?.toString() ?? 'periodico';
  final red = _mapa(r['red']);
  final redTipo = _redes.contains(red['tipo']) ? red['tipo'] as String : null;
  final ubic = _mapa(r['ubicacion']);
  final lat = _real(ubic['lat'], -90, 90);
  final lng = _real(ubic['lng'], -180, 180);
  final hayUbic = conUbicacion && lat != null && lng != null;
  final alm = _mapa(r['almacenamiento']);
  return {
    't': t,
    'motivo': _motivos.contains(motivo) ? motivo : 'periodico',
    'bateria': _entero(r['bateria'], 0, 100),
    'cargando': r['cargando'] is bool ? r['cargando'] : null,
    'red_tipo': redTipo,
    'red_ssid': redTipo == 'wifi' ? _textoONull(red['ssid'], 64) : null,
    'lat': hayUbic ? lat : null,
    'lng': hayUbic ? lng : null,
    'precision_m': hayUbic ? _real(ubic['precision_m'], 0, 100000) : null,
    'ubicacion_t': hayUbic
        ? (DateTime.tryParse(ubic['t']?.toString() ?? '')?.toUtc() ?? t)
        : null,
    'almacenamiento_libre': _entero(alm['libre'], 0, 1 << 52),
    'almacenamiento_total': _entero(alm['total'], 0, 1 << 52),
  };
}

/// La lista de apps instaladas, acotada: `[{paquete, version, build}]`.
List<Map<String, Object?>>? _apps(Object? v) {
  if (v is! List) return null;
  final r = <Map<String, Object?>>[];
  for (final a in v.take(1000)) {
    if (a is! Map) continue;
    final paquete = _texto(a['paquete'], 200);
    if (paquete.isEmpty) continue;
    r.add({
      'paquete': paquete,
      'version': _texto(a['version'], 50),
      'build': _entero(a['build'], 0, 1 << 52),
      if (_texto(a['nombre'], 100).isNotEmpty) 'nombre': _texto(a['nombre'], 100),
    });
  }
  r.sort((a, b) => (a['paquete'] as String).compareTo(b['paquete'] as String));
  return r;
}

Map<String, Object?> _mapa(Object? v) => v is Map ? v.cast<String, Object?>() : const {};

String _texto(Object? v, int max) {
  final t = v?.toString().trim() ?? '';
  return t.length > max ? t.substring(0, max) : t;
}

String? _textoONull(Object? v, int max) {
  final t = _texto(v, max);
  return t.isEmpty ? null : t;
}

int? _entero(Object? v, int min, int max) {
  final n = v is num ? v.toInt() : int.tryParse(v?.toString() ?? '');
  if (n == null || n < min || n > max) return null;
  return n;
}

double? _real(Object? v, double min, double max) {
  final n = v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');
  if (n == null || n.isNaN || n < min || n > max) return null;
  return n;
}

