/// Más: el mapa, las reglas, las personas (solo quien administra) y la
/// cuenta, con la versión de la app y el enlace para instalarla en otro
/// teléfono.
library;

import 'package:apk_server_flutter/apk_server_flutter.dart';
import 'package:flutter/material.dart';

import '../actualizacion.dart';
import '../modelo/yo.dart';
import '../sesion.dart';
import '../tema.dart';
import 'comun.dart';
import 'cuenta_page.dart';
import 'mapa_page.dart';
import 'reglas_page.dart';
import 'usuarios_page.dart';

class MasPage extends StatelessWidget {
  const MasPage({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: sesion, builder: (context, _) => _cuerpo(context));

  Widget _cuerpo(BuildContext context) {
    final yo = sesion.yo;
    if (yo == null) return const Scaffold(body: Cargando());
    final p = Paleta.de(context);
    void abre(Widget pagina) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => pagina));
    return Scaffold(
      appBar: AppBar(title: const Text('Más')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Tarjeta(
            alTocar: () => abre(const CuentaPage()),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: p.marcaSuave,
                  foregroundColor: p.marca,
                  child: Text(yo.nombre.isEmpty ? '?' : yo.nombre.characters.first.toUpperCase()),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(yo.nombre, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      Text(
                        '${yo.organizacion} · ${Yo.rolesTexto[yo.rol] ?? yo.rol}'
                        '${yo.acotado ? ' · ${yo.alcanceTexto}' : ''}',
                        style: apagado(context, tamano: 13),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
          const SizedBox(height: 12),
          UpdateTarjeta(actualizacion),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.map_outlined),
                  title: const Text('Mapa'),
                  subtitle: const Text('Dónde están los equipos, con las zonas'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => abre(const MapaPage()),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.rule),
                  title: const Text('Reglas'),
                  subtitle: const Text('Qué se vigila y a quién se avisa'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => abre(const ReglasPage()),
                ),
                if (yo.esAdmin) ...[
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.group_outlined),
                    title: const Text('Usuarios'),
                    subtitle: const Text('Quién entra al panel y qué puede hacer'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => abre(const UsuariosPage()),
                  ),
                ],
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: const Text('Mi cuenta'),
                  subtitle: const Text('Tus datos, la clave, la versión y salir'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => abre(const CuentaPage()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Lo demás (códigos de alta, zonas, dominios, llaves, la organización) está en el panel web: ${sesion.hub}',
            style: apagado(context, tamano: 13),
          ),
        ],
      ),
    );
  }
}
