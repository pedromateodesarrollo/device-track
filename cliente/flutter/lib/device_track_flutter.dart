/// device-track en una app Flutter: el equipo se da de alta solo, reporta
/// mientras la app está abierta y atiende las órdenes del panel.
///
/// [DeviceTrack] es lo que una app mete en `main`. [EquipoNativo] es el lado
/// Android (canal `device_track`), por si una pantalla quiere leer la batería
/// o la red por su cuenta. Los modelos (`Orden`, `ConfigEquipo`, `Reporte`…)
/// vienen del paquete `device_track`, el protocolo en Dart puro.
library;

export 'package:device_track/device_track.dart'
    show
        AppInstalada,
        Almacenamiento,
        ConfigEquipo,
        DatosEquipo,
        ErrorHub,
        EstadoOrden,
        Fuente,
        MotivoReporte,
        Orden,
        Red,
        Reporte,
        SinRespuesta,
        TipoFuente,
        Ubicacion;
export 'src/device_track.dart';
export 'src/nativo.dart';
