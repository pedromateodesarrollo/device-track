/// El chat con el asistente de IA de la organización, como `Asistente.vue`.
/// Las conversaciones son de cada persona. La respuesta llega en NDJSON
/// mientras el hub consulta: se ve qué está mirando. Lo que el asistente
/// propone cambiar sale como tarjeta con «Confirmar» y «Descartar»: nada
/// cambia hasta que la persona confirma.
///
/// La voz (`voz.dart`): si la organización la tiene (`yo.iaVoz`), con el
/// campo vacío el botón es un micrófono: la pregunta va por nota de voz y la
/// respuesta se oye. Lo escrito se contesta solo escrito; «Escuchar» lee
/// cualquier respuesta.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/cliente.dart';
import '../modelo/chat.dart';
import '../modelo/formato.dart';
import '../navegacion.dart';
import '../sesion.dart';
import '../sistema.dart';
import '../tema.dart';
import '../voz.dart';
import 'comun.dart';
import 'markdown.dart';

class AsistentePage extends StatefulWidget {
  const AsistentePage({super.key});

  @override
  State<AsistentePage> createState() => _AsistentePageState();
}

class _AsistentePageState extends State<AsistentePage> {
  final _texto = TextEditingController();
  final _foco = FocusNode();
  final _desplaza = ScrollController();

  List<ResumenConversacion> _conversaciones = const [];
  int? _actual;
  String _titulo = '';
  List<MensajeChat> _mensajes = [];
  bool _enviando = false;

  /// Lo que va haciendo mientras contesta: notas y consultas.
  final _avance = <String>[];
  String? _error;

  /// El error fue `conversacion_larga`: se ofrece empezar otra.
  bool _larga = false;

  // La nota de voz.
  bool get _conVoz => sesion.yo?.iaVoz ?? false;
  late final _locutor = Locutor(sesion.api)..addListener(_alHablar);
  bool _grabando = false;
  bool _escribiendoNota = false;
  int _segundosNota = 0;
  Timer? _reloj;
  DateTime _inicioNota = DateTime.now();

  static const _sugerencias = [
    '¿Qué equipos llevan más de un día sin reportar?',
    '¿Cuáles tienen la batería por debajo de 20 % ahora?',
    'Avísame por correo si una terminal baja de 15 % de batería',
    'Arma un tablero con los equipos por dominio y por estado',
  ];

  @override
  void initState() {
    super.initState();
    _cargaLista();
    navegacion.preguntaAsistente.addListener(_tomaPregunta);
    _tomaPregunta();
  }

  @override
  void dispose() {
    navegacion.preguntaAsistente.removeListener(_tomaPregunta);
    _reloj?.cancel();
    if (_grabando) cancelaNota();
    _locutor
      ..removeListener(_alHablar)
      ..callar()
      ..dispose();
    _texto.dispose();
    _foco.dispose();
    _desplaza.dispose();
    super.dispose();
  }

