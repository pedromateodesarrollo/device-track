/// La lista de equipos, con búsqueda y filtros, en tarjetas como las del
/// panel web en el teléfono (`Equipos.vue`): el estado, la batería, si está
/// conectado o cuándo se vio, qué app reporta y quién lo tenía.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../modelo/equipo.dart';
import '../modelo/formato.dart';
import '../modelo/yo.dart' show Dominio;
import '../navegacion.dart';
import '../sesion.dart';
import '../tema.dart';
import 'comun.dart';
import 'principal_page.dart' show aLaVista;

class EquiposPage extends StatefulWidget {
  const EquiposPage({super.key});

  @override
  State<EquiposPage> createState() => _EquiposPageState();
}

class _EquiposPageState extends State<EquiposPage> {
  late final _buscar = TextEditingController(text: navegacion.filtrosEquipos.value.q);
  List<Json> _equipos = const [];
  List<Dominio> _dominios = const [];
  OrdenEquipos _orden = OrdenEquipos.nombre;
  String? _error;
  bool _cargando = true;
  Timer? _espera;
  Timer? _reloj;

  /// Para no pisar una lista nueva con la respuesta tardía de una vieja.
  int _pedido = 0;

  FiltrosEquipos get _f => navegacion.filtrosEquipos.value;
  set _f(FiltrosEquipos f) => navegacion.filtrosEquipos.value = f;

  /// Con un solo dominio a la vista no hay nada que filtrar ni que distinguir.
  bool get _variosDominios => _dominios.length > 1;

