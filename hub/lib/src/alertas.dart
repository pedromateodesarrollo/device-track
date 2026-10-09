import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'correo.dart';
import 'db.dart';
import 'dominios.dart';
import 'geo.dart';
import 'log.dart';

/// Las reglas que vigilan a los equipos y las alertas que abren.
///
/// Se evalúan en dos momentos. Al llegar un reporte: batería baja, fuera de
/// zona, apagado (y cualquier contacto cierra «sin reporte»). Y cada minuto,
/// para lo que se nota justamente porque NO llega nada: el equipo que pasó una
/// hora callado.
///
/// Solo puede haber una alerta abierta por regla y equipo (índice parcial):
/// que la batería siga baja en el reporte siguiente no abre otra.
class Alertas {
  Alertas(this.bd, {this.urlPublica = ''});

  final Bd bd;

  /// Para el enlace al panel en los correos. Vacía, el correo va sin enlace.
  final String urlPublica;
  Timer? _reloj;

  /// Estados que se vigilan. Uno guardado en una gaveta o ya retirado no
  /// tiene por qué dar alertas; uno perdido, sí (es justo el que se busca).
  static const _vigilados = "('activo', 'perdido')";

  void arranca() {
    _reloj ??= Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(revisaSinReporte().catchError((Object e) {
        log.aviso('alertas', 'revisión de «sin reporte» falló: $e');
        return 0;
      }));
    });
  }

  void detiene() {
    _reloj?.cancel();
    _reloj = null;
  }

  /// Después de guardar un reporte. [motivo] es el del reporte más nuevo;
  /// [conUbicacion], si ese lote trajo una posición.
  Future<void> alReportar(int equipo, {String? motivo, bool conUbicacion = false}) async {
    final e = await bd.fila(
      '''select id, org, dominio, estado, bateria, cargando, lat, lng, precision_m
           from dt.equipo where id = @e and estado in $_vigilados''',
      {'e': equipo},
    );
    if (e == null) return;
    final reglas = await _reglasDe(e);
    for (final r in reglas) {
      final params = (r['parametros'] as Map?)?.cast<String, Object?>() ?? const {};
      switch (r['tipo']) {
        case 'sin_reporte':
          await _cierra(r, e);
        case 'bateria_baja':
          final b = e['bateria'] as int?;
          if (b == null) break;
          final tope = (params['porcentaje'] as num?)?.toInt() ?? 15;
          if (b < tope && e['cargando'] != true) {
            await _abre(r, e, {'bateria': b, 'porcentaje': tope});
          } else {
            await _cierra(r, e);
          }
        case 'fuera_de_zona':
          if (!conUbicacion || e['lat'] == null) break;
          final z = await bd.fila(
            'select id, nombre, lat, lng, radio_m from dt.zona where id = @z and org = @o',
            {'z': (params['zona'] as num?)?.toInt() ?? 0, 'o': e['org']},
          );
          if (z == null) break;
          final d = distanciaM(
            e['lat'] as double,
            e['lng'] as double,
            z['lat'] as double,
            z['lng'] as double,
          );
          final precision = (e['precision_m'] as num?)?.toDouble() ?? 0;
          final radio = (z['radio_m'] as int).toDouble();
          // Fuera solo si ni siquiera con el margen de error de la lectura
          // cae dentro: un GPS con 80 m de error junto a la pared del almacén
          // no es un equipo que se fue.
          if (d - precision > radio) {
            await _abre(r, e, {'zona': z['nombre'], 'distancia_m': d.round(), 'radio_m': z['radio_m']});
          } else if (d <= radio) {
            await _cierra(r, e);
          }
        case 'apagado':
          if (motivo == 'apagando') {
            await _abre(r, e, {});
          } else if (motivo != null) {
            await _cierra(r, e);
          }
      }
    }
  }

  /// Hubo contacto (el WebSocket se abrió): cierra «sin reporte».
  Future<void> alContacto(int equipo) async {
    final e = await bd.fila(
      'select id, org, dominio, estado from dt.equipo where id = @e and estado in $_vigilados',
      {'e': equipo},
    );
    if (e == null) return;
    for (final r in await _reglasDe(e)) {
      if (r['tipo'] == 'sin_reporte') await _cierra(r, e);
    }
  }

  /// Abre «sin reporte» a los equipos que pasaron su plazo callados y sin
  /// socket. Devuelve cuántas abrió.
  Future<int> revisaSinReporte() async {
    final abiertas = await bd.filas(
      '''insert into dt.alerta (org, equipo, regla, tipo, detalle)
         select e.org, e.id, r.id, 'sin_reporte',
                jsonb_build_object('ultima_vez', e.ultima_vez,
                                   'minutos', (r.parametros->>'minutos')::int)
           from dt.regla r
           join dt.equipo e on e.org = r.org
                           and (r.dominio is null or r.dominio = e.dominio)
                           and e.estado in $_vigilados
                           and not e.conectado
          where r.activa and r.tipo = 'sin_reporte'
            and e.ultima_vez < now() - make_interval(mins => coalesce((r.parametros->>'minutos')::int, 60))
         on conflict (regla, equipo) where cerrada is null do nothing
         returning id''',
    );
    for (final a in abiertas) {
      unawaited(_avisa(a['id'] as int, 'alerta_abierta'));
    }
    return abiertas.length;
  }

  /// Cierra a mano. Si la condición sigue, la próxima evaluación la vuelve a
  /// abrir: cerrar no apaga la regla. Con [dominios], solo la de un equipo de
  /// esos dominios.
  Future<bool> cierraAMano(int org, int alerta, String nota, {List<int>? dominios}) async {
    final r = await bd.fila(
      '''update dt.alerta set cerrada = now(), nota = @n
          where id = @a and org = @o and cerrada is null
            and equipo in (select id from dt.equipo where org = @o and ${enDominios(dominios, 'dominio')})
          returning id''',
      {'a': alerta, 'o': org, 'n': nota},
    );
    if (r == null) return false;
    unawaited(_avisa(alerta, 'alerta_cerrada'));
    return true;
  }

  Future<List<Map<String, Object?>>> _reglasDe(Map<String, Object?> e) => bd.filas(
        '''select id, tipo, parametros from dt.regla
            where org = @o and activa and (dominio is null or dominio = @d)''',
        {'o': e['org'], 'd': e['dominio']},
      );

  Future<void> _abre(Map<String, Object?> regla, Map<String, Object?> e, Map<String, Object?> detalle) async {
    final a = await bd.fila(
      '''insert into dt.alerta (org, equipo, regla, tipo, detalle)
         values (@o, @e, @r, @t, @d)
         on conflict (regla, equipo) where cerrada is null do nothing
         returning id''',
      {'o': e['org'], 'e': e['id'], 'r': regla['id'], 't': regla['tipo'], 'd': detalle},
    );
    if (a != null) unawaited(_avisa(a['id'] as int, 'alerta_abierta'));
  }

  Future<void> _cierra(Map<String, Object?> regla, Map<String, Object?> e) async {
    final a = await bd.fila(
      '''update dt.alerta set cerrada = now()
          where regla = @r and equipo = @e and cerrada is null returning id''',
      {'r': regla['id'], 'e': e['id']},
    );
    if (a != null) unawaited(_avisa(a['id'] as int, 'alerta_cerrada'));
  }

  /// Avisa de una alerta que se abrió o se cerró: el webhook de la
  /// organización y, si la regla tiene a quién avisar, un correo.
  Future<void> _avisa(int alerta, String evento) async {
    final Map<String, Object?>? a;
    try {
      a = await bd.fila(
        '''select a.id, a.tipo, a.abierta, a.cerrada, a.detalle, a.nota, a.regla, a.equipo,
                  r.id as regla_id, r.nombre as regla_nombre, r.avisar,
                  e.id as equipo_id, e.nombre as equipo_nombre, e.etiqueta, e.asignado_a,
                  e.lat, e.lng, e.ubicacion_t, e.bateria,
                  d.id as dominio_id, d.nombre as dominio_nombre, d.slug as dominio_slug,
                  o.id as org_id, o.nombre as org_nombre, o.webhook_url, o.webhook_secreto, o.correo
             from dt.alerta a
             join dt.regla r on r.id = a.regla
             join dt.equipo e on e.id = a.equipo
             join dt.dominio d on d.id = e.dominio
             join dt.org o on o.id = a.org
            where a.id = @a''',
        {'a': alerta},
      );
    } catch (e) {
      log.aviso('alertas', 'alerta $alerta ($evento): $e');
      return;
    }
    if (a == null) return;
    await _webhook(a, evento);
    if (evento == 'alerta_abierta') await _correo(a);
  }

  /// El webhook: un POST con la alerta, firmado con HMAC-SHA256 en
  /// `X-Device-Track-Firma` para que quien lo recibe sepa que es de aquí. Sin
  /// reintentos: lo que no llega se ve en el panel igual.
  Future<void> _webhook(Map<String, Object?> a, String evento) async {
    final url = (a['webhook_url'] as String?) ?? '';
    if (url.isEmpty) return;
    try {
      final cuerpo = jsonEncode({
        'evento': evento,
        'alerta': {
          'id': a['id'],
          'tipo': a['tipo'],
          'abierta': a['abierta'],
          'cerrada': a['cerrada'],
          'detalle': a['detalle'],
          'nota': a['nota'],
        },
        'regla': {'id': a['regla_id'], 'nombre': a['regla_nombre']},
        'equipo': {
          'id': a['equipo_id'],
          'nombre': a['equipo_nombre'],
          'etiqueta': a['etiqueta'],
          'dominio': {'id': a['dominio_id'], 'nombre': a['dominio_nombre'], 'slug': a['dominio_slug']},
          'asignado_a': a['asignado_a'],
          'bateria': a['bateria'],
          'ubicacion': a['lat'] == null
              ? null
              : {'lat': a['lat'], 'lng': a['lng'], 't': a['ubicacion_t']},
        },
        'org': {'id': a['org_id'], 'nombre': a['org_nombre']},
      }, toEncodable: (v) => v is DateTime ? v.toUtc().toIso8601String() : v.toString());
      final codigo = await _postea(url, (a['webhook_secreto'] as String?) ?? '', evento, cuerpo);
      if (codigo >= 300) {
        log.aviso('webhook', 'org ${a['org_id']}: $evento de la alerta ${a['id']} → HTTP $codigo');
      }
    } catch (e) {
      log.aviso('webhook', 'alerta ${a['id']} ($evento): $e');
    }
  }

  /// El correo a la lista de la regla (migración 0006), por el correo de
  /// salida de la organización. Solo al abrirse: el cierre se ve en el panel.
  /// La misma regla no vuelve a escribir por el mismo equipo antes de una
  /// hora, aunque la alerta se haya cerrado y abierto otra vez.
  Future<void> _correo(Map<String, Object?> a) async {
    final para = [for (final c in (a['avisar'] as List?) ?? const []) '$c'];
    if (para.isEmpty) return;
    final c = ConfigCorreo.deJson(a['correo']);
    if (c == null || !c.completa) return;
    try {
      // Se marca antes de mandar: dos reportes casi juntos no mandan dos.
      final marcada = await bd.fila(
        '''update dt.alerta set avisada_correo = now()
            where id = @a and avisada_correo is null
              and not exists (select 1 from dt.alerta x
                               where x.regla = @r and x.equipo = @e and x.id <> @a
                                 and x.avisada_correo > now() - interval '1 hour')
            returning id''',
        {'a': a['id'], 'r': a['regla'], 'e': a['equipo']},
      );
      if (marcada == null) return;
    } catch (e) {
      log.aviso('correo', 'alerta ${a['id']}: $e');
      return;
    }
    final m = correoDeAlerta(a, urlPublica: urlPublica);
    var fallidos = 0;
    for (final destino in para) {
      try {
        await enviaCorreo(c, para: destino, asunto: m.asunto, texto: m.texto, html: m.html);
      } on CorreoError catch (e) {
        fallidos++;
        log.aviso('correo', 'org ${a['org_id']}: aviso de la alerta ${a['id']} → ${e.codigo}: ${e.detalle}');
      } catch (e) {
        fallidos++;
        log.aviso('correo', 'org ${a['org_id']}: aviso de la alerta ${a['id']} → $e');
      }
    }
    if (fallidos > 0) {
      log.aviso('correo', 'org ${a['org_id']}: alerta ${a['id']}, $fallidos de ${para.length} avisos no salieron');
    }
  }

  /// Un POST de prueba al webhook de [org]. Devuelve el código HTTP que
  /// contestó, o 0 si no se pudo llegar.
  Future<int> pruebaWebhook(int org) async {
    final o = await bd.fila(
      'select id, nombre, webhook_url, webhook_secreto from dt.org where id = @o',
      {'o': org},
    );
    final url = (o?['webhook_url'] as String?) ?? '';
    if (url.isEmpty) return 0;
    try {
      return await _postea(
        url,
        (o!['webhook_secreto'] as String?) ?? '',
        'prueba',
        jsonEncode({
          'evento': 'prueba',
          'org': {'id': o['id'], 'nombre': o['nombre']},
          'mensaje': 'Prueba del webhook de device-track',
        }),
      );
    } catch (e) {
      log.aviso('webhook', 'prueba de la org $org: $e');
      return 0;
    }
  }

  /// Manda [cuerpo] firmado. Devuelve el código HTTP.
  static Future<int> _postea(String url, String secreto, String evento, String cuerpo) async {
    final firma = Hmac(sha256, utf8.encode(secreto)).convert(utf8.encode(cuerpo)).toString();
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final pet = await c.postUrl(Uri.parse(url));
      pet.headers
        ..contentType = ContentType.json
        ..set('x-device-track-evento', evento)
        ..set('x-device-track-firma', 'sha256=$firma');
      pet.write(cuerpo);
      final res = await pet.close().timeout(const Duration(seconds: 15));
      await res.drain<void>();
      return res.statusCode;
    } finally {
      c.close(force: true);
    }
  }
}

