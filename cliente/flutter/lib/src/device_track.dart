import 'dart:async';
import 'dart:convert';

import 'package:device_track/device_track.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'nativo.dart';

/// Lo que hace la app con una orden que el plugin no atiende solo (hoy,
/// `mensaje`: `{titulo, texto}`). Devuelve `true` si la atendió; `false` la
/// contesta `fallida` con `no_soportada`.
typedef AlOrden = Future<bool> Function(Orden orden);

/// Lo que una pantalla «Acerca de» o de soporte puede enseñar.
@immutable
class EstadoDeviceTrack {
  const EstadoDeviceTrack({
    this.dadoDeAlta = false,
    this.equipoId,
    this.equipoNombre = '',
    this.conectado = false,
    this.ultimoReporte,
    this.ultimoError,
    this.pendientes = 0,
    this.sonando = false,
    this.config = ConfigEquipo.porDefecto,
  });

  /// Tiene una credencial que el hub aceptó (o que todavía no rechazó).
  final bool dadoDeAlta;

  /// El equipo en el hub (el número que se ve en el panel).
  final int? equipoId;
  final String equipoNombre;

  /// El WebSocket está abierto: el panel lo ve conectado y las órdenes llegan
  /// al instante.
  final bool conectado;

  /// El último reporte que llegó al hub.
  final DateTime? ultimoReporte;

  /// Null si lo último salió bien. Si no: `sin_red`, `credencial` (el hub
  /// rechazó la credencial), `sin_codigo`, `sin_plugin` (no es Android) o el
  /// código que devolvió el hub (`codigo_invalido`, `codigo_vencido`,
  /// `codigo_agotado`, `codigo_anulado`…).
  final String? ultimoError;

  /// Reportes guardados sin red, esperando al siguiente.
  final int pendientes;

  /// Está sonando por una orden del panel: es el momento de enseñar un botón
  /// que llame [DeviceTrack.detenerSonar].
  final bool sonando;

  /// La configuración vigente de la organización.
  final ConfigEquipo config;

  EstadoDeviceTrack _con({
    bool? dadoDeAlta,
    Object? equipoId = _igual,
    String? equipoNombre,
    bool? conectado,
    Object? ultimoReporte = _igual,
    Object? ultimoError = _igual,
    int? pendientes,
    bool? sonando,
    ConfigEquipo? config,
  }) =>
      EstadoDeviceTrack(
        dadoDeAlta: dadoDeAlta ?? this.dadoDeAlta,
        equipoId: identical(equipoId, _igual) ? this.equipoId : equipoId as int?,
        equipoNombre: equipoNombre ?? this.equipoNombre,
        conectado: conectado ?? this.conectado,
        ultimoReporte: identical(ultimoReporte, _igual) ? this.ultimoReporte : ultimoReporte as DateTime?,
        ultimoError: identical(ultimoError, _igual) ? this.ultimoError : ultimoError as String?,
        pendientes: pendientes ?? this.pendientes,
        sonando: sonando ?? this.sonando,
        config: config ?? this.config,
      );

  @override
  bool operator ==(Object other) =>
      other is EstadoDeviceTrack &&
      other.dadoDeAlta == dadoDeAlta &&
      other.equipoId == equipoId &&
      other.equipoNombre == equipoNombre &&
      other.conectado == conectado &&
      other.ultimoReporte == ultimoReporte &&
      other.ultimoError == ultimoError &&
      other.pendientes == pendientes &&
      other.sonando == sonando &&
      other.config == config;

  @override
  int get hashCode => Object.hash(
      dadoDeAlta, equipoId, equipoNombre, conectado, ultimoReporte, ultimoError, pendientes, sonando, config);

  @override
  String toString() => 'EstadoDeviceTrack(${dadoDeAlta ? 'equipo $equipoId' : 'sin alta'}'
      '${conectado ? ', conectado' : ''}${ultimoError == null ? '' : ', error $ultimoError'})';
}

const _igual = Object();

