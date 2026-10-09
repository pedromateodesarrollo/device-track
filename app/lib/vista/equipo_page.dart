/// La ficha de un equipo (`GET /v1/equipos/:id`): sus alertas abiertas, las
/// órdenes (Sonar, Mensaje, Reportar ya), su estado de ahora, dónde está, lo
/// que se escribió de él y quién reporta. Como `EquipoDetalle.vue`, sin unir
/// ni borrar: eso queda en el panel web.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../modelo/equipo.dart';
import '../modelo/formato.dart';
import '../navegacion.dart';
import '../sesion.dart';
import '../sistema.dart';
import '../tema.dart';
import 'comun.dart';
import 'ficha_page.dart';
import 'mapa.dart';

class EquipoPage extends StatefulWidget {
  const EquipoPage({super.key, required this.id});
  final int id;

  @override
  State<EquipoPage> createState() => _EquipoPageState();
}

class _EquipoPageState extends State<EquipoPage> {
  Json? _e;
  List<Json> _ordenes = const [];
  String? _error;

  /// La orden que se está mandando (`sonar`, `mensaje`, `reportar`).
  String? _enviando;
  Timer? _relojOrdenes;

  @override
  void initState() {
    super.initState();
    _carga();
  }

  @override
  void dispose() {
    _relojOrdenes?.cancel();
    super.dispose();
  }

  Future<void> _carga() async {
    try {
      final e = await sesion.api.get('/v1/equipos/${widget.id}');
      if (!mounted) return;
      setState(() {
        _e = e;
        _ordenes = _lista(e['ordenes']);
        _error = null;
      });
      _vigilaOrdenes();
    } catch (e) {
      if (mounted) setState(() => _error = mensajeDe(e));
    }
  }

  static List<Json> _lista(Object? v) => [
    for (final x in (v as List?) ?? const [])
      if (x is Map) x.cast<String, Object?>(),
  ];

  Future<void> _cargaOrdenes() async {
    try {
      final r = await sesion.api.get('/v1/equipos/${widget.id}/ordenes');
      if (mounted) setState(() => _ordenes = _lista(r['ordenes']).take(10).toList());
    } catch (_) {
      // Se queda la lista de antes.
    }
    _vigilaOrdenes();
  }

  /// Mientras haya una orden reciente sin terminar, se mira cada pocos
  /// segundos en qué va: es lo que la persona está esperando ver.
  void _vigilaOrdenes() {
    _relojOrdenes?.cancel();
    final hace5 = DateTime.now().subtract(const Duration(minutes: 5));
    final enCurso = _ordenes.any(
      (o) =>
          const {'pendiente', 'enviada', 'recibida'}.contains(o['estado']) &&
          (leeFecha(o['creado'])?.isAfter(hace5) ?? false),
    );
    if (enCurso && mounted) _relojOrdenes = Timer(const Duration(seconds: 4), _cargaOrdenes);
  }

  Future<void> _ordena(String tipo, [Json datos = const {}]) async {
    setState(() => _enviando = tipo);
    try {
      final o = await sesion.api.post('/v1/equipos/${widget.id}/ordenes', {'tipo': tipo, 'datos': datos});
      if (!mounted) return;
      avisa(
        context,
        o['estado'] == 'enviada'
            ? '${tiposOrden[tipo]}: enviada. El equipo está conectado y le llegó ya.'
            : '${tiposOrden[tipo]}: en espera. Le llega en cuanto se conecte o mande su próximo reporte.',
      );
      await _cargaOrdenes();
    } catch (e) {
      if (mounted) avisa(context, mensajeDe(e), error: true);
    } finally {
      if (mounted) setState(() => _enviando = null);
    }
  }

  Future<void> _sonar() async {
    final seg = await showDialog<int>(context: context, builder: (_) => const _DialogoSonar());
    if (seg != null) await _ordena('sonar', {'segundos': seg});
  }

  Future<void> _mensaje() async {
    final m = await showDialog<(String, String)>(context: context, builder: (_) => const _DialogoMensaje());
    if (m != null) await _ordena('mensaje', {'titulo': m.$1, 'texto': m.$2});
  }

