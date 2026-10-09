/// El mapa en grande: todos los equipos con ubicación y las zonas (desde Más),
/// o los puntos de un panel de mapa de un tablero. Tocar un punto dice qué
/// equipo es y deja abrirlo o llevar la app de mapas hasta él.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../modelo/equipo.dart';
import '../modelo/formato.dart';
import '../modelo/tablero.dart' show PuntoMapa;
import '../navegacion.dart';
import '../sesion.dart';
import '../sistema.dart';
import 'comun.dart';
import 'mapa.dart';

class MapaPage extends StatefulWidget {
  const MapaPage({super.key, this.titulo = 'Mapa', this.puntos});
  final String titulo;

  /// Los de un panel. Null = todos los equipos que alcanza la sesión.
  final List<PuntoMapa>? puntos;

  @override
  State<MapaPage> createState() => _MapaPageState();
}

class _MapaPageState extends State<MapaPage> {
  List<PuntoMapa>? _puntos;
  List<ZonaEnMapa> _zonas = const [];

  /// Lo que se sabe de cada equipo, para la hoja de abajo.
  final _equipos = <int, Json>{};
  int _total = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.puntos != null) {
      _puntos = widget.puntos;
      _total = widget.puntos!.length;
    } else {
      _carga();
    }
  }

  Future<void> _carga() async {
    try {
      final r = await sesion.api.get('/v1/equipos');
      final equipos = [for (final e in (r['equipos'] as List?) ?? const []) if (e is Map) e.cast<String, Object?>()];
      _equipos
        ..clear()
        ..addEntries(equipos.map((e) => MapEntry(entero(e['id']) ?? 0, e)));
      // Las zonas son de adorno: si no llegan, el mapa sale igual.
      List<ZonaEnMapa> zonas = const [];
      try {
        final z = await sesion.api.get('/v1/zonas');
        zonas = [
          for (final x in (z['zonas'] as List?) ?? const [])
            if (x is Map && decimal(x['lat']) != null && decimal(x['lng']) != null)
              ZonaEnMapa(
                lat: decimal(x['lat'])!,
                lng: decimal(x['lng'])!,
                radio: decimal(x['radio_m']) ?? 100,
                nombre: '${x['nombre'] ?? ''}',
              ),
        ];
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _total = equipos.length;
        _zonas = zonas;
        _error = null;
        _puntos = [
          for (final e in equipos)
            if (decimal(e['lat']) != null && decimal(e['lng']) != null)
              PuntoMapa(
                id: entero(e['id']) ?? 0,
                nombre: '${e['nombre'] ?? ''}',
                lat: decimal(e['lat'])!,
                lng: decimal(e['lng'])!,
                estado: '${e['estado'] ?? ''}',
                conectado: e['conectado'] == true,
                bateria: entero(e['bateria']),
                alertas: entero(e['alertas']) ?? 0,
              ),
        ];
      });
    } catch (e) {
      if (mounted) setState(() => _error = mensajeDe(e));
    }
  }

  void _hoja(PuntoMapa p) {
    final e = _equipos[p.id];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(p.nombre.isEmpty ? 'Equipo ${p.id}' : p.nombre,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                  if (p.estado.isNotEmpty) EstadoEquipo(p.estado),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(p.conectado ? 'conectado' : (e != null ? hace(e['ultima_vez']) : 'desconectado')),
                  Bateria(nivel: p.bateria, cargando: e?['cargando'] == true),
                  if (p.alertas > 0) Pastilla.roja(context, p.alertas == 1 ? '1 alerta' : '${p.alertas} alertas'),
                  if (e != null && leeFecha(e['ubicacion_t']) != null)
                    Text('ubicación ${hace(e['ubicacion_t'])}', style: apagado(context, tamano: 13)),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.pop(c);
                        navegacion.abreEquipo(p.id);
                      },
                      icon: const Icon(Icons.smartphone),
                      label: const Text('Ver equipo'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => unawaited(abrirEnElMapa(p.lat, p.lng, nombre: p.nombre)),
                      icon: const Icon(Icons.map_outlined),
                      label: const Text('Abrir en el mapa'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final puntos = _puntos;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.titulo),
        actions: [
          if (puntos != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text('${puntos.length} de $_total', style: apagado(context)),
              ),
            ),
        ],
      ),
      body: _error != null
          ? VistaError(_error!, reintentar: _carga)
          : puntos == null
          ? const Cargando()
          : Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Mapa(
                puntos: [
                  for (final x in puntos)
                    PuntoEnMapa(id: x.id, lat: x.lat, lng: x.lng, color: colorEquipo(x.comoEquipo), nombre: x.nombre),
                ],
                zonas: _zonas,
                alTocarPunto: (x) => _hoja(puntos.firstWhere((p) => p.id == x.id)),
              ),
            ),
    );
  }
}
