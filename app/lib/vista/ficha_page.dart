/// Editar la ficha de un equipo: lo que escribe quien lo administra (nombre,
/// etiqueta, serie, dominio, a quién está asignado, estado y notas). Se manda
/// solo lo que cambió (`PATCH /v1/equipos/:id`). Permiso `editar`.
library;

import 'package:flutter/material.dart';

import '../modelo/equipo.dart' show Json;
import '../modelo/formato.dart';
import '../modelo/yo.dart' show Dominio;
import '../sesion.dart';
import 'comun.dart';

class FichaPage extends StatefulWidget {
  const FichaPage({super.key, required this.equipo});
  final Json equipo;

  @override
  State<FichaPage> createState() => _FichaPageState();
}

class _FichaPageState extends State<FichaPage> {
  static const _textos = ['nombre', 'etiqueta', 'serie', 'asignado_a', 'notas'];

  late final _c = {for (final k in _textos) k: TextEditingController(text: '${widget.equipo[k] ?? ''}')};
  late String _estado = '${widget.equipo['estado'] ?? 'activo'}';
  late int? _dominio = entero(widget.equipo['dominio']);
  List<Dominio> _dominios = const [];
  final _forma = GlobalKey<FormState>();
  bool _guardando = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    sesion.api.get('/v1/dominios').then((r) {
      if (!mounted) return;
      setState(() {
        _dominios = [
          for (final d in (r['dominios'] as List?) ?? const [])
            if (d is Map) Dominio.deJson(d.cast<String, Object?>()),
        ];
      });
    }).catchError((_) {});
    for (final c in _c.values) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// A dónde se puede mover: los dominios que alcanza la sesión; el suyo, siempre.
  List<Dominio> get _opcionesDominio {
    final l = [..._dominios];
    final actual = entero(widget.equipo['dominio']);
    if (actual != null && !l.any((d) => d.id == actual)) {
      l.insert(0, Dominio(id: actual, nombre: '${widget.equipo['dominio_nombre'] ?? actual}'));
    }
    return l;
  }

  Map<String, Object?> get _cambios {
    final e = widget.equipo;
    return {
      for (final k in _textos)
        if (_c[k]!.text.trim() != '${e[k] ?? ''}'.trim()) k: _c[k]!.text.trim(),
      if (_estado != e['estado']) 'estado': _estado,
      if (_dominio != null && _dominio != entero(e['dominio'])) 'dominio': _dominio,
    };
  }

  Future<void> _guarda() async {
    if (!_forma.currentState!.validate()) return;
    final cambios = _cambios;
    if (cambios.isEmpty) {
      Navigator.pop(context, false);
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await sesion.api.patch('/v1/equipos/${widget.equipo['id']}', cambios);
      if (!mounted) return;
      avisa(context, 'Ficha guardada.');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = mensajeDe(e));
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.equipo;
    final opciones = _opcionesDominio;
    Widget campo(String k, String etiqueta, {int max = 200, int lineas = 1, String? ayuda, bool requerido = false}) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        controller: _c[k],
        maxLength: max,
        minLines: lineas,
        maxLines: lineas == 1 ? 1 : 8,
        decoration: InputDecoration(labelText: etiqueta, helperText: ayuda, counterText: ''),
        validator: requerido ? (v) => (v ?? '').trim().isEmpty ? 'El equipo necesita un nombre' : null : null,
      ),
    );
    final notaEstado = (_estado == 'guardado' || _estado == 'retirado') && _estado != e['estado']
        ? '${estados[_estado]}: deja de vigilarse y sus alertas abiertas se cierran.'
        : null;
    final dominioNuevo = _dominio != entero(e['dominio'])
        ? opciones.where((d) => d.id == _dominio).map((d) => d.nombre).firstOrNull
        : null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Editar ficha'),
        actions: [
          TextButton(
            onPressed: _guardando || _cambios.isEmpty ? null : _guarda,
            child: Text(_guardando ? 'Guardando…' : 'Guardar'),
          ),
        ],
      ),
      body: Form(
        key: _forma,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            campo('nombre', 'Nombre', requerido: true),
            campo('etiqueta', 'Etiqueta', ayuda: 'El número de activo'),
            campo('serie', 'Serie'),
            if (opciones.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: DropdownButtonFormField<int>(
                  initialValue: _dominio,
                  decoration: const InputDecoration(labelText: 'Dominio'),
                  items: [for (final d in opciones) DropdownMenuItem(value: d.id, child: Text(d.nombre))],
                  onChanged: (v) => setState(() => _dominio = v),
                ),
              ),
            if (dominioNuevo != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text(
                  'Pasa a «$dominioNuevo»: desde ahí lo ven quienes alcanzan ese dominio, y lo vigilan las '
                  'reglas de ese dominio y las de toda la organización.',
                  style: apagado(context, tamano: 13),
                ),
              ),
            campo('asignado_a', 'Asignado a'),
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: DropdownButtonFormField<String>(
                initialValue: estados.containsKey(_estado) ? _estado : null,
                decoration: const InputDecoration(labelText: 'Estado'),
                items: [for (final x in estados.entries) DropdownMenuItem(value: x.key, child: Text(x.value))],
                onChanged: (v) => setState(() => _estado = v ?? _estado),
              ),
            ),
            if (notaEstado != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text(notaEstado, style: apagado(context, tamano: 13)),
              ),
            campo('notas', 'Notas', max: 2000, lineas: 3),
            if (_error != null) Aviso(_error!),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _guardando || _cambios.isEmpty ? null : _guarda,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
              child: Text(_guardando ? 'Guardando…' : 'Guardar'),
            ),
          ],
        ),
      ),
    );
  }
}
