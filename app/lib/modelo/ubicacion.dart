/// Por qué un equipo tiene (o no tiene) ubicación, dicho para una persona, con
/// un «Qué hacer» cuando se puede arreglar. Lo mismo que
/// `manager/src/ubicacion.js`, con los mismos textos: la web y el teléfono
/// dicen lo mismo del mismo equipo. El dato es el `ubicacion_estado` de cada
/// fuente (ver docs/api.md).
library;

import 'formato.dart';

typedef Json = Map<String, Object?>;

/// Los que alguien puede arreglar desde el teléfono o el panel. «Sin señal»
/// no está: es el sitio (una bodega), no una configuración.
const _arreglables = {
  'aproximada', 'simulada', 'no_pedida', 'sin_pedir', 'denegada', 'denegada_siempre',
  'servicio_apagado', 'sin_proveedor', 'sin_segundo_plano', 'ahorro_bateria',
};

const _conPosicion = {'ok', 'aproximada', 'simulada', 'vieja'};

const _proveedores = {'gps': 'GPS', 'network': 'red (Wi-Fi y antenas)', 'fused': 'combinada', 'passive': 'de otra app'};

const _ahorro = {
  'sin_cambio': 'no toca la ubicación',
  'sin_gps_pantalla_apagada': 'sin GPS con la pantalla apagada',
  'sin_ubicacion_pantalla_apagada': 'sin ubicación con la pantalla apagada',
  'solo_al_frente': 'ubicación solo con la app delante',
  'limitada': 'ubicación limitada con la pantalla apagada',
};

/// «40 s», «12 min», «3 h», «2 días».
String _duracion(num? s) {
  if (s == null) return '';
  if (s < 90) return '${s.round()} s';
  if (s < 5400) return '${(s / 60).round()} min';
  if (s < 172800) return '${(s / 3600).round()} h';
  return '${(s / 86400).round()} días';
}

String _app(Json u) {
  final n = '${u['fuente_nombre'] ?? ''}'.trim();
  if (n.isNotEmpty) return n;
  final p = '${u['fuente_paquete'] ?? ''}'.trim();
  return p.isNotEmpty ? p : 'la app';
}

bool _agente(Json u) => u['fuente_tipo'] == 'agente';

String _permitir(Json u) => _agente(u) ? 'Permitir todo el tiempo' : 'Permitir solo mientras se usa la app';

String _rutaPermiso(Json u) => 'Ajustes › Aplicaciones › ${_app(u)} › Permisos › Ubicación › «${_permitir(u)}»';