/// device-track dentro de una app Flutter: el equipo se da de alta solo, reporta
/// mientras la app está abierta y atiende las órdenes del panel.
///
/// ```dart
/// final equipos = DeviceTrack(
///   servidor: 'https://devicetrack.chalonasoft.com',
///   codigo: 'dta_…', // código de alta compilado en la app
///   contexto: () => {'empresa': sesion.empresa, 'usuario': sesion.usuario, 'sesion': true},
///   alOrden: (orden) async => mostrarAviso(orden.texto('titulo'), orden.texto('texto')),
/// );
/// equipos.iniciar();
/// ```
///
/// Qué hace solo:
///  - **Alta.** La primera vez (o si el hub rechaza la credencial, o si la
///    copia de seguridad la trajo de otro teléfono) se da de alta con
///    [codigo] como fuente `app` con el `applicationId` de la app, y guarda la
///    credencial en el almacenamiento privado de la app.
///  - **Reportes.** Al [iniciar], cada `intervalo_s` del hub mientras la app
///    está al frente, y al volver al frente si pasaron [frenoAlFrente]. Los
///    que no salen (sin red, hub caído) se guardan y van en el siguiente,
///    cada uno con su hora. La lista de apps va solo cuando cambió.
///  - **WebSocket.** Abierto mientras la app está al frente (el panel la ve
///    conectada y las órdenes llegan al instante); se cierra al pasar a
///    segundo plano. Sin él, las órdenes llegan en el siguiente reporte.
///  - **Órdenes.** `sonar` lo hace el plugin; `reportar` manda un reporte ya;
///    `mensaje` va a [alOrden]; las demás se contestan `fallida` con
///    `no_soportada`. Una orden repetida no se repite: se vuelve a acusar.
///
/// Nunca lanza ni tumba la app: lo que falla queda en [estado]
/// (`ultimoError`). Fuera de Android no hace nada (`sin_plugin`).
class DeviceTrack with WidgetsBindingObserver {
  DeviceTrack({
    required String servidor,
    required this.codigo,
    this.contexto,
    this.alOrden,
    this.nombre,
    this.frenoAlFrente = const Duration(minutes: 2),
    this.plazoUbicacion = const Duration(seconds: 20),
    this.nativo = const EquipoNativo(),
  }) : servidor = servidor.trim().replaceAll(RegExp(r'/+$'), '');

  /// `https://devicetrack.chalonasoft.com`
  final String servidor;

  /// El código de alta (`dta_…`) de la organización. Solo se usa para darse de
  /// alta: con la credencial guardada, la app no lo vuelve a mandar. Un APK es
  /// público, así que el código lleva tope de usos y vencimiento.
  final String codigo;

  /// Lo que la app quiera contar en cada reporte: la empresa, quién tiene la
  /// sesión, el almacén. Se llama en cada reporte. Hasta 4 KB; más grande, el
  /// hub lo ignora.
  final Map<String, Object?> Function()? contexto;

  /// Quien atiende `mensaje`. Sin él, `mensaje` se contesta `no_soportada`.
  final AlOrden? alOrden;

  /// Nombre sugerido para el equipo si es nuevo en el hub. Sin él, el hub
  /// pone el modelo y el final de la huella.
  final String? nombre;

  /// Al volver al frente se reporta solo si el último intento fue hace más
  /// de esto: entrar y salir de la app diez veces no son diez reportes.
  final Duration frenoAlFrente;

  /// Cuánto se espera la ubicación en cada reporte.
  final Duration plazoUbicacion;

  /// El lado Android. Se cambia solo en las pruebas.
  final EquipoNativo nativo;

  /// Para pintar: dado de alta, conectado, último reporte, último error.
  final estado = ValueNotifier<EstadoDeviceTrack>(const EstadoDeviceTrack());

  late final HubCliente _hub = HubCliente(servidor: servidor);
  CanalEquipo? _canal;
  final _subs = <StreamSubscription<Object?>>[];
  Timer? _proximo;
  ConfigEquipo _config = ConfigEquipo.porDefecto;
  String _firmaApps = '';
  String _huella = '';
  DatosEquipo _datos = const DatosEquipo();
  Fuente? _fuente;

  Future<void>? _iniciando;
  bool _listo = false;
  bool _activo = false;
  bool _alFrente = true;
  bool _observando = false;
  bool _desechado = false;
  DateTime? _ultimoIntento;

  /// Los reportes van de a uno.
  Future<void> _turno = Future.value();
  Future<bool>? _altaEnCurso;

  /// Las órdenes atendidas en este proceso (el plugin las recuerda también
  /// entre arranques) y las que se están atendiendo ahora.
  final _atendidas = <int>{}; // en orden de llegada: se suelta la más vieja
  final _enCurso = <int>{};

