/// Un panel de un tablero, ya con sus datos (`GET /v1/tableros/:id/datos`).
/// Cada forma se dibuja aquí, como en `manager/src/componentes/PanelTablero.vue`;
/// los datos los calculó el hub con la sesión de quien mira.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../modelo/equipo.dart' show colorEquipo;
import '../modelo/tablero.dart';
import '../navegacion.dart';
import '../tema.dart';
import 'comun.dart';
import 'mapa.dart';
import 'mapa_page.dart';

/// La cifra: un número grande con su título. En rojo si hay [DatosCifra.alarma];
/// si trae enlace, tocarla lleva a la lista filtrada.
class PanelCifra extends StatelessWidget {
  const PanelCifra({super.key, required this.panel, this.alQuitar});
  final Panel panel;
  final VoidCallback? alQuitar;

  @override
  Widget build(BuildContext context) {
    final p = Paleta.de(context);
    final d = panel.datos as DatosCifra;
    final enlace = d.enlace;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: d.alarma ? Color.lerp(p.mal, p.borde, .55)! : p.borde),
      ),
      child: InkWell(
        onTap: enlace == null ? null : () => navegacion.enlace(enlace),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${d.valor}',
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1,
                        height: 1.1,
                        color: d.alarma ? p.mal : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(panel.titulo, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  ],
                ),
              ),
              if (alQuitar != null) _BotonQuitar(panel: panel, alQuitar: alQuitar!),
            ],
          ),
        ),
      ),
    );
  }
}

/// Cualquier otro panel: barras, dona, tabla, mapa, o el error del que no
/// sale (sin tumbar a los demás).
class PanelTarjeta extends StatelessWidget {
  const PanelTarjeta({super.key, required this.panel, this.alQuitar});
  final Panel panel;
  final VoidCallback? alQuitar;

