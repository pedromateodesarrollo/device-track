/// Las pestañas de abajo: Inicio (los tableros), Equipos, Alertas, el
/// Asistente (si la organización lo tiene) y Más. Cada pestaña se arma la
/// primera vez que se abre y conserva lo que tenía al cambiar a otra: una
/// pregunta al asistente sigue llegando aunque se mire la lista de equipos.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../actualizacion.dart';
import '../modelo/formato.dart';
import '../navegacion.dart';
import '../sesion.dart';
import 'alertas_page.dart';
import 'asistente_page.dart';
import 'equipos_page.dart';
import 'mas_page.dart';
import 'tableros_page.dart';

/// Si la pantalla de la pestaña [p] es la que la persona tiene delante: su
/// pestaña elegida, nada encima y la app al frente. Lo usan las que se
/// refrescan solas, para no gastar datos con el teléfono en el bolsillo.
bool aLaVista(BuildContext context, Pestana p) =>
    navegacion.pestana.value == p &&
    (ModalRoute.of(context)?.isCurrent ?? true) &&
    (WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed) == AppLifecycleState.resumed;

class PrincipalPage extends StatefulWidget {
  const PrincipalPage({super.key});

  @override
  State<PrincipalPage> createState() => _PrincipalPageState();
}

class _PrincipalPageState extends State<PrincipalPage> with WidgetsBindingObserver {
  /// Las pestañas que ya se abrieron (las demás no se arman todavía).
  final _abiertas = <Pestana>{Pestana.inicio};

  /// Las alertas abiertas, para el número rojo de la pestaña.
  int _alertas = 0;
  Timer? _reloj;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    navegacion.pestana.value = Pestana.inicio;
    navegacion.pestana.addListener(_alCambiar);
    sesion.addListener(_alCambiarSesion);
    _cuentaAlertas();
    _reloj = Timer.periodic(const Duration(minutes: 1), (_) => _cuentaAlertas());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    navegacion.pestana.removeListener(_alCambiar);
    sesion.removeListener(_alCambiarSesion);
    _reloj?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState estado) {
    if (estado != AppLifecycleState.resumed) return;
    // El teléfono pudo pasar horas dormido: la versión, el rol y las
    // alertas pudieron cambiar.
    unawaited(actualizacion.alVolverAlFrente());
    unawaited(sesion.refrescaYo());
    _cuentaAlertas();
  }

  void _alCambiar() {
    if (!mounted) return;
    setState(() => _abiertas.add(navegacion.pestana.value));
    if (navegacion.pestana.value == Pestana.alertas) _cuentaAlertas();
  }

  void _alCambiarSesion() {
    if (mounted) setState(() {});
  }

  Future<void> _cuentaAlertas() async {
    if (WidgetsBinding.instance.lifecycleState case final e? when e != AppLifecycleState.resumed) return;
    try {
      final r = await sesion.api.get('/v1/resumen');
      if (mounted) setState(() => _alertas = entero(r['alertas']) ?? 0);
    } catch (_) {
      // Sin red: se queda el número de antes.
    }
  }

  List<Pestana> get _pestanas => [
    Pestana.inicio,
    Pestana.equipos,
    Pestana.alertas,
    if (sesion.yo?.ia ?? false) Pestana.asistente,
    Pestana.mas,
  ];

  Widget _pagina(Pestana p) => switch (p) {
    Pestana.inicio => const TablerosPage(),
    Pestana.equipos => const EquiposPage(),
    Pestana.alertas => AlertasPage(alCambiar: _cuentaAlertas),
    Pestana.asistente => const AsistentePage(),
    Pestana.mas => const MasPage(),
  };

  NavigationDestination _destino(Pestana p) => switch (p) {
    Pestana.inicio => const NavigationDestination(
      icon: Icon(Icons.space_dashboard_outlined),
      selectedIcon: Icon(Icons.space_dashboard),
      label: 'Inicio',
    ),
    Pestana.equipos => const NavigationDestination(
      icon: Icon(Icons.smartphone_outlined),
      selectedIcon: Icon(Icons.smartphone),
      label: 'Equipos',
    ),
    Pestana.alertas => NavigationDestination(
      icon: Badge(
        isLabelVisible: _alertas > 0,
        label: Text('$_alertas'),
        child: const Icon(Icons.notifications_outlined),
      ),
      selectedIcon: Badge(
        isLabelVisible: _alertas > 0,
        label: Text('$_alertas'),
        child: const Icon(Icons.notifications),
      ),
      label: 'Alertas',
    ),
    Pestana.asistente => const NavigationDestination(
      icon: Icon(Icons.auto_awesome_outlined),
      selectedIcon: Icon(Icons.auto_awesome),
      label: 'Asistente',
    ),
    Pestana.mas => const NavigationDestination(icon: Icon(Icons.menu), label: 'Más'),
  };

  @override
  Widget build(BuildContext context) {
    final pestanas = _pestanas;
    var actual = navegacion.pestana.value;
    // El asistente se apagó mientras se miraba: a Inicio.
    if (!pestanas.contains(actual)) actual = Pestana.inicio;
    return Scaffold(
      body: IndexedStack(
        index: pestanas.indexOf(actual),
        children: [
          for (final p in pestanas)
            _abiertas.contains(p) ? KeyedSubtree(key: ValueKey(p), child: _pagina(p)) : const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: pestanas.indexOf(actual),
        onDestinationSelected: (i) => navegacion.pestana.value = pestanas[i],
        destinations: [for (final p in pestanas) _destino(p)],
      ),
    );
  }
}
