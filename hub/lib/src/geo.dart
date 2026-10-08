import 'dart:math';

/// Distancia en metros entre dos puntos (haversine). Para saber si un equipo
/// está dentro de una zona de cien metros sobra: el error de tratar la Tierra
/// como esfera es menor que el del GPS de un teléfono.
double distanciaM(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  double rad(double g) => g * pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(rad(lat1)) * cos(rad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
  return 2 * r * asin(min(1.0, sqrt(a)));
}
