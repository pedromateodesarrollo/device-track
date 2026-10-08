import 'package:device_track/device_track.dart';
import 'package:flutter/services.dart';

/// Lo que el equipo dice de sí en el alta: su huella (el `ANDROID_ID`) y lo
/// demás.
typedef EquipoLeido = ({String huella, DatosEquipo datos});

/// Cómo terminó un «sonar»: si alguien lo paró y cuántos segundos sonó.
typedef SonarTerminado = ({bool tocado, int segundos});

/// El lado Android del plugin (canal `device_track`, `DeviceTrackPlugin.kt`):
/// lee el equipo con el mismo código que el agente, hace sonar y guarda la
/// credencial y la cola en el almacenamiento privado de la app.
///
/// [DeviceTrack] lo usa por dentro; una app lo puede usar sola para enseñar la
/// batería o la red en una pantalla. Fuera de Android cada llamada lanza
/// [MissingPluginException].
class EquipoNativo {
  const EquipoNativo([this.canal = const MethodChannel('device_track')]);

  final MethodChannel canal;

  /// Huella (`ANDROID_ID`), modelo, fabricante, Android y serie (si el equipo
  /// la da: las Zebra).
  Future<EquipoLeido> equipo() async {
    final m = await _mapa('equipo');
    return (huella: m['huella']?.toString() ?? '', datos: DatosEquipo.desdeJson(m));
  }

  /// `applicationId`, `versionName` y `versionCode` de la app.
  Future<Fuente> fuente() async => Fuente.desdeJson(await _mapa('fuente'), tipo: TipoFuente.app);

  /// Batería, si está cargando, la red y el espacio libre, como un [Reporte]
  /// con la hora de ahora y [motivo].
  Future<Reporte> estado({MotivoReporte motivo = MotivoReporte.periodico}) async {
    final m = await _mapa('estado');
    return Reporte.desdeJson({
      ...m,
      't': DateTime.now().toUtc().toIso8601String(),
      'motivo': motivo.name,
    });
  }

  /// Una posición recién leída (GPS y red a la vez, gana la mejor antes de
  /// [plazo]). Null si la app no tiene el permiso de ubicación —el plugin no lo
  /// pide— o si no llegó ninguna.
  Future<Ubicacion?> ubicacion({Duration plazo = const Duration(seconds: 20)}) async {
    final m = await canal.invokeMapMethod<String, Object?>('ubicacion', {'plazo_ms': plazo.inMilliseconds});
    return m == null ? null : Ubicacion.desdeJson(m);
  }

  /// Si la app tiene permiso de ubicación (fino o aproximado).
  Future<bool> permisoUbicacion() async => await canal.invokeMethod<bool>('permisoUbicacion') ?? false;

  /// Las apps instaladas por alguien (y las del sistema que se actualizaron).
  Future<List<AppInstalada>> apps() async {
    final l = await canal.invokeListMethod<Object?>('apps') ?? const [];
    return [for (final a in l) if (AppInstalada.desdeJson(a) case final x?) x];
  }

  /// La huella de la lista de apps: cambia cuando se instala, se quita o se
  /// actualiza una.
  Future<String> firma() async => await canal.invokeMethod<String>('firma') ?? '';

  /// Suena a todo volumen en el canal de alarmas (pasa el silencio y el «no
  /// molestar») y vibra, hasta [detenerSonar] o hasta que pasen [segundos]
  /// (de 5 a 300). Termina cuando termina el sonido.
  Future<SonarTerminado> sonar(int segundos) async {
    final m = await canal.invokeMapMethod<String, Object?>('sonar', {'segundos': segundos}) ?? const {};
    final s = m['segundos'];
    return (tocado: m['tocado'] == true, segundos: s is num ? s.toInt() : 0);
  }

  /// Para el sonido: el que estaba esperando en [sonar] termina con `tocado`.
  Future<void> detenerSonar() => canal.invokeMethod<void>('detenerSonar');

  Future<bool> sonando() async => await canal.invokeMethod<bool>('sonando') ?? false;

  /// Lo guardado: `hub`, `credencial`, `equipo_id`, `equipo_nombre`,
  /// `intervalo_s`, `ubicacion`, `firma_apps`, `huella_alta`,
  /// `ultimo_reporte_t` (ms) y `pendientes` (reportes en la cola).
  Future<Map<String, Object?>> almacen() => _mapa('almacen');

  /// Guarda las claves de [almacen] que vengan en [valores]; las demás no
  /// cambian.
  Future<void> guardar(Map<String, Object?> valores) => canal.invokeMethod<void>('guardar', valores);

  /// Borra la credencial, lo guardado y la cola.
  Future<void> olvidar() => canal.invokeMethod<void>('olvidar');

  /// Guarda un reporte que no salió. Devuelve cuántos hay (tope de 500: se
  /// quedan los más nuevos).
  Future<int> colaAgregar(Reporte r) async =>
      await canal.invokeMethod<int>('colaAgregar', {'reporte': r.toJson()}) ?? 0;

  /// Los guardados, sin sacarlos.
  Future<List<Reporte>> colaPendientes() async {
    final l = await canal.invokeListMethod<Object?>('colaPendientes') ?? const [];
    return [for (final r in l) Reporte.desdeJson(r)];
  }

  Future<void> colaVaciar() => canal.invokeMethod<void>('colaVaciar');

  /// Si la orden [id] ya se atendió. Si no, la anota: la siguiente vez dirá
  /// que sí. Recuerda las últimas 100, también después de cerrar la app.
  Future<bool> yaAtendida(int id) async => await canal.invokeMethod<bool>('yaAtendida', {'id': id}) ?? false;

  Future<Map<String, Object?>> _mapa(String metodo) async =>
      await canal.invokeMapMethod<String, Object?>(metodo) ?? const {};
}
