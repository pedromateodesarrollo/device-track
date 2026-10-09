/// A dónde se va desde cualquier parte: la cifra de un tablero lleva a la
/// lista filtrada, la fila de una tabla abre un equipo, el asistente escribe
/// enlaces del panel web (`#/panel/equipos?estado=perdido`) y el botón
/// «Personalizar con el asistente» abre el chat con la pregunta empezada.
///
/// Es una sola para toda la app ([navegacion]): las pestañas y las pantallas
/// la escuchan.
library;

import 'package:flutter/material.dart';

import 'modelo/equipo.dart';
import 'modelo/tablero.dart';
import 'sistema.dart';
import 'vista/equipo_page.dart';

final navegacion = Navegacion();

enum Pestana { inicio, equipos, alertas, asistente, mas }

class Navegacion {
  final llave = GlobalKey<NavigatorState>();

  /// La pestaña de abajo que está a la vista.
  final pestana = ValueNotifier<Pestana>(Pestana.inicio);

  /// Los filtros de la lista de equipos. Viven aquí y no en la pantalla: un
  /// enlace los cambia, y al volver de un equipo la lista sigue como estaba.
  final filtrosEquipos = ValueNotifier<FiltrosEquipos>(const FiltrosEquipos());

  /// Lo que hay que dejar escrito en el asistente al abrirlo. La pantalla lo
  /// toma y lo vuelve a poner en null.
  final preguntaAsistente = ValueNotifier<String?>(null);

  void ve(Pestana p) {
    _alPrincipio();
    pestana.value = p;
  }

  /// La lista de equipos con esos filtros.
  void equipos(FiltrosEquipos f) {
    filtrosEquipos.value = f;
    ve(Pestana.equipos);
  }

  void abreEquipo(int id) {
    llave.currentState?.push(MaterialPageRoute(builder: (_) => EquipoPage(id: id)));
  }

  void asistente(String pregunta) {
    preguntaAsistente.value = pregunta;
    ve(Pestana.asistente);
  }

  /// Un enlace del panel lleva a su pantalla; uno de la web se abre en el
  /// navegador. Devuelve `false` si no supo qué hacer con él.
  Future<bool> enlace(String url) async {
    final d = destinoDeEnlace(url);
    switch (d) {
      case DestinoEquipos(:final filtros):
        equipos(filtros);
        return true;
      case DestinoEquipo(:final id):
        abreEquipo(id);
        return true;
      case DestinoAlertas():
        ve(Pestana.alertas);
        return true;
      case null:
        final u = Uri.tryParse(url);
        if (u != null && (u.isScheme('https') || u.isScheme('http'))) return abrir(url);
        return false;
    }
  }

  /// Cierra lo que esté encima de las pestañas (la ficha de un equipo, una
  /// pantalla de Más).
  void _alPrincipio() => llave.currentState?.popUntil((r) => r.isFirst);
}
