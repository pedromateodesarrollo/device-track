import 'dart:convert';
import 'dart:typed_data';

import 'config.dart';
import 'proveedor.dart';

// ═══════════════════════════ La voz del asistente ═══════════════════════════
//
// Toda pregunta al asistente se puede hacer con una nota de voz, y la que se
// hace así se contesta también en voz:
//
//   1. La nota → `POST /v1/ia/voz/transcribir {audio, mime}` → `{texto}`. La
//      pantalla la manda a `/v1/ia/chat` como si se hubiera escrito, con
//      `voz: true` (el modelo contesta como se habla). En dos pasos para que
//      la persona vea lo que se entendió.
//   2. La respuesta → `POST /v1/ia/voz/hablar {texto, parte}` → `{audio,
//      partes}`. El hub pasa el Markdown a lo que se dice ([textoParaVoz]) y lo
//      parte ([partesDeVoz]): la primera parte es una oración, que suena en 2 a
//      4 s; las demás se piden mientras suena la anterior. El mismo texto da
//      siempre el mismo corte: entre una llamada y otra no se guarda nada.
//
// Solo con Gemini ([tieneVoz]): Anthropic no oye ni habla. Con la misma clave
// de la organización, pero con modelos propios y no el de su chat.

/// Lo más que se acepta de una nota, ya decodificada. En base64 tiene que
/// caber en el cuerpo de 2 MB del hub: tres minutos en Opus a 32 kbps son
/// ~0,7 MB, y en AAC a 32 kbps (la app), lo mismo.
const vozMaxBytes = 1400 * 1024;

/// Lo más que se dice de una respuesta; después, «el resto está en la
/// pantalla». Unos cuatro minutos de habla.
const vozMaxCaracteres = 3500;

/// El que oye las notas: el flash sin razonar (~2 s por nota; razonando
/// tardaba el doble y gastaba más).
const modeloOido = 'gemini-3.8-flash';

/// El que lee las respuestas.
const modeloVoz = 'gemini-3.8-flash-tts';

/// La voz. El modelo de voz no acepta instrucción de sistema, y lo que se le
/// diga del tono en el texto lo LEE en voz alta: solo se le manda lo que hay
/// que decir.
const nombreVoz = 'Kore';

/// ¿La organización con [c] tiene voz? Solo Gemini, con el asistente encendido.
bool tieneVoz(ConfigIa? c) => c != null && c.disponible && c.proveedor == 'gemini';

/// Lo que graban el navegador y Android y Gemini oye. El valor es el mime que
/// se le manda.
const _mimesAudio = {
  'audio/webm': 'audio/webm',
  'audio/ogg': 'audio/ogg',
  'audio/mp4': 'audio/mp4',
  'audio/m4a': 'audio/mp4',
  'audio/x-m4a': 'audio/mp4',
  'audio/aac': 'audio/aac',
  'audio/wav': 'audio/wav',
  'audio/x-wav': 'audio/wav',
  'audio/mpeg': 'audio/mp3',
  'audio/mp3': 'audio/mp3',
};

/// [mime] como se le manda al proveedor, sin `;codecs=…`; null si no es un
/// audio que se sepa oír.
String? mimeAudio(String mime) => _mimesAudio[mime.split(';').first.trim().toLowerCase()];

// ═══════════════════════════ Del Markdown a lo que se dice ══════════════════

/// [markdown] (la respuesta como se pinta) convertido en lo que se lee en voz
/// alta: las tablas y el código no se leen («El detalle está en la tabla de la
/// pantalla», una vez), títulos y renglones se vuelven oraciones, sin marcas.
String textoParaVoz(String markdown) {
  final oraciones = <String>[];
  var enCodigo = false;
  var tablaDicha = false;
  var enTabla = false;
  for (final crudo in markdown.split('\n')) {
    final l = crudo.trim();
    if (l.startsWith('```')) {
      enCodigo = !enCodigo;
      continue;
    }
    if (enCodigo) continue;
    if (l.startsWith('|')) {
      if (!enTabla && !tablaDicha) {
        oraciones.add('El detalle está en la tabla de la pantalla.');
        tablaDicha = true;
      }
      enTabla = true;
      continue;
    }
    enTabla = false;
    if (l.isEmpty || RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(l)) continue;
    var t = l
        .replaceFirst(RegExp(r'^#{1,6}\s+'), '')
        .replaceFirst(RegExp(r'^>\s?'), '')
        .replaceFirst(RegExp(r'^([-*+]|\d{1,3}[.)])\s+'), '');
    t = t
        .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!)
        .replaceAll(RegExp(r'\*\*|__|`'), '')
        .replaceAllMapped(RegExp(r'(^|[\s(])[*_]([^*_]+)[*_](?=[\s).,;:!?]|$)'), (m) => '${m[1]}${m[2]}')
        .trim();
    if (t.isEmpty) continue;
    if (!RegExp(r'[.!?…:;,]$').hasMatch(t)) t = '$t.';
    oraciones.add(t);
  }
  return oraciones.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// [texto] (ya pasado por [textoParaVoz]) en los trozos que se piden uno a
