import 'dart:math';

import '../http/servidor.dart';

/// Los tableros: cada panel es una consulta de SOLO LECTURA a una ruta del
/// panel que ya existe (`/v1/resumen`, `/v1/equipos`, `/v1/alertas`) y la
/// forma de dibujarla. Los datos se calculan cada vez, con la sesión de quien
/// mira: un tablero compartido no le enseña a nadie un equipo de un dominio
/// que no alcanza.
///
/// Un panel guardado es esto (lo valida [validaPanel]):
///
///   {id, titulo, fuente: resumen|equipos|alertas, filtros: {...},
///    forma: cifra|barras|dona|tabla|mapa, campo?, agrupar?, columnas?,
///    limite?, ancho: 1|2}

const fuentesPanel = {
  'resumen': 'Las cifras de la portada (cuántos equipos, conectados, perdidos, sin contacto, alertas)',
  'equipos': 'La lista de equipos, con filtros',
  'alertas': 'Las alertas, abiertas o todas',
};

const formasPanel = {
  'cifra': 'Un número grande',
  'barras': 'Barras: cuántos hay de cada grupo',
  'dona': 'Dona: el reparto en grupos',
  'tabla': 'Una tabla con columnas',
  'mapa': 'Los equipos en el mapa (solo fuente equipos)',
};

const camposResumen = {
  'equipos': 'Equipos',
  'conectados': 'Conectados ahora',
  'perdidos': 'Perdidos',
  'sin_contacto_24h': 'Sin contacto 24 h',
  'alertas': 'Alertas abiertas',
};

/// Filtros de cada fuente → parámetro de la ruta.
const filtrosEquipos = {
  'texto': 'Busca en nombre, etiqueta, serie, modelo y asignado',
  'dominio': 'Id o slug del dominio',
  'estado': 'activo, guardado, perdido o retirado',
  'conectado': 'si o no',
  'sin_contacto_24h': 'true: activos o perdidos callados más de 24 h',
  'con_alertas': 'true: solo los que tienen alertas abiertas',
  'incluir_retirados': 'true: también los retirados',
};

const filtrosAlertas = {
  'equipo': 'Id de un equipo',
  'todas': 'true: también las cerradas',
};

const agruparEquipos = {
  'estado': 'Estado',
  'dominio': 'Dominio',
  'modelo': 'Modelo',
  'fabricante': 'Fabricante',
  'android': 'Versión de Android (API)',
  'red': 'Tipo de red',
  'wifi': 'Red Wi-Fi',
  'conectado': 'Conectado ahora',
  'bateria': 'Batería (rangos)',
  'aplicacion': 'Aplicación que reporta',
  'version_app': 'Aplicación y versión',
  'asignado_a': 'Asignado a',
  'usuario': 'Último usuario',
  'almacen': 'Almacén o lugar',
};

const columnasEquipos = {
  'nombre': 'Equipo',
  'etiqueta': 'Etiqueta',
  'dominio': 'Dominio',
  'modelo': 'Modelo',
  'estado': 'Estado',
  'conectado': 'Conectado',
  'bateria': 'Batería',
  'red': 'Red',
  'wifi': 'Wi-Fi',
  'ultima_vez': 'Última vez',
  'asignado_a': 'Asignado a',
  'usuario': 'Último usuario',
  'almacen': 'Almacén',
  'aplicacion': 'Aplicación',
  'alertas': 'Alertas',
};

const agruparAlertas = {
  'tipo': 'Tipo de regla',
  'regla': 'Regla',
  'equipo': 'Equipo',
  'dominio': 'Dominio',
  'estado': 'Abierta o cerrada',
};

const columnasAlertas = {
  'equipo': 'Equipo',
  'regla': 'Regla',
  'tipo': 'Tipo',
  'detalle': 'Detalle',
  'dominio': 'Dominio',
  'abierta': 'Abierta',
  'cerrada': 'Cerrada',
};

