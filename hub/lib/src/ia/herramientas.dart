import 'dart:convert';

import '../db.dart';
import '../http/servidor.dart';
import 'proveedor.dart';
import 'tableros.dart';

/// Las herramientas del asistente: cada una es una ruta del panel que ya
/// existe, llamada por dentro con la sesión de la persona que pregunta
/// ([Servidor.interna]). El asistente no tiene caminos propios: ve y hace lo
/// mismo que esa persona en la pantalla, con su rol y sus dominios.
///
/// Las que cambian algo ([Herramienta.cambia]) no se ejecutan al pedirlas:
/// quedan como propuesta y la persona la confirma con un botón. Las que se
/// pueden ensayar ([Herramienta.ensayable]: solo tocan la base) se corren
/// antes dentro de una transacción que se deshace, para que lo que se propone
/// ya se sepa que va a funcionar.

/// Con qué corre una herramienta.
class Contexto {
  Contexto({required this.servidor, required this.sesion, this.urlPublica = ''});

  final Servidor servidor;
  final Sesion sesion;
  final String urlPublica;

  Future<Respuesta> llama(
    String metodo,
    String ruta, {
    Map<String, String> consulta = const {},
    Map<String, Object?> cuerpo = const {},
    Bd? bd,
  }) => servidor.interna(
    metodo,
    ruta,
    sesion: sesion,
    consulta: consulta,
    cuerpo: cuerpo,
    urlPublica: urlPublica,
    bd: bd,
  );
}

typedef Corre = Future<Respuesta> Function(Contexto c, Map<String, Object?> a, Bd? bd);

class Herramienta {
  const Herramienta({
    required this.nombre,
    required this.descripcion,
    required this.titulo,
    required this.corre,
    this.parametros = const {'type': 'object', 'properties': {}},
    this.permiso = 'leer',
    this.cambia = false,
    this.ensayable = false,
    this.recorta,
  });

  final String nombre;
  final String descripcion;

  /// Lo que ve la persona mientras corre («Consultando los equipos»).
  final String titulo;
  final Map<String, Object?> parametros;

  /// El permiso que pide su ruta: si la sesión no lo tiene, al modelo ni se
  /// le ofrece.
  final String permiso;
  final bool cambia;
  final bool ensayable;
  final Corre corre;

  /// Deja el resultado en lo que el modelo necesita (sin la lista de apps
  /// entera de cada equipo, por ejemplo).
  final Object? Function(Object? cuerpo)? recorta;

  IaHerramienta get definicion => IaHerramienta(
    nombre: nombre,
    descripcion: cambia
        ? '$descripcion NO se ejecuta al pedirla: queda propuesta y la persona la confirma con un botón.'
        : descripcion,
    parametros: cambia ? _conResumen(parametros) : parametros,
  );

  /// Lo que se le devuelve al modelo de una respuesta de la ruta.
  Object? resultado(Respuesta r) {
    if (r.estado >= 300) {
      final c = r.cuerpo is Map ? r.cuerpo as Map : const {};
      return {'error': c['error'] ?? 'http_${r.estado}', 'mensaje': c['mensaje'] ?? ''};
    }
    if (r.cuerpo == null) return {'ok': true};
    return recorta == null ? r.cuerpo : recorta!(r.cuerpo);
  }
}

/// Las herramientas que se le ofrecen a [sesion]: las que su rol permite.
List<Herramienta> herramientasPara(Sesion sesion) => [for (final h in herramientas) if (sesion.puede(h.permiso)) h];

Herramienta? herramienta(String nombre) {
  for (final h in herramientas) {
    if (h.nombre == nombre) return h;
  }
  return null;
}

/// El texto que acompaña una propuesta: lo escribe el modelo.
Map<String, Object?> _conResumen(Map<String, Object?> p) {
  final props = {...(p['properties'] as Map).cast<String, Object?>()};
  props['resumen'] = _texto(
    'Qué se va a hacer, en una frase y en español, para que la persona lo confirme. '
    'Con nombres, no ids: «Crear la regla Batería baja para Duralon, por debajo de 15 %, avisando a ana@x.com».',
  );
  return {
    ...p,
    'properties': props,
    'required': [...((p['required'] as List?) ?? const []), 'resumen'],
  };
}

// ── esquemas ──────────────────────────────────────────────────────────────────

