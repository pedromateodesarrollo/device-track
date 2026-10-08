/// Lo que va y viene entre el equipo y el hub, tipado. Cada clase sabe
/// pasarse a JSON (`toJson`) y leerse de él (`desdeJson`).
///
/// Leer es tolerante a propósito: lo que no viene o no cuadra queda en null (o
/// en su valor por defecto) en vez de lanzar. El hub hace lo mismo con lo que
/// le manda el equipo.
library;

/// Por qué se manda un reporte. El hub lo guarda con el reporte; la regla
/// `apagado` mira `apagando` y `encendido`.
enum MotivoReporte {
  /// Le tocaba (cada `intervalo_s`).
  periodico,

  /// El equipo acaba de encender.
  encendido,

  /// El equipo se está apagando.
  apagando,

  /// Lo pidió una orden `reportar`.
  orden,

  /// La app se abrió o volvió al frente.
  abrir,

  /// Lo pidió alguien a mano (un botón).
  manual;

  static MotivoReporte desde(Object? v) =>
      values.firstWhere((m) => m.name == v, orElse: () => periodico);
}

/// Lo que el equipo dice de una orden (`POST /v1/ordenes/:id/estado`).
/// `hecha` y `fallida` son finales: un `recibida` que llega tarde no las
/// deshace.
enum EstadoOrden { recibida, hecha, fallida }

/// Quién reporta: el agente (la app aparte) o una app con el plugin.
enum TipoFuente { agente, app }

/// La configuración que la organización le pone a sus equipos. Llega en el
/// alta, en cada reporte y por el WebSocket cuando alguien la cambia.
class ConfigEquipo {
  const ConfigEquipo({this.intervaloS = 600, this.ubicacion = true});

  /// La de un equipo que todavía no oyó al hub: 10 minutos, con ubicación.
  static const porDefecto = ConfigEquipo();

  /// Cada cuánto reportar, en segundos (de 60 a un día).
  final int intervaloS;

  /// Si la organización pide la ubicación.
  final bool ubicacion;

  Duration get intervalo => Duration(seconds: intervaloS);

  /// Desde `{intervalo_s, ubicacion}`. Lo que no viene se toma de [base].
  factory ConfigEquipo.desdeJson(Object? j, {ConfigEquipo base = porDefecto}) {
    final m = _mapa(j);
    final s = _entero(m['intervalo_s']);
    final u = m['ubicacion'];
    return ConfigEquipo(
      intervaloS: s == null ? base.intervaloS : s.clamp(60, 86400),
      ubicacion: u is bool ? u : base.ubicacion,
    );
  }

  Map<String, Object?> toJson() => {'intervalo_s': intervaloS, 'ubicacion': ubicacion};

  @override
  bool operator ==(Object other) =>
      other is ConfigEquipo && other.intervaloS == intervaloS && other.ubicacion == ubicacion;

  @override
  int get hashCode => Object.hash(intervaloS, ubicacion);

  @override
  String toString() => 'ConfigEquipo(${intervaloS}s${ubicacion ? ', con ubicación' : ''})';
}

/// Una orden del panel para este equipo: `sonar`, `mensaje`, `reportar`… El
/// hub la repite (por el WebSocket y en cada reporte) hasta que el equipo
/// acusa recibo: quien la atiende la descarta por su [id] si ya la hizo.
class Orden {
  const Orden({required this.id, required this.tipo, this.datos = const {}});

  final int id;
  final String tipo;

  /// Lo que trae cada tipo: `{segundos}` para `sonar`, `{titulo, texto}` para
  /// `mensaje`.
  final Map<String, Object?> datos;

  /// Null si no trae un `id` válido: una orden sin id no se puede acusar.
  static Orden? desdeJson(Object? j) {
    final m = _mapa(j);
    final id = _entero(m['id']);
    if (id == null || id <= 0) return null;
    return Orden(id: id, tipo: m['tipo']?.toString() ?? '', datos: _mapa(m['datos']));
  }

  /// Un dato como texto (vacío si no viene).
  String texto(String clave) => datos[clave]?.toString() ?? '';

  /// Un dato como entero (null si no viene o no es un número).
  int? entero(String clave) => _entero(datos[clave]);

  Map<String, Object?> toJson() => {'id': id, 'tipo': tipo, 'datos': datos};

  @override
  String toString() => 'Orden($id, $tipo, $datos)';
}

