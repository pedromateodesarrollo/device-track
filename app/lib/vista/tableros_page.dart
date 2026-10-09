/// Inicio: los tableros. Quien no tiene uno propio ve el «Resumen» de siempre
/// (id 0). Con el asistente encendido se le pide que lo personalice o que arme
/// otros; renombrar, compartir, quitar paneles y borrar se hace aquí mismo,
/// también sin asistente. Como `manager/src/componentes/Tableros.vue`.
library;

import 'dart:async';

import 'package:apk_server_flutter/apk_server_flutter.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../actualizacion.dart';
import '../modelo/tablero.dart';
import '../navegacion.dart';
import '../sesion.dart';
import '../tema.dart';
import 'comun.dart';
import 'panel_tablero.dart';
import 'principal_page.dart' show aLaVista;

class TablerosPage extends StatefulWidget {
  const TablerosPage({super.key});

  @override
  State<TablerosPage> createState() => _TablerosPageState();
}

class _TablerosPageState extends State<TablerosPage> {
  static const _claveElegido = 'tablero';

  List<Tablero> _tableros = const [];
  bool _conIa = false;
  int _elegido = 0;

  /// El elegido, con los datos de cada panel.
  Tablero? _actual;
  String? _error;
  bool _cargando = true;
  Timer? _reloj;

  @override
  void initState() {
    super.initState();
    _arranca();
    // Lo de la portada cambia solo: se refresca cada medio minuto mientras se
    // mira.
    _reloj = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && aLaVista(context, Pestana.inicio)) _cargaDatos();
    });
  }

  @override
  void dispose() {
    _reloj?.cancel();
    super.dispose();
  }

  Future<void> _arranca() async {
    try {
      _elegido = (await SharedPreferences.getInstance()).getInt(_claveElegido) ?? 0;
    } catch (_) {}
    await _carga();
  }

  Tablero? get _elTablero {
    for (final t in _tableros) {
      if (t.id == _elegido) return t;
    }
    return _tableros.isEmpty ? null : _tableros.first;
  }

  Future<void> _carga() async {
    try {
      final r = await sesion.api.get('/v1/tableros');
      final tableros = [
        for (final t in (r['tableros'] as List?) ?? const [])
          if (t is Map) Tablero.deJson(t.cast<String, Object?>()),
      ];
      if (!mounted) return;
      setState(() {
        _tableros = tableros;
        _conIa = r['ia'] == true;
        if (!tableros.any((t) => t.id == _elegido)) _elegido = tableros.isEmpty ? 0 : tableros.first.id;
      });
      await _cargaDatos();
    } catch (e) {
      if (mounted) setState(() => _error = mensajeDe(e));
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _cargaDatos() async {
    final t = _elTablero;
    if (t == null) return;
    try {
      final r = await sesion.api.get('/v1/tableros/${t.id}/datos');
      if (!mounted || _elTablero?.id != t.id) return;
      setState(() {
        _actual = Tablero.deJson(r);
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = mensajeDe(e));
    }
  }

  void _elige(Tablero t) {
    if (t.id == _elegido) return;
    setState(() {
      _elegido = t.id;
      _actual = null;
    });
    SharedPreferences.getInstance().then((p) => p.setInt(_claveElegido, t.id)).ignore();
    _cargaDatos();
  }

  Future<void> _haz(Future<void> Function() accion, {String? listo}) async {
    try {
      await accion();
      if (mounted && listo != null) avisa(context, listo);
    } catch (e) {
      if (mounted) avisa(context, mensajeDe(e), error: true);
    }
  }

  Future<void> _renombra(Tablero t) async {
    final nombre = await showDialog<String>(context: context, builder: (_) => _Renombrar(t.nombre));
    if (nombre == null || nombre.trim().isEmpty || nombre.trim() == t.nombre) return;
    await _haz(() async {
      await sesion.api.patch('/v1/tableros/${t.id}', {'nombre': nombre.trim()});
      await _carga();
    });
  }

  Future<void> _alternaCompartido(Tablero t) => _haz(
    () async {
      await sesion.api.patch('/v1/tableros/${t.id}', {'compartido': !t.compartido});
      await _carga();
    },
    listo: t.compartido
        ? 'Ya no se comparte: solo lo ves tú.'
        : 'Compartido: lo ve toda la organización, cada quien con sus equipos.',
  );

  Future<void> _borra(Tablero t) async {
    final si = await confirma(
      context,
      titulo: 'Borrar «${t.nombre}»',
      texto: t.compartido
          ? 'Se borra con sus paneles, también para quienes lo veían compartido. No se puede deshacer.'
          : 'Se borra con sus paneles. No se puede deshacer.',
      boton: 'Borrar',
      peligro: true,
    );
    if (!si) return;
    await _haz(() async {
      await sesion.api.borra('/v1/tableros/${t.id}');
      setState(() => _actual = null);
      await _carga();
    }, listo: 'Tablero borrado.');
  }

  Future<void> _quitaPanel(Tablero t, Panel p) => _haz(() async {
    await sesion.api.borra('/v1/tableros/${t.id}/paneles/${Uri.encodeComponent(p.id)}');
    await _cargaDatos();
  });

  @override
  Widget build(BuildContext context) {
    final t = _elTablero;
    return Scaffold(
      appBar: AppBar(
        title: Text(t?.nombre ?? 'Inicio'),
        actions: [
          if (t != null && t.propio)
            PopupMenuButton<String>(
              tooltip: 'Más del tablero',
              onSelected: (o) => switch (o) {
                'renombrar' => _renombra(t),
                'compartir' => _alternaCompartido(t),
                'borrar' => _borra(t),
                _ => null,
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'renombrar', child: Text('Renombrar')),
                PopupMenuItem(
                  value: 'compartir',
                  child: Text(t.compartido ? 'Dejar de compartir' : 'Compartir con la organización'),
                ),
                const PopupMenuItem(value: 'borrar', child: Text('Borrar el tablero')),
              ],
            ),
        ],
        bottom: _tableros.length > 1
            ? PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: _Pestanas(tableros: _tableros, elegido: t?.id, alElegir: _elige),
              )
            : null,
      ),
      body: RefreshIndicator(onRefresh: _carga, child: _cuerpo(t)),
    );
  }

  Widget _cuerpo(Tablero? t) {
    if (_cargando) return const Cargando();
    if (t == null) {
      return ListView(children: [VistaError(_error ?? 'No hay tableros.', reintentar: _carga)]);
    }
    final actual = _actual?.id == t.id ? _actual : null;
    final paneles = actual?.paneles ?? const <Panel>[];
    final cifras = [for (final p in paneles) if (p.forma == 'cifra' && p.error == null && p.datos is DatosCifra) p];
    final otros = [for (final p in paneles) if (!cifras.contains(p)) p];
    final quitar = t.propio;
    return LayoutBuilder(
      builder: (context, c) {
        // En el teléfono, un panel por fila; en una tableta, los de medio
        // ancho de a dos.
        final ancho = c.maxWidth - 32;
        final columnasCifras = c.maxWidth >= 700 ? 4 : (c.maxWidth >= 480 ? 3 : 2);
        final dos = c.maxWidth >= 700;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            UpdateTarjeta(actualizacion),
            if (_error != null) Aviso(_error!),
            _cabecera(t),
            if (actual == null)
              const Cargando()
            else ...[
              if (cifras.isNotEmpty)
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final p in cifras)
                      SizedBox(
                        width: (ancho - 10 * (columnasCifras - 1)) / columnasCifras,
                        child: PanelCifra(panel: p, alQuitar: quitar ? () => _quitaPanel(t, p) : null),
                      ),
                  ],
                ),
              if (cifras.isNotEmpty && otros.isNotEmpty) const SizedBox(height: 14),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final p in otros)
                    SizedBox(
                      width: dos && p.ancho == 1 ? (ancho - 12) / 2 : ancho,
                      child: PanelTarjeta(panel: p, alQuitar: quitar ? () => _quitaPanel(t, p) : null),
                    ),
                ],
              ),
              if (paneles.isEmpty)
                Vacio(
                  _conIa
                      ? 'Este tablero está vacío. Pídele al asistente que le agregue paneles.'
                      : 'Este tablero está vacío.',
                  icono: Icons.space_dashboard_outlined,
                ),
            ],
          ],
        );
      },
    );
  }

  /// Lo que se dice arriba de los paneles: de quién es, si se comparte y el
  /// botón del asistente.
  Widget _cabecera(Tablero t) {
    final nota = switch (t) {
      _ when t.propio && t.compartido => 'Lo ve toda la organización, cada quien con sus equipos.',
      _ when !t.propio && !t.esResumen => 'Tablero de ${t.de ?? 'otra persona'}: lo ves con tus equipos, pero solo lo cambia quien lo hizo.',
      _ when t.esResumen && !_conIa && (sesion.yo?.esAdmin ?? false) =>
        'Con el asistente de IA (en el panel web, Organización → Asistente IA) este tablero se puede personalizar y se pueden armar otros.',
      _ => null,
    };
    if (nota == null && !_conIa) return const SizedBox(height: 4);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (nota != null) Text(nota, style: apagado(context, tamano: 13)),
          if (_conIa) ...[
            if (nota != null) const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => navegacion.asistente(t.preguntaAsistente),
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: Text(t.botonAsistente),
            ),
          ],
        ],
      ),
    );
  }
}

