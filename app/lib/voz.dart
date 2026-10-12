/// La voz del asistente en el teléfono, como `voz.js` en el panel web: grabar
/// una nota, que el hub la escriba, y leer las respuestas en voz alta.
///
/// El hub oye y habla (`hub/lib/src/ia/voz.dart`):
///   POST /v1/ia/voz/transcribir {audio, mime} → {texto}
///   POST /v1/ia/voz/hablar {texto, parte}     → {audio (WAV en base64), partes}
/// Grabar y tocar lo hace Android (`Voz.kt`, canal `device_track_panel/voz`).
/// Solo se ofrece si `/v1/yo` dice `ia_voz`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api/cliente.dart';

const _canal = MethodChannel('device_track_panel/voz');

/// Lo más que dura una nota: a los 3 minutos se manda sola.
const maxSegundosNota = 180;

class NotaDeVoz {
  const NotaDeVoz(this.audio, this.mime, this.segundos);
  final Uint8List audio;
  final String mime;
  final int segundos;
}

/// Algo salió mal con el micrófono o el altavoz; [mensaje] es para la persona.
class VozError implements Exception {
  const VozError(this.mensaje);
  final String mensaje;

  @override
  String toString() => mensaje;
}

/// `75` → `1:15`.
String duracion(int segundos) => '${segundos ~/ 60}:${(segundos % 60).toString().padLeft(2, '0')}';

/// Pide el micrófono (la primera vez, Android pregunta) y empieza a grabar.
Future<void> empiezaNota() async {
  try {
    if (await _canal.invokeMethod<bool>('permiso') != true) {
      throw const VozError(
        'La app no tiene permiso para usar el micrófono. Actívalo en Ajustes → Apps → device-track panel → Permisos.',
      );
    }
    final error = await _canal.invokeMethod<String>('grabar');
    if (error != null) throw VozError(error);
  } on MissingPluginException {
    throw const VozError('Este teléfono no puede grabar notas de voz.');
  } on PlatformException catch (e) {
    throw VozError(e.message ?? 'No se pudo usar el micrófono.');
  }
}

/// La nota grabada, o null si no quedó nada (se soltó enseguida).
Future<NotaDeVoz?> terminaNota() async {
  try {
    final m = await _canal.invokeMapMethod<String, Object?>('terminar');
    final audio = m?['audio'];
    if (audio is! Uint8List || audio.isEmpty) return null;
    return NotaDeVoz(audio, '${m!['mime'] ?? 'audio/mp4'}', (m['segundos'] as num?)?.toInt() ?? 1);
  } on MissingPluginException {
    return null;
  }
}

Future<void> cancelaNota() async {
  try {
    await _canal.invokeMethod<bool>('cancelar');
  } on MissingPluginException {
    // Fuera de Android no hay nada que cancelar.
  }
}

/// Lo que dice [nota]. Lanza [HubError] si no se entendió.
Future<String> transcribe(HubCliente api, NotaDeVoz nota) async {
  final r = await api.post('/v1/ia/voz/transcribir', {'audio': base64Encode(nota.audio), 'mime': nota.mime});
  return '${r['texto'] ?? ''}'.trim();
}

/// Lee respuestas en voz alta, una a la vez.
///
/// [decir] pide la primera parte, la toca y, mientras suena, pide la siguiente
/// (una por delante: cada parte cuesta). [sonando] es la clave de lo que suena
/// (o se prepara) y [cargando], si se espera la primera parte. [callar] corta
/// todo.
class Locutor extends ChangeNotifier {
  Locutor(this.api);

  final HubCliente api;

  Object? sonando;
  bool cargando = false;
  String? error;
  int _turno = 0;

  Future<Json> _parte(String texto, int i) {
    final f = api.post('/v1/ia/voz/hablar', {'texto': texto, 'parte': i});
    // Si se calla antes de que llegue, nadie la espera.
    f.ignore();
    return f;
  }

  Future<void> callar() async {
    _turno++;
    final habia = sonando != null;
    sonando = null;
    cargando = false;
    if (habia) notifyListeners();
    try {
      await _canal.invokeMethod<bool>('callar');
    } on MissingPluginException {
      // Fuera de Android no suena nada.
    }
  }

  Future<void> decir(Object clave, String texto) async {
    await callar();
    final mio = _turno;
    sonando = clave;
    cargando = true;
    error = null;
    notifyListeners();
    try {
      Future<Json>? siguiente = _parte(texto, 0);
      for (var i = 0; siguiente != null; i++) {
        final p = await siguiente;
        if (mio != _turno) return;
        final hay = i + 1 < ((p['partes'] as num?)?.toInt() ?? 0);
        siguiente = hay ? _parte(texto, i + 1) : null;
        if (cargando) {
          cargando = false;
          notifyListeners();
        }
        final entera = await _canal.invokeMethod<bool>('tocar', {'wav': base64Decode('${p['audio'] ?? ''}')});
        if (mio != _turno || entera != true) break;
      }
    } on HubError catch (e) {
      if (mio == _turno) error = e.mensaje;
    } on MissingPluginException {
      if (mio == _turno) error = 'Este teléfono no puede leer en voz alta.';
    } on PlatformException catch (e) {
      if (mio == _turno) error = e.message ?? 'No se pudo leer en voz alta.';
    } finally {
      if (mio == _turno) {
        sonando = null;
        cargando = false;
        notifyListeners();
      }
    }
  }
}
