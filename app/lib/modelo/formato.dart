/// Cómo se dicen las cosas en la pantalla: fechas, tamaños, distancias y los
/// nombres de estados, redes, motivos y reglas. Son los mismos textos del
/// panel web (`manager/src/api.js`): quien usa los dos no tiene que aprender
/// dos vocabularios.
///
/// Las fechas del hub vienen en ISO y en UTC; aquí se pasan a la hora del
/// teléfono.
library;

/// Lee una fecha del hub. Null si no hay o no se entiende.
DateTime? leeFecha(Object? v) {
  if (v is DateTime) return v.toLocal();
  if (v is! String || v.isEmpty) return null;
  return DateTime.tryParse(v)?.toLocal();
}

/// «ahora», «hace 5 min», «ayer», o la fecha si es de hace más de una semana.
String hace(Object? valor, {DateTime? ahora}) {
  final t = leeFecha(valor);
  if (t == null) return 'nunca';
  final seg = (ahora ?? DateTime.now()).difference(t).inSeconds;
  if (seg < 60) return 'ahora';
  if (seg < 3600) return 'hace ${seg ~/ 60} min';
  if (seg < 86400) return 'hace ${seg ~/ 3600} h';
  if (seg < 172800) return 'ayer';
  if (seg < 604800) return 'hace ${seg ~/ 86400} días';
  return dia(t);
}

/// 7/10/2026, a la dominicana (día primero).
String dia(Object? valor) {
  final t = leeFecha(valor);
  if (t == null) return '';
  return '${t.day}/${t.month}/${t.year}';
}

/// 3:05 p. m.
String hora(Object? valor) {
  final t = leeFecha(valor);
  if (t == null) return '';
  final h12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final mm = t.minute.toString().padLeft(2, '0');
  return '$h12:$mm ${t.hour < 12 ? 'a. m.' : 'p. m.'}';
}

/// 7/10/2026 3:05 p. m.
String fecha(Object? valor) {
  final t = leeFecha(valor);
  if (t == null) return '';
  return '${dia(t)} ${hora(t)}';
}

String bytes(num? n) {
  if (n == null) return '';
  const k = 1024;
  if (n < k) return '$n B';
  if (n < k * k) return '${(n / k).toStringAsFixed(0)} KB';
  if (n < k * k * k) return '${(n / (k * k)).toStringAsFixed(1)} MB';
  return '${(n / (k * k * k)).toStringAsFixed(1)} GB';
}

/// 850 m, 1.2 km.
String distancia(num? m) {
  if (m == null) return '';
  if (m < 1000) return '${m.round()} m';
  return '${(m / 1000).toStringAsFixed(m < 10000 ? 1 : 0)} km';
}

