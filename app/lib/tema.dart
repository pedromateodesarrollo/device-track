/// Los colores del panel web (`manager/src/style.css`), claro y oscuro según
/// el teléfono. Sobrios a propósito: lo que tiene color es lo que dice algo
/// (rojo = hay que mirarlo, verde = está bien).
library;

import 'package:flutter/material.dart';

import 'modelo/equipo.dart' show ColorEquipo;

/// Lo que el `ColorScheme` de Material no tiene: los colores con sentido del
/// panel. Se lee con `Paleta.de(context)`.
@immutable
class Paleta extends ThemeExtension<Paleta> {
  const Paleta({
    required this.marca,
    required this.marcaSuave,
    required this.ok,
    required this.mal,
    required this.malSuave,
    required this.tibio,
    required this.grisMapa,
    required this.zona,
    required this.fondo2,
    required this.fondo3,
    required this.texto2,
    required this.borde,
  });

  final Color marca;
  final Color marcaSuave;
  final Color ok;
  final Color mal;
  final Color malSuave;
  final Color tibio;
  final Color grisMapa;
  final Color zona;
  final Color fondo2;
  final Color fondo3;
  final Color texto2;
  final Color borde;

  static const claro = Paleta(
    marca: Color(0xFF2563EB),
    marcaSuave: Color(0xFFEFF4FF),
    ok: Color(0xFF16A34A),
    mal: Color(0xFFDC2626),
    malSuave: Color(0xFFFEF2F2),
    tibio: Color(0xFFCA8A04),
    grisMapa: Color(0xFF6B7280),
    zona: Color(0xFF7C3AED),
    fondo2: Color(0xFFF6F7F9),
    fondo3: Color(0xFFECEEF2),
    texto2: Color(0xFF5B6270),
    borde: Color(0xFFDFE3EA),
  );

  static const oscuro = Paleta(
    marca: Color(0xFF5B8CFF),
    marcaSuave: Color(0xFF172033),
    ok: Color(0xFF16A34A),
    mal: Color(0xFFDC2626),
    malSuave: Color(0xFF2A1416),
    tibio: Color(0xFFCA8A04),
    grisMapa: Color(0xFF8B93A1),
    zona: Color(0xFFA78BFA),
    fondo2: Color(0xFF15181E),
    fondo3: Color(0xFF1D222A),
    texto2: Color(0xFF9AA3B2),
    borde: Color(0xFF262B34),
  );

  static Paleta de(BuildContext context) => Theme.of(context).extension<Paleta>() ?? claro;

  /// El color de un equipo en el mapa y en las listas.
  Color deEquipo(ColorEquipo c) => switch (c) {
    ColorEquipo.mal => mal,
    ColorEquipo.ok => ok,
    ColorEquipo.gris || ColorEquipo.apagado => grisMapa,
  };

  /// La pastilla del estado de un equipo: activo en verde, perdido en rojo,
  /// guardado en ámbar, retirado en gris.
  (Color fondo, Color letra) deEstado(String estado) => switch (estado) {
    'activo' => (ok.withValues(alpha: .16), ok),
    'perdido' => (mal.withValues(alpha: .16), mal),
    'guardado' => (tibio.withValues(alpha: .16), tibio),
    _ => (fondo3, texto2),
  };

  @override
  Paleta copyWith() => this;

  @override
  Paleta lerp(ThemeExtension<Paleta>? otra, double t) => t < .5 || otra is! Paleta ? this : otra;
}

ThemeData tema(Brightness brillo) {
  final oscuro = brillo == Brightness.dark;
  final p = oscuro ? Paleta.oscuro : Paleta.claro;
  final fondo = oscuro ? const Color(0xFF0E1014) : Colors.white;
  final texto = oscuro ? const Color(0xFFE8EAEE) : const Color(0xFF16181D);
  final esquema = ColorScheme.fromSeed(seedColor: p.marca, brightness: brillo).copyWith(
    primary: p.marca,
    onPrimary: Colors.white,
    primaryContainer: p.marcaSuave,
    onPrimaryContainer: p.marca,
    secondaryContainer: p.marcaSuave,
    onSecondaryContainer: p.marca,
    error: p.mal,
    onError: Colors.white,
    errorContainer: p.malSuave,
    onErrorContainer: p.mal,
    surface: fondo,
    onSurface: texto,
    onSurfaceVariant: p.texto2,
    surfaceContainerLowest: fondo,
    surfaceContainerLow: p.fondo2,
    surfaceContainer: p.fondo2,
    surfaceContainerHigh: p.fondo3,
    surfaceContainerHighest: p.fondo3,
    outline: p.texto2,
    outlineVariant: p.borde,
  );
  final borde = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(12),
    side: BorderSide(color: p.borde),
  );
  return ThemeData(
    colorScheme: esquema,
    brightness: brillo,
    scaffoldBackgroundColor: fondo,
    extensions: [p],
    appBarTheme: AppBarTheme(
      backgroundColor: fondo,
      foregroundColor: texto,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: .5,
      centerTitle: false,
      titleTextStyle: TextStyle(color: texto, fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -.3),
    ),
    // La «tarjeta» del panel: fondo gris claro con borde, sin sombra.
    cardTheme: CardThemeData(
      color: p.fondo2,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: borde,
      clipBehavior: Clip.antiAlias,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.fondo2,
      indicatorColor: p.marcaSuave,
      surfaceTintColor: Colors.transparent,
      height: 66,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: p.borde)),
      enabledBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: p.borde)),
      isDense: true,
    ),
    chipTheme: ChipThemeData(side: BorderSide(color: p.borde)),
    dividerTheme: DividerThemeData(color: p.borde, space: 1),
    // La parte vacía de la barra sale de `secondaryContainer` (marcaSuave), que
    // sobre el fondo de un diálogo no se ve: el tiempo de Sonar parecía un
    // punto suelto.
    sliderTheme: SliderThemeData(inactiveTrackColor: p.marca.withValues(alpha: .25)),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide(color: p.borde),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
