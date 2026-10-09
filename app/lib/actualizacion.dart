/// La app se actualiza sola con apk-server: pregunta al abrir, cada hora y
/// cuando el hub avisa por su WebSocket; baja la versión nueva en segundo
/// plano y avisa con una notificación. El hub y el slug (`devicetrack-panel`)
/// salen del manifiesto (`android/app/build.gradle.kts`).
///
/// No instala sola (`autoInstalar: false`): instalar cierra la app, y a mitad
/// de una pregunta al asistente o de mandar una orden no puede pasar. La
/// tarjeta de Inicio y la de Mi cuenta dicen que hay una lista y la instalan
/// con un toque.
library;

import 'dart:async';

import 'package:apk_server_flutter/apk_server_flutter.dart';

import 'sesion.dart';

late final UpdateService actualizacion;

/// Lo que este teléfono cuenta de sí al preguntar por versiones: quién tiene
/// la sesión y de qué organización. Lo ve quien administra apk-server.
Map<String, Object?> _contexto() {
  final yo = sesion.yo;
  if (yo == null) return const {'sesion': false};
  return {'usuario': yo.nombre, 'organizacion': yo.organizacion, 'hub': sesion.hub, 'sesion': true};
}

void actualizacionArrancar() {
  actualizacion = UpdateService(contexto: _contexto);
  unawaited(actualizacion.iniciar());
}