/// Lo que contesta `POST /v1/alta`.
class Alta {
  const Alta({
    required this.equipoId,
    required this.equipoNombre,
    required this.credencial,
    this.config = ConfigEquipo.porDefecto,
    this.ws = '',
  });

  /// El equipo en el hub. Si ya existía (otra fuente en el mismo teléfono), es
  /// el mismo de antes.
  final int equipoId;
  final String equipoNombre;

  /// La credencial de esta fuente (`dtd_…`). Se guarda: con ella se reporta.
  final String credencial;

  final ConfigEquipo config;

  /// La dirección del WebSocket según el hub (`wss://…/v1/ws`).
  final String ws;

  /// Lanza [FormatException] si la respuesta no trae credencial.
  factory Alta.desdeJson(Object? j) {
    final m = _mapa(j);
    final credencial = m['credencial']?.toString() ?? '';
    if (!credencial.startsWith('dtd_')) {
      throw const FormatException('El alta no devolvió la credencial del equipo (dtd_…)');
    }
    final e = _mapa(m['equipo']);
    return Alta(
      equipoId: _entero(e['id']) ?? 0,
      equipoNombre: e['nombre']?.toString() ?? '',
      credencial: credencial,
      config: ConfigEquipo.desdeJson(m['config']),
      ws: m['ws']?.toString() ?? '',
    );
  }

  @override
  String toString() => 'Alta(equipo $equipoId «$equipoNombre», $config)';
}

/// Quién reporta: `{tipo, paquete, nombre, version, build}`.
class Fuente {
  const Fuente({required this.tipo, required this.paquete, this.nombre, this.version, this.build});

  final TipoFuente tipo;

  /// El `applicationId` (en otra plataforma, lo que identifique a la app).
  final String paquete;

  /// El nombre de la app como lo ve la gente («WMS Duralon»). El panel lo
  /// enseña en la columna «Aplicación» de la lista de equipos; sin él, enseña
  /// el [paquete].
  final String? nombre;

  /// `versionName`.
  final String? version;

  /// `versionCode`.
  final int? build;

  factory Fuente.desdeJson(Object? j, {TipoFuente tipo = TipoFuente.app}) {
    final m = _mapa(j);
    return Fuente(
      tipo: TipoFuente.values.firstWhere((t) => t.name == m['tipo'], orElse: () => tipo),
      paquete: m['paquete']?.toString() ?? '',
      nombre: _textoONull(m['nombre']),
      version: _textoONull(m['version']),
      build: _entero(m['build']),
    );
  }

  Map<String, Object?> toJson() => {
        'tipo': tipo.name,
        'paquete': paquete,
        if (nombre != null) 'nombre': nombre,
        if (version != null) 'version': version,
        if (build != null) 'build': build,
      };
}

/// Lo que el equipo dice de sí en el alta. Todo opcional.
class DatosEquipo {
  const DatosEquipo({this.modelo, this.fabricante, this.android, this.serie, this.nombre});

  /// `Build.MODEL`.
  final String? modelo;

  /// `Build.MANUFACTURER`.
  final String? fabricante;

  /// Nivel de SDK.
  final int? android;

  /// Número de serie, si el equipo lo da (las Zebra).
  final String? serie;

  /// Nombre sugerido, si el equipo es nuevo en el hub.
  final String? nombre;

  factory DatosEquipo.desdeJson(Object? j) {
    final m = _mapa(j);
    return DatosEquipo(
      modelo: _textoONull(m['modelo']),
      fabricante: _textoONull(m['fabricante']),
      android: _entero(m['android']),
      serie: _textoONull(m['serie']),
      nombre: _textoONull(m['nombre']),
    );
  }

  Map<String, Object?> toJson() => {
        if (modelo != null) 'modelo': modelo,
        if (fabricante != null) 'fabricante': fabricante,
        if (android != null) 'android': android,
        if (serie != null) 'serie': serie,
        if (nombre != null) 'nombre': nombre,
      };
}

/// Una posición: `{lat, lng, precision_m, t}`.
class Ubicacion {
  const Ubicacion({required this.lat, required this.lng, this.precisionM, this.t});

  final double lat;
  final double lng;

  /// Radio de error, en metros.
  final double? precisionM;

  /// Cuándo se leyó (puede ser antes que el reporte).
  final DateTime? t;

