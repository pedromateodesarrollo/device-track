import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';

/// El cliente de los modelos de IA: Anthropic (Claude) y Google (Gemini).
///
/// HTTP a mano con `dart:io`, como el correo: el hub sigue con sus dos
/// dependencias. Sin streaming: una vuelta es una petición y su respuesta
/// entera. El asistente avisa al panel de cada herramienta que usa, y eso es
/// lo que la persona ve avanzar.
///
/// La conversación va en el formato de cada proveedor ([IaProveedor.mensajeUsuario],
/// [IaVuelta.mensaje], [IaProveedor.mensajeResultados]) y se le devuelve tal
/// cual la mandó: lo que el modelo pensó entre una herramienta y otra (los
/// bloques de razonamiento de Claude, las firmas de Gemini) viaja intacto. Quitar
/// o reescribir algo de un turno anterior es un 400 en los modelos de 2026.

/// Una herramienta que el modelo puede pedir. [parametros] es un JSON Schema.
class IaHerramienta {
  const IaHerramienta({required this.nombre, required this.descripcion, required this.parametros});

  final String nombre;
  final String descripcion;
  final Map<String, Object?> parametros;
}

/// Lo que el modelo pidió hacer.
class IaLlamada {
  const IaLlamada(this.id, this.nombre, this.args);

  final String id;
  final String nombre;
  final Map<String, Object?> args;
}

/// Lo que salió de una [IaLlamada]. [contenido] va como JSON.
class IaResultado {
  const IaResultado(this.llamada, this.contenido, {this.error = false});

  final IaLlamada llamada;
  final Object? contenido;
  final bool error;
}

/// Tokens de una o varias vueltas.
class IaUso {
  const IaUso({this.entrada = 0, this.salida = 0, this.cacheLectura = 0, this.cacheEscritura = 0});

  final int entrada;
  final int salida;
  final int cacheLectura;
  final int cacheEscritura;

  IaUso operator +(IaUso o) => IaUso(
    entrada: entrada + o.entrada,
    salida: salida + o.salida,
    cacheLectura: cacheLectura + o.cacheLectura,
    cacheEscritura: cacheEscritura + o.cacheEscritura,
  );
}

/// Una vuelta del modelo.
class IaVuelta {
  const IaVuelta({
    required this.texto,
    required this.llamadas,
    required this.mensaje,
    required this.motivo,
    required this.uso,
    required this.modelo,
  });

  /// Lo que escribió para la persona (puede venir junto con llamadas).
  final String texto;
  final List<IaLlamada> llamadas;

  /// El turno del modelo en el formato del proveedor, para añadirlo tal cual
  /// a la conversación.
  final Map<String, Object?> mensaje;

  /// `fin`, `herramientas`, `cortada` (se acabó el tope de salida) o
  /// `rechazo` (el proveedor no quiso contestar).
  final String motivo;
  final IaUso uso;

  /// El modelo que contestó. Puede no ser el pedido: Anthropic pasa a otro
  /// cuando el suyo declina (`fallbacks`).
  final String modelo;
}

/// Algo salió mal al hablar con el proveedor. [codigo] es estable, para la
/// API; [detalle] es lo que dijo el proveedor (nunca lleva la clave: la clave
/// va en una cabecera y no se repite en ningún mensaje).
class IaError implements Exception {
  IaError(this.codigo, [this.detalle = '']);

  final String codigo;
  final String detalle;

  @override
  String toString() => 'IaError($codigo: $detalle)';
}

abstract class IaProveedor {
  IaProveedor(this.modelo, this.clave, this.base, this.espera);

  /// El cliente que corresponde a [c]. [base] cambia la dirección del
  /// proveedor (solo para las pruebas).
  factory IaProveedor.de(ConfigIa c, {Uri? base, Duration espera = const Duration(minutes: 3)}) =>
      switch (c.proveedor) {
        'anthropic' => IaAnthropic(c.modelo, c.clave, base ?? Uri.parse('https://api.anthropic.com'), espera),
        'gemini' => IaGemini(c.modelo, c.clave, base ?? Uri.parse('https://generativelanguage.googleapis.com'), espera),
        _ => throw IaError('ia_proveedor_invalido', c.proveedor),
      };

  final String modelo;
  final String clave;
  final Uri base;

  /// Lo más que se espera una respuesta. Un modelo que razona puede tardar un
  /// minuto en una pregunta difícil.
  final Duration espera;

  String get id;

  Map<String, Object?> mensajeUsuario(String texto);

  /// Todos los resultados de una vuelta, en un solo turno: así lo piden los
  /// dos proveedores cuando el modelo hace varias llamadas a la vez.
  Map<String, Object?> mensajeResultados(List<IaResultado> resultados);

