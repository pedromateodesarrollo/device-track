/// Las personas del panel (`GET /v1/usuarios`), solo para quien administra:
/// invitar, mandar otro enlace y cambiar el rol. Como `Usuarios.vue`.
///
/// Se entra por invitación: la persona pone su propia clave con el enlace, y
/// quien invita nunca la ve. Si la organización tiene correo de salida, el
/// enlace le llega por correo; si no, se comparte desde aquí.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../modelo/equipo.dart' show Json;
import '../modelo/formato.dart';
import '../modelo/yo.dart';
import '../sesion.dart';
import '../sistema.dart';
import '../tema.dart';
import 'comun.dart';

class UsuariosPage extends StatefulWidget {
  const UsuariosPage({super.key});

  @override
  State<UsuariosPage> createState() => _UsuariosPageState();
}

class _UsuariosPageState extends State<UsuariosPage> {
  List<Json> _usuarios = const [];
  List<Dominio> _dominios = const [];
  bool _cargando = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _carga();
    sesion.api.get('/v1/dominios').then((r) {
      if (!mounted) return;
      setState(() {
        _dominios = [
          for (final d in (r['dominios'] as List?) ?? const [])
            if (d is Map) Dominio.deJson(d.cast<String, Object?>()),
        ];
      });
    }).catchError((_) {});
  }

  Future<void> _carga() async {
    try {
      final r = await sesion.api.get('/v1/usuarios');
      if (!mounted) return;
      setState(() {
        _usuarios = [for (final u in (r['usuarios'] as List?) ?? const []) if (u is Map) u.cast<String, Object?>()];
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = mensajeDe(e));
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  String _alcance(Json u) {
    final ids = [for (final d in (u['dominios'] as List?) ?? const []) entero(d)];
    if (ids.isEmpty) return 'Toda la organización';
    return ids.map((id) => _dominios.where((d) => d.id == id).map((d) => d.nombre).firstOrNull ?? '#$id').join(', ');
  }

  Future<void> _invita() async {
    final r = await Navigator.of(context).push<_Resultado>(
      MaterialPageRoute(builder: (_) => _InvitarPage(dominios: _dominios)),
    );
    await _carga();
    if (r != null && mounted) await _muestraEnlace(r);
  }

  Future<void> _reinvita(Json u) async {
    try {
      final r = await sesion.api.post('/v1/usuarios/${u['id']}/invitacion');
      if (!mounted) return;
      await _carga();
      await _muestraEnlace(_Resultado('${u['correo']}', '${r['enlace'] ?? ''}', r['envio']));
    } catch (e) {
      if (mounted) avisa(context, mensajeDe(e), error: true);
    }
  }

  Future<void> _cambiaRol(Json u, String rol) async {
    if (rol == u['rol']) return;
    try {
      // Un administrador ve toda la organización: pasar a admin le quita los
      // límites que tuviera.
      await sesion.api.patch('/v1/usuarios/${u['id']}', {'rol': rol, if (rol == 'admin') 'dominios': <int>[]});
      if (mounted) avisa(context, '${u['nombre']} ahora es ${Yo.rolesTexto[rol]?.toLowerCase() ?? rol}.');
    } catch (e) {
      if (mounted) avisa(context, mensajeDe(e), error: true);
    }
    await _carga();
  }

  Future<void> _muestraEnlace(_Resultado r) =>
      showDialog<void>(context: context, builder: (_) => _DialogoEnlace(r));

  @override
  Widget build(BuildContext context) {
    final yo = sesion.yo;
    return Scaffold(
      appBar: AppBar(title: const Text('Usuarios')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _invita,
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Invitar'),
      ),
      body: RefreshIndicator(
        onRefresh: _carga,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const _QuePuedeCadaRol(),
            const SizedBox(height: 14),
            if (_error != null) Aviso(_error!),
            if (_cargando)
              const Cargando()
            else
              for (final u in _usuarios) ...[
                _tarjeta(u, esYo: entero(u['id']) == yo?.id),
                const SizedBox(height: 10),
              ],
          ],
        ),
      ),
    );
  }

  Widget _tarjeta(Json u, {required bool esYo}) {
    final activo = u['activo'] == true;
    final rol = '${u['rol'] ?? ''}';
    final verAlcance = _dominios.length > 1 || ((u['dominios'] as List?)?.isNotEmpty ?? false);
    return Tarjeta(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${u['nombre'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    Text('${u['correo'] ?? ''}', style: apagado(context, tamano: 13)),
                    // Debajo y no al lado: a la derecha le quitaba ancho al
                    // correo, que se partía a media palabra («…@gmai / l.com»).
                    if (esYo)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Pastilla('${Yo.rolesTexto[rol] ?? rol} (tú)'),
                      ),
                  ],
                ),
              ),
              if (!esYo)
                PopupMenuButton<String>(
                  tooltip: 'Cambiar el rol',
                  initialValue: rol,
                  onSelected: (r) => _cambiaRol(u, r),
                  itemBuilder: (_) => [
                    for (final r in Yo.rolesTexto.entries)
                      CheckedPopupMenuItem(value: r.key, checked: r.key == rol, child: Text(r.value)),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [Text(Yo.rolesTexto[rol] ?? rol), const Icon(Icons.arrow_drop_down)],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            activo ? 'Entró ${hace(u['ultimo_acceso'])}' : 'Invitado, sin entrar todavía',
            style: apagado(context, tamano: 13),
          ),
          if (verAlcance) Text('Ve: ${_alcance(u)}', style: apagado(context, tamano: 13)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _reinvita(u),
              icon: const Icon(Icons.link, size: 18),
              label: Text(activo ? 'Enlace para clave nueva' : 'Otro enlace'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Qué puede cada rol, en pantalla: quien invita tiene que saberlo antes de
/// elegir.
class _QuePuedeCadaRol extends StatelessWidget {
  const _QuePuedeCadaRol();

  @override
  Widget build(BuildContext context) => Tarjeta(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Titulo('Qué puede cada rol'),
        for (final r in const ['consulta', 'editor', 'admin'])
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${Yo.rolesTexto[r]}: ', style: const TextStyle(fontWeight: FontWeight.w700)),
                  TextSpan(text: Yo.rolesExplica[r]),
                ],
              ),
              style: const TextStyle(fontSize: 14),
            ),
          ),
      ],
    ),
  );
}