  Future<void> _edita() async {
    final e = _e;
    if (e == null) return;
    final cambio = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => FichaPage(equipo: e)));
    if (cambio == true) await _carga();
  }

  @override
  Widget build(BuildContext context) {
    final e = _e;
    return Scaffold(
      appBar: AppBar(
        title: Text(e == null ? 'Equipo' : '${e['nombre'] ?? 'Equipo ${widget.id}'}'),
        actions: [
          if (e != null && sesion.puede('editar'))
            IconButton(tooltip: 'Editar ficha', icon: const Icon(Icons.edit_outlined), onPressed: _edita),
        ],
      ),
      body: e == null
          ? (_error != null ? VistaError(_error!, reintentar: _carga) : const Cargando())
          : RefreshIndicator(
              onRefresh: _carga,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                children: [
                  if (_error != null) Aviso(_error!),
                  _cabecera(e),
                  ..._alertas(e),
                  const SizedBox(height: 14),
                  _ordenesTarjeta(e),
                  const SizedBox(height: 14),
                  _donde(e),
                  const SizedBox(height: 14),
                  _estado(e),
                  const SizedBox(height: 14),
                  _ficha(e),
                  const SizedBox(height: 14),
                  _fuentes(e),
                ],
              ),
            ),
    );
  }

  Widget _cabecera(Json e) {
    final p = Paleta.de(context);
    final conectado = e['conectado'] == true;
    final sub = [?texto(e['etiqueta']), ?texto(e['modelo']), ?texto(e['dominio_nombre'])];
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Punto(color: conectado ? p.ok : p.grisMapa, tamano: 12),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (sub.isNotEmpty) Text(sub.join(' · '), style: apagado(context)),
                Text(
                  conectado ? 'conectado ahora' : 'visto ${hace(e['ultima_vez'])}',
                  style: apagado(context, tamano: 13),
                ),
              ],
            ),
          ),
          EstadoEquipo('${e['estado'] ?? ''}'),
        ],
      ),
    );
  }

  /// Arriba, que es lo primero que hay que ver.
  List<Widget> _alertas(Json e) {
    final abiertas = _lista(e['alertas_abiertas']);
    if (abiertas.isEmpty) return const [];
    final p = Paleta.de(context);
    return [
      const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: p.malSuave,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: p.mal.withValues(alpha: .45)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              abiertas.length == 1 ? 'Una alerta abierta' : '${abiertas.length} alertas abiertas',
              style: TextStyle(fontWeight: FontWeight.w700, color: p.mal),
            ),
            const SizedBox(height: 4),
            for (final a in abiertas)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: '${texto(a['regla']) ?? nombreTipoRegla(a['tipo'])}: ${detalleAlerta(a)}'),
                      TextSpan(text: ' · ${hace(a['abierta'])}', style: apagado(context)),
                    ],
                  ),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: () => navegacion.ve(Pestana.alertas), child: const Text('Ir a alertas')),
            ),
          ],
        ),
      ),
    ];
  }

  Widget _ordenesTarjeta(Json e) {
    final puede = sesion.puede('ordenar');
    final retirado = e['estado'] == 'retirado';
    Widget boton(String tipo, IconData icono, VoidCallback alTocar) => Expanded(
      child: FilledButton.tonal(
        onPressed: _enviando != null ? null : alTocar,
        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
        child: Column(
          children: [
            _enviando == tipo
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(icono),
            const SizedBox(height: 4),
            Text(tiposOrden[tipo]!, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Titulo('Órdenes'),
          if (retirado)
            Text('Un equipo retirado no recibe órdenes.', style: apagado(context, tamano: 14))
          else if (puede) ...[
            Text(
              e['conectado'] == true
                  ? 'Está conectado: la orden le llega al instante.'
                  : 'No está conectado: la orden le llega en su próximo reporte (vence en una hora).',
              style: apagado(context, tamano: 13),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                boton('sonar', Icons.volume_up_outlined, _sonar),
                const SizedBox(width: 8),
                boton('mensaje', Icons.message_outlined, _mensaje),
                const SizedBox(width: 8),
                boton('reportar', Icons.my_location, () => _ordena('reportar')),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Text('Últimas órdenes', style: apagado(context, tamano: 13)),
          if (_ordenes.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Ninguna todavía.', style: apagado(context, tamano: 14)),
            ),
          for (final o in _ordenes.take(5)) _FilaOrden(o),
        ],
      ),
    );
  }

  Widget _donde(Json e) {
    final lat = decimal(e['lat']);
    final lng = decimal(e['lng']);
    final precision = decimal(e['precision_m']);
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Titulo('Dónde está'),
          if (lat == null || lng == null)
            Text('Este equipo no ha mandado ubicación.', style: apagado(context, tamano: 14))
          else ...[
            SizedBox(
              height: 220,
              child: Mapa(
                puntos: [
                  PuntoEnMapa(id: widget.id, lat: lat, lng: lng, color: colorEquipo(e), nombre: '${e['nombre'] ?? ''}'),
                ],
                precision: precision,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              [
                'Ubicación ${hace(e['ubicacion_t'])}',
                if (precision != null) '± ${distancia(precision)}',
              ].join(' · '),
              style: apagado(context, tamano: 13),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () async {
                final ok = await abrirEnElMapa(lat, lng, nombre: '${e['nombre'] ?? ''}');
                if (!ok && mounted) avisa(context, 'No hay una app de mapas ni un navegador para abrirlo.', error: true);
              },
              icon: const Icon(Icons.map_outlined),
              label: const Text('Abrir en el mapa'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _estado(Json e) {
    final libre = entero(e['almacenamiento_libre']);
    final total = entero(e['almacenamiento_total']);
    final red = redDe(e);
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Titulo('Estado actual'),
          Dato(
            'Batería',
            '',
            hijo: Row(
              children: [
                Bateria(nivel: entero(e['bateria']), cargando: e['cargando'] == true),
                if (e['cargando'] == true) Text('  cargando', style: apagado(context, tamano: 13)),
              ],
            ),
          ),
          Dato('Red', red.isEmpty ? 'Sin dato' : red),
          Dato(
            'Almacenamiento',
            total == null || total == 0 ? 'Sin dato' : '${bytes(libre)} libres de ${bytes(total)}',
          ),
          Dato('Android', android(e['android']).isEmpty ? 'Sin dato' : android(e['android'])),
          Dato('Modelo', [?texto(e['fabricante']), ?texto(e['modelo'])].join(' ')),
          Dato(
            'Último reporte',
            e['ultimo_reporte'] == null
                ? 'Todavía no ha reportado'
                : '${fecha(e['ultimo_reporte'])} · ${motivos[e['ultimo_motivo']] ?? e['ultimo_motivo'] ?? ''}',
          ),
          Dato('Última vez', e['conectado'] == true ? 'Conectado ahora' : fecha(e['ultima_vez'])),
          Dato('En el inventario desde', fecha(e['primera_vez'])),
          Dato('Huella', '${e['huella'] ?? '—'}'),
        ],
      ),
    );
  }

  Widget _ficha(Json e) => Tarjeta(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Titulo(
          'Ficha',
          derecha: sesion.puede('editar')
              ? TextButton.icon(onPressed: _edita, icon: const Icon(Icons.edit_outlined, size: 18), label: const Text('Editar'))
              : null,
        ),
        Text(
          sesion.puede('editar') ? 'Lo que pones tú. El estado actual lo cuenta el equipo.' : 'Lo que puso quien administra.',
          style: apagado(context, tamano: 13),
        ),
        const SizedBox(height: 6),
        Dato('Nombre', '${e['nombre'] ?? ''}'),
        Dato('Etiqueta', '${e['etiqueta'] ?? ''}'),
        Dato('Serie', '${e['serie'] ?? ''}'),
        Dato('Dominio', '${e['dominio_nombre'] ?? ''}'),
        Dato('Asignado a', '${e['asignado_a'] ?? ''}'),
        Dato('Estado', estados['${e['estado']}'] ?? '${e['estado'] ?? ''}'),
        Dato('Notas', '${e['notas'] ?? ''}'),
      ],
    ),
  );

  Widget _fuentes(Json e) {
    final todas = _lista(e['fuentes']);
    final vivas = [for (final f in todas) if (f['revocada'] == null) f];
    final apps = _lista(e['apps']);
    final p = Paleta.de(context);
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Titulo('Quién reporta'),
          Text(
            'El agente y cada app con el plugin que corre en este equipo. Cada una cuenta su contexto.',
            style: apagado(context, tamano: 13),
          ),
          if (vivas.isEmpty) Text('Ninguna fuente activa.', style: apagado(context, tamano: 14)),
          for (final f in vivas)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: p.borde),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Pastilla(
                        '${f['tipo'] ?? ''}',
                        fondo: f['tipo'] == 'agente' ? p.marca : null,
                        letra: f['tipo'] == 'agente' ? Colors.white : null,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(nombreFuente(f), style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      Hace(f['ultima_vez'], estilo: apagado(context, tamano: 13)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      '${f['paquete'] ?? ''}',
                      if (texto(f['version']) != null)
                        '${f['version']}${f['build'] != null ? ' (${f['build']})' : ''}',
                    ].join(' · '),
                    style: apagado(context, tamano: 13).copyWith(fontFamily: 'monospace'),
                  ),
                  if (f['contexto'] is Map && (f['contexto'] as Map).isNotEmpty) ...[
                    const SizedBox(height: 6),
                    for (final c in (f['contexto'] as Map).entries)
                      Dato('${c.key}', c.value is Map || c.value is List ? '${c.value}' : '${c.value ?? ''}'),
                  ],
                ],
              ),
            ),
          if (apps.isNotEmpty)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('Apps instaladas (${apps.length})', style: const TextStyle(fontSize: 15)),
                subtitle: Text('lista del ${fecha(e['apps_t'])}', style: apagado(context, tamano: 12)),
                children: [
                  for (final a in apps)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(texto(a['nombre']) ?? '${a['paquete'] ?? ''}'),
                      subtitle: Text(
                        '${a['paquete'] ?? ''} · ${a['version'] ?? ''}',
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                    ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('El equipo no ha mandado la lista de apps instaladas.', style: apagado(context, tamano: 13)),
            ),
        ],
      ),
    );
  }
}

