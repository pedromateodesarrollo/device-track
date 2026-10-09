import 'dart:convert';
import 'dart:io';

/// Un proveedor de IA de mentira: contesta como Anthropic (`/v1/messages`) y
/// como Gemini (`…:generateContent`), y anota lo que le llega. Así se prueba
/// el cliente sin red ni gasto.
class IaFalso {
  IaFalso._(this._servidor);

  final HttpServer _servidor;

  /// Lo que llegó: ruta, cabeceras (en minúsculas) y cuerpo.
  final peticiones = <({String ruta, Map<String, String> cabeceras, Map<String, dynamic> cuerpo})>[];

  /// Las próximas respuestas, en orden: `(estado, cuerpo)`. Vacía, contesta
  /// un texto corto como el proveedor que le toque.
  final respuestas = <(int, Object)>[];

  int get puerto => _servidor.port;
  Uri get base => Uri.parse('http://127.0.0.1:$puerto');

  static Future<IaFalso> arranca() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final f = IaFalso._(s);
    s.listen(f._atiende);
    return f;
  }

  Future<void> cierra() => _servidor.close(force: true);

  Future<void> _atiende(HttpRequest pet) async {
    final texto = await utf8.decodeStream(pet);
    final cabeceras = <String, String>{};
    pet.headers.forEach((k, v) => cabeceras[k.toLowerCase()] = v.join(','));
    final cuerpo = texto.isEmpty ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(texto) as Map);
    peticiones.add((ruta: pet.uri.toString(), cabeceras: cabeceras, cuerpo: cuerpo));

    final (int estado, Object respuesta) = respuestas.isNotEmpty
        ? respuestas.removeAt(0)
        : cabeceras['x-api-key'] == 'mala'
        ? (401, {'type': 'error', 'error': {'type': 'authentication_error', 'message': 'invalid x-api-key'}})
        : pet.uri.path.startsWith('/v1/messages')
        ? (200, anthropicTexto('Listo, funciono', modelo: '${cuerpo['model']}'))
        : (200, geminiTexto('Listo, funciono'));
    pet.response
      ..statusCode = estado
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(respuesta));
    await pet.response.close();
  }

  static Map<String, Object?> anthropicTexto(String texto, {String modelo = 'claude-opus-5-5'}) => {
    'model': modelo,
    'content': [
      {'type': 'thinking', 'thinking': '', 'signature': 'firma-1'},
      {'type': 'text', 'text': texto},
    ],
    'stop_reason': 'end_turn',
    'usage': {'input_tokens': 12, 'output_tokens': 5, 'cache_read_input_tokens': 3},
  };

  static Map<String, Object?> geminiTexto(String texto) => {
    'candidates': [
      {
        'content': {
          'role': 'model',
          'parts': [
            {'text': texto},
          ],
        },
        'finishReason': 'STOP',
      },
    ],
    'usageMetadata': {'promptTokenCount': 10, 'candidatesTokenCount': 4, 'thoughtsTokenCount': 2},
    'modelVersion': 'gemini-3.8-flash',
  };
}