  /// Arranca: lee lo guardado, se da de alta si hace falta, reporta y abre el
  /// WebSocket. Idempotente. No hace falta esperarlo, y no lanza.
  Future<void> iniciar() => _iniciando ??= _iniciar();

  Future<void> _iniciar() async {
    final binding = WidgetsFlutterBinding.ensureInitialized();
    _activo = true;
    final ciclo = binding.lifecycleState;
    _alFrente = ciclo == null || ciclo == AppLifecycleState.resumed || ciclo == AppLifecycleState.inactive;
    binding.addObserver(this);
    _observando = true;
    try {
      final eq = await nativo.equipo();
      _huella = eq.huella;
      final d = eq.datos;
      _datos = DatosEquipo(
        modelo: d.modelo,
        fabricante: d.fabricante,
        android: d.android,
        serie: d.serie,
        nombre: nombre ?? d.nombre,
      );
      _fuente = await nativo.fuente();
      if (_cargar(await nativo.almacen())) {
        // Los reportes guardados tampoco son de este equipo en este hub.
        try {
          await nativo.colaVaciar();
        } catch (_) {}
      }
      _listo = true;
    } on MissingPluginException {
      // No es Android (o el plugin no se registró): no hay equipo que leer.
      _actualiza(ultimoError: 'sin_plugin');
      return;
    } catch (e) {
      _actualiza(ultimoError: 'plugin: $e');
      return;
    }
    // Con credencial, el WebSocket ya: el reporte puede tardar esperando la
    // ubicación. Sin ella, lo abre el alta.
    _conectarWs();
    await reportar(motivo: MotivoReporte.abrir);
  }

  /// Lo que quedó guardado del arranque anterior. Devuelve `true` si había una
  /// credencial que no es de este teléfono o de este hub.
  bool _cargar(Map<String, Object?> g) {
    final hub = (g['hub'] ?? '').toString().replaceAll(RegExp(r'/+$'), '');
    final credencial = (g['credencial'] ?? '').toString();
    final huellaAlta = (g['huella_alta'] ?? '').toString();
    // Otro hub (la app cambió de servidor) u otro teléfono (una copia de
    // seguridad restaurada trajo estas preferencias): esa credencial no es de
    // este equipo en este hub, y con ella reportaría como otro.
    final vale = credencial.isNotEmpty && hub == servidor && (huellaAlta.isEmpty || huellaAlta == _huella);
    _hub.credencial = vale ? credencial : null;
    _config = ConfigEquipo.desdeJson(g);
    _firmaApps = vale ? (g['firma_apps'] ?? '').toString() : '';
    final t = g['ultimo_reporte_t'];
    final id = g['equipo_id'];
    final pendientes = g['pendientes'];
    _actualiza(
      dadoDeAlta: vale,
      equipoId: vale && id is int && id > 0 ? id : null,
      equipoNombre: vale ? (g['equipo_nombre'] ?? '').toString() : '',
      ultimoReporte: vale && t is int && t > 0 ? DateTime.fromMillisecondsSinceEpoch(t) : null,
      pendientes: vale && pendientes is int ? pendientes : 0,
      config: _config,
    );
    return credencial.isNotEmpty && !vale;
  }

  /// Manda un reporte ya (un botón «Reportar» en la pantalla de soporte).
  /// Devuelve `true` si llegó al hub. No lanza.
  Future<bool> reportar({MotivoReporte motivo = MotivoReporte.manual}) {
    final hecho = Completer<bool>();
    _turno = _turno.then((_) async {
      var ok = false;
      try {
        ok = await _reportar(motivo);
      } catch (e) {
        _actualiza(ultimoError: '$e');
      }
      hecho.complete(ok);
    });
    return hecho.future;
  }