/// El enlace de una invitación y si salió por correo.
class _Resultado {
  const _Resultado(this.correo, this.enlace, this.envio);
  final String correo;
  final String enlace;

  /// `null` (sin correo de salida), `{enviado: true, para}` o
  /// `{enviado: false, error, detalle}`.
  final Object? envio;
}

class _DialogoEnlace extends StatelessWidget {
  const _DialogoEnlace(this.r);
  final _Resultado r;

  @override
  Widget build(BuildContext context) {
    final envio = r.envio is Map ? (r.envio as Map).cast<String, Object?>() : null;
    final salio = envio?['enviado'] == true;
    final String explica;
    if (salio) {
      explica = 'Le mandamos la invitación por correo a ${r.correo}. Por si no le llega, este es el enlace: '
          'sirve una vez y vence en 7 días.';
    } else if (envio != null) {
      explica = 'El correo no salió (${texto(envio['detalle']) ?? texto(envio['error']) ?? 'sin detalle'}). '
          'Revisa el correo de salida de la organización en el panel web; mientras, compártele este enlace. '
          'Sirve una vez y vence en 7 días.';
    } else {
      explica = 'La organización no tiene correo de salida: mándale este enlace a ${r.correo} por donde quieras. '
          'Con él pone su propia clave. Sirve una vez y vence en 7 días.';
    }
    return AlertDialog(
      icon: Icon(salio ? Icons.mark_email_read_outlined : Icons.link, color: salio ? Paleta.de(context).ok : null),
      title: Text(salio ? 'Invitación enviada' : 'Enlace de invitación'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(explica),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Paleta.de(context).fondo3, borderRadius: BorderRadius.circular(8)),
            child: SelectableText(r.enlace, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        ],
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: r.enlace));
            if (context.mounted) avisa(context, 'Enlace copiado.');
          },
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copiar'),
        ),
        TextButton.icon(
          onPressed: () => compartir(
            'Te invitaron al panel de device-track. Pon tu clave aquí (sirve una vez y vence en 7 días): ${r.enlace}',
            asunto: 'Invitación al panel de device-track',
          ),
          icon: const Icon(Icons.share, size: 18),
          label: const Text('Compartir'),
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Listo')),
      ],
    );
  }
}