Map<String, Object?> _obj(Map<String, Object?> props, [List<String> requeridos = const []]) => {
  'type': 'object',
  'properties': props,
  if (requeridos.isNotEmpty) 'required': requeridos,
};
Map<String, Object?> _texto(String d, [List<String>? valores]) => {
  'type': 'string',
  'description': d,
  'enum': ?valores,
};
Map<String, Object?> _entero(String d) => {'type': 'integer', 'description': d};
Map<String, Object?> _numero(String d) => {'type': 'number', 'description': d};
Map<String, Object?> _si(String d) => {'type': 'boolean', 'description': d};
Map<String, Object?> _lista(Map<String, Object?> items, String d) => {'type': 'array', 'items': items, 'description': d};

final _idEquipo = _entero('Id del equipo (sale de listar_equipos)');
final _desde = _texto('Desde, fecha y hora ISO 8601 en UTC. Sin ella, 24 horas antes de «hasta»');
final _hasta = _texto('Hasta, fecha y hora ISO 8601 en UTC. Sin ella, ahora');
final _dominio = _texto('Id o slug del dominio (sale de listar_dominios)');
final _parametrosRegla = _obj({
  'minutos': _entero('sin_reporte: minutos sin contacto (5 a 10080)'),
  'porcentaje': _entero('bateria_baja: por debajo de este porcentaje (1 a 99)'),
  'zona': _entero('fuera_de_zona: id de la zona (sale de listar_zonas)'),
});
final _avisar = _lista(
  _texto('Correo'),
  'Correos a los que se escribe cuando la regla abre una alerta (hasta 20). Lista vacía = nadie. '
  'Sale por el correo de salida de la organización',
);

final _panel = _obj({
  'titulo': _texto('Título del panel, corto'),
  'fuente': _texto(fuentesPanel.entries.map((e) => '${e.key}: ${e.value}').join('; '), fuentesPanel.keys.toList()),
  'forma': _texto(formasPanel.entries.map((e) => '${e.key}: ${e.value}').join('; '), formasPanel.keys.toList()),
  'campo': _texto('Con fuente resumen y forma cifra: ${camposResumen.keys.join(', ')}'),
  'agrupar': _texto(
    'Con barras o dona. Equipos: ${agruparEquipos.keys.join(', ')}. Alertas: ${agruparAlertas.keys.join(', ')}',
  ),
  'columnas': _lista(
    _texto('Columna'),
    'Con tabla. Equipos: ${columnasEquipos.keys.join(', ')}. Alertas: ${columnasAlertas.keys.join(', ')}',
  ),
  'filtros': _obj({
    for (final e in filtrosEquipos.entries) e.key: _texto('Equipos: ${e.value}'),
    for (final e in filtrosAlertas.entries) e.key: _texto('Alertas: ${e.value}'),
  }),
  'limite': _entero('Con tabla: cuántas filas (1 a 100, 20 si no se dice)'),
  'ancho': _entero('1 (normal) o 2 (doble, para tablas y mapas)'),
}, ['titulo', 'fuente', 'forma']);

// ── recortes ──────────────────────────────────────────────────────────────────

/// Un equipo de la lista, en lo que el modelo necesita.
Map<String, Object?> _equipoCorto(Map e) {
  final m = e.cast<String, Object?>();
  final app = valorEquipo(m, 'version_app');
  return {
    for (final k in [
      'id', 'nombre', 'etiqueta', 'serie', 'modelo', 'estado', 'conectado', 'ultima_vez', 'bateria',
      'cargando', 'red_tipo', 'red_ssid', 'lat', 'lng', 'precision_m', 'ubicacion_t', 'asignado_a', 'alertas',
    ])
      if (m[k] != null && m[k] != '') k: m[k],
    'dominio': m['dominio_nombre'],
    'app': ?app,
    'usuario': ?valorEquipo(m, 'usuario'),
    'almacen': ?valorEquipo(m, 'almacen'),
  };
}

Object? _recortaEquipos(Object? c) {
  final lista = ((c as Map)['equipos'] as List?) ?? const [];
  return {
    'total': lista.length,
    'equipos': [for (final e in lista.take(300)) _equipoCorto(e as Map)],
    if (lista.length > 300) 'nota': 'Hay ${lista.length}; van los primeros 300. Filtra para ver otros.',
  };
}