  Future<bool> _reportar(MotivoReporte motivo) async {
    if (!_listo || !_activo) return false;
    _ultimoIntento = DateTime.now();
    // La próxima primero: si este falla, la cadena sigue.
    _programarSiguiente();
    if (!_hub.dadoDeAlta && !await _darDeAlta()) return false;

    final leido = await _leer(motivo);
    for (var intento = 0;; intento++) {
      final credencial = _hub.credencial;
      final (cuerpo, firma) = await _armar(leido);
      try {
        final r = await _hub.reporte(cuerpo);
        await _alSalir(firma);
        final config = r.config;
        if (config != null) await _aplicarConfig(config);
        for (final o in r.ordenes) {
          unawaited(_atender(o));
        }
        return true;
      } on ErrorHub catch (e) {
        if (e.noAutorizado) {
          // La credencial ya no vale: otra alta desde esta app la reemplazó o
          // borraron el equipo. Con el código, otra vez, y se reenvía.
          _actualiza(dadoDeAlta: false, ultimoError: 'credencial');
          if (intento == 0 && await _volverADarDeAlta(credencial)) continue;
        } else {
          _actualiza(ultimoError: e.codigo);
        }
        // Un 400 no se arregla reintentando; un 429, un 5xx o una credencial
        // que se recupera después, sí.
        if (e.reintentable || e.noAutorizado) await _encolar(leido);
        return false;
      } on SinRespuesta {
        await _encolar(leido);
        _actualiza(ultimoError: 'sin_red');
        return false;
      }
    }
  }

  /// Lo que se lee del equipo: estado y, si la organización la pide y la app
  /// tiene el permiso, la ubicación. Es lo que se guarda si no sale.
  Future<Reporte> _leer(MotivoReporte motivo) async {
    var r = Reporte(motivo: motivo);
    try {
      r = await nativo.estado(motivo: motivo);
    } catch (_) {}
    if (_config.ubicacion) {
      try {
        final u = await nativo.ubicacion(plazo: plazoUbicacion);
        if (u != null) r = r.con(ubicacion: u);
      } catch (_) {}
    }
    return r.paraCola;
  }

  /// El reporte entero: lo leído, los atrasados, las apps si cambiaron, el
  /// contexto y la versión de la app. Devuelve también la firma de las apps
  /// que se mandan, para guardarla si el hub las recibe.
  Future<(Reporte, String?)> _armar(Reporte leido) async {
    List<AppInstalada>? apps;
    String? firma;
    try {
      final f = await nativo.firma();
      if (f.isNotEmpty && f != _firmaApps) {
        apps = await nativo.apps();
        firma = f;
      }
    } catch (_) {}
    var atrasados = const <Reporte>[];
    try {
      atrasados = await nativo.colaPendientes();
    } catch (_) {}
    final cuerpo = leido.con(
      atrasados: atrasados,
      apps: apps,
      contexto: _contexto(),
      fuente: _fuente,
      android: _datos.android,
    );
    return (cuerpo, firma);
  }

  /// El contexto de la app, si se puede mandar. Un callback que lanza o que
  /// devuelve algo que no es JSON no tumba el reporte: va sin contexto.
  Map<String, Object?>? _contexto() {
    final f = contexto;
    if (f == null) return null;
    try {
      final m = f();
      jsonEncode(m);
      return m;
    } catch (e) {
      debugPrint('device_track: el contexto no se pudo mandar: $e');
      return null;
    }
  }

  Future<void> _alSalir(String? firma) async {
    final ahora = DateTime.now();
    try {
      await nativo.colaVaciar();
      await nativo.guardar({
        'ultimo_reporte_t': ahora.millisecondsSinceEpoch,
        if (firma != null) 'firma_apps': firma,
      });
    } catch (_) {}
    if (firma != null) _firmaApps = firma;
    _actualiza(dadoDeAlta: true, ultimoReporte: ahora, ultimoError: null, pendientes: 0);
  }

  Future<void> _encolar(Reporte leido) async {
    try {
      _actualiza(pendientes: await nativo.colaAgregar(leido));
    } catch (_) {}
  }

  /// Una sola alta a la vez: el reporte y el WebSocket pueden enterarse del
  /// 401 al mismo tiempo, y cada alta gasta un uso del código.
  Future<bool> _darDeAlta() => _altaEnCurso ??= _alta().whenComplete(() => _altaEnCurso = null);

  /// [rechazada] es la credencial que el hub no aceptó. Si mientras tanto otro
  /// camino ya la cambió, no hace falta otra alta (que además revocaría la
  /// nueva).
  Future<bool> _volverADarDeAlta(String? rechazada) async {
    if (_hub.dadoDeAlta && _hub.credencial != rechazada) return true;
    return _darDeAlta();
  }