  /// Una vuelta. [esfuerzo] (`low`, `medium`, `high`) va solo a los modelos
  /// que lo entienden.
  Future<IaVuelta> turno({
    required String instruccion,
    required List<Map<String, Object?>> mensajes,
    List<IaHerramienta> herramientas = const [],
    int maxSalida = 16000,
    String? esfuerzo,
  });

  /// POST con JSON; devuelve el JSON de la respuesta o lanza [IaError].
  Future<Map<String, Object?>> postJson(Uri url, Map<String, String> cabeceras, Object cuerpo) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final pet = await c.postUrl(url);
      cabeceras.forEach(pet.headers.set);
      pet.headers.contentType = ContentType.json;
      pet.add(utf8.encode(jsonEncode(cuerpo)));
      final res = await pet.close().timeout(espera);
      final texto = await utf8.decodeStream(res).timeout(espera);
      if (res.statusCode >= 300) throw errorHttp(res.statusCode, texto);
      final Object? j;
      try {
        j = jsonDecode(texto);
      } on FormatException {
        throw IaError('ia_respuesta_rara', _recorta(texto));
      }
      if (j is! Map) throw IaError('ia_respuesta_rara', _recorta(texto));
      return j.cast<String, Object?>();
    } on TimeoutException {
      throw IaError('ia_sin_respuesta', 'El proveedor no contestó en ${espera.inSeconds} s');
    } on SocketException catch (e) {
      throw IaError('ia_sin_conexion', e.message);
    } on HandshakeException catch (e) {
      throw IaError('ia_sin_conexion', e.message);
    } on HttpException catch (e) {
      throw IaError('ia_sin_conexion', e.message);
    } finally {
      c.close(force: true);
    }
  }

  /// Traduce un error HTTP del proveedor a un código que el panel sabe explicar.
  static IaError errorHttp(int estado, String cuerpo) {
    var mensaje = cuerpo;
    try {
      final j = jsonDecode(cuerpo);
      if (j is Map && j['error'] is Map) mensaje = '${(j['error'] as Map)['message'] ?? cuerpo}';
    } on FormatException {
      // No era JSON: queda el texto tal cual.
    }
    final m = mensaje.toLowerCase();
    final codigo = switch (estado) {
      401 || 403 => 'ia_clave_invalida',
      // Gemini contesta una clave mala con un 400.
      400 when m.contains('api key not valid') || m.contains('api_key_invalid') => 'ia_clave_invalida',
      400 when m.contains('credit balance') => 'ia_sin_saldo',
      404 => 'ia_modelo_no_existe',
      400 when m.contains('model') && (m.contains('not found') || m.contains('not supported')) => 'ia_modelo_no_existe',
      429 => 'ia_limite',
      >= 500 => 'ia_proveedor_caido',
      _ => 'ia_proveedor_error',
    };
    return IaError(codigo, 'HTTP $estado: ${_recorta(mensaje)}');
  }

  static String _recorta(String t) => t.length > 400 ? '${t.substring(0, 400)}…' : t;
}

// ═══════════════════════════════ Anthropic ═══════════════════════════════════

class IaAnthropic extends IaProveedor {
  IaAnthropic(super.modelo, super.clave, super.base, super.espera);

  @override
  String get id => 'anthropic';

  /// Los modelos que aceptan `output_config.effort`. Haiku 4.5 lo rechaza.
  static bool aceptaEsfuerzo(String modelo) =>
      RegExp(r'^claude-(opus-5|sonnet-5|fable|mythos|opus-4-[5678])').hasMatch(modelo);

  /// Los modelos con clasificadores que pueden declinar una pregunta: con
  /// `fallbacks: "default"` la API la pasa sola al modelo que recomienda en
  /// vez de devolver la negativa.
  static bool conRespaldo(String modelo) =>
      RegExp(r'^claude-(opus-5|sonnet-5-5|fable-5-1)').hasMatch(modelo);