Object? _recortaEquipo(Object? c) {
  final e = (c as Map).cast<String, Object?>();
  final apps = (e['apps'] as List?) ?? const [];
  return {
    ...e..remove('apps'),
    'apps_total': apps.length,
    'apps': [
      for (final a in apps.take(150))
        if (a is Map) {'nombre': a['nombre'], 'paquete': a['paquete'], 'version': a['version']},
    ],
  };
}

/// Un recorrido de miles de puntos no le sirve a nadie entero: uno de cada n.
Object? _recortaRecorrido(Object? c) {
  final m = (c as Map).cast<String, Object?>();
  final puntos = (m['puntos'] as List?) ?? const [];
  if (puntos.length <= 200) return m;
  final paso = (puntos.length / 200).ceil();
  return {
    ...m,
    'puntos': [for (var i = 0; i < puntos.length; i += paso) puntos[i], puntos.last],
    'nota': '${puntos.length} puntos; va uno de cada $paso y el último.',
  };
}

Object? _sinSecretosOrg(Object? c) {
  final m = {...(c as Map).cast<String, Object?>()};
  m.remove('webhook_url');
  final correo = m.remove('correo');
  if (correo is Map) m['correo_de_salida'] = correo['configurado'] == true;
  return m;
}

String _id(Map<String, Object?> a, String k) => '${(a[k] as num?)?.toInt() ?? int.tryParse('${a[k]}') ?? 0}';

Map<String, Object?> _sin(Map<String, Object?> a, List<String> claves) =>
    {for (final e in a.entries) if (!claves.contains(e.key) && e.value != null) e.key: e.value};

// ── el catálogo ──────────────────────────────────────────────────────────────

