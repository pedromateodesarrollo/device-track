/// Las piezas que se repiten en todas las pantallas: el punto de conectado, la
/// pila, la pastilla del estado, los avisos y las confirmaciones. Las mismas
/// del panel web (`Bateria.vue`, `.estado-equipo`, `.nueva`).
library;

import 'package:flutter/material.dart';

import '../api/cliente.dart';
import '../modelo/formato.dart';
import '../tema.dart';

/// Texto gris, el `.apagado` del panel.
TextStyle apagado(BuildContext context, {double? tamano}) =>
    TextStyle(color: Paleta.de(context).texto2, fontSize: tamano);

/// El punto verde (conectado) o gris.
class Punto extends StatelessWidget {
  const Punto({super.key, required this.color, this.tamano = 9});
  final Color color;
  final double tamano;

  @override
  Widget build(BuildContext context) => Container(
    width: tamano,
    height: tamano,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// Una pila chica con su nivel y un rayo si está cargando. Roja por debajo
/// del 20 %, ámbar por debajo del 40 %.
class Bateria extends StatelessWidget {
  const Bateria({super.key, this.nivel, this.cargando = false});
  final int? nivel;
  final bool cargando;

  @override
  Widget build(BuildContext context) {
    final p = Paleta.de(context);
    final n = nivel;
    if (n == null) return Text('—', style: apagado(context));
    final color = n < 20 ? p.mal : (n < 40 ? p.tibio : p.ok);
    final borde = Theme.of(context).colorScheme.onSurface.withValues(alpha: .5);
    return Semantics(
      label: 'Batería $n %${cargando ? ', cargando' : ''}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 22,
            height: 12,
            padding: const EdgeInsets.all(1.5),
            decoration: BoxDecoration(border: Border.all(color: borde), borderRadius: BorderRadius.circular(3)),
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: (n.clamp(5, 100)) / 100,
              child: Container(
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(1)),
              ),
            ),
          ),
          Container(width: 2, height: 5, color: borde),
          if (cargando) Icon(Icons.bolt, size: 14, color: p.tibio),
          const SizedBox(width: 4),
          Text('$n %'),
        ],
      ),
    );
  }
}

/// «Activo», «Perdido»…, con su color.
class EstadoEquipo extends StatelessWidget {
  const EstadoEquipo(this.estado, {super.key});
  final String estado;

  @override
  Widget build(BuildContext context) {
    final (fondo, letra) = Paleta.de(context).deEstado(estado);
    return Pastilla(estados[estado] ?? estado, fondo: fondo, letra: letra);
  }
}

/// Una marca chica junto a un nombre: «2 alertas», «hecha», «tú».
class Pastilla extends StatelessWidget {
  const Pastilla(this.texto, {super.key, this.fondo, this.letra});
  final String texto;
  final Color? fondo;
  final Color? letra;

  /// Roja, con letra blanca: las alertas.
  factory Pastilla.roja(BuildContext context, String texto) =>
      Pastilla(texto, fondo: Paleta.de(context).mal, letra: Colors.white);

  @override
  Widget build(BuildContext context) {
    final p = Paleta.de(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: fondo ?? p.fondo3, borderRadius: BorderRadius.circular(99)),
      child: Text(
        texto,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: letra ?? p.texto2),
      ),
    );
  }
}

/// Un rótulo y su valor, uno debajo del otro en el teléfono: el `<dl>` del
/// panel.
class Dato extends StatelessWidget {
  const Dato(this.etiqueta, this.valor, {super.key, this.hijo});
  final String etiqueta;
  final String valor;

  /// En vez del texto, si el valor se dibuja (la pila).
  final Widget? hijo;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 128, child: Text(etiqueta, style: apagado(context, tamano: 14))),
        Expanded(child: hijo ?? SelectableText(valor.isEmpty ? '—' : valor)),
      ],
    ),
  );
}

/// El título de una sección dentro de una tarjeta.
class Titulo extends StatelessWidget {
  const Titulo(this.texto, {super.key, this.derecha});
  final String texto;
  final Widget? derecha;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Expanded(
          child: Text(texto, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: -.2)),
        ),
        ?derecha,
      ],
    ),
  );
}

/// Una tarjeta con su relleno.
class Tarjeta extends StatelessWidget {
  const Tarjeta({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.alTocar, this.borde});
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? alTocar;

  /// El borde de la izquierda, de color: la tarjeta de un equipo.
  final Color? borde;

  @override
  Widget build(BuildContext context) {
    Widget c = Padding(padding: padding, child: child);
    if (borde != null) {
      c = DecoratedBox(
        decoration: BoxDecoration(border: Border(left: BorderSide(color: borde!, width: 4))),
        child: c,
      );
    }
    return Card(child: alTocar == null ? c : InkWell(onTap: alTocar, child: c));
  }
}

/// Lo que se enseña mientras carga, si falló, o el contenido.
class Cargando extends StatelessWidget {
  const Cargando({super.key});

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()),
  );
}

class VistaError extends StatelessWidget {
  const VistaError(this.mensaje, {super.key, this.reintentar});
  final String mensaje;
  final VoidCallback? reintentar;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, size: 40, color: Paleta.de(context).texto2),
          const SizedBox(height: 12),
          Text(mensaje, textAlign: TextAlign.center),
          if (reintentar != null) ...[
            const SizedBox(height: 16),
            OutlinedButton(onPressed: reintentar, child: const Text('Reintentar')),
          ],
        ],
      ),
    ),
  );
}

/// Un texto en rojo, el `.aviso` del panel.
class Aviso extends StatelessWidget {
  const Aviso(this.texto, {super.key});
  final String texto;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Text(texto, style: TextStyle(color: Paleta.de(context).mal, fontSize: 14)),
  );
}

/// Lo que no hay: «Ninguna alerta abierta.»
class Vacio extends StatelessWidget {
  const Vacio(this.texto, {super.key, this.icono = Icons.inbox_outlined});
  final String texto;
  final IconData icono;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
    child: Column(
      children: [
        Icon(icono, size: 40, color: Paleta.de(context).texto2),
        const SizedBox(height: 12),
        Text(texto, textAlign: TextAlign.center, style: apagado(context)),
      ],
    ),
  );
}

/// Un aviso abajo. [error] lo pinta en rojo.
void avisa(BuildContext context, String texto, {bool error = false}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(texto),
        backgroundColor: error ? Paleta.de(context).mal : null,
        duration: Duration(seconds: error ? 6 : 4),
      ),
    );
}

/// El mensaje de un error para la persona: el del hub si lo trae.
String mensajeDe(Object e) => e is HubError ? e.mensaje : 'Algo falló: $e';

/// Pregunta antes de algo que no se deshace. `true` si dijo que sí.
Future<bool> confirma(
  BuildContext context, {
  required String titulo,
  required String texto,
  required String boton,
  bool peligro = false,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(titulo),
      content: Text(texto),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
        FilledButton(
          style: peligro ? FilledButton.styleFrom(backgroundColor: Paleta.de(c).mal) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(boton),
        ),
      ],
    ),
  );
  return r == true;
}

/// «hace 5 min» con la fecha completa al dejar el dedo encima.
class Hace extends StatelessWidget {
  const Hace(this.valor, {super.key, this.estilo});
  final Object? valor;
  final TextStyle? estilo;

  @override
  Widget build(BuildContext context) =>
      Tooltip(message: fecha(valor), child: Text(hace(valor), style: estilo));
}
