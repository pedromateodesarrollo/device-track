/// Lo poco que se le pide a Android por el canal propio de la app
/// (`MainActivity.kt`): la versión instalada, abrir una ubicación o un enlace
/// y compartir un texto. Fuera de Android (las pruebas) no hace nada.
library;

import 'package:flutter/services.dart';

const _canal = MethodChannel('device_track_panel/sistema');

class VersionApp {
  const VersionApp(this.version, this.build);
  final String version;
  final int build;

  @override
  String toString() => '$version ($build)';
}

Future<VersionApp?> versionApp() async {
  try {
    final m = await _canal.invokeMapMethod<String, Object?>('version');
    if (m == null) return null;
    return VersionApp('${m['version'] ?? ''}', (m['build'] as num?)?.toInt() ?? 0);
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

/// `geo:` o `https:`. `false` si ninguna app lo abrió.
Future<bool> abrir(String url) async {
  try {
    return await _canal.invokeMethod<bool>('abrir', {'url': url}) ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// Abre la ubicación en la app de mapas del teléfono; si no hay ninguna, en
/// OpenStreetMap en el navegador.
Future<bool> abrirEnElMapa(double lat, double lng, {String nombre = ''}) async {
  final etiqueta = nombre.isEmpty ? '' : '(${Uri.encodeComponent(nombre)})';
  if (await abrir('geo:$lat,$lng?q=$lat,$lng$etiqueta')) return true;
  return abrir('https://www.openstreetmap.org/?mlat=$lat&mlon=$lng#map=17/$lat/$lng');
}

Future<void> compartir(String texto, {String? asunto, String titulo = 'Compartir'}) async {
  try {
    await _canal.invokeMethod<bool>('compartir', {'texto': texto, 'asunto': ?asunto, 'titulo': titulo});
  } on MissingPluginException {
    // Fuera de Android no hay con qué.
  } on PlatformException {
    // Idem.
  }
}