class _InvitarPage extends StatefulWidget {
  const _InvitarPage({required this.dominios});
  final List<Dominio> dominios;

  @override
  State<_InvitarPage> createState() => _InvitarPageState();
}

class _InvitarPageState extends State<_InvitarPage> {
  final _forma = GlobalKey<FormState>();
  final _correo = TextEditingController();
  final _nombre = TextEditingController();
  String _rol = 'editor';

  /// Los dominios a los que se limita. Ninguno = toda la organización.
  final _elegidos = <int>{};
  bool _enviando = false;
  String? _error;

  @override
  void dispose() {
    _correo.dispose();
    _nombre.dispose();
    super.dispose();
  }

  Future<void> _invita() async {
    if (!_forma.currentState!.validate()) return;
    setState(() {
      _enviando = true;
      _error = null;
    });
    try {
      final u = await sesion.api.post('/v1/usuarios', {
        'correo': _correo.text.trim(),
        'nombre': _nombre.text.trim(),
        'rol': _rol,
        'dominios': _rol == 'admin' ? <int>[] : _elegidos.toList(),
      });
      if (!mounted) return;
      Navigator.pop(context, _Resultado('${u['correo'] ?? _correo.text.trim()}', '${u['enlace'] ?? ''}', u['envio']));
    } catch (e) {
      if (mounted) setState(() => _error = mensajeDe(e));
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final variosDominios = widget.dominios.length > 1;
    return Scaffold(
      appBar: AppBar(title: const Text('Invitar a alguien')),
      body: Form(
        key: _forma,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Text(
              'Si la organización tiene correo de salida, le llega la invitación; si no, te damos un enlace '
              'y tú se lo pasas. Tú nunca ves su clave.',
              style: apagado(context, tamano: 14),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _correo,
              decoration: const InputDecoration(labelText: 'Correo'),
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              validator: (v) => (v ?? '').trim().contains('@') ? null : 'Revisa el correo',
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _nombre,
              decoration: const InputDecoration(labelText: 'Nombre', helperText: 'Si lo dejas vacío, sale del correo.'),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 18),
            const Text('Rol', style: TextStyle(fontWeight: FontWeight.w700)),
            RadioGroup<String>(
              groupValue: _rol,
              onChanged: (v) => setState(() => _rol = v ?? _rol),
              child: Column(
                children: [
                  for (final r in const ['consulta', 'editor', 'admin'])
                    RadioListTile<String>(
                      value: r,
                      contentPadding: EdgeInsets.zero,
                      title: Text(Yo.rolesTexto[r]!),
                      subtitle: Text(Yo.rolesExplica[r]!),
                    ),
                ],
              ),
            ),
            if (variosDominios && _rol != 'admin') ...[
              const SizedBox(height: 10),
              const Text('Qué equipos ve', style: TextStyle(fontWeight: FontWeight.w700)),
              for (final d in widget.dominios)
                CheckboxListTile(
                  value: _elegidos.contains(d.id),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(d.nombre),
                  onChanged: (v) => setState(() => v == true ? _elegidos.add(d.id) : _elegidos.remove(d.id)),
                ),
              Text(
                _elegidos.isEmpty
                    ? 'Sin marcar ninguno: toda la organización.'
                    : 'Solo los de esos dominios, con sus zonas, reglas, alertas y códigos de alta.',
                style: apagado(context, tamano: 13),
              ),
            ],
            if (_error != null) Aviso(_error!),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _enviando ? null : _invita,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: Text(_enviando ? 'Invitando…' : 'Invitar'),
            ),
          ],
        ),
      ),
    );
  }
}
