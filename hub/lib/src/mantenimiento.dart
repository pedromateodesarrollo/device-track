import 'dart:async';

import 'db.dart';
import 'log.dart';
import 'ordenes.dart';

/// Limpieza periódica: el historial que pasó los días que guarda cada
/// organización y las órdenes que vencieron sin respuesta.
///
/// Corre cada hora y una vez al arrancar. Borra por tandas: un hub que estuvo
/// apagado un mes no se queda minutos bloqueando la tabla de reportes.
class Mantenimiento {
  Mantenimiento(this.bd, this.ordenes);

  final Bd bd;
  final Ordenes ordenes;
  Timer? _reloj;

  void arranca() {
    unawaited(corre());
    _reloj ??= Timer.periodic(const Duration(hours: 1), (_) => unawaited(corre()));
  }

  void detiene() {
    _reloj?.cancel();
    _reloj = null;
  }

  Future<void> corre() async {
    try {
      final vencidas = await ordenes.venceViejas();
      var borrados = 0;
      for (var i = 0; i < 100; i++) {
        final r = await bd.filas(
          '''delete from dt.reporte where id in (
               select r.id from dt.reporte r
                 join dt.equipo e on e.id = r.equipo
                 join dt.org o on o.id = e.org
                where r.t < now() - make_interval(days => o.dias_historial)
                limit 10000)
             returning id''',
        );
        borrados += r.length;
        if (r.length < 10000) break;
      }
      if (vencidas > 0 || borrados > 0) {
        log.info('mantenimiento', '$vencidas órdenes vencidas, $borrados reportes viejos borrados');
      }
    } catch (e) {
      log.aviso('mantenimiento', 'falló: $e');
    }
  }
}
