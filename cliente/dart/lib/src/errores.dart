/// El hub contestó, con un error suyo: `{"error": "<código>", "mensaje": "…"}`
/// y su código HTTP. Si lo que contestó no es JSON (un nginx con un 502),
/// [codigo] es `http_<status>`.
class ErrorHub implements Exception {
  const ErrorHub(this.status, this.codigo, this.mensaje);

  final int status;

  /// `codigo_invalido`, `equipo_no_autenticado`, `demasiados_reportes`…
  final String codigo;

  /// Para una persona.
  final String mensaje;

  /// 401. En el alta: el código de alta no existe. Después: la credencial del
  /// equipo ya no vale (otra alta desde la misma app la reemplazó, o borraron
  /// el equipo) y hay que darlo de alta otra vez.
  bool get noAutorizado => status == 401;

  /// 429 o 5xx: vale la pena volver a intentarlo más tarde. Lo demás (400,
  /// 404, 410) no se arregla repitiendo.
  bool get reintentable => status == 429 || status >= 500;

  @override
  String toString() => 'ErrorHub($status $codigo: $mensaje)';
}

/// No hubo respuesta útil del hub: sin red, el hub caído, se acabó el plazo o
/// contestó algo que no es JSON (el portal cautivo de una Wi-Fi). Siempre vale
/// la pena reintentar.
class SinRespuesta implements Exception {
  const SinRespuesta(this.mensaje, [this.causa]);

  final String mensaje;

  /// La excepción de abajo (`SocketException`, `TimeoutException`…).
  final Object? causa;

  @override
  String toString() => 'SinRespuesta($mensaje${causa == null ? '' : ': $causa'})';
}