/// El correo de una alerta que se abrió. Público para las pruebas.
({String asunto, String texto, String html}) correoDeAlerta(Map<String, Object?> a, {String urlPublica = '', DateTime? ahora}) {
  final tipo = '${a['tipo']}';
  final regla = '${a['regla_nombre'] ?? ''}'.trim();
  final queEs = regla.isNotEmpty ? regla : (_nombresTipo[tipo] ?? tipo);
  final equipo = '${a['equipo_nombre'] ?? ''}'.trim().isNotEmpty ? '${a['equipo_nombre']}' : 'Equipo ${a['equipo_id']}';
  final etiqueta = '${a['etiqueta'] ?? ''}'.trim();
  final detalle = detalleDeAlerta(tipo, (a['detalle'] as Map?)?.cast<String, Object?>() ?? const {}, ahora: ahora);
  final lineas = <(String, String)>[
    ('Equipo', etiqueta.isEmpty ? equipo : '$equipo ($etiqueta)'),
    ('Dominio', '${a['dominio_nombre'] ?? ''}'),
    if ('${a['asignado_a'] ?? ''}'.trim().isNotEmpty) ('Asignado a', '${a['asignado_a']}'),
    if (a['bateria'] != null) ('Batería', '${a['bateria']} %'),
  ];
  final mapa = a['lat'] == null
      ? ''
      : 'https://www.openstreetmap.org/?mlat=${a['lat']}&mlon=${a['lng']}#map=17/${a['lat']}/${a['lng']}';
  final panel = urlPublica.isEmpty ? '' : '$urlPublica/#/panel/equipos/${a['equipo_id']}';
  final pie = 'Te llega porque estás en la lista de avisos de la regla «$queEs» de ${a['org_nombre']}. '
      'Para dejar de recibirlos, que te quiten de esa regla en Reglas y zonas.';

  final texto = StringBuffer()
    ..writeln('$queEs: $detalle')
    ..writeln();
  for (final (k, v) in lineas) {
    texto.writeln('$k: $v');
  }
  if (mapa.isNotEmpty) texto.writeln('Última ubicación: $mapa');
  if (panel.isNotEmpty) texto.writeln('Ver en el panel: $panel');
  texto
    ..writeln()
    ..writeln(pie);

  String h(String t) => const HtmlEscape().convert(t);
  final html = StringBuffer()
    ..write('<div style="font-family:system-ui,sans-serif;font-size:15px;color:#1c2430;max-width:560px">')
    ..write('<p style="font-size:17px;margin:0 0 14px"><strong>${h(queEs)}</strong>: ${h(detalle)}</p>')
    ..write('<table style="border-collapse:collapse;margin:0 0 14px">');
  for (final (k, v) in lineas) {
    html.write('<tr><td style="padding:3px 14px 3px 0;color:#5b6573">${h(k)}</td><td style="padding:3px 0">${h(v)}</td></tr>');
  }
  html.write('</table>');
  if (mapa.isNotEmpty) html.write('<p style="margin:0 0 8px"><a href="${h(mapa)}">Ver la última ubicación en el mapa</a></p>');
  if (panel.isNotEmpty) html.write('<p style="margin:0 0 8px"><a href="${h(panel)}">Abrir el equipo en el panel</a></p>');
  html.write('<p style="color:#5b6573;font-size:13px;margin-top:22px">${h(pie)}</p></div>');

  return (asunto: '$queEs: $equipo', texto: texto.toString(), html: html.toString());
}

