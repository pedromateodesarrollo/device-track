/// Las alertas: las abiertas, o todas (`GET /v1/alertas?todas=1`), cada una
/// con lo que pasa en una línea. Quien puede editar las cierra con una nota.
/// Como `Alertas.vue`.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../modelo/equipo.dart' show Json;
import '../modelo/formato.dart';
import '../navegacion.dart';
import '../sesion.dart';
import '../tema.dart';
import 'comun.dart';
import 'principal_page.dart' show aLaVista;

class AlertasPage extends StatefulWidget {
  const AlertasPage({super.key, this.alCambiar});

  /// Cuando se cierra una: el número rojo de la pestaña cambia.
  final VoidCallback? alCambiar;

  @override
  State<AlertasPage> createState() => _AlertasPageState();
}

class _AlertasPageState extends State<AlertasPage> {
  List<Json> _alertas = const [];
  bool _todas = false;
  bool _variosDominios = false;
  bool _cargando = true;
  String? _error;
  Timer? _reloj;

  @override
  void initState() {
    super.initState();
    _carga();
    sesion.api.get('/v1/dominios').then((r) {
      if (mounted) setState(() => _variosDominios = ((r['dominios'] as List?)?.length ?? 0) > 1);
    }).catchError((_) {});
    navegacion.pestana.addListener(_alVolver);
    _reloj = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && aLaVista(context, Pestana.alertas)) _carga();
    });
  }

  @override
  void dispose() {
    navegacion.pestana.removeListener(_alVolver);
    _reloj?.cancel();
    super.dispose();
  }

  void _alVolver() {
    if (navegacion.pestana.value == Pestana.alertas) _carga();
  }

  Future<void> _carga() async {
    try {
      final r = await sesion.api.get('/v1/alertas', consulta: {if (_todas) 'todas': '1'});
      if (!mounted) return;
      setState(() {
        _alertas = [
          for (final a in (r['alertas'] as List?) ?? const [])
            if (a is Map) a.cast<String, Object?>(),
        ];
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = mensajeDe(e));
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _cierra(Json a) async {
    final nota = await showDialog<String>(context: context, builder: (_) => _DialogoCerrar(a));
    if (nota == null) return;
    try {
      await sesion.api.post('/v1/alertas/${a['id']}/cerrar', {'nota': nota});
      if (!mounted) return;
      avisa(context, 'Alerta cerrada.');
      widget.alCambiar?.call();
      await _carga();
    } catch (e) {
      if (mounted) avisa(context, mensajeDe(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Alertas')),
      body: RefreshIndicator(
        onRefresh: _carga,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Abiertas')),
                ButtonSegment(value: true, label: Text('También las cerradas')),
              ],
              selected: {_todas},
              showSelectedIcon: false,
              onSelectionChanged: (s) {
                setState(() {
                  _todas = s.first;
                  _cargando = true;
                });
                _carga();
              },
            ),
            const SizedBox(height: 12),
            if (_error != null) Aviso(_error!),
            if (_cargando)
              const Cargando()
            else if (_alertas.isEmpty)
              Vacio(
                _todas
                    ? 'Todavía no ha habido ninguna alerta.'
                    : 'Ninguna alerta abierta. Las reglas que vigilan a los equipos están en Más → Reglas.',
                icono: Icons.notifications_none,
              )
            else
              for (final a in _alertas)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _TarjetaAlerta(
                    alerta: a,
                    conDominio: _variosDominios,
                    alCerrar: a['cerrada'] == null && sesion.puede('editar') ? () => _cierra(a) : null,
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _TarjetaAlerta extends StatelessWidget {
  const _TarjetaAlerta({required this.alerta, this.conDominio = false, this.alCerrar});
  final Json alerta;
  final bool conDominio;
  final VoidCallback? alCerrar;

  @override
  Widget build(BuildContext context) {
    final a = alerta;
    final p = Paleta.de(context);
    final cerrada = a['cerrada'] != null;
    final tipo = nombreTipoRegla(a['tipo']);
    final regla = texto(a['regla_nombre']) ?? tipo;
    final debajo = [?texto(a['etiqueta']), if (conDominio) ?texto(a['dominio_nombre'])];
    final equipo = entero(a['equipo']);
    return Opacity(
      opacity: cerrada ? .7 : 1,
      child: Tarjeta(
        borde: cerrada ? p.grisMapa : p.mal,
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        alTocar: equipo == null ? null : () => navegacion.abreEquipo(equipo),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${a['equipo_nombre'] ?? 'Equipo $equipo'}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  if (debajo.isNotEmpty) Text(debajo.join(' · '), style: apagado(context, tamano: 13)),
                  const SizedBox(height: 4),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: regla, style: const TextStyle(fontWeight: FontWeight.w600)),
                        if (regla != tipo) TextSpan(text: ' · $tipo', style: apagado(context)),
                      ],
                    ),
                  ),
                  if (detalleAlerta(a).isNotEmpty) Text(detalleAlerta(a)),
                  const SizedBox(height: 4),
                  Text(
                    'Desde ${fecha(a['abierta'])} (${hace(a['abierta'])})',
                    style: apagado(context, tamano: 13),
                  ),
                  if (cerrada)
                    Text(
                      'Cerrada ${fecha(a['cerrada'])}${texto(a['nota']) != null ? ' · «${a['nota']}»' : ''}',
                      style: apagado(context, tamano: 13),
                    ),
                ],
              ),
            ),
            if (alCerrar != null) TextButton(onPressed: alCerrar, child: const Text('Cerrar')),
          ],
        ),
      ),
    );
  }
}

class _DialogoCerrar extends StatefulWidget {
  const _DialogoCerrar(this.alerta);
  final Json alerta;

  @override
  State<_DialogoCerrar> createState() => _DialogoCerrarState();
}

class _DialogoCerrarState extends State<_DialogoCerrar> {
  final _nota = TextEditingController();

  @override
  void dispose() {
    _nota.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Cerrar la alerta de ${widget.alerta['equipo_nombre'] ?? 'este equipo'}'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _nota,
          maxLength: 500,
          minLines: 1,
          maxLines: 4,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Nota',
            hintText: 'Lo encontramos, se le cambió la batería…',
          ),
        ),
        Text(
          'Cerrar no apaga la regla: si lo que la abrió sigue pasando, se vuelve a abrir en el próximo reporte.',
          style: apagado(context, tamano: 13),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: () => Navigator.pop(context, _nota.text.trim()), child: const Text('Cerrar la alerta')),
    ],
  );
}
