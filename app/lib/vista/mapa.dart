/// Lo común de los mapas, como `manager/src/mapa.js`: teselas de
/// OpenStreetMap con su atribución, puntos de color según el estado del
/// equipo y las zonas en círculo punteado.
///
/// Por qué un mapa de verdad y no solo una lista con «Abrir en el mapa»: el
/// panel de mapa sirve para ver de un vistazo DÓNDE están todos, y eso no lo
/// da una lista. flutter_map dibuja las teselas en Flutter (no es un WebView),
/// no pide llave ni servicios de Google, y usa las mismas teselas que el panel
/// web. Para llegar a un equipo, cada uno tiene «Abrir en el mapa» (`geo:`),
/// que abre la app de mapas del teléfono.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../modelo/equipo.dart' show ColorEquipo;
import '../sistema.dart';
import '../tema.dart';

/// Santo Domingo, para cuando todavía no hay nada que enseñar.
const centroInicial = LatLng(18.4861, -69.9312);

class PuntoEnMapa {
  const PuntoEnMapa({required this.id, required this.lat, required this.lng, required this.color, this.nombre = ''});
  final int id;
  final double lat;
  final double lng;
  final ColorEquipo color;
  final String nombre;

  LatLng get punto => LatLng(lat, lng);
}

class ZonaEnMapa {
  const ZonaEnMapa({required this.lat, required this.lng, required this.radio, this.nombre = ''});
  final double lat;
  final double lng;
  final double radio;
  final String nombre;
}

class Mapa extends StatelessWidget {
  const Mapa({
    super.key,
    required this.puntos,
    this.zonas = const [],
    this.precision,
    this.interactivo = true,
    this.alTocarPunto,
    this.alTocar,
    this.zoomUno = 16,
  });

  final List<PuntoEnMapa> puntos;
  final List<ZonaEnMapa> zonas;

  /// El círculo de precisión del GPS alrededor del único punto, en metros.
  final double? precision;

  /// Sin interacción (dentro de una lista que se desliza): tocarlo hace
  /// [alTocar], que suele abrir el mapa en grande.
  final bool interactivo;
  final void Function(PuntoEnMapa)? alTocarPunto;
  final VoidCallback? alTocar;

  /// El acercamiento con un solo punto.
  final double zoomUno;

  @override
  Widget build(BuildContext context) {
    final p = Paleta.de(context);
    final oscuro = Theme.of(context).brightness == Brightness.dark;
    final coordenadas = [for (final x in puntos) x.punto];
    final mapa = FlutterMap(
      options: MapOptions(
        initialCenter: coordenadas.isEmpty ? centroInicial : coordenadas.first,
        initialZoom: coordenadas.length == 1 ? zoomUno : 12,
        initialCameraFit: coordenadas.length > 1
            ? CameraFit.coordinates(coordinates: coordenadas, padding: const EdgeInsets.all(36), maxZoom: 16)
            : null,
        interactionOptions: InteractionOptions(
          flags: interactivo ? InteractiveFlag.all & ~InteractiveFlag.rotate : InteractiveFlag.none,
        ),
        onTap: alTocar == null ? null : (_, _) => alTocar!(),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.chalonasoft.devicetrack.panel',
          maxZoom: 19,
          // Como el panel web: de noche, las teselas invertidas.
          tileBuilder: oscuro ? darkModeTileBuilder : null,
        ),
        if (zonas.isNotEmpty)
          CircleLayer(
            circles: [
              for (final z in zonas)
                CircleMarker(
                  point: LatLng(z.lat, z.lng),
                  radius: z.radio,
                  useRadiusInMeter: true,
                  color: p.zona.withValues(alpha: .08),
                  borderColor: p.zona,
                  borderStrokeWidth: 2,
                ),
            ],
          ),
        if (precision != null && precision! > 0 && puntos.length == 1)
          CircleLayer(
            circles: [
              CircleMarker(
                point: puntos.first.punto,
                radius: precision!,
                useRadiusInMeter: true,
                color: p.marca.withValues(alpha: .12),
                borderColor: p.marca,
                borderStrokeWidth: 1,
              ),
            ],
          ),
        MarkerLayer(
          markers: [
            for (final x in puntos)
              Marker(
                point: x.punto,
                width: 26,
                height: 26,
                child: GestureDetector(
                  onTap: alTocarPunto == null ? alTocar : () => alTocarPunto!(x),
                  child: Tooltip(
                    message: x.nombre,
                    child: Center(
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: p.deEquipo(x.color),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2.5),
                          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        SimpleAttributionWidget(
          source: const Text('© colaboradores de OpenStreetMap', style: TextStyle(fontSize: 11)),
          onTap: () => abrir('https://www.openstreetmap.org/copyright'),
        ),
      ],
    );
    return ClipRRect(borderRadius: BorderRadius.circular(10), child: mapa);
  }
}