const maxPaneles = 12;

/// El tablero que todos tienen aunque no hayan hecho ninguno: lo mismo que la
/// portada de siempre. Con el asistente se puede copiar y cambiar.
const tableroInicial = {
  'id': 0,
  'nombre': 'Resumen',
  'propio': false,
  'compartido': false,
  'paneles': [
    {'id': 'equipos', 'titulo': 'Equipos', 'fuente': 'resumen', 'forma': 'cifra', 'campo': 'equipos', 'ancho': 1},
    {'id': 'conectados', 'titulo': 'Conectados ahora', 'fuente': 'resumen', 'forma': 'cifra', 'campo': 'conectados', 'ancho': 1},
    {'id': 'perdidos', 'titulo': 'Perdidos', 'fuente': 'resumen', 'forma': 'cifra', 'campo': 'perdidos', 'ancho': 1},
    {'id': 'sin24', 'titulo': 'Sin contacto 24 h', 'fuente': 'resumen', 'forma': 'cifra', 'campo': 'sin_contacto_24h', 'ancho': 1},
    {'id': 'alertas', 'titulo': 'Alertas abiertas', 'fuente': 'resumen', 'forma': 'cifra', 'campo': 'alertas', 'ancho': 1},
    {
      'id': 'lista-alertas',
      'titulo': 'Alertas abiertas',
      'fuente': 'alertas',
      'forma': 'tabla',
      'columnas': ['equipo', 'regla', 'detalle', 'abierta'],
      'limite': 8,
      'ancho': 2,
    },
  ],
};

/// Revisa un panel y lo deja limpio (solo lo que se conoce). Devuelve el
/// panel o el texto del error, que el asistente lee para corregirse.
(Map<String, Object?>?, String?) validaPanel(Map<String, Object?> crudo, {String? id}) {
  final fuente = '${crudo['fuente'] ?? ''}';
  final forma = '${crudo['forma'] ?? ''}';
  if (!fuentesPanel.containsKey(fuente)) return (null, 'fuente es ${fuentesPanel.keys.join(', ')}');
  if (!formasPanel.containsKey(forma)) return (null, 'forma es ${formasPanel.keys.join(', ')}');
  final titulo = '${crudo['titulo'] ?? ''}'.trim();
  if (titulo.isEmpty || titulo.length > 80) return (null, 'el panel necesita un titulo (hasta 80 letras)');
  final p = <String, Object?>{
    'id': id ?? (('${crudo['id'] ?? ''}'.trim().isNotEmpty) ? '${crudo['id']}'.trim() : _idPanel()),
    'titulo': titulo,
    'fuente': fuente,
    'forma': forma,
    'ancho': crudo['ancho'] == 2 || crudo['ancho'] == '2' ? 2 : 1,
  };

  // Filtros: solo los que entiende la fuente.
  final permitidos = switch (fuente) {
    'equipos' => filtrosEquipos,
    'alertas' => filtrosAlertas,
    _ => const <String, String>{},
  };
  final filtros = <String, Object?>{};
  final f = crudo['filtros'];
  if (f is Map) {
    for (final e in f.entries) {
      final k = '${e.key}';
      if (!permitidos.containsKey(k)) return (null, 'filtro «$k» desconocido; para $fuente: ${permitidos.keys.join(', ')}');
      if (e.value == null || '${e.value}'.trim().isEmpty) continue;
      filtros[k] = e.value is bool || e.value is num ? e.value : '${e.value}'.trim();
    }
  }
  if (filtros.isNotEmpty) p['filtros'] = filtros;

  switch (forma) {
    case 'cifra':
      if (fuente == 'resumen') {
        final campo = '${crudo['campo'] ?? ''}';
        if (!camposResumen.containsKey(campo)) return (null, 'con fuente resumen, campo es ${camposResumen.keys.join(', ')}');
        p['campo'] = campo;
      }
    case 'barras' || 'dona':
      final grupos = switch (fuente) {
        'equipos' => agruparEquipos,
        'alertas' => agruparAlertas,
        _ => const <String, String>{},
      };
      if (grupos.isEmpty) return (null, 'barras y dona son con fuente equipos o alertas');
      final agrupar = '${crudo['agrupar'] ?? ''}';
      if (!grupos.containsKey(agrupar)) return (null, 'agrupar es ${grupos.keys.join(', ')}');
      p['agrupar'] = agrupar;
    case 'tabla':
      final cols = switch (fuente) {
        'equipos' => columnasEquipos,
        'alertas' => columnasAlertas,
        _ => const <String, String>{},
      };
      if (cols.isEmpty) return (null, 'tabla es con fuente equipos o alertas');
      final pedidas = crudo['columnas'] is List ? [for (final c in crudo['columnas'] as List) '$c'] : <String>[];
      if (pedidas.isEmpty) return (null, 'la tabla necesita columnas: ${cols.keys.join(', ')}');
      for (final c in pedidas) {
        if (!cols.containsKey(c)) return (null, 'columna «$c» desconocida: ${cols.keys.join(', ')}');
      }
      p['columnas'] = pedidas.take(8).toList();
      final limite = crudo['limite'] is num ? (crudo['limite'] as num).toInt() : int.tryParse('${crudo['limite'] ?? ''}');
      p['limite'] = (limite ?? 20).clamp(1, 100);
    case 'mapa':
      if (fuente != 'equipos') return (null, 'el mapa es con fuente equipos');
  }
  if (fuente == 'resumen' && forma != 'cifra') return (null, 'con fuente resumen la forma es cifra');
  return (p, null);
}

