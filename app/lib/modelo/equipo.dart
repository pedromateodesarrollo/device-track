/// Lo que se calcula de un equipo de `GET /v1/equipos` para la lista: quién
/// lo tenía, qué app lo reporta, cómo está su red y de qué color va. La misma
/// lógica que `manager/src/componentes/Equipos.vue`, para que el teléfono y
/// la web digan lo mismo del mismo equipo.
library;

import 'formato.dart';

typedef Json = Map<String, Object?>;

/// Las fuentes de un equipo (el agente y cada app con el plugin), de la que
/// reportó más reciente a la más vieja. El hub ya las manda así, pero no
/// cuesta asegurarlo: de ese orden sale la «Aplicación» y el «Último usuario».
List<Json> fuentesDe(Json e) {
  final l = [
    for (final f in (e['fuentes'] as List?) ?? const [])
      if (f is Map) f.cast<String, Object?>(),
  ];
  int t(Json f) => leeFecha(f['ultima_vez'])?.millisecondsSinceEpoch ?? 0;
  l.sort((a, b) => t(b).compareTo(t(a)));
  return l;
}

/// Quién tenía el equipo: el `usuario` del contexto de la fuente más reciente
/// que lo dice (la app manda quién tiene la sesión, por convención; ver
/// docs/api.md).
class UltimoUsuario {
  const UltimoUsuario({required this.nombre, this.donde = '', this.sinSesion = false, this.cuando});

  final String nombre;

  /// `almacen` o `lugar` del mismo contexto, si vienen.
  final String donde;

  /// `sesion: false`: la app ya cerró la sesión y el nombre es el de la
  /// ÚLTIMA. Justo lo que se pregunta cuando una terminal no aparece.
  final bool sinSesion;
  final Object? cuando;

  /// «Almacén A1 · sin sesión», lo que va debajo del nombre.
  String get debajo => [if (donde.isNotEmpty) donde, if (sinSesion) 'sin sesión'].join(' · ');
}

UltimoUsuario? ultimoUsuario(Json e) {
  for (final f in fuentesDe(e)) {
    final c = f['contexto'];
    if (c is! Map) continue;
    final u = c['usuario'];
    if (u is! String || u.trim().isEmpty) continue;
    final almacen = c['almacen'];
    final lugar = c['lugar'];
    return UltimoUsuario(
      nombre: u.trim(),
      donde: almacen is String ? almacen : (lugar is String ? lugar : ''),
      sinSesion: c['sesion'] == false,
      cuando: f['ultima_vez'],
    );
  }
  return null;
}

/// Qué app está reportando: la fuente más reciente, con el nombre que manda
/// (`fuente.nombre`) o, si no lo sabe, su paquete. Las demás van debajo.
class Aplicacion {
  const Aplicacion({required this.nombre, this.debajo = ''});
  final String nombre;

  /// «1.62.0 · también device-track» o «1.62.0 · y 2 más».
  final String debajo;
}

String nombreFuente(Json f) {
  final n = f['nombre'];
  if (n is String && n.trim().isNotEmpty) return n.trim();
  final p = texto(f['paquete']);
  return p ?? '${f['tipo'] ?? ''}';
}

Aplicacion? aplicacion(Json e) {
  final fuentes = fuentesDe(e);
  if (fuentes.isEmpty) return null;
  final f = fuentes.first;
  final otras = fuentes.skip(1).toList();
  final tambien = otras.length == 1
      ? 'también ${nombreFuente(otras.first)}'
      : otras.isNotEmpty
      ? 'y ${otras.length} más'
      : '';
  return Aplicacion(
    nombre: nombreFuente(f),
    debajo: [?texto(f['version']), if (tambien.isNotEmpty) tambien].join(' · '),
  );
}

/// «Wi-Fi · Almacén», «Datos», o vacío si no se sabe.
String redDe(Json e) {
  final tipo = texto(e['red_tipo']);
  if (tipo == null) return '';
  final ssid = texto(e['red_ssid']);
  if (tipo == 'wifi' && ssid != null) return 'Wi-Fi · $ssid';
  return redes[tipo] ?? tipo;
}

/// De qué color va un equipo en el mapa y en las listas: rojo si tiene algo
/// que mirar, verde si está conectado ahora, gris si no.
enum ColorEquipo { mal, ok, gris, apagado }

ColorEquipo colorEquipo(Json e) {
  if (e['estado'] == 'perdido' || (entero(e['alertas']) ?? 0) > 0) return ColorEquipo.mal;
  if (e['estado'] == 'guardado' || e['estado'] == 'retirado') return ColorEquipo.apagado;
  if (e['conectado'] == true) return ColorEquipo.ok;
  return ColorEquipo.gris;
}

/// «conectado» o «hace 5 min»: lo que más se pregunta de un equipo.
String cuandoSeVio(Json e) => e['conectado'] == true ? 'conectado' : hace(e['ultima_vez']);