  @override
  Map<String, Object?> mensajeUsuario(String texto) => {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': texto},
    ],
  };

  @override
  Map<String, Object?> mensajeResultados(List<IaResultado> resultados) => {
    'role': 'user',
    'content': [
      for (final r in resultados)
        {
          'type': 'tool_result',
          'tool_use_id': r.llamada.id,
          'content': r.contenido is String ? r.contenido : jsonEncode(r.contenido, toEncodable: _aJson),
          if (r.error) 'is_error': true,
        },
    ],
  };

  /// El cuerpo de la petición. Público para las pruebas.
  Map<String, Object?> cuerpo({
    required String instruccion,
    required List<Map<String, Object?>> mensajes,
    List<IaHerramienta> herramientas = const [],
    int maxSalida = 16000,
    String? esfuerzo,
  }) => {
    'model': modelo,
    'max_tokens': maxSalida,
    // Herramientas + instrucción son lo que se repite idéntico en cada vuelta
    // y en cada pregunta: se cachean. Sin `temperature` ni `thinking`: los
    // modelos de 2026 rechazan el primero, y el razonamiento lo decide cada
    // modelo (Opus 5.5 piensa siempre).
    'system': [
      {'type': 'text', 'text': instruccion, 'cache_control': {'type': 'ephemeral'}},
    ],
    'messages': mensajes,
    if (herramientas.isNotEmpty)
      'tools': [
        for (final h in herramientas) {'name': h.nombre, 'description': h.descripcion, 'input_schema': h.parametros},
      ],
    if (esfuerzo != null && aceptaEsfuerzo(modelo)) 'output_config': {'effort': esfuerzo},
    if (conRespaldo(modelo)) 'fallbacks': 'default',
  };

  @override
  Future<IaVuelta> turno({
    required String instruccion,
    required List<Map<String, Object?>> mensajes,
    List<IaHerramienta> herramientas = const [],
    int maxSalida = 16000,
    String? esfuerzo,
  }) async {
    final r = await postJson(
      base.resolve('/v1/messages'),
      {
        'x-api-key': clave,
        'anthropic-version': '2023-06-01',
        if (conRespaldo(modelo)) 'anthropic-beta': 'server-side-fallback-2026-07-01',
      },
      cuerpo(
        instruccion: instruccion,
        mensajes: mensajes,
        herramientas: herramientas,
        maxSalida: maxSalida,
        esfuerzo: esfuerzo,
      ),
    );
    return leeRespuesta(r, modelo);
  }

  /// Público para las pruebas.
  static IaVuelta leeRespuesta(Map<String, Object?> r, String pedido) {
    final contenido = (r['content'] as List?) ?? const [];
    final texto = StringBuffer();
    final llamadas = <IaLlamada>[];
    for (final b in contenido) {
      if (b is! Map) continue;
      switch (b['type']) {
        case 'text':
          texto.write(b['text'] ?? '');
        case 'tool_use':
          llamadas.add(IaLlamada(
            '${b['id']}',
            '${b['name']}',
            b['input'] is Map ? (b['input'] as Map).cast<String, Object?>() : const {},
          ));
      }
    }
    final u = (r['usage'] as Map?) ?? const {};
    final motivo = switch (r['stop_reason']) {
      'tool_use' when llamadas.isNotEmpty => 'herramientas',
      'max_tokens' => 'cortada',
      'refusal' => 'rechazo',
      _ => 'fin',
    };
    return IaVuelta(
      texto: texto.toString().trim(),
      llamadas: motivo == 'herramientas' ? llamadas : const [],
      // El turno entero, con sus bloques de razonamiento: se devuelve igual.
      mensaje: {'role': 'assistant', 'content': contenido},
      motivo: motivo,
      modelo: '${r['model'] ?? pedido}',
      uso: IaUso(
        entrada: _n(u['input_tokens']),
        salida: _n(u['output_tokens']),
        cacheLectura: _n(u['cache_read_input_tokens']),
        cacheEscritura: _n(u['cache_creation_input_tokens']),
      ),
    );
  }
}

// ═══════════════════════════════ Gemini ══════════════════════════════════════

class IaGemini extends IaProveedor {
  IaGemini(super.modelo, super.clave, super.base, super.espera);

  @override
  String get id => 'gemini';

  @override
  Map<String, Object?> mensajeUsuario(String texto) => {
    'role': 'user',
    'parts': [
      {'text': texto},
    ],
  };

  @override
  Map<String, Object?> mensajeResultados(List<IaResultado> resultados) => {
    'role': 'user',
    'parts': [
      for (final r in resultados)
        {
          'functionResponse': {
            'name': r.llamada.nombre,
            if (!r.llamada.id.startsWith('g:')) 'id': r.llamada.id,
            // `response` tiene que ser un objeto: una lista suelta la rechaza.
            'response': jsonDecode(jsonEncode(
              r.error ? {'error': r.contenido} : {'resultado': r.contenido},
              toEncodable: _aJson,
            )),
          },
        },
    ],
  };

  Map<String, Object?> cuerpo({
    required String instruccion,
    required List<Map<String, Object?>> mensajes,
    List<IaHerramienta> herramientas = const [],
    int maxSalida = 16000,
  }) => {
    'systemInstruction': {
      'parts': [
        {'text': instruccion},
      ],
    },
    'contents': mensajes,
    if (herramientas.isNotEmpty)
      'tools': [
        {
          'functionDeclarations': [
            for (final h in herramientas)
              {
                'name': h.nombre,
                'description': h.descripcion,
                // Un objeto sin propiedades es un 400 en Gemini: una
                // herramienta sin argumentos va sin `parameters`.
                if ((h.parametros['properties'] as Map?)?.isNotEmpty ?? false)
                  'parameters': esquemaGemini(h.parametros),
              },
          ],
        },
      ],
    'generationConfig': {'maxOutputTokens': maxSalida},
  };