  @override
  void initState() {
    super.initState();
    navegacion.filtrosEquipos.addListener(_alCambiarFiltros);
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
    _reloj = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && aLaVista(context, Pestana.equipos)) _carga();
    });
  }

  @override
  void dispose() {
    navegacion.filtrosEquipos.removeListener(_alCambiarFiltros);
    _buscar.dispose();
    _espera?.cancel();
    _reloj?.cancel();
    super.dispose();
  }

  void _alCambiarFiltros() {
    // Un enlace (la cifra «Perdidos» del tablero) cambia los filtros desde
    // afuera: el campo de búsqueda tiene que decir lo mismo.
    if (_buscar.text != _f.q) _buscar.text = _f.q;
    setState(() {});
    _carga();
  }

  Future<void> _carga() async {
    final n = ++_pedido;
    try {
      final r = await sesion.api.get('/v1/equipos', consulta: _f.consulta);
      if (!mounted || n != _pedido) return;
      setState(() {
        _equipos = [
          for (final e in (r['equipos'] as List?) ?? const [])
            if (e is Map) e.cast<String, Object?>(),
        ];
        _error = null;
      });
    } catch (e) {
      if (mounted && n == _pedido) setState(() => _error = mensajeDe(e));
    } finally {
      if (mounted && n == _pedido) setState(() => _cargando = false);
    }
  }

  void _alEscribir(String q) {
    _espera?.cancel();
    // El texto espera a que se deje de escribir; lo demás, al momento.
    _espera = Timer(const Duration(milliseconds: 350), () => _f = _f.copia(q: q));
  }

  @override
  Widget build(BuildContext context) {
    final lista = ordena(_equipos, _orden);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Equipos'),
        actions: [
          if (!_cargando)
            Center(
              child: Text('${lista.length} ${lista.length == 1 ? 'equipo' : 'equipos'}', style: apagado(context)),
            ),
          PopupMenuButton<OrdenEquipos>(
            tooltip: 'Ordenar',
            icon: const Icon(Icons.sort),
            initialValue: _orden,
            onSelected: (o) => setState(() => _orden = o),
            itemBuilder: (_) => [
              for (final o in OrdenEquipos.values)
                CheckedPopupMenuItem(value: o, checked: o == _orden, child: Text('Por ${o.titulo.toLowerCase()}')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _carga,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _filtros()),
            if (_error != null) SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Aviso(_error!))),
            if (_cargando)
              const SliverToBoxAdapter(child: Cargando())
            else if (lista.isEmpty)
              SliverToBoxAdapter(
                child: Vacio(
                  _f.vacios
                      ? 'Todavía no hay equipos. Crea un código de alta en el panel web y escanéalo con el agente desde el equipo.'
                      : 'Ningún equipo con esos filtros.',
                  icono: Icons.smartphone_outlined,
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                sliver: SliverList.separated(
                  itemCount: lista.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => TarjetaEquipo(equipo: lista[i], conDominio: _variosDominios),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _filtros() {
    final f = _f;
    Widget menu<T>({
      required String etiqueta,
      required T valor,
      required Map<T, String> opciones,
      required void Function(T) alElegir,
    }) {
      final elegido = opciones[valor];
      final activo = valor != opciones.keys.first;
      return PopupMenuButton<T>(
        tooltip: etiqueta,
        onSelected: alElegir,
        itemBuilder: (_) => [
          for (final o in opciones.entries) CheckedPopupMenuItem(value: o.key, checked: o.key == valor, child: Text(o.value)),
        ],
        child: Chip(
          label: Text(activo ? elegido ?? etiqueta : etiqueta),
          avatar: const Icon(Icons.arrow_drop_down, size: 18),
          backgroundColor: activo ? Paleta.de(context).marcaSuave : null,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _buscar,
            onChanged: _alEscribir,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Nombre, etiqueta, serie, modelo o persona',
              suffixIcon: _buscar.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Borrar',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _buscar.clear();
                        _f = _f.copia(q: '');
                      },
                    ),
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                if (_variosDominios) ...[
                  menu<String>(
                    etiqueta: 'Dominio',
                    valor: f.dominio,
                    opciones: {'': 'Todos los dominios', for (final d in _dominios) '${d.id}': '${d.nombre} (${d.equipos ?? 0})'},
                    alElegir: (v) => _f = f.copia(dominio: v),
                  ),
                  const SizedBox(width: 8),
                ],
                menu<String>(
                  etiqueta: 'Estado',
                  valor: f.estado,
                  opciones: {'': 'Cualquier estado', ...estados},
                  alElegir: (v) => _f = f.copia(estado: v),
                ),
                const SizedBox(width: 8),
                menu<String>(
                  etiqueta: 'Conexión',
                  valor: f.conectado,
                  opciones: const {
                    '': 'Conectados o no',
                    '1': 'Conectados ahora',
                    '0': 'Desconectados',
                    'sin24': 'Sin contacto 24 h',
                  },
                  alElegir: (v) => _f = f.copia(conectado: v),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('Con alerta'),
                  selected: f.alerta,
                  onSelected: (v) => _f = f.copia(alerta: v),
                ),
                if (f.estado.isEmpty) ...[
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('Retirados'),
                    selected: f.retirados,
                    onSelected: (v) => _f = f.copia(retirados: v),
                  ),
                ],
                if (!f.vacios) ...[
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: () {
                      _buscar.clear();
                      _f = const FiltrosEquipos();
                    },
                    child: const Text('Quitar filtros'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Un equipo en la lista: lo que se pregunta de él sin abrirlo.
class TarjetaEquipo extends StatelessWidget {
  const TarjetaEquipo({super.key, required this.equipo, this.conDominio = false});
  final Json equipo;
  final bool conDominio;

  @override
  Widget build(BuildContext context) {
    final e = equipo;
    final p = Paleta.de(context);
    final id = entero(e['id']) ?? 0;
    final alertas = entero(e['alertas']) ?? 0;
    final usuario = ultimoUsuario(e);
    final app = aplicacion(e);
    final red = redDe(e);
    final estado = '${e['estado'] ?? ''}';
    final debajo = [?texto(e['etiqueta']), if (conDominio) ?texto(e['dominio_nombre']), ?texto(e['asignado_a'])];
    final chico = apagado(context, tamano: 13);
    return Opacity(
      opacity: estado == 'retirado' ? .6 : 1,
      child: Tarjeta(
        borde: p.deEquipo(colorEquipo(e)),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        alTocar: () => navegacion.abreEquipo(id),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Punto(color: e['conectado'] == true ? p.ok : p.grisMapa),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${e['nombre'] ?? 'Equipo $id'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                ),
                if (alertas > 0) ...[
                  Pastilla.roja(context, alertas == 1 ? '1 alerta' : '$alertas alertas'),
                  const SizedBox(width: 6),
                ],
                EstadoEquipo(estado),
              ],
            ),
            if (debajo.isNotEmpty || texto(e['modelo']) != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(debajo.isNotEmpty ? debajo.join(' · ') : '${e['modelo']}', style: chico),
              ),
            if (usuario != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Icon(Icons.person_outline, size: 16, color: p.texto2),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: usuario.nombre),
                            if (usuario.debajo.isNotEmpty) TextSpan(text: ' · ${usuario.debajo}', style: chico),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
            if (app != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    Icon(Icons.apps, size: 16, color: p.texto2),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: app.nombre),
                            if (app.debajo.isNotEmpty) TextSpan(text: ' · ${app.debajo}', style: chico),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (e['conectado'] == true)
                  Text('conectado', style: TextStyle(fontSize: 14, color: p.ok))
                else
                  Hace(e['ultima_vez'], estilo: const TextStyle(fontSize: 14)),
                Bateria(nivel: entero(e['bateria']), cargando: e['cargando'] == true),
                if (red.isNotEmpty) Text(red, style: chico),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