  @override
  Widget build(BuildContext context) {
    final d = panel.datos;
    final total = switch (d) {
      DatosSeries(:final total) || DatosTabla(:final total) || DatosMapa(:final total) => total,
      _ => null,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(panel.titulo, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                if (total != null) Text('$total', style: apagado(context, tamano: 13)),
                if (alQuitar != null) _BotonQuitar(panel: panel, alQuitar: alQuitar!) else const SizedBox(width: 8),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: switch (d) {
                _ when panel.error != null => Aviso('No sale: ${panel.error}'),
                DatosCifra(:final valor) => Text('$valor', style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w700)),
                DatosSeries() when panel.forma == 'dona' => _Dona(d),
                DatosSeries() => _Barras(d),
                DatosTabla() => _Tabla(d),
                DatosMapa() => _MapaPanel(titulo: panel.titulo, datos: d),
                null => Text('Sin datos.', style: apagado(context)),
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _BotonQuitar extends StatelessWidget {
  const _BotonQuitar({required this.panel, required this.alQuitar});
  final Panel panel;
  final VoidCallback alQuitar;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Quitar el panel',
    visualDensity: VisualDensity.compact,
    icon: Icon(Icons.close, size: 18, color: Paleta.de(context).texto2),
    onPressed: () async {
      final si = await confirma(
        context,
        titulo: 'Quitar «${panel.titulo}»',
        texto: 'Sale de este tablero. Para volver a ponerlo, pídeselo al asistente.',
        boton: 'Quitar',
        peligro: true,
      );
      if (si) alQuitar();
    },
  );
}

// -------------------------------------------------------------- colores

/// Los grupos que ya dicen algo llevan su color: lo malo en rojo, lo bueno en
/// verde. Los demás, de la paleta en orden. Igual que el panel web.
Color colorSerie(BuildContext context, Serie s, int i) {
  final p = Paleta.de(context);
  final conSentido = <String, Color>{
    '0–15 %': p.mal,
    '16–50 %': p.tibio,
    '51–100 %': p.ok,
    'activo': p.ok,
    'perdido': p.mal,
    'guardado': p.tibio,
    'retirado': p.grisMapa,
    'Conectado': p.ok,
    'Desconectado': p.grisMapa,
    'Abierta': p.mal,
    'Cerrada': p.grisMapa,
    'Sin dato': p.fondo3,
  };
  final paleta = [
    p.marca,
    p.zona,
    const Color(0xFF0D9488),
    const Color(0xFFDB2777),
    const Color(0xFFF97316),
    const Color(0xFF06B6D4),
    const Color(0xFF84CC16),
    const Color(0xFF64748B),
    p.tibio,
    const Color(0xFFA1A1AA),
    p.ok,
    p.mal,
  ];
  return conSentido[s.etiqueta] ?? paleta[i % paleta.length];
}

// --------------------------------------------------------------- barras

class _Barras extends StatelessWidget {
  const _Barras(this.d);
  final DatosSeries d;

  @override
  Widget build(BuildContext context) {
    if (d.series.isEmpty) return Text('Nada que contar.', style: apagado(context));
    final maximo = math.max(1, d.maximo);
    final pista = Paleta.de(context).fondo3;
    return Column(
      children: [
        for (final (i, s) in d.series.indexed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 110,
                  child: Text(s.etiqueta, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Stack(
                      children: [
                        Container(height: 14, color: pista),
                        FractionallySizedBox(
                          widthFactor: s.valor / maximo,
                          child: Container(height: 14, color: colorSerie(context, s, i)),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text('${s.valor}', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ----------------------------------------------------------------- dona

class _Dona extends StatelessWidget {
  const _Dona(this.d);
  final DatosSeries d;

  @override
  Widget build(BuildContext context) {
    if (d.series.isEmpty) return Text('Nada que contar.', style: apagado(context));
    final suma = math.max(1, d.suma);
    final colores = [for (final (i, s) in d.series.indexed) colorSerie(context, s, i)];
    final dona = SizedBox(
      width: 130,
      height: 130,
      child: CustomPaint(
        painter: _PintaDona(
          valores: [for (final s in d.series) s.valor / suma],
          colores: colores,
          fondo: Paleta.de(context).fondo3,
        ),
        child: Center(
          child: Text('${d.total}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
        ),
      ),
    );
    final leyenda = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, s) in d.series.indexed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: colores[i], borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: s.etiqueta),
                        TextSpan(
                          text: '  ${s.valor} · ${(s.valor * 100 / suma).round()} %',
                          style: apagado(context),
                        ),
                      ],
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    return LayoutBuilder(
      builder: (context, c) => c.maxWidth >= 340
          ? Row(children: [dona, const SizedBox(width: 16), Expanded(child: leyenda)])
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Center(child: dona), const SizedBox(height: 12), leyenda]),
    );
  }
}

class _PintaDona extends CustomPainter {
  _PintaDona({required this.valores, required this.colores, required this.fondo});
  final List<double> valores;
  final List<Color> colores;
  final Color fondo;

  @override
  void paint(Canvas canvas, Size size) {
    final grosor = size.shortestSide * .17;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: (size.shortestSide - grosor) / 2);
    final pincel = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = grosor;
    canvas.drawArc(rect, 0, math.pi * 2, false, pincel..color = fondo);
    var desde = -math.pi / 2;
    for (final (i, v) in valores.indexed) {
      final barrido = v * math.pi * 2;
      canvas.drawArc(rect, desde, barrido, false, pincel..color = colores[i]);
      desde += barrido;
    }
  }

  @override
  bool shouldRepaint(_PintaDona viejo) => viejo.valores != valores || viejo.colores != colores;
}

// ---------------------------------------------------------------- tabla

class _Tabla extends StatelessWidget {
  const _Tabla(this.d);
  final DatosTabla d;

  @override
  Widget build(BuildContext context) {
    if (d.filas.isEmpty) return Text('Nada que enseñar.', style: apagado(context));
    final p = Paleta.de(context);
    final ahora = DateTime.now();
    Widget celda(String texto, {bool cabeza = false, bool enlace = false}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Text(
        texto,
        style: TextStyle(
          fontSize: 13,
          fontWeight: cabeza || enlace ? FontWeight.w600 : null,
          color: cabeza ? p.texto2 : (enlace ? p.marca : null),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            border: TableBorder(horizontalInside: BorderSide(color: p.borde)),
            children: [
              TableRow(
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.borde))),
                children: [for (final c in d.columnas) celda(c.titulo, cabeza: true)],
              ),
              for (final f in d.filas)
                TableRow(
                  children: [
                    for (final (j, c) in d.columnas.indexed)
                      _celdaTocable(
                        f.id,
                        celda(
                          DatosTabla.celda(c.id, j < f.valores.length ? f.valores[j] : null, ahora: ahora),
                          enlace: j == 0 && f.id != null,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
        if (d.total > d.filas.length)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('${d.filas.length} de ${d.total}', style: apagado(context, tamano: 13)),
          ),
      ],
    );
  }

  /// Toda la fila abre el equipo (en las dos fuentes, el `id` es el equipo).
  Widget _celdaTocable(int? id, Widget hijo) =>
      id == null ? hijo : TableRowInkWell(onTap: () => navegacion.abreEquipo(id), child: hijo);
}

// ----------------------------------------------------------------- mapa

class _MapaPanel extends StatelessWidget {
  const _MapaPanel({required this.titulo, required this.datos});
  final String titulo;
  final DatosMapa datos;

  List<PuntoEnMapa> get _puntos => [
    for (final x in datos.puntos)
      PuntoEnMapa(id: x.id, lat: x.lat, lng: x.lng, color: colorEquipo(x.comoEquipo), nombre: x.nombre),
  ];

  void _abre(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => MapaPage(titulo: titulo, puntos: datos.puntos)),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      // Quieto dentro de la lista (si no, arrastrarlo pelearía con el
      // desplazamiento): tocarlo lo abre en grande.
      SizedBox(
        height: 220,
        child: Mapa(puntos: _puntos, interactivo: false, alTocar: () => _abre(context)),
      ),
      const SizedBox(height: 6),
      Row(
        children: [
          Expanded(
            child: Text('${datos.puntos.length} con ubicación de ${datos.total}', style: apagado(context, tamano: 13)),
          ),
          TextButton.icon(
            onPressed: () => _abre(context),
            icon: const Icon(Icons.open_in_full, size: 16),
            label: const Text('Ver en grande'),
          ),
        ],
      ),
    ],
  );
}