  @override
  Future<IaVuelta> turno({
    required String instruccion,
    required List<Map<String, Object?>> mensajes,
    List<IaHerramienta> herramientas = const [],
    int maxSalida = 16000,
    String? esfuerzo,
  }) async {
    final r = await postJson(
      base.resolve('/v1beta/models/$modelo:generateContent'),
      // La clave en la cabecera y no en `?key=`: una URL acaba en logs.
      {'x-goog-api-key': clave},
      cuerpo(instruccion: instruccion, mensajes: mensajes, herramientas: herramientas, maxSalida: maxSalida),
    );
    return leeRespuesta(r, modelo);
  }

  static IaVuelta leeRespuesta(Map<String, Object?> r, String pedido) {
    final candidatos = (r['candidates'] as List?) ?? const [];
    final c = candidatos.isNotEmpty && candidatos.first is Map ? candidatos.first as Map : const {};
    final contenido = c['content'] is Map
        ? (c['content'] as Map).cast<String, Object?>()
        : <String, Object?>{'role': 'model', 'parts': const []};
    // Gemini no acepta un turno sin partes en la historia.
    final partes = (contenido['parts'] as List?) ?? const [];
    final mensaje = partes.isEmpty
        ? <String, Object?>{
            'role': 'model',
            'parts': [
              {'text': ' '},
            ],
          }
        : {...contenido, 'role': 'model'};
    final texto = StringBuffer();
    final llamadas = <IaLlamada>[];
    var n = 0;
    for (final p in partes) {
      if (p is! Map) continue;
      if (p['thought'] == true) continue; // resumen de lo que pensó, no respuesta
      final fc = p['functionCall'];
      if (fc is Map) {
        n++;
        llamadas.add(IaLlamada(
          // Sin id propio, uno nuestro que no se le devuelve.
          '${fc['id'] ?? 'g:$n'}',
          '${fc['name']}',
          fc['args'] is Map ? (fc['args'] as Map).cast<String, Object?>() : const {},
        ));
      } else if (p['text'] is String) {
        texto.write(p['text']);
      }
    }
    final fin = '${c['finishReason'] ?? ''}';
    final u = (r['usageMetadata'] as Map?) ?? const {};
    final motivo = llamadas.isNotEmpty
        ? 'herramientas'
        : fin == 'MAX_TOKENS'
        ? 'cortada'
        : (fin == 'SAFETY' || fin == 'PROHIBITED_CONTENT' || fin == 'BLOCKLIST' ||
              (r['promptFeedback'] as Map?)?['blockReason'] != null)
        ? 'rechazo'
        : 'fin';
    return IaVuelta(
      texto: texto.toString().trim(),
      llamadas: llamadas,
      mensaje: mensaje,
      motivo: motivo,
      modelo: '${r['modelVersion'] ?? pedido}',
      uso: IaUso(
        entrada: _n(u['promptTokenCount']),
        // Lo que el modelo piensa se cobra como salida.
        salida: _n(u['candidatesTokenCount']) + _n(u['thoughtsTokenCount']),
        cacheLectura: _n(u['cachedContentTokenCount']),
      ),
    );
  }

  /// Gemini acepta un subconjunto de OpenAPI con `type` en mayúsculas; lo que
  /// no entiende (`additionalProperties`, por ejemplo) lo rechaza con un 400.
  static Map<String, Object?> esquemaGemini(Map<String, Object?> e) {
    const permitidas = {
      'type', 'format', 'description', 'nullable', 'enum', 'properties', 'required',
      'items', 'minItems', 'maxItems', 'minimum', 'maximum',
    };
    final out = <String, Object?>{};
    e.forEach((k, v) {
      if (!permitidas.contains(k)) return;
      if (k == 'type' && v is String) {
        out[k] = v.toUpperCase();
      } else if (k == 'properties' && v is Map) {
        out[k] = {
          for (final p in v.entries) '${p.key}': esquemaGemini((p.value as Map).cast<String, Object?>()),
        };
      } else if (k == 'items' && v is Map) {
        out[k] = esquemaGemini(v.cast<String, Object?>());
      } else {
        out[k] = v;
      }
    });
    return out;
  }
}

int _n(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

/// Lo que sale de Postgres (fechas) hacia el JSON de un resultado.
Object? _aJson(Object? v) => v is DateTime ? v.toUtc().toIso8601String() : v.toString();