final _azar = Random();
String _idPanel() => List.generate(8, (_) => 'abcdefghijkmnpqrstuvwxyz23456789'[_azar.nextInt(32)]).join();

/// Los datos de [paneles] para [sesion]. Cada panel lleva `datos` o `error`;
/// uno que falla no tumba a los demás.
Future<List<Map<String, Object?>>> datosDePaneles(
  Servidor s,
  Sesion sesion,
  List<Map<String, Object?>> paneles, {
  DateTime? ahora,
}) async {
  // Las consultas se repiten (cinco cifras del resumen son una sola llamada).
  final cache = <String, Future<Respuesta>>{};
  Future<Respuesta> llama(String ruta, Map<String, String> consulta) {
    final clave = '$ruta?${(consulta.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => '${e.key}=${e.value}').join('&')}';
    return cache[clave] ??= s.interna('GET', ruta, sesion: sesion, consulta: consulta);
  }

  return Future.wait([
    for (final p in paneles)
      () async {
        final base = {for (final k in ['id', 'titulo', 'fuente', 'forma', 'ancho']) k: p[k]};
        try {
          final (ruta, consulta, lista) = _consultaDe(p);
          final r = await llama(ruta, consulta);
          if (r.estado >= 300) {
            final c = r.cuerpo is Map ? r.cuerpo as Map : const {};
            return {...base, 'error': '${c['mensaje'] ?? c['error'] ?? 'HTTP ${r.estado}'}'};
          }
          final cuerpo = r.cuerpo as Map;
          if (lista == null) return {...base, 'datos': _cifraResumen(p, cuerpo)};
          final filas = [for (final f in (cuerpo[lista] as List? ?? const [])) (f as Map).cast<String, Object?>()];
          return {...base, 'datos': _datos(p, filas, ahora ?? DateTime.now())};
        } catch (e) {
          return {...base, 'error': '$e'};
        }
      }(),
  ]);
}