/// Qué dice el motivo y qué hacer.
({String texto, String queHacer}) _textos(Json u) {
  final app = _app(u);
  final ahorro = _ahorro['${u['ahorro_ubicacion']}'];
  switch (u['motivo']) {
    case 'ok':
      return (texto: 'Llega bien.', queHacer: '');
    case 'aproximada':
      return (
        texto: '$app solo tiene ubicación aproximada (a varios kilómetros), no la precisa.',
        queHacer: 'Ajustes › Aplicaciones › $app › Permisos › Ubicación › activar «Usar ubicación precisa».',
      );
    case 'simulada':
      return (
        texto: 'La posición es falsa: en el teléfono hay una app de ubicación simulada activa.',
        queHacer: 'Ajustes › Sistema › Opciones de desarrollador › «Seleccionar app de ubicación simulada» › Ninguna.',
      );
    case 'vieja':
      final edad = decimal(u['edad_s']);
      return (
        texto: 'No consiguió una posición nueva; mandó la última que tenía el teléfono'
            '${edad != null ? ', de hace ${_duracion(edad)}' : ''}.',
        queHacer: '',
      );
    case 'no_pedida':
      return (
        texto: 'La organización no pide la ubicación.',
        queHacer: 'Organización › marcar «Pedir la ubicación a los equipos» (quien administra).',
      );
    case 'no_declarada':
      return (
        texto: '$app no está hecha para pedir la ubicación (no declara el permiso): hace falta otra versión de la app, o el agente.',
        queHacer: '',
      );
    case 'sin_pedir':
      return (
        texto: '$app todavía no ha pedido el permiso de ubicación.',
        queHacer: _agente(u)
            ? 'Abrir el agente en el teléfono y tocar «Revisar permisos».'
            : 'Entrar a $app con un usuario: al entrar pide el permiso; contestar «Mientras se usa la app». O directo: ${_rutaPermiso(u)}.',
      );
    case 'denegada':
      return (texto: 'Le negaron el permiso de ubicación a $app.', queHacer: '${_rutaPermiso(u)}.');
    case 'denegada_siempre':
      return (
        texto: 'Le negaron el permiso de ubicación a $app y marcaron «No volver a preguntar»: la app ya no puede pedirlo, solo se da en Ajustes.',
        queHacer: '${_rutaPermiso(u)}.',
      );
    case 'servicio_apagado':
      return (
        texto: 'La ubicación del teléfono está apagada.',
        queHacer: 'Bajar la barra de arriba y tocar «Ubicación», o Ajustes › Ubicación › «Usar ubicación».',
      );
    case 'sin_proveedor':
      return (
        texto: u['red_existe'] == false && u['google_play'] == false
            ? 'El GPS está apagado y el teléfono no tiene servicios de Google: no tiene con qué ubicarse.'
            : 'La ubicación está encendida, pero sin GPS ni ubicación por red: no tiene con qué ubicarse.',
        queHacer: 'Ajustes › Ubicación › Servicios de ubicación: activar el GPS y la precisión de ubicación (en teléfonos viejos, modo «Alta precisión»).',
      );
    case 'sin_segundo_plano':
      return (
        texto: 'Con la app cerrada no la puede leer: $app tiene «Permitir solo mientras se usa la app» y le hace falta «Permitir todo el tiempo».',
        queHacer: 'Ajustes › Aplicaciones › $app › Permisos › Ubicación › «Permitir todo el tiempo».',
      );
    case 'ahorro_bateria':
      return (
        texto: u['reposo'] == true
            ? 'El teléfono estaba en reposo (ahorro de batería de Android) y no dejó leer la ubicación.'
            : 'El ahorro de batería no deja leer la ubicación${ahorro != null ? ' ($ahorro)' : ''}.',
        queHacer: 'Apagar el ahorro de batería, y en Ajustes › Aplicaciones › $app › Batería › «Sin restricciones».',
      );
    case 'sin_senal':
      final pistas = <String>[
        if (u['gps'] == false) 'el GPS está apagado',
        if (u['google_play'] == false)
          'no tiene servicios de Google (sin ellos casi no hay ubicación por red)'
        else if (u['wifi'] == false && u['escaneo_wifi'] == false)
          'el Wi-Fi está apagado (ayuda a ubicarse bajo techo)',
        if (u['avion'] == true) 'está en modo avión',
      ];
      final espera = decimal(u['espera_s']);
      final ultima = decimal(u['ultima_edad_s']);
      return (
        texto: 'Todo está permitido y encendido, pero no llegó ninguna posición'
            '${espera != null && espera > 0 ? ' en ${_duracion(espera)}' : ''}: sin señal de GPS (bajo techo, en una bodega) '
            'y sin ubicación por Wi-Fi o antenas${pistas.isNotEmpty ? '; además, ${pistas.join(', ')}' : ''}.'
            '${ultima != null ? ' La última que tenía el teléfono es de hace ${_duracion(ultima)}.' : ''}',
        queHacer: 'Si hace falta saber dónde está: llevarlo a un sitio abierto o junto a una ventana y pedir «Reportar ya». '
            'Con el Wi-Fi encendido se ubica mejor bajo techo.',
      );
    case 'error':
      final err = '${u['error'] ?? ''}';
      return (texto: 'El equipo no pudo leer la ubicación${err.isNotEmpty ? ' ($err)' : ''}.', queHacer: '');
    default:
      return (texto: 'El equipo dice «${u['motivo']}».', queHacer: '');
  }
}

