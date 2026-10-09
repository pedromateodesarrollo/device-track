/// Los tableros de Inicio: `GET /v1/tableros` (la lista, con la definición de
/// cada panel) y `GET /v1/tableros/:id/datos` (cada panel con sus `datos` o su
/// `error`). El hub ya hizo las cuentas (`hub/lib/src/ia/tableros.dart`): aquí
/// solo se leen y se dejan en clases con tipo para dibujarlas.
///
/// Todo se lee con cuidado: un panel con una forma que esta versión de la app
/// no conoce (un hub más nuevo) sale como un panel con error, no tumba el
/// tablero.
library;

import 'equipo.dart' show FiltrosEquipos;
import 'formato.dart';

typedef Json = Map<String, Object?>;

class Tablero {
  const Tablero({
    required this.id,
    required this.nombre,
    this.propio = false,
    this.compartido = false,
    this.de,
    this.paneles = const [],
  });

  /// 0 es el «Resumen» de siempre: sale mientras la persona no tenga uno propio.
  final int id;
  final String nombre;
  final bool propio;
  final bool compartido;

  /// El dueño, si es compartido por otra persona.
  final String? de;

  /// Con `/datos`, cada panel con lo que muestra; con la lista, solo la
  /// definición (sin datos).
  final List<Panel> paneles;

  bool get esResumen => id == 0;

  factory Tablero.deJson(Json m) => Tablero(
    id: entero(m['id']) ?? 0,
    nombre: '${m['nombre'] ?? ''}',
    propio: m['propio'] == true,
    compartido: m['compartido'] == true,
    de: texto(m['de']),
    paneles: [
      for (final p in (m['paneles'] as List?) ?? const [])
        if (p is Map) Panel.deJson(p.cast<String, Object?>()),
    ],
  );

  /// Lo que se le escribe al asistente para empezar, como en el panel web:
  /// «Quiero personalizar mi Resumen: », «Quiero cambiar mi tablero
  /// «Batería»: ». Uno de otra persona no se cambia: se le pide uno nuevo.
  String get preguntaAsistente {
    if (esResumen) return 'Quiero personalizar mi Resumen: ';
    if (propio) return 'Quiero cambiar mi tablero «$nombre»: ';
    return 'Quiero un tablero nuevo con ';
  }

  /// El botón que lleva al asistente con esa pregunta.
  String get botonAsistente {
    if (esResumen) return 'Personalizar con el asistente';
    if (propio) return 'Cambiar con el asistente';
    return 'Otro tablero con el asistente';
  }
}

class Panel {
  const Panel({
    required this.id,
    required this.titulo,
    required this.fuente,
    required this.forma,
    this.ancho = 1,
    this.datos,
    this.error,
  });

  final String id;
  final String titulo;

  /// `resumen`, `equipos` o `alertas`.
  final String fuente;

  /// `cifra`, `barras`, `dona`, `tabla` o `mapa`.
  final String forma;

  /// 1 = medio ancho, 2 = ancho completo.
  final int ancho;
  final DatosPanel? datos;
  final String? error;

  factory Panel.deJson(Json m) {
    final forma = '${m['forma'] ?? ''}';
    String? error = texto(m['error']);
    DatosPanel? datos;
    final crudo = m['datos'];
    if (error == null && crudo is Map) {
      try {
        datos = DatosPanel.de(forma, crudo.cast<String, Object?>());
        if (datos == null) error = 'Esta versión de la app no sabe dibujar «$forma»: actualízala.';
      } catch (_) {
        error = 'El hub mandó este panel en un formato que la app no entiende.';
      }
    }
    return Panel(
      id: '${m['id'] ?? ''}',
      titulo: '${m['titulo'] ?? ''}',
      fuente: '${m['fuente'] ?? ''}',
      forma: forma,
      ancho: entero(m['ancho']) == 2 ? 2 : 1,
      datos: datos,
      error: error,
    );
  }
}

sealed class DatosPanel {
  const DatosPanel();

  /// Los `datos` de un panel según su [forma]. Null si la forma no se conoce.
  static DatosPanel? de(String forma, Json d) => switch (forma) {
    'cifra' => DatosCifra.deJson(d),
    'barras' || 'dona' => DatosSeries.deJson(d),
    'tabla' => DatosTabla.deJson(d),
    'mapa' => DatosMapa.deJson(d),
    _ => null,
  };
}

/// Un número grande. [alarma] lo pinta en rojo (perdidos, sin contacto,
/// alertas, cuando no es cero) y [enlace] es a dónde lleva al tocarlo.
class DatosCifra extends DatosPanel {
  const DatosCifra({required this.valor, this.enlace, this.alarma = false});
  final int valor;
  final String? enlace;
  final bool alarma;

  factory DatosCifra.deJson(Json d) =>
      DatosCifra(valor: entero(d['valor']) ?? 0, enlace: texto(d['enlace']), alarma: d['alarma'] == true);
}

class Serie {
  const Serie(this.etiqueta, this.valor);
  final String etiqueta;
  final int valor;
}

/// Barras y dona: cuántos hay de cada grupo, de mayor a menor (el hub junta lo
/// que pase de 11 en «Otros»).
class DatosSeries extends DatosPanel {
  const DatosSeries({required this.series, required this.total});
  final List<Serie> series;
  final int total;

  int get maximo => series.fold(0, (m, s) => s.valor > m ? s.valor : m);
  int get suma => series.fold(0, (t, s) => t + s.valor);

