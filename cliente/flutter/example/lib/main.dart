import 'package:device_track_flutter/device_track_flutter.dart';
import 'package:flutter/material.dart';

/// Una app mínima con device-track. En una app de verdad el código de alta va
/// compilado y `DeviceTrack` se crea en `main`; aquí se escribe en un campo
/// para poder probar con cualquier organización.
void main() => runApp(const Ejemplo());

class Ejemplo extends StatelessWidget {
  const Ejemplo({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'device-track',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: const Inicio(),
      );
}

class Inicio extends StatefulWidget {
  const Inicio({super.key});

  @override
  State<Inicio> createState() => _InicioState();
}

class _InicioState extends State<Inicio> {
  final _servidor = TextEditingController(text: 'https://devicetrack.chalonasoft.com');
  final _codigo = TextEditingController();
  DeviceTrack? _equipos;

  void _iniciar() {
    final equipos = DeviceTrack(
      servidor: _servidor.text,
      codigo: _codigo.text,
      contexto: () => {'app': 'ejemplo', 'sesion': false},
      alOrden: _alOrden,
    );
    setState(() => _equipos = equipos);
    equipos.iniciar();
  }

  /// `mensaje` desde el panel: un aviso en pantalla.
  Future<bool> _alOrden(Orden orden) async {
    if (!mounted) return false;
    final titulo = orden.texto('titulo');
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(titulo.isEmpty ? 'Aviso' : titulo),
        content: Text(orden.texto('texto')),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Entendido'))],
      ),
    );
    return true;
  }

  @override
  void dispose() {
    _equipos?.dispose();
    _servidor.dispose();
    _codigo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final equipos = _equipos;
    return Scaffold(
      appBar: AppBar(title: const Text('device-track')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: equipos == null ? _formulario() : [_Estado(equipos)],
      ),
    );
  }

  List<Widget> _formulario() => [
        const Text('El código de alta sale en el panel: Códigos de alta → Crear.'),
        const SizedBox(height: 16),
        TextField(
          controller: _servidor,
          decoration: const InputDecoration(labelText: 'Hub', border: OutlineInputBorder()),
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _codigo,
          decoration: const InputDecoration(labelText: 'Código de alta (dta_…)', border: OutlineInputBorder()),
          autocorrect: false,
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: _iniciar, child: const Text('Dar de alta y reportar')),
      ];
}

/// Lo que enseñaría una pantalla «Acerca de».
class _Estado extends StatelessWidget {
  const _Estado(this.equipos);

  final DeviceTrack equipos;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<EstadoDeviceTrack>(
        valueListenable: equipos.estado,
        builder: (context, e, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (e.sonando)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      const Text('Este equipo está sonando: lo están buscando.'),
                      const SizedBox(height: 8),
                      FilledButton(onPressed: equipos.detenerSonar, child: const Text('Ya lo encontré')),
                    ],
                  ),
                ),
              ),
            _fila('Equipo', e.dadoDeAlta ? '${e.equipoId} · ${e.equipoNombre}' : 'sin alta'),
            _fila('Conectado', e.conectado ? 'sí' : 'no'),
            _fila('Último reporte', e.ultimoReporte == null ? '—' : _hora(e.ultimoReporte!)),
            _fila('Por mandar', '${e.pendientes}'),
            _fila('Cada', '${e.config.intervaloS} s${e.config.ubicacion ? ', con ubicación' : ''}'),
            if (e.ultimoError != null) _fila('Último error', e.ultimoError!),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: equipos.reportar, child: const Text('Reportar ahora')),
          ],
        ),
      );

  Widget _fila(String nombre, String valor) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(nombre),
        trailing: Text(valor),
      );

  static String _hora(DateTime t) {
    final l = t.toLocal();
    String d(int n) => n.toString().padLeft(2, '0');
    return '${d(l.hour)}:${d(l.minute)}:${d(l.second)}';
  }
}