/// La ruta, su consulta y la lista que se toma de la respuesta (null = el
/// resumen, que es un objeto).
(String, Map<String, String>, String?) _consultaDe(Map<String, Object?> p) {
  final f = (p['filtros'] as Map?)?.cast<String, Object?>() ?? const {};
  bool si(String k) => f[k] == true || '${f[k]}' == 'true' || '${f[k]}' == '1' || '${f[k]}' == 'si';
  switch (p['fuente']) {
    case 'resumen':
      return ('/v1/resumen', const {}, null);
    case 'equipos':
      return (
        '/v1/equipos',
        {
          if (f['texto'] != null) 'q': '${f['texto']}',
          if (f['dominio'] != null) 'dominio': '${f['dominio']}',
          if (f['estado'] != null) 'estado': '${f['estado']}',
          if (f['conectado'] != null) 'conectado': si('conectado') ? '1' : '0',
          if (si('sin_contacto_24h')) 'sin_contacto': '1',
          if (si('con_alertas')) 'alerta': '1',
          if (si('incluir_retirados')) 'retirados': '1',
        },
        'equipos',
      );
    case 'alertas':
      return (
        '/v1/alertas',
        {
          if (f['equipo'] != null) 'equipo': '${f['equipo']}',
          if (si('todas')) 'todas': '1',
          'limite': '2000',
        },
        'alertas',
      );
  }
  throw StateError('fuente ${p['fuente']}');
}

Map<String, Object?> _cifraResumen(Map<String, Object?> p, Map cuerpo) {
  final campo = '${p['campo']}';
  final enlace = switch (campo) {
    'equipos' => '#/panel/equipos?todos=1',
    'conectados' => '#/panel/equipos?conectado=1',
    'perdidos' => '#/panel/equipos?estado=perdido',
    'sin_contacto_24h' => '#/panel/equipos?conectado=sin24',
    'alertas' => '#/panel/alertas',
    _ => null,
  };
  final valor = (cuerpo[campo] as num?)?.toInt() ?? 0;
  return {
    'valor': valor,
    'enlace': ?enlace,
    // Lo que el panel pinta en rojo cuando no es cero.
    'alarma': const {'perdidos', 'sin_contacto_24h', 'alertas'}.contains(campo) && valor > 0,
  };
}

Map<String, Object?> _datos(Map<String, Object?> p, List<Map<String, Object?>> filas, DateTime ahora) {
  final equipos = p['fuente'] == 'equipos';
  switch (p['forma']) {
    case 'cifra':
      return {'valor': filas.length};
    case 'barras' || 'dona':
      final cuenta = <String, int>{};
      for (final f in filas) {
        final g = !equipos
            ? valorAlerta(f, '${p['agrupar']}', ahora)
            : p['agrupar'] == 'bateria'
            ? rangoBateria(f['bateria'])
            : valorEquipo(f, '${p['agrupar']}');
        final clave = (g == null || '$g'.trim().isEmpty) ? 'Sin dato' : '$g';
        cuenta[clave] = (cuenta[clave] ?? 0) + 1;
      }
      final orden = cuenta.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      final series = [for (final e in orden.take(11)) {'etiqueta': e.key, 'valor': e.value}];
      if (orden.length > 11) {
        series.add({'etiqueta': 'Otros', 'valor': orden.skip(11).fold<int>(0, (t, e) => t + e.value)});
      }
      return {'series': series, 'total': filas.length};
    case 'tabla':
      final cols = [for (final c in p['columnas'] as List) '$c'];
      final titulos = equipos ? columnasEquipos : columnasAlertas;
      final limite = (p['limite'] as int?) ?? 20;
      return {
        'columnas': [for (final c in cols) {'id': c, 'titulo': titulos[c]}],
        'filas': [
          for (final f in filas.take(limite))
            {
              'id': equipos ? f['id'] : f['equipo'],
              'valores': [for (final c in cols) equipos ? valorEquipo(f, c) : valorAlerta(f, c, ahora)],
            },
        ],
        'total': filas.length,
      };
    case 'mapa':
      return {
        'puntos': [
          for (final f in filas)
            if (f['lat'] != null)
              {
                'id': f['id'],
                'nombre': f['nombre'],
                'lat': f['lat'],
                'lng': f['lng'],
                'estado': f['estado'],
                'conectado': f['conectado'],
                'bateria': f['bateria'],
                'alertas': f['alertas'],
              },
        ],
        'total': filas.length,
      };
  }
  return const {};
}