/// Los filtros de la lista de equipos. Los mismos parámetros que entiende
/// `GET /v1/equipos`, más `sin24` en [conectado], que no es un filtro del hub
/// sino `sin_contacto=1` (la misma cuenta que el resumen).
class FiltrosEquipos {
  const FiltrosEquipos({
    this.q = '',
    this.dominio = '',
    this.estado = '',
    this.conectado = '',
    this.alerta = false,
    this.retirados = false,
  });

  final String q;
  final String dominio;
  final String estado;

  /// '', '1', '0' o 'sin24'.
  final String conectado;
  final bool alerta;
  final bool retirados;

  bool get vacios =>
      q.isEmpty && dominio.isEmpty && estado.isEmpty && conectado.isEmpty && !alerta && !retirados;

  /// Desde la consulta de un enlace del panel (`?estado=perdido`,
  /// `?conectado=sin24`, `?todos=1`). Lo que no se reconoce se ignora.
  factory FiltrosEquipos.deConsulta(Map<String, String> c) => FiltrosEquipos(
    q: c['q'] ?? '',
    dominio: c['dominio'] ?? '',
    estado: estados.containsKey(c['estado']) ? c['estado']! : '',
    conectado: const {'1', '0', 'sin24'}.contains(c['conectado']) ? c['conectado']! : '',
    alerta: c['alerta'] == '1',
    retirados: c['retirados'] == '1',
  );

  /// La consulta para `GET /v1/equipos`, sin los vacíos.
  Map<String, String> get consulta => {
    if (q.trim().isNotEmpty) 'q': q.trim(),
    if (dominio.isNotEmpty) 'dominio': dominio,
    if (estado.isNotEmpty) 'estado': estado,
    if (conectado == '1' || conectado == '0') 'conectado': conectado,
    if (conectado == 'sin24') 'sin_contacto': '1',
    if (alerta) 'alerta': '1',
    if (retirados && estado.isEmpty) 'retirados': '1',
  };

  FiltrosEquipos copia({
    String? q,
    String? dominio,
    String? estado,
    String? conectado,
    bool? alerta,
    bool? retirados,
  }) => FiltrosEquipos(
    q: q ?? this.q,
    dominio: dominio ?? this.dominio,
    estado: estado ?? this.estado,
    conectado: conectado ?? this.conectado,
    alerta: alerta ?? this.alerta,
    retirados: retirados ?? this.retirados,
  );

  @override
  bool operator ==(Object other) =>
      other is FiltrosEquipos &&
      other.q == q &&
      other.dominio == dominio &&
      other.estado == estado &&
      other.conectado == conectado &&
      other.alerta == alerta &&
      other.retirados == retirados;

  @override
  int get hashCode => Object.hash(q, dominio, estado, conectado, alerta, retirados);
}

/// Cómo se ordena la lista. El hub la manda por nombre; lo demás se ordena
/// aquí, con lo que no tiene valor al final en los dos sentidos.
enum OrdenEquipos {
  nombre('Nombre'),
  ultimaVez('Última vez'),
  bateria('Batería'),
  alertas('Alertas'),
  usuario('Último usuario');

  const OrdenEquipos(this.titulo);
  final String titulo;
}

List<Json> ordena(List<Json> equipos, OrdenEquipos orden) {
  int porNombre(Json a, Json b) =>
      '${a['nombre'] ?? ''}'.toLowerCase().compareTo('${b['nombre'] ?? ''}'.toLowerCase());
  // Lo que no tiene valor va al final, en cualquier sentido.
  int compara<T extends Comparable<T>>(T? a, T? b, {bool alReves = false}) {
    if (a == null || b == null) return a == null ? (b == null ? 0 : 1) : -1;
    return alReves ? b.compareTo(a) : a.compareTo(b);
  }

  // Conectado ahora es lo más reciente que hay.
  num? momento(Json e) =>
      e['conectado'] == true ? double.infinity : leeFecha(e['ultima_vez'])?.millisecondsSinceEpoch;

  final l = [...equipos];
  l.sort((a, b) {
    final n = switch (orden) {
      OrdenEquipos.nombre => 0,
      OrdenEquipos.ultimaVez => compara<num>(momento(a), momento(b), alReves: true),
      OrdenEquipos.bateria => compara<num>(entero(a['bateria']), entero(b['bateria'])),
      OrdenEquipos.alertas => compara<num>(entero(a['alertas']) ?? 0, entero(b['alertas']) ?? 0, alReves: true),
      OrdenEquipos.usuario => compara<String>(
        ultimoUsuario(a)?.nombre.toLowerCase(),
        ultimoUsuario(b)?.nombre.toLowerCase(),
      ),
    };
    return n != 0 ? n : porNombre(a, b);
  });
  return l;
}
