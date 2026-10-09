/// Mi cuenta: quién soy y qué puedo, cambiar la clave, la versión de la app
/// (buscar actualización y el enlace para instalarla en otro teléfono) y
/// salir. Como `Cuenta.vue`.
library;

import 'package:apk_server_flutter/apk_server_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../actualizacion.dart';
import '../modelo/yo.dart';
import '../sesion.dart';
import '../sistema.dart';
import 'comun.dart';

/// De dónde se instala la app, si apk-server todavía no lo dijo.
const _instalarPorDefecto = 'https://apk.chalonasoft.com/i/devicetrack-panel';

class CuentaPage extends StatefulWidget {
  const CuentaPage({super.key});

  @override
  State<CuentaPage> createState() => _CuentaPageState();
}

class _CuentaPageState extends State<CuentaPage> {
  final _forma = GlobalKey<FormState>();
  final _actual = TextEditingController();
  final _nueva = TextEditingController();
  final _otra = TextEditingController();
  bool _cambiando = false;
  bool _buscando = false;
  String? _error;
  VersionApp? _version;

  @override
  void initState() {
    super.initState();
    versionApp().then((v) {
      if (mounted) setState(() => _version = v);
    });
  }

  @override
  void dispose() {
    _actual.dispose();
    _nueva.dispose();
    _otra.dispose();
    super.dispose();
  }

  String get _urlInstalar => actualizacion.urlInstalar ?? _instalarPorDefecto;

  Future<void> _cambiaClave() async {
    if (!_forma.currentState!.validate()) return;
    setState(() {
      _cambiando = true;
      _error = null;
    });
    try {
      await sesion.api.post('/v1/usuarios/${sesion.yo!.id}/clave', {'actual': _actual.text, 'clave': _nueva.text});
      _actual.clear();
      _nueva.clear();
      _otra.clear();
      if (mounted) avisa(context, 'Listo: la clave cambió.');
    } catch (e) {
      if (mounted) setState(() => _error = mensajeDe(e));
    } finally {
      if (mounted) setState(() => _cambiando = false);
    }
  }

  Future<void> _busca() async {
    setState(() => _buscando = true);
    try {
      await actualizacion.verificarYDescargar(forzar: true);
    } finally {
      if (mounted) setState(() => _buscando = false);
    }
    if (!mounted) return;
    final e = actualizacion.estado.value;
    if (e.fase != UpdateFase.descargando && e.fase != UpdateFase.listo && e.fase != UpdateFase.instalando) {
      avisa(context, e.fase == UpdateFase.error ? 'No se pudo preguntar por versiones nuevas.' : 'Ya tienes la última versión.');
    }
  }

  Future<void> _sale() async {
    final si = await confirma(
      context,
      titulo: 'Salir',
      texto: 'Se olvida la sesión en este teléfono. Para volver a entrar hace falta la clave.',
      boton: 'Salir',
    );
    if (!si) return;
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    await sesion.sale();
  }

  @override
  Widget build(BuildContext context) {
    final yo = sesion.yo;
    if (yo == null) return const Scaffold(body: Cargando());
    return Scaffold(
      appBar: AppBar(title: const Text('Mi cuenta')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          Tarjeta(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Titulo('Tus datos'),
                Dato('Nombre', yo.nombre),
                Dato('Correo', yo.correo),
                Dato('Organización', yo.organizacion),
                Dato('Rol', Yo.rolesTexto[yo.rol] ?? yo.rol),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(Yo.rolesExplica[yo.rol] ?? '', style: apagado(context, tamano: 13)),
                ),
                if (yo.acotado)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Ves solo los equipos de ${yo.alcanceTexto}, con sus zonas, reglas, alertas y códigos de alta. '
                      'Para ver más, pídeselo a quien administra.',
                      style: apagado(context, tamano: 13),
                    ),
                  ),
                Dato('Hub', sesion.hub),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Tarjeta(
            child: Form(
              key: _forma,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Titulo('Cambiar la clave'),
                  TextFormField(
                    controller: _actual,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: const InputDecoration(labelText: 'Clave actual'),
                    validator: (v) => (v ?? '').isEmpty ? 'Escribe tu clave de ahora' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _nueva,
                    obscureText: true,
                    autofillHints: const [AutofillHints.newPassword],
                    decoration: const InputDecoration(labelText: 'Clave nueva', helperText: '10 caracteres o más'),
                    validator: (v) => (v ?? '').length < 10 ? 'La clave necesita 10 caracteres o más' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _otra,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'La clave nueva otra vez'),
                    validator: (v) => v != _nueva.text ? 'Las dos claves nuevas no coinciden' : null,
                  ),
                  if (_error != null) Aviso(_error!),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: _cambiando ? null : _cambiaClave,
                    child: Text(_cambiando ? 'Cambiando…' : 'Cambiar la clave'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Tarjeta(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Titulo('La app'),
                Dato('Versión', _version?.toString() ?? '…'),
                const SizedBox(height: 8),
                UpdateTarjeta(actualizacion),
                OutlinedButton.icon(
                  onPressed: _buscando ? null : _busca,
                  icon: _buscando
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.system_update_outlined),
                  label: Text(_buscando ? 'Buscando…' : 'Buscar actualización'),
                ),
                const SizedBox(height: 16),
                const Text('Instalarla en otro teléfono', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                  'Abre este enlace en el teléfono (Android) y toca «Instalar». Después se actualiza sola.',
                  style: apagado(context, tamano: 13),
                ),
                const SizedBox(height: 6),
                SelectableText(_urlInstalar, style: const TextStyle(fontSize: 14)),
                Wrap(
                  spacing: 4,
                  children: [
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: _urlInstalar));
                        if (context.mounted) avisa(context, 'Enlace copiado.');
                      },
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Copiar'),
                    ),
                    TextButton.icon(
                      onPressed: () => compartir(
                        'Instala el panel de device-track en tu teléfono: $_urlInstalar',
                        asunto: 'device-track en el teléfono',
                      ),
                      icon: const Icon(Icons.share, size: 18),
                      label: const Text('Compartir'),
                    ),
                    TextButton.icon(
                      onPressed: () => abrir(_urlInstalar),
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('Abrir'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: _sale,
            icon: const Icon(Icons.logout),
            label: const Text('Salir'),
          ),
        ],
      ),
    );
  }
}
