import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'db.dart';
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
  Alertas(this.bd);

  final Bd bd;
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
      '''select id, org, grupo, estado, bateria, cargando, lat, lng, precision_m
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
      'select id, org, grupo, estado from dt.equipo where id = @e and estado in $_vigilados',
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
                           and (r.grupo = '' or r.grupo = e.grupo)
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
  /// abrir: cerrar no apaga la regla.
  Future<bool> cierraAMano(int org, int alerta, String nota) async {
    final r = await bd.fila(
      '''update dt.alerta set cerrada = now(), nota = @n
          where id = @a and org = @o and cerrada is null returning id''',
      {'a': alerta, 'o': org, 'n': nota},
    );
    if (r == null) return false;
    unawaited(_avisa(alerta, 'alerta_cerrada'));
    return true;
  }

  Future<List<Map<String, Object?>>> _reglasDe(Map<String, Object?> e) => bd.filas(
        '''select id, tipo, parametros from dt.regla
            where org = @o and activa and (grupo = '' or grupo = @g)''',
        {'o': e['org'], 'g': e['grupo']},
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

  /// El webhook de la organización: un POST con la alerta, firmado con
  /// HMAC-SHA256 en `X-Device-Track-Firma` para que quien lo recibe sepa que
  /// es de aquí. Sin reintentos: lo que no llega se ve en el panel igual.
  Future<void> _avisa(int alerta, String evento) async {
    try {
      final a = await bd.fila(
        '''select a.id, a.tipo, a.abierta, a.cerrada, a.detalle, a.nota,
                  r.id as regla_id, r.nombre as regla_nombre,
                  e.id as equipo_id, e.nombre as equipo_nombre, e.etiqueta, e.grupo, e.asignado_a,
                  e.lat, e.lng, e.ubicacion_t, e.bateria,
                  o.id as org_id, o.nombre as org_nombre, o.webhook_url, o.webhook_secreto
             from dt.alerta a
             join dt.regla r on r.id = a.regla
             join dt.equipo e on e.id = a.equipo
             join dt.org o on o.id = a.org
            where a.id = @a''',
        {'a': alerta},
      );
      if (a == null) return;
      final url = (a['webhook_url'] as String?) ?? '';
      if (url.isEmpty) return;
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
          'grupo': a['grupo'],
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
        log.aviso('webhook', 'org ${a['org_id']}: $evento de la alerta $alerta → HTTP $codigo');
      }
    } catch (e) {
      log.aviso('webhook', 'alerta $alerta ($evento): $e');
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