List<String> _datos(Json u) {
  final motivo = '${u['motivo']}';
  final ahorro = _ahorro['${u['ahorro_ubicacion']}'];
  final precision = decimal(u['precision_m']);
  final edad = decimal(u['edad_s']);
  final permiso = u['permiso'];
  return [
    if (permiso != null)
      switch (permiso) {
        'precisa' => 'Permiso: precisa',
        'aproximada' => 'Permiso: solo aproximada',
        'ninguno' => 'Sin permiso',
        _ => 'Permiso: $permiso',
      },
    if (u['segundo_plano'] is bool && permiso != null && permiso != 'ninguno')
      u['segundo_plano'] == true ? 'todo el tiempo' : 'solo con la app abierta',
    if (u['servicio'] == false) 'ubicación del teléfono apagada',
    if (u['servicio'] != false && u['gps'] == false) 'GPS apagado',
    if (u['servicio'] != false && u['red'] == false)
      u['red_existe'] == false ? 'sin ubicación por red' : 'ubicación por red apagada',
    if (u['google_play'] == false) 'sin servicios de Google',
    if (u['ahorro'] == true) 'ahorro de batería${ahorro != null ? ' ($ahorro)' : ''}',
    if (u['sin_optimizar'] == false && _agente(u)) 'con optimización de batería',
    if (u['avion'] == true) 'modo avión',
    if (u['proveedor'] != null) 'por ${_proveedores[u['proveedor']] ?? u['proveedor']}',
    if (precision != null && _conPosicion.contains(motivo)) '± ${distancia(precision)}',
    if (edad != null && _conPosicion.contains(motivo) && edad >= 60) 'leída hace ${_duracion(edad)}',
  ];
}

/// Lo que la fila «Ubicación» de la ficha enseña.
class ExplicaUbicacion {
  const ExplicaUbicacion({
    this.motivo,
    required this.texto,
    this.queHacer = '',
    this.arreglable = false,
    this.datos = const [],
    this.quien = '',
    this.vieja = '',
    this.porFuente = const [],
  });

  /// Null = ninguna fuente lo manda (versión vieja).
  final String? motivo;
  final String texto;
  final String queHacer;
  final bool arreglable;
  final List<String> datos;

  /// Qué app lo dijo y cuándo.
  final String quien;

  /// Si la posición guardada es de mucho antes del último reporte.
  final String vieja;

  /// Cuando sus fuentes dicen cosas distintas: `(app, cuando, texto)`.
  final List<({String app, String cuando, String texto})> porFuente;

  bool get ok => motivo == 'ok';

  factory ExplicaUbicacion.de(Json e) {
    var vieja = '';
    final ut = leeFecha(e['ubicacion_t']);
    final ur = leeFecha(e['ultimo_reporte']);
    if (e['lat'] != null && ut != null && ur != null && ur.difference(ut) > const Duration(minutes: 30)) {
      vieja = 'La última posición es de ${hace(e['ubicacion_t'])}; desde entonces reporta sin ella.';
    }
    final crudo = e['ubicacion_estado'];
    if (crudo is! Map || crudo['motivo'] == null) {
      return ExplicaUbicacion(texto: 'El equipo aún no informa el motivo (versión vieja).', vieja: vieja);
    }
    final u = crudo.cast<String, Object?>();
    final t = _textos(u);
    final fuentes = [
      for (final f in (e['fuentes'] as List?) ?? const [])
        if (f is Map && f['ubicacion_estado'] is Map && f['revocada'] == null) f.cast<String, Object?>(),
    ];
    final distintos = {for (final f in fuentes) (f['ubicacion_estado'] as Map)['motivo']};
    return ExplicaUbicacion(
      motivo: '${u['motivo']}',
      texto: t.texto,
      queHacer: t.queHacer,
      arreglable: _arreglables.contains(u['motivo']),
      datos: _datos(u),
      quien: 'Lo dijo ${_app(u)}${u['t'] != null ? ' ${hace(u['t'])}' : ''}.',
      vieja: vieja,
      porFuente: fuentes.length > 1 && distintos.length > 1
          ? [
              for (final f in fuentes)
                () {
                  final uf = {
                    ...(f['ubicacion_estado'] as Map).cast<String, Object?>(),
                    'fuente_nombre': f['nombre'],
                    'fuente_paquete': f['paquete'],
                    'fuente_tipo': f['tipo'],
                  };
                  return (app: _app(uf), cuando: hace(f['ubicacion_estado_t']), texto: _textos(uf).texto);
                }(),
            ]
          : const [],
    );
  }
}

/// Para la lista: el aviso junto al nombre, solo si falta ubicación (o no
/// sirve) por algo que se puede arreglar. Null si no hay que avisar.
String? avisoUbicacion(Json e) {
  final u = e['ubicacion_estado'];
  if (u is! Map) return null;
  final motivo = u['motivo'];
  if (!_arreglables.contains(motivo) || motivo == 'no_pedida') return null;
  return 'Ubicación: ${_textos(u.cast<String, Object?>()).texto}';
}
