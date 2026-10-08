import 'dart:io';
import 'dart:math';

/// Configuración del hub, toda por variable de entorno.
///
/// Un servicio que un tercero instala en su propio servidor se configura por
/// entorno: es lo que entienden systemd, Docker y cualquier PaaS. Nada de
/// archivos de configuración con rutas que adivinar.
class Config {
  Config({
    required this.urlBd,
    required this.host,
    required this.puerto,
    required this.secretoJwt,
    required this.registro,
    required this.origenesCors,
    required this.rutaManager,
    required this.urlPublica,
    required this.secretoEfimero,
  });

  /// `postgres://usuario:clave@host:5432/base`
  final String urlBd;

  /// Dirección en la que escucha. `0.0.0.0` dentro de Docker; detrás de un
  /// nginx en la misma máquina, `127.0.0.1`, para que nadie llegue de lado.
  final String host;
  final int puerto;

  /// Clave HS256 de los JWT de sesión. Cambiarla cierra la sesión de todos.
  final String secretoJwt;

  /// `cerrado` (por defecto: los usuarios los invita un administrador),
  /// `abierto` (cualquiera crea su organización).
  final String registro;

  /// Vacío = `*`. Con contenido, solo se refleja el Origin que esté en la lista.
  final List<String> origenesCors;

  /// Carpeta con el panel web compilado. Si no existe, el hub sirve solo API.
  final String rutaManager;

  /// URL con la que el mundo llega al hub (`https://equipos.ejemplo.com`). Va
  /// en el QR de los códigos de alta y en los enlaces de invitación. Vacía =
  /// se deduce de las cabeceras del proxy (`X-Forwarded-Proto` y `Host`).
  final String urlPublica;

  /// True cuando el secreto JWT se generó al arrancar (no venía por entorno).
  /// Vale para desarrollo; en producción significa que un reinicio saca a todos.
  final bool secretoEfimero;

  static const _reglas = <String>[
    'DT_DATABASE_URL   (obligatoria)  postgres://usuario:clave@host:5432/base',
    'DT_HOST           (0.0.0.0)',
    'DT_PUERTO         (3140)',
    'DT_SECRETO_JWT    (aleatoria si falta; en producción, fíjala)',
    'DT_REGISTRO       (cerrado|abierto, por defecto cerrado)',
    'DT_CORS           (lista separada por comas; vacío = *)',
    'DT_MANAGER        (ruta al panel compilado; por defecto ./manager)',
    'DT_URL_PUBLICA    (https://tu-dominio; vacía = se deduce del proxy)',
    'DT_MIGRACIONES    (carpeta de migraciones; por defecto ./migraciones)',
  ];

  static String get ayuda => _reglas.join('\n  ');

  factory Config.desdeEntorno([Map<String, String>? entorno]) {
    final e = entorno ?? Platform.environment;
    final url = (e['DT_DATABASE_URL'] ?? '').trim();
    if (url.isEmpty) {
      throw ArgumentError('Falta DT_DATABASE_URL.\n  Variables:\n  $ayuda');
    }
    final secreto = (e['DT_SECRETO_JWT'] ?? '').trim();
    final registro = (e['DT_REGISTRO'] ?? 'cerrado').trim().toLowerCase();
    if (!const ['abierto', 'cerrado'].contains(registro)) {
      throw ArgumentError('DT_REGISTRO debe ser cerrado o abierto');
    }
    final urlPublica = (e['DT_URL_PUBLICA'] ?? '').trim();
    return Config(
      urlBd: url,
      host: (e['DT_HOST'] ?? '').trim().isEmpty ? '0.0.0.0' : e['DT_HOST']!.trim(),
      puerto: int.tryParse(e['DT_PUERTO'] ?? '') ?? 3140,
      secretoJwt: secreto.isEmpty ? _secretoAleatorio() : secreto,
      secretoEfimero: secreto.isEmpty,
      registro: registro,
      origenesCors: (e['DT_CORS'] ?? '')
          .split(',')
          .map((o) => o.trim())
          .where((o) => o.isNotEmpty)
          .toList(),
      rutaManager: (e['DT_MANAGER'] ?? 'manager').trim(),
      urlPublica: urlPublica.replaceAll(RegExp(r'/+$'), ''),
    );
  }

  static String _secretoAleatorio() {
    final r = Random.secure();
    return List.generate(48, (_) => r.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