  /// La pregunta empezada que mandó otra pantalla («Quiero personalizar mi
  /// Resumen: »): va en una conversación nueva, con el cursor al final.
  void _tomaPregunta() {
    final p = navegacion.preguntaAsistente.value;
    if (p == null) return;
    navegacion.preguntaAsistente.value = null;
    if (_enviando) {
      _texto.text = p;
    } else {
      _nueva(texto: p);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _texto.selection = TextSelection.collapsed(offset: _texto.text.length);
      _foco.requestFocus();
    });
  }

  Future<void> _cargaLista() async {
    try {
      final r = await sesion.api.get('/v1/ia/conversaciones');
      if (!mounted) return;
      setState(() {
        _conversaciones = [
          for (final c in (r['conversaciones'] as List?) ?? const [])
            if (c is Map) ResumenConversacion.deJson(c.cast<String, Object?>()),
        ];
      });
    } catch (_) {
      // La lista es secundaria: el chat funciona igual.
    }
  }

  Future<void> _abre(int id) async {
    setState(() => _error = null);
    try {
      final c = Conversacion.deJson(await sesion.api.get('/v1/ia/conversaciones/$id'));
      if (!mounted) return;
      setState(() {
        _actual = c.id;
        _titulo = c.titulo;
        _mensajes = c.mensajes;
        _larga = false;
      });
      _baja();
    } catch (e) {
      if (mounted) setState(() => _error = mensajeDe(e));
    }
  }

  void _nueva({String texto = ''}) {
    setState(() {
      _actual = null;
      _titulo = '';
      _mensajes = [];
      _error = null;
      _larga = false;
      _texto.text = texto;
    });
  }

  Future<void> _borra(ResumenConversacion c) async {
    final si = await confirma(
      context,
      titulo: 'Borrar la conversación',
      texto: '«${c.titulo}» se borra con lo que se dijo. Lo que ya se hizo (reglas, tableros…) se queda.',
      boton: 'Borrar',
      peligro: true,
    );
    if (!si) return;
    try {
      await sesion.api.borra('/v1/ia/conversaciones/${c.id}');
      if (_actual == c.id) _nueva();
      await _cargaLista();
    } catch (e) {
      if (mounted) avisa(context, mensajeDe(e), error: true);
    }
  }

  void _baja() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_desplaza.hasClients) return;
      _desplaza.animateTo(
        _desplaza.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  void _alHablar() {
    if (mounted) setState(() {});
  }

  // ── La nota de voz ──

  Future<void> _empiezaNota() async {
    if (_enviando || _grabando || _escribiendoNota) return;
    setState(() => _error = null);
    await _locutor.callar();
    try {
      await empiezaNota();
    } on VozError catch (e) {
      if (mounted) setState(() => _error = e.mensaje);
      return;
    }
    if (!mounted) {
      cancelaNota();
      return;
    }
    _inicioNota = DateTime.now();
    setState(() {
      _grabando = true;
      _segundosNota = 0;
    });
    _reloj = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final s = DateTime.now().difference(_inicioNota).inSeconds;
      if (s != _segundosNota && mounted) setState(() => _segundosNota = s);
      if (s >= maxSegundosNota) _terminaNota();
    });
  }

  void _cancelaNota() {
    _reloj?.cancel();
    cancelaNota();
    setState(() => _grabando = false);
  }

  Future<void> _terminaNota() async {
    if (!_grabando) return;
    _reloj?.cancel();
    setState(() {
      _grabando = false;
      _escribiendoNota = true;
    });
    var dicho = '';
    try {
      final nota = await terminaNota();
      if (nota == null) {
        _error = 'No se grabó nada: mantén el micrófono abierto mientras hablas.';
      } else {
        dicho = await transcribe(sesion.api, nota);
      }
    } on HubError catch (e) {
      _error = explicaIa(e.codigo, e.mensaje);
    } finally {
      if (mounted) setState(() => _escribiendoNota = false);
    }
    if (dicho.isNotEmpty && mounted) _envia(dicho, true);
  }

  Future<void> _envia([String? pregunta, bool voz = false]) async {
    final mensaje = (pregunta ?? _texto.text).trim();
    if (mensaje.isEmpty || _enviando) return;
    _locutor.callar();
    final persona = MensajeChat(deLaPersona: true, texto: mensaje, voz: voz);
    final respuesta = MensajeChat(deLaPersona: false);
    setState(() {
      _error = null;
      _larga = false;
      _enviando = true;
      _avance.clear();
      _texto.clear();
      _mensajes = [..._mensajes, persona, respuesta];
    });
    _baja();

    // La pregunta no quedó en la conversación: se quita de la vista y vuelve
    // al campo para intentarlo otra vez.
    void deshace(String porque, {bool larga = false}) {
      _mensajes = [for (final m in _mensajes) if (!identical(m, persona) && !identical(m, respuesta)) m];
      _texto.text = mensaje;
      _error = porque;
      _larga = larga;
    }

    try {
      final eventos = await sesion.api.chat({
        'mensaje': mensaje,
        'conversacion': ?_actual,
        'desfase_min': DateTime.now().timeZoneOffset.inMinutes,
        if (voz) 'voz': true,
      });
      await for (final e in eventos) {
        if (!mounted) return;
        setState(() {
          switch (e) {
            case EventoConversacion(:final id, :final titulo):
              if (_actual != id) {
                _actual = id;
                _titulo = titulo;
              }
            case EventoNota(:final texto):
              _avance.add(texto);
            case EventoHerramienta(:final nombre, :final titulo):
              _avance.add('$titulo…');
              respuesta.herramientas.add(HerramientaUsada(nombre: nombre, titulo: titulo));
            case EventoPropuesta(:final propuesta):
              respuesta.propuestas.add(propuesta);
            case EventoRespuesta(:final texto):
              respuesta.texto = texto;
            case EventoError():
              deshace(e.paraLaPersona);
            case EventoFin() || EventoIlegible():
              break;
          }
        });
        _baja();
      }
      // Se cortó sin respuesta ni error: la pregunta no se guardó.
      if (mounted && respuesta.texto.isEmpty && _mensajes.contains(respuesta)) {
        setState(() => deshace('El hub cortó la respuesta. Vuelve a intentarlo.'));
      }
    } on HubError catch (e) {
      if (mounted) {
        setState(() => deshace(
              e.codigo == 'conversacion_larga' ? e.mensaje : explicaIa(e.codigo, e.mensaje),
              larga: e.codigo == 'conversacion_larga',
            ));
      }
    } finally {
      if (mounted) {
        setState(() {
          _enviando = false;
          _avance.clear();
        });
        _cargaLista();
        _baja();
      }
    }
    // Lo que se preguntó con la voz se contesta en voz.
    if (voz && mounted && respuesta.texto.isNotEmpty && _mensajes.contains(respuesta)) {
      _locutor.decir(respuesta, respuesta.texto);
    }
  }

  void _enlace(String url) async {
    if (!await navegacion.enlace(url) && mounted) avisa(context, 'Ese enlace no se puede abrir aquí: $url');
  }

  void _conversacionesHoja() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .6,
        maxChildSize: .92,
        builder: (c, desplaza) => StatefulBuilder(
          builder: (c, refresca) => ListView(
            controller: desplaza,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(c);
                    _nueva();
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Conversación nueva'),
                ),
              ),
              if (_conversaciones.isEmpty)
                const Padding(padding: EdgeInsets.all(16), child: Text('Todavía no hay conversaciones.')),
              for (final x in _conversaciones)
                ListTile(
                  selected: x.id == _actual,
                  title: Text(x.titulo.isEmpty ? 'Sin título' : x.titulo, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(hace(x.actualizado)),
                  onTap: () {
                    Navigator.pop(c);
                    _abre(x.id);
                  },
                  trailing: IconButton(
                    tooltip: 'Borrar la conversación',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await _borra(x);
                      refresca(() {});
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titulo.isEmpty ? 'Asistente' : _titulo, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Conversación nueva',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: _enviando ? null : _nueva,
          ),
          IconButton(tooltip: 'Conversaciones', icon: const Icon(Icons.history), onPressed: _conversacionesHoja),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _mensajes.isEmpty
                ? _vacio()
                : ListView.builder(
                    controller: _desplaza,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    itemCount: _mensajes.length,
                    itemBuilder: (_, i) => _burbuja(_mensajes[i], ultimo: i == _mensajes.length - 1),
                  ),
          ),
          if (_locutor.error != null && _error == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Aviso(_locutor.error!),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Row(
                children: [
                  Expanded(child: Aviso(_error!)),
                  if (_larga) TextButton(onPressed: () => _nueva(texto: _texto.text), child: const Text('Empezar otra')),
                ],
              ),
            ),
          _entrada(),
        ],
      ),
    );
  }

  Widget _vacio() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Icon(Icons.auto_awesome, size: 36, color: Paleta.de(context).marca),
      const SizedBox(height: 12),
      Text(
        'Pregúntale por tus equipos, pídele un reporte, que te avise de algo o que te arme un tablero. '
        'Ve y hace solo lo que tú puedes; lo que cambie algo te lo propone y lo confirmas tú.',
        style: apagado(context),
      ),
      const SizedBox(height: 16),
      for (final s in _sugerencias)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: OutlinedButton(
            onPressed: () => _envia(s),
            style: OutlinedButton.styleFrom(alignment: Alignment.centerLeft, padding: const EdgeInsets.all(12)),
            child: Text(s),
          ),
        ),
    ],
  );

  Widget _entrada() => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: _grabando
          ? _grabandoNota()
          : _escribiendoNota
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Text('Escribiendo lo que dijiste…', style: apagado(context)),
                ],
              ),
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _texto,
                    focusNode: _foco,
                    enabled: !_enviando,
                    minLines: 1,
                    maxLines: 6,
                    maxLength: 8000,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: _conVoz ? 'Escribe o toca el micrófono…' : 'Escribe tu pregunta…',
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Con el campo vacío y voz, el botón es el micrófono.
                ValueListenableBuilder(
                  valueListenable: _texto,
                  builder: (_, v, _) => _conVoz && v.text.trim().isEmpty && !_enviando
                      ? IconButton.filled(
                          tooltip: 'Preguntar con una nota de voz',
                          onPressed: _empiezaNota,
                          icon: const Icon(Icons.mic),
                        )
                      : IconButton.filled(
                          tooltip: 'Enviar',
                          onPressed: _enviando ? null : _envia,
                          icon: _enviando
                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.send),
                        ),
                ),
              ],
            ),
    ),
  );

  Widget _grabandoNota() {
    final p = Paleta.de(context);
    return Row(
      children: [
        const SizedBox(width: 4),
        Icon(Icons.fiber_manual_record, color: p.mal, size: 16),
        const SizedBox(width: 6),
        Text(duracion(_segundosNota), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
        Text(' / ${duracion(maxSegundosNota)}', style: apagado(context, tamano: 12)),
        const SizedBox(width: 10),
        Expanded(child: Text('Habla…', style: apagado(context), overflow: TextOverflow.ellipsis)),
        IconButton(tooltip: 'Cancelar la nota', onPressed: _cancelaNota, icon: const Icon(Icons.close)),
        IconButton.filled(tooltip: 'Enviar la nota', onPressed: _terminaNota, icon: const Icon(Icons.send)),
      ],
    );
  }

  Widget _burbuja(MensajeChat m, {required bool ultimo}) {
    final p = Paleta.de(context);
    final ancho = MediaQuery.sizeOf(context).width * .86;
    if (m.deLaPersona) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(maxWidth: ancho),
          margin: const EdgeInsets.only(bottom: 10, left: 32),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: p.marca, borderRadius: BorderRadius.circular(14)),
          child: m.voz
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2, right: 6),
                      child: Icon(Icons.mic, size: 16, color: Colors.white70),
                    ),
                    Flexible(child: SelectableText(m.texto, style: const TextStyle(color: Colors.white))),
                  ],
                )
              : SelectableText(m.texto, style: const TextStyle(color: Colors.white)),
        ),
      );
    }
    final escribiendo = _enviando && ultimo && m.texto.isEmpty;
    final consultas = {for (final h in m.herramientas) h.titulo}.toList();
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: p.fondo2,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: p.borde),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (consultas.isNotEmpty && !escribiendo)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('Consultó: ${consultas.join(' · ')}', style: apagado(context, tamano: 12)),
              ),
            if (escribiendo) ...[
              for (final a in _avance)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(a, style: a.endsWith('…') ? apagado(context, tamano: 14) : null),
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Text(_avance.isEmpty ? 'Pensando…' : 'Consultando…', style: apagado(context, tamano: 14)),
                ],
              ),
            ],
            if (m.texto.isNotEmpty) SelectionArea(child: MarkdownVista(m.texto, alEnlace: _enlace)),
            if (_conVoz && m.texto.isNotEmpty && !escribiendo) _escuchar(m),
            for (final pr in m.propuestas) _TarjetaPropuesta(pr, alCambiar: () => setState(() {})),
          ],
        ),
      ),
    );
  }

  Widget _escuchar(MensajeChat m) {
    final suena = identical(_locutor.sonando, m);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: TextButton.icon(
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
        onPressed: () => suena ? _locutor.callar() : _locutor.decir(m, m.texto),
        icon: suena && _locutor.cargando
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(suena ? Icons.stop_circle_outlined : Icons.volume_up_outlined, size: 18),
        label: Text(suena ? (_locutor.cargando ? 'Preparando la voz…' : 'Callar') : 'Escuchar'),
      ),
    );
  }
}

