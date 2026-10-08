/// device-track — hub.
///
/// Junta las piezas: base de datos, REST, el WebSocket de los equipos, las
/// alertas, la limpieza y el panel web. Un solo proceso; el que se
/// auto-hospeda no tiene que orquestar nada.
library;

import 'dart:io';

import 'src/alertas.dart';
import 'src/config.dart';
import 'src/db.dart';
import 'src/http/rutas_auth.dart';
import 'src/http/rutas_dispositivo.dart';
import 'src/http/rutas_dominios.dart';
import 'src/http/rutas_llaves.dart';
import 'src/http/rutas_panel.dart';
import 'src/http/servidor.dart';
import 'src/log.dart';
import 'src/mantenimiento.dart';
import 'src/ordenes.dart';
import 'src/ws/canal.dart';

export 'src/config.dart';
export 'src/db.dart';
export 'src/log.dart';

class Hub {
  Hub._(this.config, this.bd, this._servidor, this._http, this.alertas, this._mantenimiento);

  final Config config;
  final Bd bd;
  final Servidor _servidor;
  final HttpServer _http;
  final Alertas alertas;
  final Mantenimiento _mantenimiento;

  int get puerto => _http.port;
  Servidor get servidor => _servidor;

  static Future<Hub> arranca(
    Config config, {
    String migraciones = 'migraciones',
    bool relojes = true,
  }) async {
    final bd = await Bd.abrir(config.urlBd);
    await bd.migrar(migraciones);

    final canal = Canal(bd);
    final ordenes = Ordenes(bd, canal);
    final alertas = Alertas(bd);
    final mantenimiento = Mantenimiento(bd, ordenes);
    // Al conectar: lo que tenía esperando y, como hubo contacto, fuera la
    // alerta de «sin reporte».
    canal.alConectar = (e, ws) async {
      await ordenes.entregaPendientes(e.equipo, tipo: e.tipo);
      await alertas.alContacto(e.equipo);
    };

    final servidor = Servidor(config, bd);
    servidor.upgrades.add(canal.upgrade);
    registraRutasAuth(servidor);
    registraRutasLlaves(servidor);
    registraRutasDominios(servidor);
    registraRutasDispositivo(servidor, ordenes, alertas);
    registraRutasPanel(servidor, canal, ordenes, alertas);

    // Al arrancar no hay ningún socket: lo que diga la base es de antes del
    // reinicio. Se limpia para no enseñar equipos fantasma como conectados.
    await bd.ejecuta('update dt.equipo set conectado = false where conectado');

    if (relojes) {
      alertas.arranca();
      mantenimiento.arranca();
    }

    final http = await servidor.escuchar();
    log.info('hub', 'escuchando en ${config.host}:${http.port}');
    if (config.secretoEfimero) {
      log.aviso(
        'hub',
        'DT_SECRETO_JWT no está definida: se generó una al vuelo, '
        'así que un reinicio cierra la sesión de todos. Fíjala en producción.',
      );
    }
    return Hub._(config, bd, servidor, http, alertas, mantenimiento);
  }

  Future<void> detiene() async {
    alertas.detiene();
    _mantenimiento.detiene();
    await _http.close(force: true);
    await bd.cerrar();
  }
}