final herramientas = <Herramienta>[
  // Consultas.
  Herramienta(
    nombre: 'resumen',
    descripcion: 'Cuántos equipos hay, cuántos conectados ahora, perdidos, sin contacto en 24 h y alertas abiertas.',
    titulo: 'Mirando el resumen',
    corre: (c, a, bd) => c.llama('GET', '/v1/resumen'),
  ),
  Herramienta(
    nombre: 'listar_equipos',
    descripcion: 'Los equipos con su último estado: batería, red, ubicación, conexión, a quién están asignados, '
        'la app que reporta, el último usuario y su almacén. Sin filtros, todos menos los retirados.',
    titulo: 'Consultando los equipos',
    parametros: _obj({
      'texto': _texto('Busca en nombre, etiqueta, serie, modelo y asignado'),
      'dominio': _dominio,
      'estado': _texto('Estado', ['activo', 'guardado', 'perdido', 'retirado']),
      'conectado': _texto('Con el canal abierto ahora', ['si', 'no']),
      'sin_contacto_24h': _si('Solo activos o perdidos que llevan más de 24 h sin contacto'),
      'con_alertas': _si('Solo los que tienen alertas abiertas'),
      'incluir_retirados': _si('También los retirados'),
    }),
    corre: (c, a, bd) => c.llama('GET', '/v1/equipos', consulta: {
      if (a['texto'] != null) 'q': '${a['texto']}',
      if (a['dominio'] != null) 'dominio': '${a['dominio']}',
      if (a['estado'] != null) 'estado': '${a['estado']}',
      if (a['conectado'] != null) 'conectado': a['conectado'] == 'si' || a['conectado'] == true ? '1' : '0',
      if (a['sin_contacto_24h'] == true) 'sin_contacto': '1',
      if (a['con_alertas'] == true) 'alerta': '1',
      if (a['incluir_retirados'] == true) 'retirados': '1',
    }),
    recorta: _recortaEquipos,
  ),
  Herramienta(
    nombre: 'ver_equipo',
    descripcion: 'La ficha de un equipo: inventario, notas, apps instaladas, las apps que reportan por él '
        '(con su contexto: usuario, almacén), alertas abiertas y últimas órdenes.',
    titulo: 'Abriendo la ficha del equipo',
    parametros: _obj({'id': _idEquipo}, ['id']),
    corre: (c, a, bd) => c.llama('GET', '/v1/equipos/${_id(a, 'id')}'),
    recorta: _recortaEquipo,
  ),
  Herramienta(
    nombre: 'recorrido_equipo',
    descripcion: 'Por dónde anduvo un equipo: sus posiciones en un rango de tiempo.',
    titulo: 'Buscando el recorrido',
    parametros: _obj({'id': _idEquipo, 'desde': _desde, 'hasta': _hasta}, ['id']),
    corre: (c, a, bd) => c.llama('GET', '/v1/equipos/${_id(a, 'id')}/recorrido', consulta: {
      if (a['desde'] != null) 'desde': '${a['desde']}',
      if (a['hasta'] != null) 'hasta': '${a['hasta']}',
    }),
    recorta: _recortaRecorrido,
  ),
  Herramienta(
    nombre: 'reportes_equipo',
    descripcion: 'El historial de reportes de un equipo: batería, carga, red, Wi-Fi, ubicación y motivo de cada uno.',
    titulo: 'Leyendo el historial',
    parametros: _obj({
      'id': _idEquipo,
      'desde': _desde,
      'hasta': _hasta,
      'limite': _entero('Cuántos, los más nuevos primero (hasta 200)'),
    }, ['id']),
    corre: (c, a, bd) => c.llama('GET', '/v1/equipos/${_id(a, 'id')}/reportes', consulta: {
      if (a['desde'] != null) 'desde': '${a['desde']}',
      if (a['hasta'] != null) 'hasta': '${a['hasta']}',
      'limite': '${((a['limite'] as num?)?.toInt() ?? 100).clamp(1, 200)}',
    }),
  ),
  Herramienta(
    nombre: 'ordenes_equipo',
    descripcion: 'Las órdenes que se le mandaron a un equipo (sonar, mensaje, reportar) y en qué quedaron.',
    titulo: 'Mirando las órdenes',
    parametros: _obj({'id': _idEquipo}, ['id']),
    corre: (c, a, bd) => c.llama('GET', '/v1/equipos/${_id(a, 'id')}/ordenes'),
  ),
  Herramienta(
    nombre: 'listar_alertas',
    descripcion: 'Las alertas abiertas (o todas, con todas=true), con su equipo, regla y detalle.',
    titulo: 'Consultando las alertas',
    parametros: _obj({
      'equipo': _entero('Solo las de este equipo'),
      'todas': _si('También las cerradas'),
      'limite': _entero('Cuántas, las más nuevas primero (hasta 500)'),
    }),
    corre: (c, a, bd) => c.llama('GET', '/v1/alertas', consulta: {
      if (a['equipo'] != null) 'equipo': _id(a, 'equipo'),
      if (a['todas'] == true) 'todas': '1',
      'limite': '${((a['limite'] as num?)?.toInt() ?? 200).clamp(1, 500)}',
    }),
  ),
  Herramienta(
    nombre: 'listar_reglas',
    descripcion: 'Las reglas que abren alertas, con sus parámetros, a quién avisan por correo y cuántas alertas tienen abiertas.',
    titulo: 'Mirando las reglas',
    corre: (c, a, bd) => c.llama('GET', '/v1/reglas'),
  ),
  Herramienta(
    nombre: 'listar_zonas',
    descripcion: 'Las zonas (círculos en el mapa: almacenes, sucursales) para las reglas «fuera de zona».',
    titulo: 'Mirando las zonas',
    corre: (c, a, bd) => c.llama('GET', '/v1/zonas'),
  ),
  Herramienta(
    nombre: 'listar_dominios',
    descripcion: 'Los dominios (grupos de equipos: un cliente, un almacén) que esta persona alcanza, con cuántos equipos tiene cada uno.',
    titulo: 'Mirando los dominios',
    corre: (c, a, bd) => c.llama('GET', '/v1/dominios'),
  ),
  Herramienta(
    nombre: 'ver_organizacion',
    descripcion: 'La configuración de la organización: cada cuánto reportan los equipos, si se pide la ubicación, '
        'días de historial y si hay correo de salida.',
    titulo: 'Mirando la configuración',
    corre: (c, a, bd) => c.llama('GET', '/v1/org'),
    recorta: _sinSecretosOrg,
  ),
  Herramienta(
    nombre: 'listar_usuarios',
    descripcion: 'Las personas del panel, con su rol, sus dominios y si ya activaron su cuenta.',
    titulo: 'Mirando las personas',
    permiso: 'admin',
    corre: (c, a, bd) => c.llama('GET', '/v1/usuarios'),
  ),

  // Cambios: quedan propuestos.
  Herramienta(
    nombre: 'crear_regla',
    descripcion: 'Crea una regla que abre alertas: sin_reporte {minutos}, bateria_baja {porcentaje}, '
        'fuera_de_zona {zona}, apagado. Es la forma de «avisarle» a alguien de algo: con avisar, por correo.',
    titulo: 'Preparando la regla',
    permiso: 'editar',
    cambia: true,
    ensayable: true,
    parametros: _obj({
      'tipo': _texto('Tipo de regla', ['sin_reporte', 'bateria_baja', 'fuera_de_zona', 'apagado']),
      'nombre': _texto('Nombre de la regla'),
      'dominio': _texto('Id o slug del dominio que vigila. Sin él, toda la organización'),
      'parametros': _parametrosRegla,
      'activa': _si('Encendida (por defecto sí)'),
      'avisar': _avisar,
    }, ['tipo']),
    corre: (c, a, bd) => c.llama('POST', '/v1/reglas', cuerpo: _sin(a, ['resumen']), bd: bd),
  ),
  Herramienta(
    nombre: 'cambiar_regla',
    descripcion: 'Cambia una regla: solo lo que venga (nombre, dominio, parametros, activa, avisar). El tipo no se cambia.',
    titulo: 'Preparando el cambio de la regla',
    permiso: 'editar',
    cambia: true,
    ensayable: true,
    parametros: _obj({
      'id': _entero('Id de la regla'),
      'nombre': _texto('Nombre'),
      'dominio': _texto('Id o slug del dominio'),
      'parametros': _parametrosRegla,
      'activa': _si('Encendida o apagada'),
      'avisar': _avisar,
    }, ['id']),
    corre: (c, a, bd) => c.llama('PATCH', '/v1/reglas/${_id(a, 'id')}', cuerpo: _sin(a, ['id', 'resumen']), bd: bd),
  ),
  Herramienta(
    nombre: 'borrar_regla',
    descripcion: 'Borra una regla, con sus alertas.',
    titulo: 'Preparando el borrado de la regla',
    permiso: 'editar',
    cambia: true,
    ensayable: true,
    parametros: _obj({'id': _entero('Id de la regla')}, ['id']),
    corre: (c, a, bd) => c.llama('DELETE', '/v1/reglas/${_id(a, 'id')}', bd: bd),
  ),
  Herramienta(
    nombre: 'crear_zona',
    descripcion: 'Crea una zona: un círculo con centro (lat, lng) y radio en metros, de toda la organización o de un dominio.',
    titulo: 'Preparando la zona',
    permiso: 'editar',
    cambia: true,
    ensayable: true,
    parametros: _obj({
      'nombre': _texto('Nombre: «Almacén central»'),
      'lat': _numero('Latitud del centro'),
      'lng': _numero('Longitud del centro'),
      'radio_m': _entero('Radio en metros (10 a 100000)'),
      'dominio': _texto('Id o slug del dominio. Sin él, de toda la organización'),
    }, ['nombre', 'lat', 'lng', 'radio_m']),
    corre: (c, a, bd) => c.llama('POST', '/v1/zonas', cuerpo: _sin(a, ['resumen']), bd: bd),
  ),
  Herramienta(
    nombre: 'cambiar_zona',
    descripcion: 'Cambia una zona (nombre, centro, radio, dominio).',
    titulo: 'Preparando el cambio de la zona',
    permiso: 'editar',
    cambia: true,
    ensayable: true,
    parametros: _obj({
      'id': _entero('Id de la zona'),
      'nombre': _texto('Nombre'),
      'lat': _numero('Latitud'),
      'lng': _numero('Longitud'),
      'radio_m': _entero('Radio en metros'),
      'dominio': _texto('Id o slug del dominio'),
    }, ['id']),
    corre: (c, a, bd) => c.llama('PATCH', '/v1/zonas/${_id(a, 'id')}', cuerpo: _sin(a, ['id', 'resumen']), bd: bd),
  ),
  Herramienta(
    nombre: 'borrar_zona',
    descripcion: 'Borra una zona.',
    titulo: 'Preparando el borrado de la zona',
    permiso: 'editar',
    cambia: true,
    ensayable: true,
    parametros: _obj({'id': _entero('Id de la zona')}, ['id']),
    corre: (c, a, bd) => c.llama('DELETE', '/v1/zonas/${_id(a, 'id')}', bd: bd),
  ),
  Herramienta(
    nombre: 'cambiar_equipo',
    descripcion: 'Cambia la ficha de un equipo: nombre, etiqueta, serie, a quién está asignado, notas, estado '
        '(activo, guardado, perdido, retirado) o dominio. Solo lo que venga.',
    titulo: 'Preparando el cambio del equipo',
    permiso: 'editar',
    cambia: true,
    ensayable: true,
    parametros: _obj({
      'id': _idEquipo,
      'nombre': _texto('Nombre'),
      'etiqueta': _texto('Etiqueta o número de activo fijo'),
      'serie': _texto('Número de serie'),
      'asignado_a': _texto('A quién está asignado'),
      'notas': _texto('Notas (reemplazan las de antes)'),
      'estado': _texto('Estado', ['activo', 'guardado', 'perdido', 'retirado']),
      'dominio': _dominio,
    }, ['id']),
    corre: (c, a, bd) => c.llama('PATCH', '/v1/equipos/${_id(a, 'id')}', cuerpo: _sin(a, ['id', 'resumen']), bd: bd),
  ),
  Herramienta(
    nombre: 'ordenar_equipo',
    descripcion: 'Le manda una orden a un equipo: sonar (suena a todo volumen hasta que lo toquen), '
        'mensaje (sale en su pantalla) o reportar (que reporte ya).',
    titulo: 'Preparando la orden',
    permiso: 'ordenar',
    cambia: true,
    parametros: _obj({
      'id': _idEquipo,
      'tipo': _texto('La orden', ['sonar', 'mensaje', 'reportar']),
      'texto': _texto('mensaje: el texto (hasta 500 letras)'),
      'titulo': _texto('mensaje: un título corto'),
      'segundos': _entero('sonar: cuánto suena (5 a 300, 30 si no se dice)'),
    }, ['id', 'tipo']),
    corre: (c, a, bd) => c.llama('POST', '/v1/equipos/${_id(a, 'id')}/ordenes', cuerpo: {
      'tipo': a['tipo'],
      'datos': {
        if (a['texto'] != null) 'texto': a['texto'],
        if (a['titulo'] != null) 'titulo': a['titulo'],
        if (a['segundos'] != null) 'segundos': a['segundos'],
      },
    }),
  ),
  Herramienta(
    nombre: 'cerrar_alerta',
    descripcion: 'Cierra una alerta a mano, con una nota. Si la condición sigue, la regla la vuelve a abrir.',
    titulo: 'Preparando el cierre de la alerta',
    permiso: 'editar',
    cambia: true,
    parametros: _obj({'id': _entero('Id de la alerta'), 'nota': _texto('Por qué se cierra')}, ['id']),
    corre: (c, a, bd) => c.llama('POST', '/v1/alertas/${_id(a, 'id')}/cerrar', cuerpo: {'nota': a['nota'] ?? ''}),
  ),
  Herramienta(
    nombre: 'invitar_usuario',
    descripcion: 'Invita a una persona al panel. Le llega la invitación por el correo de salida de la organización; '
        'si no hay, queda un enlace para compartir.',
    titulo: 'Preparando la invitación',
    permiso: 'admin',
    cambia: true,
    parametros: _obj({
      'correo': _texto('Su correo'),
      'nombre': _texto('Su nombre'),
      'rol': _texto('admin: todo; editor: equipos, reglas, órdenes; consulta: solo mira', ['admin', 'editor', 'consulta']),
      'dominios': _lista(_texto('Id o slug'), 'Los dominios que verá. Vacío = toda la organización (un admin siempre la ve toda)'),
    }, ['correo', 'rol']),
    corre: (c, a, bd) => c.llama('POST', '/v1/usuarios', cuerpo: _sin(a, ['resumen'])),
  ),

  // Tableros: son de la persona, y se cambian directo.
  Herramienta(
    nombre: 'listar_tableros',
    descripcion: 'Los tableros que ve la persona: los suyos y los que otros compartieron, con sus paneles. '
        'El 0 es el Resumen de siempre, que sale mientras la persona no tenga uno propio.',
    titulo: 'Mirando los tableros',
    corre: (c, a, bd) => c.llama('GET', '/v1/tableros'),
  ),
  Herramienta(
    nombre: 'ver_tablero',
    descripcion: 'Un tablero con lo que muestra ahora cada panel (o su error).',
    titulo: 'Mirando el tablero',
    parametros: _obj({'id': _entero('Id del tablero (0 = el Resumen de siempre)')}, ['id']),
    corre: (c, a, bd) => c.llama('GET', '/v1/tableros/${_id(a, 'id')}/datos'),
  ),
  Herramienta(
    nombre: 'crear_tablero',
    descripcion: 'Crea un tablero de la persona. Con desde_resumen=true empieza con los paneles del Resumen de '
        'siempre (para «cambiar la portada»). Cada panel se prueba antes de guardarlo.',
    titulo: 'Armando el tablero',
    parametros: _obj({
      'nombre': _texto('Nombre del tablero'),
      'desde_resumen': _si('Empezar con los paneles del Resumen'),
      'paneles': _lista(_panel, 'Paneles (hasta $maxPaneles)'),
      'compartido': _si('Que lo vea toda la organización (cada quien con sus datos)'),
    }, ['nombre']),
    corre: (c, a, bd) => c.llama('POST', '/v1/tableros', cuerpo: a),
  ),
  Herramienta(
    nombre: 'cambiar_tablero',
    descripcion: 'Cambia el nombre de un tablero propio o si está compartido.',
    titulo: 'Cambiando el tablero',
    parametros: _obj({
      'id': _entero('Id del tablero'),
      'nombre': _texto('Nombre'),
      'compartido': _si('Compartido con la organización'),
    }, ['id']),
    corre: (c, a, bd) => c.llama('PATCH', '/v1/tableros/${_id(a, 'id')}', cuerpo: _sin(a, ['id'])),
  ),
  Herramienta(
    nombre: 'agregar_panel',
    descripcion: 'Agrega un panel a un tablero propio. Se prueba antes: si falla, dice por qué.',
    titulo: 'Agregando el panel',
    parametros: _obj({
      'tablero': _entero('Id del tablero'),
      'panel': _panel,
      'posicion': _entero('Dónde va, desde 0. Sin ella, al final'),
    }, ['tablero', 'panel']),
    corre: (c, a, bd) => c.llama('POST', '/v1/tableros/${_id(a, 'tablero')}/paneles', cuerpo: {
      ...((a['panel'] as Map?)?.cast<String, Object?>() ?? const {}),
      'posicion': ?a['posicion'],
    }),
  ),
  Herramienta(
    nombre: 'cambiar_panel',
    descripcion: 'Reemplaza un panel de un tablero propio por otra definición (mismo id).',
    titulo: 'Cambiando el panel',
    parametros: _obj({
      'tablero': _entero('Id del tablero'),
      'panel_id': _texto('Id del panel (sale de listar_tableros)'),
      'panel': _panel,
      'posicion': _entero('Moverlo a esta posición, desde 0'),
    }, ['tablero', 'panel_id', 'panel']),
    corre: (c, a, bd) => c.llama('PUT', '/v1/tableros/${_id(a, 'tablero')}/paneles/${Uri.encodeComponent('${a['panel_id']}')}', cuerpo: {
      ...((a['panel'] as Map?)?.cast<String, Object?>() ?? const {}),
      'posicion': ?a['posicion'],
    }),
  ),
  Herramienta(
    nombre: 'quitar_panel',
    descripcion: 'Quita un panel de un tablero propio.',
    titulo: 'Quitando el panel',
    parametros: _obj({'tablero': _entero('Id del tablero'), 'panel_id': _texto('Id del panel')}, ['tablero', 'panel_id']),
    corre: (c, a, bd) => c.llama('DELETE', '/v1/tableros/${_id(a, 'tablero')}/paneles/${Uri.encodeComponent('${a['panel_id']}')}'),
  ),
  Herramienta(
    nombre: 'borrar_tablero',
    descripcion: 'Borra un tablero propio entero.',
    titulo: 'Preparando el borrado del tablero',
    cambia: true,
    ensayable: true,
    parametros: _obj({'id': _entero('Id del tablero')}, ['id']),
    corre: (c, a, bd) => c.llama('DELETE', '/v1/tableros/${_id(a, 'id')}', bd: bd),
  ),
];

/// Lo que se le devuelve al modelo, con tope: un resultado enorme se come la
/// conversación.
String resultadoJson(Object? r, {int tope = 40000}) {
  final t = jsonEncode(r, toEncodable: (v) => v is DateTime ? v.toUtc().toIso8601String() : v.toString());
  if (t.length <= tope) return t;
  return '${t.substring(0, tope)}… [recortado: eran ${t.length} caracteres; pide menos con filtros]';
}
