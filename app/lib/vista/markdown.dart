/// Dibuja lo que parte `modelo/markdown.dart`: títulos, párrafos, listas,
/// tablas (con desplazamiento a lo ancho), código, citas y líneas, con los
/// colores del tema. Un enlace es texto subrayado; qué hace al tocarlo lo
/// decide quien lo usa ([alEnlace]).
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../modelo/markdown.dart';
import '../tema.dart';

class MarkdownVista extends StatefulWidget {
  const MarkdownVista(this.texto, {super.key, this.alEnlace});
  final String texto;
  final void Function(String url)? alEnlace;

  @override
  State<MarkdownVista> createState() => _MarkdownVistaState();
}

class _MarkdownVistaState extends State<MarkdownVista> {
  late List<Bloque> _bloques = bloquesMarkdown(widget.texto);

  /// Los reconocedores de toques de los enlaces: se sueltan al rehacer.
  final _toques = <TapGestureRecognizer>[];

  @override
  void didUpdateWidget(MarkdownVista viejo) {
    super.didUpdateWidget(viejo);
    if (viejo.texto != widget.texto) _bloques = bloquesMarkdown(widget.texto);
  }

  @override
  void dispose() {
    _suelta();
    super.dispose();
  }

  void _suelta() {
    for (final t in _toques) {
      t.dispose();
    }
    _toques.clear();
  }

  @override
  Widget build(BuildContext context) {
    _suelta();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final (i, b) in _bloques.indexed) Padding(
        padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
        child: _bloque(context, b),
      )],
    );
  }

  Widget _bloque(BuildContext context, Bloque b) {
    final p = Paleta.de(context);
    switch (b) {
      case Titulo(:final nivel, :final texto):
        final tam = switch (nivel) { 1 => 20.0, 2 => 18.0, _ => 16.0 };
        return Text.rich(_linea(context, texto), style: TextStyle(fontSize: tam, fontWeight: FontWeight.w700));
      case Parrafo(:final texto):
        return Text.rich(_linea(context, texto));
      case Lista(:final items):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final it in items)
              Padding(
                padding: EdgeInsets.only(left: 4.0 + it.nivel * 16, top: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: it.numero != null ? 24 : 16,
                      child: Text(it.numero != null ? '${it.numero}.' : (it.nivel == 0 ? '•' : '◦')),
                    ),
                    Expanded(child: Text.rich(_linea(context, it.texto))),
                  ],
                ),
              ),
          ],
        );
      case Tabla(:final cabecera, :final filas, :final columnas):
        Widget celda(String t, {bool cabeza = false}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text.rich(
            _linea(context, t),
            style: TextStyle(fontSize: 13.5, fontWeight: cabeza ? FontWeight.w700 : null),
          ),
        );
        List<Widget> completa(List<String> f, {bool cabeza = false}) => [
          for (var j = 0; j < columnas; j++) celda(j < f.length ? f[j] : '', cabeza: cabeza),
        ];
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(color: p.borde, borderRadius: BorderRadius.circular(6)),
            children: [
              TableRow(decoration: BoxDecoration(color: p.fondo3), children: completa(cabecera, cabeza: true)),
              for (final f in filas) TableRow(children: completa(f)),
            ],
          ),
        );
      case Codigo(:final texto):
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: p.fondo3, borderRadius: BorderRadius.circular(8)),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(texto, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
          ),
        );
      case Cita(:final bloques):
        return Container(
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: p.borde, width: 3))),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: p.texto2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final x in bloques) _bloque(context, x)],
            ),
          ),
        );
      case Linea():
        return const Divider(height: 12);
    }
  }

  TextSpan _linea(BuildContext context, String texto) {
    final p = Paleta.de(context);
    return TextSpan(
      children: [
        for (final t in trozos(texto))
          TextSpan(
            text: t.texto,
            style: TextStyle(
              fontWeight: t.negrita ? FontWeight.w700 : null,
              fontStyle: t.cursiva ? FontStyle.italic : null,
              fontFamily: t.codigo ? 'monospace' : null,
              backgroundColor: t.codigo ? p.fondo3 : null,
              color: t.enlace != null ? p.marca : null,
              decoration: t.enlace != null ? TextDecoration.underline : null,
            ),
            recognizer: t.enlace == null || widget.alEnlace == null ? null : _toque(t.enlace!),
          ),
      ],
    );
  }

  TapGestureRecognizer _toque(String url) {
    final r = TapGestureRecognizer()..onTap = () => widget.alEnlace?.call(url);
    _toques.add(r);
    return r;
  }
}