/// Un número del hub, venga como venga (`count(*)` llega entero, pero un
/// proxy o una versión vieja podría mandarlo en texto).
int? entero(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

double? decimal(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

/// Texto limpio o null si viene vacío.
String? texto(Object? v) {
  if (v == null) return null;
  final s = '$v'.trim();
  return s.isEmpty ? null : s;
}

// ------------------------------------------------------------ vocabulario

const estados = {
  'activo': 'Activo',
  'guardado': 'Guardado',
  'perdido': 'Perdido',
  'retirado': 'Retirado',
};

const redes = {'wifi': 'Wi-Fi', 'datos': 'Datos', 'ninguna': 'Sin red', 'otra': 'Otra'};

const motivos = {
  'periodico': 'periódico',
  'encendido': 'al encender',
  'apagando': 'al apagarse',
  'orden': 'por una orden',
  'abrir': 'al abrir la app',
  'manual': 'a mano',
};

class TipoRegla {
  const TipoRegla(this.nombre, this.explica);
  final String nombre;
  final String explica;
}

const tiposRegla = {
  'sin_reporte': TipoRegla(
    'Sin reporte',
    'Se abre cuando el equipo pasa ese tiempo sin dar señales (ni reporte ni conexión). '
        'Se cierra sola en cuanto vuelve a reportar.',
  ),
  'bateria_baja': TipoRegla(
    'Batería baja',
    'Se abre cuando reporta por debajo del porcentaje y no está cargando. '
        'Se cierra al ponerlo a cargar o cuando sube.',
  ),
  'fuera_de_zona': TipoRegla(
    'Fuera de zona',
    'Se abre cuando su ubicación queda fuera del círculo, descontando el error del GPS. '
        'Se cierra cuando vuelve a entrar.',
  ),
  'apagado': TipoRegla(
    'Apagado',
    'Se abre cuando el equipo avisa que se está apagando. Se cierra cuando vuelve a encender.',
  ),
};

String nombreTipoRegla(Object? tipo) => tiposRegla['$tipo']?.nombre ?? '${tipo ?? ''}';

const estadosOrden = {
  'pendiente': 'pendiente',
  'enviada': 'enviada',
  'recibida': 'recibida',
  'hecha': 'hecha',
  'fallida': 'falló',
  'vencida': 'vencida',
};

const tiposOrden = {'sonar': 'Sonar', 'mensaje': 'Mensaje', 'reportar': 'Reportar ya'};

/// Nivel de SDK → versión de Android que la gente conoce.
const versionesAndroid = {
  21: '5.0', 22: '5.1', 23: '6', 24: '7.0', 25: '7.1', 26: '8.0', 27: '8.1', 28: '9',
  29: '10', 30: '11', 31: '12', 32: '12L', 33: '13', 34: '14', 35: '15', 36: '16',
};

String android(Object? sdk) {
  final n = entero(sdk);
  if (n == null || n == 0) return '';
  final v = versionesAndroid[n];
  return v != null ? 'Android $v (SDK $n)' : 'SDK $n';
}

/// Lo que dice una alerta, en una línea que se entienda sin abrir nada.
/// [a] es una fila de `/v1/alertas` o de `alertas_abiertas` de la ficha.
String detalleAlerta(Map<String, Object?> a) {
  final d = a['detalle'] is Map ? (a['detalle'] as Map).cast<String, Object?>() : const <String, Object?>{};
  switch (a['tipo']) {
    case 'bateria_baja':
      return '${d['bateria'] ?? '?'} % (umbral ${d['porcentaje'] ?? '?'} %)';
    case 'fuera_de_zona':
      final radio = decimal(d['radio_m']);
      return 'a ${distancia(decimal(d['distancia_m']))} de ${d['zona'] ?? 'la zona'}'
          '${radio != null && radio > 0 ? ' (radio ${distancia(radio)})' : ''}';
    case 'sin_reporte':
      return d['ultima_vez'] != null
          ? 'sin contacto desde ${fecha(d['ultima_vez'])}'
          : 'sin contacto en ${d['minutos'] ?? '?'} min';
    case 'apagado':
      return 'avisó que se estaba apagando';
    default:
      return '';
  }
}

/// Lo que dice un error del asistente de IA, en simple. El detalle técnico
/// (lo que contestó el proveedor) va entre paréntesis por si hace falta.
const _erroresIa = {
  'ia_clave_invalida': 'El proveedor no aceptó la clave: revisa que esté completa y que sea de ese proveedor.',
  'ia_modelo_no_existe': 'Ese modelo no existe en tu cuenta del proveedor, o está mal escrito.',
  'ia_sin_saldo': 'Tu cuenta del proveedor se quedó sin saldo: recárgala en su consola.',
  'ia_limite': 'El proveedor dice que se pasó su límite de peticiones: espera un minuto.',
  'ia_proveedor_caido': 'El proveedor no está respondiendo bien ahora: prueba en un rato.',
  'ia_sin_conexion': 'El hub no pudo hablar con el proveedor.',
  'ia_sin_respuesta': 'El proveedor tardó demasiado en contestar.',
};

String explicaIa(String? codigo, String mensaje) {
  final simple = _erroresIa[codigo];
  if (simple == null) return mensaje.isNotEmpty ? mensaje : (codigo ?? 'Algo falló');
  return mensaje.isNotEmpty ? '$simple ($mensaje)' : simple;
}