/// Una pestaña por tablero. Los de otra persona dicen de quién son.
class _Pestanas extends StatelessWidget {
  const _Pestanas({required this.tableros, required this.elegido, required this.alElegir});
  final List<Tablero> tableros;
  final int? elegido;
  final void Function(Tablero) alElegir;

  @override
  Widget build(BuildContext context) {
    final p = Paleta.de(context);
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          for (final t in tableros)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                selected: t.id == elegido,
                showCheckmark: false,
                selectedColor: p.marcaSuave,
                onSelected: (_) => alElegir(t),
                avatar: t.compartido && t.propio ? const Icon(Icons.group_outlined, size: 16) : null,
                label: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: t.nombre),
                      if (!t.propio && !t.esResumen)
                        TextSpan(text: ' · ${t.de ?? ''}', style: TextStyle(color: p.texto2)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Renombrar extends StatefulWidget {
  const _Renombrar(this.nombre);
  final String nombre;

  @override
  State<_Renombrar> createState() => _RenombrarState();
}

class _RenombrarState extends State<_Renombrar> {
  late final _texto = TextEditingController(text: widget.nombre);

  @override
  void dispose() {
    _texto.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Renombrar el tablero'),
    content: TextField(
      controller: _texto,
      autofocus: true,
      maxLength: 80,
      decoration: const InputDecoration(labelText: 'Nombre'),
      onSubmitted: (v) => Navigator.pop(context, v),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: () => Navigator.pop(context, _texto.text), child: const Text('Guardar')),
    ],
  );
}