  factory DatosSeries.deJson(Json d) => DatosSeries(
    series: [
      for (final s in (d['series'] as List?) ?? const [])
        if (s is Map) Serie('${s['etiqueta'] ?? ''}', entero(s['valor']) ?? 0),
    ],
    total: entero(d['total']) ?? 0,
  );
}

class Columna {
  const Columna(this.id, this.titulo);
  final String id;
  final String titulo;
}

class FilaTabla {
  const FilaTabla({this.id, required this.valores});

  /// El equipo de la fila (en las dos fuentes: en `alertas` es el equipo de la
  /// alerta). Tocar la fila lo abre.
  final int? id;
  final List<Object?> valores;
}

class DatosTabla extends DatosPanel {
  const DatosTabla({required this.columnas, required this.filas, required this.total});
  final List<Columna> columnas;
  final List<FilaTabla> filas;

  /// Cuántas había en total: la tabla trae como mucho su `limite`.
  final int total;

  factory DatosTabla.deJson(Json d) => DatosTabla(
    columnas: [
      for (final c in (d['columnas'] as List?) ?? const [])
        if (c is Map) Columna('${c['id'] ?? ''}', texto(c['titulo']) ?? '${c['id'] ?? ''}'),
    ],
    filas: [
      for (final f in (d['filas'] as List?) ?? const [])
        if (f is Map) FilaTabla(id: entero(f['id']), valores: [...(f['valores'] as List?) ?? const []]),
    ],
    total: entero(d['total']) ?? 0,
  );

  /// Cómo se lee el valor de la columna [columna] en una celda: las fechas en
  /// hora local y relativas («hace 5 min»), la batería con su %, lo que falta
  /// con una raya.
  static String celda(String columna, Object? v, {DateTime? ahora}) {
    if (v == null || (v is String && v.trim().isEmpty)) return '—';
    switch (columna) {
      case 'ultima_vez' || 'abierta' || 'cerrada':
        return leeFecha(v) == null ? '$v' : hace(v, ahora: ahora);
      case 'bateria':
        return '${entero(v) ?? v} %';
    }
    if (v is bool) return v ? 'sí' : 'no';
    if (v is double) return v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(1);
    return '$v';
  }
}

class PuntoMapa {
  const PuntoMapa({
    required this.id,
    required this.nombre,
    required this.lat,
    required this.lng,
    this.estado = '',
    this.conectado = false,
    this.bateria,
    this.alertas = 0,
  });

  final int id;
  final String nombre;
  final double lat;
  final double lng;
  final String estado;
  final bool conectado;
  final int? bateria;
  final int alertas;

  /// Lo mismo que necesita `colorEquipo`.
  Json get comoEquipo => {'estado': estado, 'conectado': conectado, 'alertas': alertas};
}

class DatosMapa extends DatosPanel {
  const DatosMapa({required this.puntos, required this.total});
  final List<PuntoMapa> puntos;

  /// Cuántos equipos había (con o sin ubicación).
  final int total;

  factory DatosMapa.deJson(Json d) => DatosMapa(
    puntos: [
      for (final p in (d['puntos'] as List?) ?? const [])
        if (p is Map && decimal(p['lat']) != null && decimal(p['lng']) != null)
          PuntoMapa(
            id: entero(p['id']) ?? 0,
            nombre: '${p['nombre'] ?? ''}',
            lat: decimal(p['lat'])!,
            lng: decimal(p['lng'])!,
            estado: '${p['estado'] ?? ''}',
            conectado: p['conectado'] == true,
            bateria: entero(p['bateria']),
            alertas: entero(p['alertas']) ?? 0,
          ),
    ],
    total: entero(d['total']) ?? 0,
  );
}

// ---------------------------------------------------------------- enlaces

/// A dónde lleva un enlace del panel web (`#/panel/equipos?estado=perdido`):
/// la cifra de un tablero lo trae, y el asistente puede escribirlo.
sealed class Destino {
  const Destino();
}

class DestinoEquipos extends Destino {
  const DestinoEquipos(this.filtros);
  final FiltrosEquipos filtros;
}

class DestinoEquipo extends Destino {
  const DestinoEquipo(this.id);
  final int id;
}

class DestinoAlertas extends Destino {
  const DestinoAlertas();
}

/// Lee `#/panel/equipos?conectado=1`, `#/panel/equipos/42`, `#/panel/alertas`,
/// con o sin la dirección del hub delante. Null si no es una pantalla que la
/// app tenga.
Destino? destinoDeEnlace(String? enlace) {
  if (enlace == null) return null;
  final i = enlace.indexOf('#/panel');
  if (i < 0) return null;
  final ruta = enlace.substring(i + 1); // «/panel/equipos?estado=perdido»
  final uri = Uri.tryParse(ruta);
  if (uri == null) return null;
  final partes = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (partes.isEmpty || partes.first != 'panel') return null;
  final resto = partes.skip(1).toList();
  if (resto.isEmpty) return null;
  switch (resto.first) {
    case 'equipos':
      if (resto.length > 1) {
        final id = int.tryParse(resto[1]);
        return id == null ? null : DestinoEquipo(id);
      }
      // `todos=1` es «sin filtros»: no hay nada más que leer.
      return DestinoEquipos(FiltrosEquipos.deConsulta(uri.queryParameters));
    case 'alertas':
      return const DestinoAlertas();
  }
  return null;
}