  Future<bool> _alta() async {
    final codigo = this.codigo.trim();
    final fuente = _fuente;
    if (codigo.isEmpty) {
      _actualiza(ultimoError: 'sin_codigo');
      return false;
    }
    if (_huella.isEmpty || fuente == null) {
      _actualiza(ultimoError: 'sin_huella');
      return false;
    }
    try {
      final a = await _hub.alta(codigo: codigo, huella: _huella, fuente: fuente, equipo: _datos);
      // Equipo nuevo (o fuente nueva): la primera lista de apps va siempre.
      _firmaApps = '';
      _config = a.config;
      try {
        await nativo.guardar({
          'hub': servidor,
          'credencial': a.credencial,
          'equipo_id': a.equipoId,
          'equipo_nombre': a.equipoNombre,
          'firma_apps': '',
          'huella_alta': _huella,
          ...a.config.toJson(),
        });
      } catch (_) {
        // Sin guardar, la próxima vez que se abra se da de alta otra vez.
      }
      _actualiza(
        dadoDeAlta: true,
        equipoId: a.equipoId,
        equipoNombre: a.equipoNombre,
        config: a.config,
        ultimoError: null,
      );
      _conectarWs();
      return true;
    } on ErrorHub catch (e) {
      _actualiza(ultimoError: e.codigo);
      return false;
    } on SinRespuesta {
      _actualiza(ultimoError: 'sin_red');
      return false;
    }
  }

  Future<void> _aplicarConfig(ConfigEquipo c) async {
    final cambio = c.intervaloS != _config.intervaloS;
    _config = c;
    _actualiza(config: c);
    if (cambio) _programarSiguiente();
    try {
      await nativo.guardar(c.toJson());
    } catch (_) {}
  }

  /// El próximo reporte periódico: [ConfigEquipo.intervalo] después del último
  /// intento. Solo con la app al frente.
  void _programarSiguiente() {
    _proximo?.cancel();
    _proximo = null;
    if (!_listo || !_activo || !_alFrente) return;
    final desde = _ultimoIntento ?? DateTime.now();
    var espera = _config.intervalo - DateTime.now().difference(desde);
    if (espera.isNegative) espera = Duration.zero;
    _proximo = Timer(espera, () => unawaited(reportar(motivo: MotivoReporte.periodico)));
  }

  // ── WebSocket ──────────────────────────────────────────────────────────

  void _conectarWs() {
    if (!_listo || !_activo || !_alFrente || !_hub.dadoDeAlta) return;
    (_canal ??= _nuevoCanal()).conectar();
  }

  CanalEquipo _nuevoCanal() {
    final c = CanalEquipo(_hub);
    _subs.addAll([
      c.ordenes.listen((o) => unawaited(_atender(o))),
      c.configs.listen((cfg) => unawaited(_aplicarConfig(cfg))),
      c.estado.listen((v) => _actualiza(conectado: v)),
      c.credencialRechazada.listen((cred) => unawaited(_rechazadaPorWs(cred))),
    ]);
    return c;
  }

  Future<void> _rechazadaPorWs(String credencial) async {
    try {
      if (_hub.credencial == credencial) _actualiza(dadoDeAlta: false, ultimoError: 'credencial');
      if (await _volverADarDeAlta(credencial)) _conectarWs();
    } catch (_) {}
  }

