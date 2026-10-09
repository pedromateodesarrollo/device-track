/// Las reglas (`GET /v1/reglas`): qué vigila cada una, a qué equipos, a quién
/// avisa por correo y cuántas alertas tiene abiertas. Quien puede editar la
/// enciende o la apaga aquí (`PATCH {activa}`); crearlas y cambiarlas es en el
/// panel web o pidiéndoselo al asistente.
library;

import 'package:flutter/material.dart';

import '../modelo/equipo.dart' show Json;
import '../modelo/formato.dart';
import '../navegacion.dart';
import '../sesion.dart';
import '../tema.dart';
import 'comun.dart';

class ReglasPage extends StatefulWidget {
  const ReglasPage({super.key});

  @override
  State<ReglasPage> createState() => _ReglasPageState();
}

class _ReglasPageState extends State<ReglasPage> {
  List<Json> _reglas = const [];
  Map<int, String> _zonas = const {};
  final _cambiando = <int>{};
  bool _cargando = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _carga();
  }

  Future<void> _carga() async {
    try {
      final r = await sesion.api.get('/v1/reglas');
      Map<int, String> zonas = const {};
      try {
        final z = await sesion.api.get('/v1/zonas');
        zonas = {
          for (final x in (z['zonas'] as List?) ?? const [])
            if (x is Map) entero(x['id']) ?? 0: '${x['nombre'] ?? ''}',
        };
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _reglas = [for (final x in (r['reglas'] as List?) ?? const []) if (x is Map) x.cast<String, Object?>()];
        _zonas = zonas;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = mensajeDe(e));
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  /// Si esta sesión puede tocar esa regla: con permiso de editar y, si está
  /// limitada a unos dominios, solo las de esos dominios.
  bool _toca(Json r) => sesion.puede('editar') && (sesion.yo?.alcanza(entero(r['dominio'])) ?? false);

  Future<void> _alterna(Json r, bool activa) async {
    final id = entero(r['id']) ?? 0;
    setState(() => _cambiando.add(id));
    try {
      await sesion.api.patch('/v1/reglas/$id', {'activa': activa});
      if (mounted) {
        avisa(context, activa ? 'Regla encendida.' : 'Regla apagada: sus alertas abiertas se cerraron.');
      }
      await _carga();
    } catch (e) {
      if (mounted) avisa(context, mensajeDe(e), error: true);
    } finally {
      if (mounted) setState(() => _cambiando.remove(id));
    }
  }

  String _describe(Json r) {
    final p = r['parametros'] is Map ? (r['parametros'] as Map) : const {};
    switch (r['tipo']) {
      case 'sin_reporte':
        return 'Más de ${_minutos(entero(p['minutos']))} sin contacto';
      case 'bateria_baja':
        return 'Por debajo del ${p['porcentaje']} % sin cargar';
      case 'fuera_de_zona':
        final z = entero(p['zona']);
        return 'Fuera de ${_zonas[z] ?? 'la zona $z'}';
      case 'apagado':
        return 'Cuando avisa que se apaga';
    }
    return '';
  }

  static String _minutos(int? m) {
    if (m == null || m == 0) return '?';
    if (m < 60) return '$m min';
    String uno(double v) => v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(1);
    if (m < 1440) return '${uno(m / 60)} h';
    return '${uno(m / 1440)} días';
  }

  @override
  Widget build(BuildContext context) {
    final p = Paleta.de(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Reglas')),
      body: RefreshIndicator(
        onRefresh: _carga,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Text(
              'Una regla dice qué vigilar, para todos los equipos o solo para los de un dominio; cuando se '
              'cumple abre una alerta, que se cierra sola cuando el equipo se recupera.'
              '${sesion.yo?.acotado ?? false ? ' Las de toda la organización las ves, pero solo las cambia quien ve toda la organización.' : ''}',
              style: apagado(context, tamano: 14),
            ),
            const SizedBox(height: 12),
            if (_error != null) Aviso(_error!),
            if (_cargando)
              const Cargando()
            else if (_reglas.isEmpty)
              const Vacio('Todavía no hay reglas: los equipos reportan, pero nada abre alertas.', icono: Icons.rule)
            else
              for (final r in _reglas) ...[
                _tarjeta(r, p),
                const SizedBox(height: 10),
              ],
            const SizedBox(height: 8),
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Qué hace cada tipo'),
                children: [
                  for (final t in tiposRegla.values)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(t.nombre, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(t.explica),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tarjeta(Json r, Paleta p) {
    final id = entero(r['id']) ?? 0;
    final activa = r['activa'] == true;
    final tipo = nombreTipoRegla(r['tipo']);
    final nombre = texto(r['nombre']) ?? tipo;
    final avisar = [for (final c in (r['avisar'] as List?) ?? const []) '$c'];
    final abiertas = entero(r['abiertas']) ?? 0;
    final toca = _toca(r);
    return Opacity(
      opacity: activa ? 1 : .65,
      child: Tarjeta(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(nombre, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      if (nombre != tipo) Text(tipo, style: apagado(context, tamano: 13)),
                    ],
                  ),
                ),
                if (toca)
                  _cambiando.contains(id)
                      ? const Padding(
                          padding: EdgeInsets.all(14),
                          child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : Switch(value: activa, onChanged: (v) => _alterna(r, v))
                else
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(activa ? 'activa' : 'apagada', style: apagado(context, tamano: 13)),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(_describe(r)),
            Text(
              r['dominio'] != null ? 'Los equipos de ${r['dominio_nombre'] ?? 'su dominio'}' : 'Todos los equipos',
              style: apagado(context, tamano: 13),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.mail_outline, size: 16, color: p.texto2),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    avisar.isEmpty ? 'No avisa por correo.' : 'Avisa por correo a ${avisar.join(', ')}',
                    style: TextStyle(fontSize: 13, color: avisar.isEmpty ? p.texto2 : null),
                  ),
                ),
              ],
            ),
            if (abiertas > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: InkWell(
                  onTap: () => navegacion.ve(Pestana.alertas),
                  child: Pastilla.roja(context, abiertas == 1 ? '1 alerta abierta' : '$abiertas alertas abiertas'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