  /// Null si no trae latitud y longitud.
  static Ubicacion? desdeJson(Object? j) {
    final m = _mapa(j);
    final lat = _real(m['lat']);
    final lng = _real(m['lng']);
    if (lat == null || lng == null) return null;
    return Ubicacion(lat: lat, lng: lng, precisionM: _real(m['precision_m']), t: _fecha(m['t']));
  }

  Map<String, Object?> toJson() => {
        'lat': lat,
        'lng': lng,
        if (precisionM != null) 'precision_m': precisionM,
        if (t != null) 't': t!.toUtc().toIso8601String(),
      };
}

/// La red: `wifi`, `datos`, `ninguna` u `otra`, y el nombre de la Wi-Fi si
/// Android lo da (pide permiso de ubicación).
class Red {
  const Red({required this.tipo, this.ssid});

  final String tipo;
  final String? ssid;

  static Red? desdeJson(Object? j) {
    final m = _mapa(j);
    final tipo = _textoONull(m['tipo']);
    if (tipo == null) return null;
    return Red(tipo: tipo, ssid: _textoONull(m['ssid']));
  }

  Map<String, Object?> toJson() => {'tipo': tipo, if (ssid != null) 'ssid': ssid};
}

/// Espacio en disco, en bytes.
class Almacenamiento {
  const Almacenamiento({required this.libre, required this.total});

  final int libre;
  final int total;

  static Almacenamiento? desdeJson(Object? j) {
    final m = _mapa(j);
    final libre = _entero(m['libre']);
    final total = _entero(m['total']);
    if (libre == null || total == null) return null;
    return Almacenamiento(libre: libre, total: total);
  }

  Map<String, Object?> toJson() => {'libre': libre, 'total': total};
}

/// Una app instalada: `{paquete, version, build, nombre}`.
class AppInstalada {
  const AppInstalada({required this.paquete, this.version = '', this.build, this.nombre = ''});

  final String paquete;
  final String version;
  final int? build;

  /// Como la ve la persona en el lanzador.
  final String nombre;

  static AppInstalada? desdeJson(Object? j) {
    final m = _mapa(j);
    final paquete = _textoONull(m['paquete']);
    if (paquete == null) return null;
    return AppInstalada(
      paquete: paquete,
      version: m['version']?.toString() ?? '',
      build: _entero(m['build']),
      nombre: m['nombre']?.toString() ?? '',
    );
  }

  Map<String, Object?> toJson() => {
        'paquete': paquete,
        'version': version,
        if (build != null) 'build': build,
        if (nombre.isNotEmpty) 'nombre': nombre,
      };
}

/// Un reporte (`POST /v1/reporte`). Todo es opcional salvo la hora y el
/// motivo: lo que no viene, en el hub no cambia.
class Reporte {
  Reporte({
    DateTime? t,
    this.motivo = MotivoReporte.periodico,
    this.bateria,
    this.cargando,
    this.red,
    this.ubicacion,
    this.almacenamiento,
    this.apps,
    this.contexto,
    this.atrasados = const [],
    this.fuente,
    this.android,
  }) : t = t ?? DateTime.now().toUtc();

  /// Cuándo se tomó. El historial queda con esta hora, no con la de llegada.
  final DateTime t;
  final MotivoReporte motivo;

  /// 0–100.
  final int? bateria;
  final bool? cargando;
  final Red? red;
  final Ubicacion? ubicacion;
  final Almacenamiento? almacenamiento;

  /// Mandarla solo cuando cambió: el hub guarda la última.
  final List<AppInstalada>? apps;

  /// Lo que la app quiera contar (empresa, quién tiene la sesión). Hasta 4 KB;
  /// más grande, el hub lo ignora.
  final Map<String, Object?>? contexto;

  /// Los reportes que no salieron antes, cada uno con su hora. Van en
  /// `reportes`.
  final List<Reporte> atrasados;

  /// `nombre`, `version` y `build` de quien reporta: el hub los actualiza en
  /// su fuente.
  final Fuente? fuente;

  /// Nivel de SDK (va en `equipo.android`): cambia cuando el equipo se
  /// actualiza.
  final int? android;

  /// Lo que se guarda en la cola cuando no sale: lo leído del equipo, con su
  /// hora y su motivo. Sin apps, contexto, fuente ni atrasados, que van en el
  /// reporte que los lleve.
  Reporte get paraCola => Reporte(
        t: t,
        motivo: motivo,
        bateria: bateria,
        cargando: cargando,
        red: red,
        ubicacion: ubicacion,
        almacenamiento: almacenamiento,
      );