/// Lo que el asistente propone hacer: su resumen, los argumentos legibles y
/// los botones. Confirmar lo ejecuta el hub con la sesión de quien confirma,
/// ahora: si entre tanto le quitaron el permiso, no se hace.
class _TarjetaPropuesta extends StatefulWidget {
  const _TarjetaPropuesta(this.p, {required this.alCambiar});
  final Propuesta p;
  final VoidCallback alCambiar;

  @override
  State<_TarjetaPropuesta> createState() => _TarjetaPropuestaState();
}

class _TarjetaPropuestaState extends State<_TarjetaPropuesta> {
  bool _ocupada = false;
  String? _error;

  Future<void> _resuelve(String accion) async {
    setState(() {
      _ocupada = true;
      _error = null;
    });
    try {
      final r = await sesion.api.post('/v1/ia/propuestas/${widget.p.id}/$accion');
      widget.p
        ..estado = texto(r['estado']) ?? widget.p.estado
        ..resultado = r['resultado'];
      widget.alCambiar();
    } on HubError catch (e) {
      // Ya se resolvió en otro lado o venció: lo dice el hub.
      if (e.codigo == 'propuesta_vencida') widget.p.vencida = true;
      _error = e.mensaje;
    } finally {
      if (mounted) setState(() => _ocupada = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pr = widget.p;
    final p = Paleta.de(context);
    final quedo = pr.comoQuedo;
    final enlace = pr.enlaceInvitacion;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Color.lerp(p.marca, p.borde, .55)!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(pr.titulo, style: apagado(context, tamano: 12)),
          const SizedBox(height: 2),
          Text(pr.resumen.isEmpty ? pr.titulo : pr.resumen, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final (k, v) in pr.argsLegibles)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 110, child: Text(k, style: apagado(context, tamano: 13))),
                  Expanded(child: Text(v, style: const TextStyle(fontSize: 13))),
                ],
              ),
            ),
          const SizedBox(height: 10),
          if (_error != null) Aviso(_error!),
          if (pr.pendiente && !pr.vencida)
            Row(
              children: [
                FilledButton(onPressed: _ocupada ? null : () => _resuelve('confirmar'), child: const Text('Confirmar')),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: _ocupada ? null : () => _resuelve('descartar'), child: const Text('Descartar')),
                if (_ocupada) ...[
                  const SizedBox(width: 12),
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ],
            )
          else if (pr.pendiente)
            Text('Venció: pídesela de nuevo.', style: apagado(context, tamano: 13))
          else if (quedo != null)
            Text(
              quedo,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: pr.estado == 'fallida' ? p.mal : (pr.estado == 'hecha' ? p.ok : p.texto2),
              ),
            ),
          if (enlace != null) ...[
            const SizedBox(height: 8),
            Text('Enlace de la invitación (sirve una vez y vence en 7 días):', style: apagado(context, tamano: 13)),
            SelectableText(enlace, style: const TextStyle(fontSize: 13)),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: enlace));
                    if (context.mounted) avisa(context, 'Enlace copiado.');
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copiar'),
                ),
                TextButton.icon(
                  onPressed: () => compartir(enlace, asunto: 'Invitación al panel de device-track'),
                  icon: const Icon(Icons.share, size: 18),
                  label: const Text('Compartir'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
