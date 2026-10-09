/// Las credenciales del asistente de IA de una organización (`dt.org.ia`).
///
/// Son de la organización y de nadie más: cada una pone las de su cuenta con
/// el proveedor, que le cobra a ella. El hub no tiene una clave propia ni le
/// presta a una organización la de otra.
class ConfigIa {
  const ConfigIa({
    required this.proveedor,
    required this.modelo,
    this.clave = '',
    this.activo = true,
  });

  /// `anthropic` o `gemini`.
  final String proveedor;
  final String modelo;
  final String clave;

  /// Apagado conserva las credenciales pero quita el asistente del panel.
  final bool activo;

  static const proveedores = ['anthropic', 'gemini'];

  /// Lo que el panel sugiere al elegir. Se acepta cualquier otro nombre que
  /// el proveedor reconozca: el botón «Probar» dice si existe.
  static const modelos = {
    'anthropic': ['claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-4-5', 'claude-fable-5-1'],
    'gemini': ['gemini-3.8-flash', 'gemini-2.5-flash', 'gemini-2.5-pro'],
  };

  static const nombres = {'anthropic': 'Anthropic (Claude)', 'gemini': 'Google (Gemini)'};

  /// Un nombre de modelo: letras, números, puntos y guiones. Nada que pueda
  /// cambiar la URL a la que se llama (Gemini lo lleva en la ruta).
  static final formatoModelo = RegExp(r'^[a-z0-9][a-z0-9.\-]{1,80}$');

  bool get completa => proveedores.contains(proveedor) && formatoModelo.hasMatch(modelo) && clave.isNotEmpty;

  /// Si la organización tiene asistente ahora mismo.
  bool get disponible => activo && completa;

  /// Lo que se guarda en `dt.org.ia`.
  Map<String, Object?> aJson() => {
    'proveedor': proveedor,
    'modelo': modelo,
    'clave': clave,
    'activo': activo,
  };

  /// Lo que ve el panel: todo menos la clave.
  Map<String, Object?> publico() => {
    'proveedor': proveedor,
    'modelo': modelo,
    'activo': activo,
    'clave_puesta': clave.isNotEmpty,
    'configurado': completa,
    'disponible': disponible,
  };

  static ConfigIa? deJson(Object? j) {
    if (j is! Map || (j['proveedor'] ?? '').toString().isEmpty) return null;
    return ConfigIa(
      proveedor: '${j['proveedor']}',
      modelo: '${j['modelo'] ?? ''}',
      clave: '${j['clave'] ?? ''}',
      activo: j['activo'] != false,
    );
  }
}