  // ── Ciclo de la app ────────────────────────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _alVolverAlFrente();
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _alIrAlFondo();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
  }

  void _alVolverAlFrente() {
    if (_alFrente) return;
    _alFrente = true;
    if (!_listo || !_activo) return;
    _conectarWs();
    _canal?.reconectarAhora();
    final u = _ultimoIntento;
    if (u == null || DateTime.now().difference(u) >= frenoAlFrente) {
      unawaited(reportar(motivo: MotivoReporte.abrir));
    } else {
      _programarSiguiente();
    }
  }

  void _alIrAlFondo() {
    if (!_alFrente) return;
    _alFrente = false;
    _proximo?.cancel();
    _proximo = null;
    final c = _canal;
    if (c != null) unawaited(c.cerrar());
  }

  // ── Órdenes ────────────────────────────────────────────────────────────

  Future<void> _atender(Orden o) async {
    if (_enCurso.contains(o.id)) {
      // Sigue en curso (un «sonar» de 30 s) y el hub la repitió porque no le
      // llegó el «recibida»: se le dice otra vez, sin empezarla de nuevo.
      await _acuse(o.id, EstadoOrden.recibida);
      return;
    }
    _enCurso.add(o.id);
    try {
      if (await _yaAtendida(o.id)) {
        // Ya se hizo, pero el hub no se enteró (el acuse se perdió sin red):
        // se le vuelve a decir, sin repetirla.
        await _acuse(o.id, EstadoOrden.hecha, 'ya atendida');
        return;
      }
      await _acuse(o.id, EstadoOrden.recibida);
      final (resultado, detalle) = await _hacer(o);
      await _acuse(o.id, resultado, detalle);
    } catch (e) {
      debugPrint('device_track: la orden ${o.id} falló: $e');
    } finally {
      _enCurso.remove(o.id);
    }
  }

  Future<(EstadoOrden, String)> _hacer(Orden o) async {
    switch (o.tipo) {
      case 'sonar':
        final segundos = (o.entero('segundos') ?? 30).clamp(5, 300);
        _actualiza(sonando: true);
        try {
          final r = await nativo.sonar(segundos);
          return (EstadoOrden.hecha, r.tocado ? 'la tocaron a los ${r.segundos} s' : 'sonó ${r.segundos} s');
        } on MissingPluginException {
          return (EstadoOrden.fallida, 'no_soportada');
        } on PlatformException catch (e) {
          return (EstadoOrden.fallida, 'error: ${e.message}');
        } finally {
          _actualiza(sonando: false);
        }
      case 'reportar':
        if (await reportar(motivo: MotivoReporte.orden)) return (EstadoOrden.hecha, '');
        return (EstadoOrden.fallida, estado.value.ultimoError ?? 'sin_reporte');
      case 'mensaje':
        final f = alOrden;
        if (f == null) return (EstadoOrden.fallida, 'no_soportada');
        try {
          return await f(o) ? (EstadoOrden.hecha, 'mostrado') : (EstadoOrden.fallida, 'no_soportada');
        } catch (e) {
          return (EstadoOrden.fallida, 'error: $e');
        }
      default:
        return (EstadoOrden.fallida, 'no_soportada');
    }
  }

  Future<bool> _yaAtendida(int id) async {
    if (!_atendidas.add(id)) return true;
    if (_atendidas.length > 200) _atendidas.remove(_atendidas.first);
    try {
      return await nativo.yaAtendida(id);
    } catch (_) {
      return false;
    }
  }

  Future<void> _acuse(int id, EstadoOrden e, [String detalle = '']) async {
    try {
      await _hub.estadoOrden(id, e, detalle: detalle);
    } catch (_) {
      // Sin red: el hub la vuelve a mandar en el próximo reporte y ahí se
      // acusa, sin repetirla.
    }
  }

  /// Para el sonido de una orden `sonar` (el botón «Ya lo encontré»). El hub
  /// queda con «la tocaron a los N s».
  Future<void> detenerSonar() async {
    try {
      await nativo.detenerSonar();
    } catch (_) {}
  }

  // ── Fin ────────────────────────────────────────────────────────────────

  /// Deja de reportar y cierra el WebSocket (al cerrar sesión, por ejemplo).
  /// La credencial queda guardada; [iniciar] lo vuelve a arrancar.
  Future<void> detener() async {
    _activo = false;
    _iniciando = null;
    if (_observando) {
      WidgetsBinding.instance.removeObserver(this);
      _observando = false;
    }
    _proximo?.cancel();
    _proximo = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    final c = _canal;
    _canal = null;
    await c?.dispose();
    _actualiza(conectado: false);
  }

  Future<void> dispose() async {
    await detener();
    _desechado = true;
    _hub.cerrar();
    estado.dispose();
  }

  void _actualiza({
    bool? dadoDeAlta,
    Object? equipoId = _igual,
    String? equipoNombre,
    bool? conectado,
    Object? ultimoReporte = _igual,
    Object? ultimoError = _igual,
    int? pendientes,
    bool? sonando,
    ConfigEquipo? config,
  }) {
    if (_desechado) return;
    estado.value = estado.value._con(
      dadoDeAlta: dadoDeAlta,
      equipoId: equipoId,
      equipoNombre: equipoNombre,
      conectado: conectado,
      ultimoReporte: ultimoReporte,
      ultimoError: ultimoError,
      pendientes: pendientes,
      sonando: sonando,
      config: config,
    );
  }
}