/// Lo que vale [campo] en un equipo de `/v1/equipos`, para agrupar o para una
/// columna.
Object? valorEquipo(Map<String, Object?> e, String campo) {
  final fuentes = [for (final f in (e['fuentes'] as List?) ?? const []) (f as Map).cast<String, Object?>()];
  final reciente = fuentes.isEmpty ? null : fuentes.first;
  // El usuario y el lugar: de la fuente más reciente que los diga.
  Map<String, Object?>? contextoCon(String k) {
    for (final f in fuentes) {
      final c = f['contexto'];
      if (c is Map && '${c[k] ?? ''}'.trim().isNotEmpty) return c.cast<String, Object?>();
    }
    return null;
  }

  switch (campo) {
    case 'dominio':
      return e['dominio_nombre'];
    case 'conectado':
      return e['conectado'] == true ? 'Conectado' : 'Desconectado';
    case 'red':
      return e['red_tipo'];
    case 'wifi':
      return e['red_ssid'];
    case 'android':
      return e['android'] == null ? null : 'API ${e['android']}';
    case 'bateria':
      return e['bateria'];
    case 'aplicacion':
      return reciente == null ? null : _nombreApp(reciente);
    case 'version_app':
      return reciente == null ? null : '${_nombreApp(reciente)} ${reciente['version'] ?? ''}'.trim();
    case 'usuario':
      return contextoCon('usuario')?['usuario'];
    case 'almacen':
      final c = contextoCon('almacen') ?? contextoCon('lugar');
      return c?['almacen'] ?? c?['lugar'];
    case 'ultima_vez':
      return e['ultima_vez'];
    default:
      return e[campo];
  }
}

/// Para agrupar por batería: en rangos, no un grupo por cada porcentaje.
String? rangoBateria(Object? b) {
  if (b is! num) return null;
  if (b <= 15) return '0–15 %';
  if (b <= 50) return '16–50 %';
  return '51–100 %';
}

String _nombreApp(Map<String, Object?> f) {
  final n = '${f['nombre'] ?? ''}'.trim();
  return n.isNotEmpty ? n : '${f['paquete'] ?? ''}';
}

Object? valorAlerta(Map<String, Object?> a, String campo, DateTime ahora) {
  switch (campo) {
    case 'equipo':
      return a['equipo_nombre'];
    case 'regla':
      final r = '${a['regla_nombre'] ?? ''}'.trim();
      return r.isNotEmpty ? r : _tipos[a['tipo']] ?? a['tipo'];
    case 'tipo':
      return _tipos[a['tipo']] ?? a['tipo'];
    case 'dominio':
      return a['dominio_nombre'];
    case 'estado':
      return a['cerrada'] == null ? 'Abierta' : 'Cerrada';
    case 'detalle':
      return detalleCorto('${a['tipo']}', (a['detalle'] as Map?)?.cast<String, Object?>() ?? const {});
    default:
      return a[campo];
  }
}

const _tipos = {
  'sin_reporte': 'Sin reporte',
  'bateria_baja': 'Batería baja',
  'fuera_de_zona': 'Fuera de zona',
  'apagado': 'Apagado',
};

String detalleCorto(String tipo, Map<String, Object?> d) => switch (tipo) {
  'bateria_baja' => '${d['bateria'] ?? '?'} % (umbral ${d['porcentaje'] ?? '?'} %)',
  'fuera_de_zona' => 'a ${d['distancia_m'] ?? '?'} m de ${d['zona'] ?? 'la zona'}',
  'sin_reporte' => 'sin contacto (${d['minutos'] ?? '?'} min)',
  'apagado' => 'avisó que se apagaba',
  _ => '',
};