/// uno. La primera parte es la primera oración (si pasa de [primera], hasta
/// una coma): la voz tarda en generarse casi lo que dura, y una oración corta
/// empieza a oírse enseguida. Las demás juntan oraciones hasta [resto]. Lo que
/// pase de [maximo] no se dice.
List<String> partesDeVoz(String texto, {int primera = 110, int resto = 550, int maximo = vozMaxCaracteres}) {
  final limpio = texto.trim();
  if (limpio.isEmpty) return const [];

  final oraciones = <String>[];
  for (final o in limpio.split(RegExp(r'(?<=[.!?…;:])\s+'))) {
    var t = o.trim();
    // Una primera oración larga tardaría en sonar: se corta en una coma. Por
    // un espacio no: la voz cerraría la frase a media idea.
    if (oraciones.isEmpty && t.length > primera) {
      final coma = t.lastIndexOf(', ', primera);
      if (coma >= primera ~/ 3) {
        oraciones.add(t.substring(0, coma + 1));
        t = t.substring(coma + 2).trim();
      }
    }
    oraciones.addAll(_trocear(t, resto));
  }

  final partes = <String>[];
  final actual = StringBuffer();
  var dicho = 0;
  var cortado = false;
  for (final o in oraciones) {
    if (o.isEmpty) continue;
    if (dicho + o.length > maximo && partes.isNotEmpty) {
      cortado = true;
      break;
    }
    final tope = partes.isEmpty ? primera : resto;
    if (actual.isNotEmpty && actual.length + 1 + o.length > tope) {
      partes.add(actual.toString());
      actual.clear();
    }
    if (actual.isNotEmpty) actual.write(' ');
    actual.write(o);
    dicho += o.length + 1;
    // La primera se cierra en cuanto tiene una oración: que empiece a sonar.
    if (partes.isEmpty) {
      partes.add(actual.toString());
      actual.clear();
    }
  }
  if (actual.isNotEmpty) partes.add(actual.toString());
  if (cortado) partes.add('El resto está en la pantalla.');
  return partes;
}

List<String> _trocear(String o, int max) {
  final out = <String>[];
  var s = o;
  while (s.length > max) {
    var corte = s.lastIndexOf(', ', max);
    if (corte < max ~/ 2) corte = s.lastIndexOf(' ', max);
    if (corte <= 0) corte = max;
    out.add(s.substring(0, corte + (s[corte] == ',' ? 1 : 0)).trim());
    s = s.substring(corte + 1).trim();
  }
  if (s.isNotEmpty) out.add(s);
  return out;
}

