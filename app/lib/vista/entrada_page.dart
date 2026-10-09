/// Entrar: la dirección del hub (device-track se puede hospedar en cualquier
/// parte), el correo y la clave. Se guarda el hub y el token; la clave no.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/cliente.dart';
import '../sesion.dart';
import '../tema.dart';
import 'comun.dart';

class EntradaPage extends StatefulWidget {
  const EntradaPage({super.key});

  @override
  State<EntradaPage> createState() => _EntradaPageState();
}

class _EntradaPageState extends State<EntradaPage> {
  final _forma = GlobalKey<FormState>();
  late final _hub = TextEditingController(text: sesion.hub);
  final _correo = TextEditingController();
  final _clave = TextEditingController();
  bool _verClave = false;
  bool _entrando = false;
  String? _error;

  // «¿Olvidaste tu clave?» solo sale si el hub escrito tiene por dónde mandar
  // el enlace (`recuperar` de /salud: alguna organización con correo de
  // salida). Se pregunta al abrir y cada vez que cambia la dirección.
  bool _recuperable = false;
  Timer? _esperaHub;

  @override
  void initState() {
    super.initState();
    _consultaRecuperar();
  }

  Future<void> _consultaRecuperar() async {
    final hub = normalizaHub(_hub.text);
    var puede = false;
    if (hub != null) {
      final api = HubCliente(hub: hub);
      try {
        puede = (await api.get('/salud'))['recuperar'] == true;
      } on HubError {
        // Sin conexión o un hub viejo: sin recuperación, la entrada sigue igual.
      } finally {
        api.cierra();
      }
    }
    // Si mientras tanto cambió la dirección, esta respuesta ya no vale.
    if (mounted && normalizaHub(_hub.text) == hub) setState(() => _recuperable = puede);
  }

  void _hubCambio(String _) {
    _esperaHub?.cancel();
    _esperaHub = Timer(const Duration(milliseconds: 700), _consultaRecuperar);
  }

  Future<void> _recupera() async {
    final hub = normalizaHub(_hub.text);
    if (hub == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _Recuperar(hub: hub, correo: _correo.text.trim()),
    );
  }

  @override
  void dispose() {
    _esperaHub?.cancel();
    _hub.dispose();
    _correo.dispose();
    _clave.dispose();
    super.dispose();
  }

  Future<void> _entra() async {
    if (!_forma.currentState!.validate()) return;
    final hub = normalizaHub(_hub.text)!;
    setState(() {
      _entrando = true;
      _error = null;
    });
    try {
      await sesion.entra(hub: hub, correo: _correo.text, clave: _clave.text);
    } on HubError catch (e) {
      if (mounted) setState(() => _error = e.mensaje);
    } finally {
      if (mounted) setState(() => _entrando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Paleta.de(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _forma,
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            const TextSpan(text: 'device'),
                            TextSpan(text: '-track', style: TextStyle(color: p.marca)),
                          ],
                        ),
                        style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -1),
                      ),
                      const SizedBox(height: 4),
                      Text('Los teléfonos y terminales de tu empresa: dónde están y si siguen vivos.',
                          style: apagado(context)),
                      const SizedBox(height: 28),
                      if (sesion.aviso != null)
                        Container(
                          margin: const EdgeInsets.only(bottom: 16),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: p.malSuave,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: p.mal.withValues(alpha: .4)),
                          ),
                          child: Text(sesion.aviso!),
                        ),
                      TextFormField(
                        controller: _correo,
                        decoration: const InputDecoration(labelText: 'Correo'),
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email, AutofillHints.username],
                        textInputAction: TextInputAction.next,
                        validator: (v) => (v ?? '').contains('@') ? null : 'Escribe tu correo',
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _clave,
                        decoration: InputDecoration(
                          labelText: 'Clave',
                          suffixIcon: IconButton(
                            tooltip: _verClave ? 'Esconder la clave' : 'Ver la clave',
                            icon: Icon(_verClave ? Icons.visibility_off : Icons.visibility),
                            onPressed: () => setState(() => _verClave = !_verClave),
                          ),
                        ),
                        obscureText: !_verClave,
                        autofillHints: const [AutofillHints.password],
                        textInputAction: TextInputAction.go,
                        onFieldSubmitted: (_) => _entra(),
                        validator: (v) => (v ?? '').isEmpty ? 'Escribe tu clave' : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _hub,
                        decoration: const InputDecoration(
                          labelText: 'Dirección del hub',
                          helperText: 'La de tu organización. device-track se puede instalar en un servidor propio.',
                          helperMaxLines: 2,
                        ),
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        onChanged: _hubCambio,
                        validator: (v) => normalizaHub(v ?? '') == null ? 'Escribe la dirección, como devicetrack.miempresa.com' : null,
                      ),
                      if (_error != null) Aviso(_error!),
                      const SizedBox(height: 22),
                      FilledButton(
                        onPressed: _entrando ? null : _entra,
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                        child: Text(_entrando ? 'Entrando…' : 'Entrar'),
                      ),
                      if (_recuperable) ...[
                        const SizedBox(height: 8),
                        TextButton(onPressed: _recupera, child: const Text('¿Olvidaste tu clave?')),
                      ],
                      const SizedBox(height: 18),
                      Text(
                        'Se entra por invitación: quien administra tu organización te manda un enlace '
                        'para poner tu clave.',
                        style: apagado(context, tamano: 13),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pide el enlace para poner una clave nueva. El hub contesta lo mismo tenga o
/// no cuenta ese correo, así que el mensaje tampoco lo dice.
class _Recuperar extends StatefulWidget {
  const _Recuperar({required this.hub, required this.correo});

  final String hub;
  final String correo;

  @override
  State<_Recuperar> createState() => _RecuperarState();
}

class _RecuperarState extends State<_Recuperar> {
  late final _correo = TextEditingController(text: widget.correo);
  bool _mandando = false;
  bool _pedido = false;
  String? _error;

  @override
  void dispose() {
    _correo.dispose();
    super.dispose();
  }

  Future<void> _manda() async {
    if (!_correo.text.contains('@')) {
      setState(() => _error = 'Escribe tu correo');
      return;
    }
    setState(() {
      _mandando = true;
      _error = null;
    });
    final api = HubCliente(hub: widget.hub);
    try {
      await api.post('/v1/auth/recuperar', {'correo': _correo.text.trim()});
      if (mounted) setState(() => _pedido = true);
    } on HubError catch (e) {
      if (mounted) setState(() => _error = e.mensaje);
    } finally {
      api.cierra();
      if (mounted) setState(() => _mandando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_pedido) {
      return AlertDialog(
        title: const Text('Revisa tu correo'),
        content: Text(
          'Si ${_correo.text.trim()} tiene cuenta, te llegó un enlace para poner una clave nueva. '
          'Vence en 1 hora.\n\nSi no llega, mira en el correo no deseado o pídele uno a quien administra.',
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Listo'))],
      );
    }
    return AlertDialog(
      title: const Text('¿Olvidaste tu clave?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Te mandamos un enlace a tu correo para poner una clave nueva. Tu clave de ahora '
            'sigue valiendo hasta que la cambies.',
            style: apagado(context),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _correo,
            decoration: const InputDecoration(labelText: 'Correo'),
            keyboardType: TextInputType.emailAddress,
            autofocus: widget.correo.isEmpty,
            onSubmitted: (_) => _manda(),
          ),
          if (_error != null) Aviso(_error!),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: _mandando ? null : _manda,
          child: Text(_mandando ? 'Mandando…' : 'Mandar el enlace'),
        ),
      ],
    );
  }
}