class _FilaOrden extends StatelessWidget {
  const _FilaOrden(this.o);
  final Json o;

  @override
  Widget build(BuildContext context) {
    final p = Paleta.de(context);
    final d = o['datos'] is Map ? (o['datos'] as Map).cast<String, Object?>() : const <String, Object?>{};
    final que = switch (o['tipo']) {
      'sonar' => '${d['segundos'] ?? 30} s',
      'mensaje' => [?texto(d['titulo']), ?texto(d['texto'])].join(': '),
      _ => '',
    };
    final estado = '${o['estado'] ?? ''}';
    final (fondo, letra) = switch (estado) {
      'hecha' => (p.ok, Colors.white),
      'fallida' => (p.mal, Colors.white),
      'enviada' || 'recibida' => (p.marca, Colors.white),
      _ => (p.fondo3, p.texto2),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: tiposOrden[o['tipo']] ?? '${o['tipo']}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (que.isNotEmpty) TextSpan(text: '  $que', style: apagado(context)),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  [hace(o['creado']), ?texto(o['detalle'])].join(' · '),
                  style: apagado(context, tamano: 12),
                ),
              ],
            ),
          ),
          Pastilla(estadosOrden[estado] ?? estado, fondo: fondo, letra: letra),
        ],
      ),
    );
  }
}

