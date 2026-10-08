/// Cliente de device-track: el protocolo del equipo, sin plataforma encima.
///
/// [HubCliente] da de alta el equipo con un código (`dta_…`), manda reportes y
/// acusa las órdenes; [CanalEquipo] mantiene el WebSocket por donde llegan las
/// órdenes al instante. NO lee nada del equipo ni guarda nada en disco: eso es
/// de la plataforma (en Flutter, el paquete `device_track_flutter`). Sirve
/// tal cual para un servidor o un equipo que no sea Android.
///
/// El contrato completo está en `docs/api.md` del repositorio.
library;

export 'src/canal.dart';
export 'src/errores.dart';
export 'src/hub.dart';
export 'src/modelos.dart';