/// [bytes] como WAV. Los modelos de voz nuevos ya devuelven WAV; los de la
/// serie 2.5 devolvían PCM crudo (`audio/L16;codec=pcm;rate=24000`), que ni el
/// navegador ni Android tocan sin cabecera.
Uint8List comoWav(Uint8List bytes, String mime) {
  final esRiff = bytes.length >= 12 &&
      String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WAVE';
  if (esRiff) return bytes;
  final tasa = int.tryParse(RegExp(r'rate=(\d+)').firstMatch(mime)?.group(1) ?? '') ?? 24000;
  final cab = ByteData(44);
  void ascii(int en, String s) {
    for (var i = 0; i < s.length; i++) {
      cab.setUint8(en + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  cab.setUint32(4, 36 + bytes.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  cab.setUint32(16, 16, Endian.little);
  cab.setUint16(20, 1, Endian.little); // PCM
  cab.setUint16(22, 1, Endian.little); // mono
  cab.setUint32(24, tasa, Endian.little);
  cab.setUint32(28, tasa * 2, Endian.little);
  cab.setUint16(32, 2, Endian.little);
  cab.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  cab.setUint32(40, bytes.length, Endian.little);
  return Uint8List.fromList([...cab.buffer.asUint8List(), ...bytes]);
}

// ═══════════════════════════ Gemini ═════════════════════════════════════════

/// Oír y hablar con la cuenta de Gemini de la organización.
class VozGemini {
  VozGemini(ConfigIa c, {Uri? base})
    : _g = IaGemini(
        c.modelo,
        c.clave,
        base ?? Uri.parse('https://generativelanguage.googleapis.com'),
        const Duration(seconds: 90),
      );

  final IaGemini _g;

  /// Lo que dice la nota [audio] ([mime] ya pasado por [mimeAudio]).
  Future<({String texto, IaUso uso})> transcribir(Uint8List audio, String mime) async {
    final r = await _g.postJson(
      _g.base.resolve('/v1beta/models/$modeloOido:generateContent'),
      {'x-goog-api-key': _g.clave},
      cuerpoTranscribir(audio, mime),
    );
    final v = IaGemini.leeRespuesta(r, modeloOido);
    var dicho = v.texto;
    try {
      final j = jsonDecode(v.texto);
      if (j is Map) dicho = '${j['texto'] ?? ''}';
    } on FormatException {
      // Si no vino el JSON pedido, el texto es la transcripción.
    }
    return (texto: dicho.trim(), uso: v.uso);
  }

  /// [texto] dicho en voz: un WAV.
  Future<({Uint8List wav, IaUso uso})> hablar(String texto) async {
    var uso = const IaUso();
    // A veces termina sin audio: se repite una vez antes de rendirse.
    for (var intento = 1; intento <= 2; intento++) {
      final r = await _g.postJson(
        _g.base.resolve('/v1beta/models/$modeloVoz:generateContent'),
        {'x-goog-api-key': _g.clave},
        cuerpoHablar(texto),
      );
      final u = (r['usageMetadata'] as Map?) ?? const {};
      uso += IaUso(entrada: _n(u['promptTokenCount']), salida: _n(u['candidatesTokenCount']));
      final candidatos = (r['candidates'] as List?) ?? const [];
      final c = candidatos.isNotEmpty && candidatos.first is Map ? candidatos.first as Map : const {};
      final partes = (c['content'] as Map?)?['parts'];
      if (partes is List) {
        for (final p in partes) {
          final d = p is Map ? p['inlineData'] : null;
          if (d is Map && d['data'] is String) {
            return (wav: comoWav(base64Decode(d['data'] as String), '${d['mimeType'] ?? ''}'), uso: uso);
          }
        }
      }
    }
    throw IaError('ia_respuesta_rara', 'La voz no trajo audio');
  }

  /// El cuerpo para oír una nota. Público para las pruebas.
  static Map<String, Object?> cuerpoTranscribir(Uint8List audio, String mime) => {
    'systemInstruction': {
      'parts': [
        {
          'text': 'Transcribe esta nota de voz en español, palabra por palabra, como texto escrito: '
              'con puntuación, mayúsculas y los números en cifras. Es una pregunta o un pedido para '
              'el asistente de device-track, que lleva el seguimiento de teléfonos y terminales Android '
              '(se oyen términos como equipo, terminal, dominio, batería, alerta, regla, zona, tablero, '
              'Zebra, TC56). No la contestes, no la resumas ni le agregues nada. Si no se oye nada que '
              'se entienda, devuelve el texto vacío.',
        },
      ],
    },
    'contents': [
      {
        'role': 'user',
        'parts': [
          {
            'inlineData': {'mimeType': mime, 'data': base64Encode(audio)},
          },
        ],
      },
    ],
    'generationConfig': {
      'temperature': 0,
      'maxOutputTokens': 4096,
      'thinkingConfig': {'thinkingBudget': 0},
      'responseMimeType': 'application/json',
      'responseSchema': {
        'type': 'OBJECT',
        'properties': {
          'texto': {'type': 'STRING'},
        },
        'required': ['texto'],
      },
    },
  };

  /// El cuerpo para decir [texto]: solo el texto. Público para las pruebas.
  static Map<String, Object?> cuerpoHablar(String texto) => {
    'contents': [
      {
        'role': 'user',
        'parts': [
          {'text': texto},
        ],
      },
    ],
    'generationConfig': {
      'responseModalities': ['AUDIO'],
      'speechConfig': {
        'voiceConfig': {
          'prebuiltVoiceConfig': {'voiceName': nombreVoz},
        },
      },
    },
  };
}

int _n(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

/// Lo que se le añade a la pregunta cuando llegó por voz. Va en la pregunta y
/// no en la instrucción: la instrucción sigue igual y el proveedor la cachea.
const avisoDeVoz =
    '[Esta pregunta llegó por nota de voz y la persona va a OÍR tu respuesta (también la ve en '
    'pantalla). En esta respuesta: contesta como se habla, empezando con una o dos oraciones que '
    'respondan lo que preguntó; cantidades redondeadas como se dicen, salvo que pida el número exacto; '
    'sin tablas ni listas largas (si hace falta un listado, di primero lo principal y pon la tabla al '
    'final: no se lee en voz alta, la verá en pantalla). Es una transcripción: puede traer mal un '
    'nombre, una etiqueta o un número; si algo no cuadra con lo que encuentras, dilo o pregunta antes '
    'de suponer.]';