class _DialogoSonar extends StatefulWidget {
  const _DialogoSonar();

  @override
  State<_DialogoSonar> createState() => _DialogoSonarState();
}

class _DialogoSonarState extends State<_DialogoSonar> {
  double _segundos = 30;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Hacer sonar'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('A todo volumen, aunque esté en silencio, hasta que lo toquen o pase el tiempo.'),
        const SizedBox(height: 16),
        Text('${_segundos.round()} segundos', style: const TextStyle(fontWeight: FontWeight.w600)),
        Slider(
          value: _segundos,
          min: 5,
          max: 300,
          divisions: 59,
          label: '${_segundos.round()} s',
          onChanged: (v) => setState(() => _segundos = v),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: () => Navigator.pop(context, _segundos.round()), child: const Text('Hacer sonar')),
    ],
  );
}

class _DialogoMensaje extends StatefulWidget {
  const _DialogoMensaje();

  @override
  State<_DialogoMensaje> createState() => _DialogoMensajeState();
}

class _DialogoMensajeState extends State<_DialogoMensaje> {
  final _titulo = TextEditingController();
  final _texto = TextEditingController();

  @override
  void dispose() {
    _titulo.dispose();
    _texto.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Mostrar un mensaje'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Sale como aviso en la pantalla del equipo.'),
          const SizedBox(height: 12),
          TextField(
            controller: _titulo,
            maxLength: 80,
            decoration: const InputDecoration(labelText: 'Título (opcional)'),
          ),
          TextField(
            controller: _texto,
            maxLength: 500,
            minLines: 2,
            maxLines: 5,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Mensaje', hintText: 'Devuelve este equipo a la oficina'),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(
        onPressed: _texto.text.trim().isEmpty ? null : () => Navigator.pop(context, (_titulo.text.trim(), _texto.text.trim())),
        child: const Text('Mostrar'),
      ),
    ],
  );
}