  /// El mismo reporte con [atrasados] (y lo demás que se diga) cambiado.
  Reporte con({
    List<Reporte>? atrasados,
    List<AppInstalada>? apps,
    Map<String, Object?>? contexto,
    Fuente? fuente,
    int? android,
    Ubicacion? ubicacion,
  }) =>
      Reporte(
        t: t,
        motivo: motivo,
        bateria: bateria,
        cargando: cargando,
        red: red,
        ubicacion: ubicacion ?? this.ubicacion,
        almacenamiento: almacenamiento,
        apps: apps ?? this.apps,
        contexto: contexto ?? this.contexto,
        atrasados: atrasados ?? this.atrasados,
        fuente: fuente ?? this.fuente,
        android: android ?? this.android,
      );

  factory Reporte.desdeJson(Object? j) {
    final m = _mapa(j);
    final apps = m['apps'];
    final atrasados = m['reportes'];
    final contexto = m['contexto'];
    return Reporte(
      t: _fecha(m['t']),
      motivo: MotivoReporte.desde(m['motivo']),
      bateria: _entero(m['bateria']),
      cargando: m['cargando'] is bool ? m['cargando'] as bool : null,
      red: Red.desdeJson(m['red']),
      ubicacion: Ubicacion.desdeJson(m['ubicacion']),
      almacenamiento: Almacenamiento.desdeJson(m['almacenamiento']),
      apps: apps is List ? [for (final a in apps) if (AppInstalada.desdeJson(a) case final x?) x] : null,
      contexto: contexto is Map ? Map<String, Object?>.from(contexto) : null,
      atrasados: atrasados is List ? [for (final r in atrasados) Reporte.desdeJson(r)] : const [],
      fuente: m['fuente'] is Map ? Fuente.desdeJson(m['fuente']) : null,
      android: _entero(_mapa(m['equipo'])['android']),
    );
  }

  Map<String, Object?> toJson() => {
        't': t.toUtc().toIso8601String(),
        'motivo': motivo.name,
        if (bateria != null) 'bateria': bateria,
        if (cargando != null) 'cargando': cargando,
        if (red != null) 'red': red!.toJson(),
        if (ubicacion != null) 'ubicacion': ubicacion!.toJson(),
        if (almacenamiento != null) 'almacenamiento': almacenamiento!.toJson(),
        if (apps != null) 'apps': [for (final a in apps!) a.toJson()],
        if (contexto != null) 'contexto': contexto,
        if (atrasados.isNotEmpty) 'reportes': [for (final r in atrasados) r.toJson()],
        if (fuente != null) 'fuente': fuente!.toJson(),
        if (android != null) 'equipo': {'android': android},
      };

  @override
  String toString() => 'Reporte(${motivo.name}, $t${atrasados.isEmpty ? '' : ', +${atrasados.length} atrasados'})';
}

/// Lo que contesta `POST /v1/reporte`: la configuración vigente y las órdenes
/// que estén esperando (así se entera también un equipo sin WebSocket).
class RespuestaReporte {
  const RespuestaReporte({this.config, this.ordenes = const []});

  /// Null si no vino.
  final ConfigEquipo? config;
  final List<Orden> ordenes;

  factory RespuestaReporte.desdeJson(Object? j) {
    final m = _mapa(j);
    final ordenes = m['ordenes'];
    return RespuestaReporte(
      config: m['config'] is Map ? ConfigEquipo.desdeJson(m['config']) : null,
      ordenes: ordenes is List ? [for (final o in ordenes) if (Orden.desdeJson(o) case final x?) x] : const [],
    );
  }
}

Map<String, Object?> _mapa(Object? v) => v is Map ? Map<String, Object?>.from(v) : const {};

String? _textoONull(Object? v) {
  final t = v?.toString().trim() ?? '';
  return t.isEmpty ? null : t;
}

int? _entero(Object? v) => v is num ? v.toInt() : int.tryParse(v?.toString() ?? '');

double? _real(Object? v) {
  final n = v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');
  return n == null || n.isNaN ? null : n;
}

DateTime? _fecha(Object? v) => v is DateTime ? v.toUtc() : DateTime.tryParse(v?.toString() ?? '')?.toUtc();
