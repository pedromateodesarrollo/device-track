/// El panel de device-track en el teléfono: tableros, equipos, alertas, el
/// asistente de IA y lo básico de la administración, contra cualquier hub.
///
/// Es una app nativa: habla con el mismo API que el panel web
/// (`docs/api.md`) y dibuja sus propias pantallas.
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'actualizacion.dart';
import 'navegacion.dart';
import 'sesion.dart';
import 'tema.dart';
import 'vista/comun.dart';
import 'vista/entrada_page.dart';
import 'vista/principal_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  actualizacionArrancar();
  // Al salir o vencerse la sesión, nada se queda encima de la entrada (la
  // ficha de un equipo, una hoja abierta).
  sesion.addListener(() {
    if (sesion.estado == EstadoSesion.fuera) navegacion.llave.currentState?.popUntil((r) => r.isFirst);
  });
  sesion.arranca();
  runApp(const PanelApp());
}

class PanelApp extends StatelessWidget {
  const PanelApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'device-track',
    debugShowCheckedModeBanner: false,
    navigatorKey: navegacion.llave,
    theme: tema(Brightness.light),
    darkTheme: tema(Brightness.dark),
    locale: const Locale('es'),
    supportedLocales: const [Locale('es')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: const Raiz(),
  );
}

/// Cambia de pantalla con la sesión: entrada, cargando o el panel.
class Raiz extends StatelessWidget {
  const Raiz({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: sesion,
    builder: (context, _) => switch (sesion.estado) {
      EstadoSesion.arrancando || EstadoSesion.cargando => const Scaffold(body: Cargando()),
      EstadoSesion.fuera => const EntradaPage(),
      EstadoSesion.sinRespuesta => Scaffold(
        body: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              VistaError(sesion.aviso ?? 'No se pudo hablar con el hub.', reintentar: sesion.cargaYo),
              TextButton(onPressed: sesion.sale, child: const Text('Salir y entrar con otra cuenta')),
            ],
          ),
        ),
      ),
      EstadoSesion.dentro => PrincipalPage(key: ValueKey('${sesion.hub}#${sesion.yo?.id}')),
    },
  );
}
