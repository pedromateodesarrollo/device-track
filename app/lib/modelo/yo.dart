/// Quién tiene la sesión (`GET /v1/yo`) y lo que puede hacer.
///
/// Esconder un botón es cortesía: quien decide es el hub, que vuelve a mirar
/// el rol y los dominios en la base en cada petición. Pero un botón que
/// siempre contesta «sin permiso» es peor que no tenerlo.
library;

import 'formato.dart';

class Dominio {
  const Dominio({required this.id, required this.nombre, this.slug = '', this.equipos});

  final int id;
  final String nombre;
  final String slug;

  /// Cuántos equipos tiene (solo en `GET /v1/dominios`).
  final int? equipos;

  factory Dominio.deJson(Map<String, Object?> m) => Dominio(
    id: entero(m['id']) ?? 0,
    nombre: '${m['nombre'] ?? ''}',
    slug: '${m['slug'] ?? ''}',
    equipos: entero(m['equipos']),
  );
}

class Yo {
  const Yo({
    required this.id,
    required this.correo,
    required this.nombre,
    required this.rol,
    required this.org,
    required this.organizacion,
    this.dominios = const [],
    this.ia = false,
  });

  final int id;
  final String correo;
  final String nombre;

  /// `admin`, `editor` o `consulta`.
  final String rol;
  final int org;
  final String organizacion;

  /// Los dominios a los que está limitada. Vacía = toda la organización.
  final List<Dominio> dominios;

  /// Si la organización tiene el asistente de IA encendido.
  final bool ia;

  factory Yo.deJson(Map<String, Object?> m) => Yo(
    id: entero(m['id']) ?? 0,
    correo: '${m['correo'] ?? ''}',
    nombre: '${m['nombre'] ?? ''}',
    rol: '${m['rol'] ?? ''}',
    org: entero(m['org']) ?? 0,
    organizacion: '${m['organizacion'] ?? ''}',
    dominios: [
      for (final d in (m['dominios'] as List?) ?? const [])
        if (d is Map) Dominio.deJson(d.cast<String, Object?>()),
    ],
    ia: m['ia'] == true,
  );

  Yo conIa(bool ia) => Yo(
    id: id,
    correo: correo,
    nombre: nombre,
    rol: rol,
    org: org,
    organizacion: organizacion,
    dominios: dominios,
    ia: ia,
  );

  bool get acotado => dominios.isNotEmpty;

  /// Administrar es de toda la organización: una sesión limitada a unos
  /// dominios nunca lo es, aunque el rol dijera otra cosa (igual que el hub,
  /// `Sesion.esAdmin`).
  bool get esAdmin => rol == 'admin' && !acotado;

  /// Lo que cada rol puede: `admin` todo; `editor` mira, edita y ordena;
  /// `consulta` solo mira. Es `Sesion.puede` del hub.
  static const _porRol = {
    'editor': {'leer', 'editar', 'ordenar'},
    'consulta': {'leer'},
  };

  bool puede(String permiso) {
    if (esAdmin) return true;
    return _porRol[rol]?.contains(permiso) ?? false;
  }

  /// Si puede tocar una regla o una zona de ese dominio (null = de toda la
  /// organización). Limitada, ve las de toda la organización pero solo toca
  /// las de sus dominios.
  bool alcanza(int? dominio) => !acotado || (dominio != null && dominios.any((d) => d.id == dominio));

  /// «Duralon» o «Duralon, JF».
  String get alcanceTexto => dominios.map((d) => d.nombre).join(', ');

  static const rolesTexto = {
    'admin': 'Administrador',
    'editor': 'Editor',
    'consulta': 'Consulta',
  };

  static const rolesExplica = {
    'admin': 'Lo del editor y además la organización, las personas, los dominios y las llaves de API. '
        'Siempre ve toda la organización.',
    'editor': 'Maneja los equipos y sus órdenes, las reglas, las zonas, las alertas y los códigos de alta.',
    'consulta': 'Mira: equipos, mapa, alertas y reglas. No cambia nada.',
  };
}