/// Lo mismo que dice el panel de cada alerta (`detalleAlerta` en api.js),
/// pero con el tiempo relativo: un correo no sabe en qué huso lo leen.
String detalleDeAlerta(String tipo, Map<String, Object?> d, {DateTime? ahora}) {
  switch (tipo) {
    case 'bateria_baja':
      return '${d['bateria'] ?? '?'} % (umbral ${d['porcentaje'] ?? '?'} %)';
    case 'fuera_de_zona':
      final radio = d['radio_m'] is num ? ' (radio ${_distancia(d['radio_m'] as num)})' : '';
      final dist = d['distancia_m'] is num ? _distancia(d['distancia_m'] as num) : '?';
      return 'a $dist de ${d['zona'] ?? 'la zona'}$radio';
    case 'sin_reporte':
      final desde = DateTime.tryParse('${d['ultima_vez'] ?? ''}');
      if (desde == null) return 'sin contacto en ${d['minutos'] ?? '?'} min';
      return 'sin contacto desde hace ${_lapso((ahora ?? DateTime.now()).difference(desde))}';
    case 'apagado':
      return 'avisó que se estaba apagando';
    default:
      return '';
  }
}

const _nombresTipo = {
  'sin_reporte': 'Sin reporte',
  'bateria_baja': 'Batería baja',
  'fuera_de_zona': 'Fuera de zona',
  'apagado': 'Apagado',
};

String _distancia(num m) => m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';

String _lapso(Duration d) {
  final min = d.inMinutes;
  if (min < 60) return '$min min';
  final h = d.inHours;
  if (h < 48) return min % 60 == 0 ? '$h h' : '$h h ${min % 60} min';
  return '${d.inDays} días';
}
