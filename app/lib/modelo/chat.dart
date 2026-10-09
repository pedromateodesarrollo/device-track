/// El asistente de IA: lo que contesta `POST /v1/ia/chat` (NDJSON, una línea
/// JSON por evento mientras consulta) y lo que guarda una conversación
/// (`GET /v1/ia/conversaciones/:id`).
///
/// Los eventos llegan en este orden posible: `conversacion`, `nota`,
/// `herramienta`, `propuesta`, `respuesta`, `fin`, o `error` en cualquier
/// momento después del primero (ver `hub/lib/src/http/rutas_asistente.dart`).
library;

import 'dart:convert';

import 'formato.dart';

typedef Json = Map<String, Object?>;

// ------------------------------------------------------------------ NDJSON

/// Convierte el cuerpo de la respuesta, tal como llega por la red, en
/// eventos. Una línea puede llegar partida en dos trozos (y una letra con
/// tilde, partida entre sus dos bytes): el decodificador UTF-8 y el
/// separador de líneas de `dart:convert` guardan lo que sobra hasta el
/// trozo siguiente.
Stream<EventoChat> eventosDe(Stream<List<int>> cuerpo) => cuerpo
    .transform(utf8.decoder)
    .transform(const LineSplitter())
    .where((l) => l.trim().isNotEmpty)
    .map(EventoChat.deLinea);

// ----------------------------------------------------------------- eventos

sealed class EventoChat {
  const EventoChat();

  /// Una línea. La que no es JSON (un proxy que metió algo, un corte) no
  /// tumba la conversación: sale como [EventoIlegible] y la pantalla la
  /// ignora. Un error del hub viene como evento propio ([EventoError]).
  factory EventoChat.deLinea(String linea) {
    Object? j;
    try {
      j = jsonDecode(linea);
    } on FormatException {
      return EventoIlegible(linea);
    }
    if (j is! Map) return EventoIlegible(linea);
    return EventoChat.deJson(j.cast<String, Object?>());
  }

  factory EventoChat.deJson(Json e) {
    switch (e['tipo']) {
      case 'conversacion':
        return EventoConversacion(id: entero(e['id']) ?? 0, titulo: '${e['titulo'] ?? ''}');
      case 'nota':
        return EventoNota('${e['texto'] ?? ''}');
      case 'herramienta':
        return EventoHerramienta(nombre: '${e['nombre'] ?? ''}', titulo: '${e['titulo'] ?? ''}');
      case 'propuesta':
        final p = e['propuesta'];
        if (p is! Map) return EventoIlegible(jsonEncode(e));
        return EventoPropuesta(Propuesta.deJson(p.cast<String, Object?>()));
      case 'respuesta':
        return EventoRespuesta('${e['texto'] ?? ''}');
      case 'fin':
        final uso = e['uso'] is Map ? (e['uso'] as Map).cast<String, Object?>() : const <String, Object?>{};
        return EventoFin(
          conversacion: entero(e['conversacion']) ?? 0,
          entrada: entero(uso['entrada']) ?? 0,
          salida: entero(uso['salida']) ?? 0,
        );
      case 'error':
        return EventoError(codigo: '${e['error'] ?? ''}', mensaje: '${e['mensaje'] ?? ''}');
    }
    return EventoIlegible(jsonEncode(e));
  }
}

/// La conversación en que quedó la pregunta (nueva o la misma).
class EventoConversacion extends EventoChat {
  const EventoConversacion({required this.id, required this.titulo});
  final int id;
  final String titulo;
}

/// Lo que el modelo dice mientras consulta («Voy a mirar las alertas»).
class EventoNota extends EventoChat {
  const EventoNota(this.texto);
  final String texto;
}

/// Empezó una consulta: [titulo] es lo que se le enseña a la persona
/// («Consultando los equipos»).
class EventoHerramienta extends EventoChat {
  const EventoHerramienta({required this.nombre, required this.titulo});
  final String nombre;
  final String titulo;
}

class EventoPropuesta extends EventoChat {
  const EventoPropuesta(this.propuesta);
  final Propuesta propuesta;
}

/// La respuesta, en Markdown.
class EventoRespuesta extends EventoChat {
  const EventoRespuesta(this.texto);
  final String texto;
}

class EventoFin extends EventoChat {
  const EventoFin({required this.conversacion, this.entrada = 0, this.salida = 0});
  final int conversacion;

  /// Tokens gastados en la pregunta.
  final int entrada;
  final int salida;
}

/// La pregunta falló (el proveedor, la clave, un error interno). La
/// conversación queda como estaba: la pregunta no se guarda.
class EventoError extends EventoChat {
  const EventoError({required this.codigo, required this.mensaje});
  final String codigo;
  final String mensaje;

  String get paraLaPersona => explicaIa(codigo, mensaje);
}

class EventoIlegible extends EventoChat {
  const EventoIlegible(this.linea);
  final String linea;
}

// -------------------------------------------------------------- propuestas

/// Un cambio que el asistente propuso y la persona confirma o descarta. Lo
/// que cambia algo (reglas, zonas, la ficha de un equipo, órdenes, cerrar una
/// alerta, invitar) nunca se hace al pedirlo.
class Propuesta {
  Propuesta({
    required this.id,
    required this.herramienta,
    this.args = const {},
    this.resumen = '',
    this.estado = 'pendiente',
    this.resultado,
    this.vencida = false,
  });

  final int id;
  final String herramienta;
  final Json args;

  /// Lo que se va a hacer, en una frase, escrito por el modelo.
  final String resumen;

  /// `pendiente`, `hecha`, `fallida` o `descartada`.
  String estado;

  /// Lo que contestó el hub al confirmarla.
  Object? resultado;
  bool vencida;

  bool get pendiente => estado == 'pendiente';

  factory Propuesta.deJson(Json m) => Propuesta(
    id: entero(m['id']) ?? 0,
    herramienta: '${m['herramienta'] ?? ''}',
    args: m['args'] is Map ? (m['args'] as Map).cast<String, Object?>() : const {},
    resumen: '${m['resumen'] ?? ''}',
    estado: texto(m['estado']) ?? 'pendiente',
    resultado: m['resultado'],
    vencida: m['vencida'] == true,
  );

  /// Cómo quedó, en una línea. Null mientras está pendiente.
  String? get comoQuedo {
    switch (estado) {
      case 'hecha':
        return 'Hecho.';
      case 'descartada':
        return 'Descartada.';
      case 'fallida':
        final r = resultado;
        final m = r is Map ? texto(r['mensaje']) ?? texto(r['error']) : null;
        return m == null ? 'No se pudo hacer.' : 'No se pudo hacer: $m';
    }
    return null;
  }

  /// El enlace de invitación, si la propuesta era invitar a alguien y ya se
  /// hizo: el correo pudo no salir, y quien confirma lo tiene que poder pasar.
  String? get enlaceInvitacion {
    final r = resultado;
    return estado == 'hecha' && r is Map ? texto(r['enlace']) : null;
  }

  String get titulo => _herramientas[herramienta] ?? herramienta.replaceAll('_', ' ');

  /// Los argumentos, para que la persona lea qué va a pasar: «Tipo: Batería
  /// baja», «Avisar a: ana@x.com, luis@x.com». Sin el id interno del equipo o
  /// de la regla cuando el resumen ya dice el nombre… pero con él si no hay
  /// otra cosa: mejor un número que nada.
  List<(String, String)> get argsLegibles {
    final r = <(String, String)>[];
    void agrega(String clave, Object? v, [String prefijo = '']) {
      if (v == null) return;
      if (v is Map) {
        for (final e in v.entries) {
          agrega('${e.key}', e.value, '$prefijo${_etiqueta(clave)} · ');
        }
        return;
      }
      r.add(('$prefijo${_etiqueta(clave)}', _valor(clave, v)));
    }

    for (final e in args.entries) {
      agrega(e.key, e.value);
    }
    return r;
  }

  static String _etiqueta(String k) => _etiquetas[k] ?? (k.isEmpty ? k : '${k[0].toUpperCase()}${k.substring(1)}'.replaceAll('_', ' '));

  static String _valor(String clave, Object v) {
    if (v is bool) return v ? 'sí' : 'no';
    if (v is List) return v.isEmpty ? (clave == 'dominios' ? 'toda la organización' : '—') : v.join(', ');
    if (clave == 'tipo') return tiposRegla['$v']?.nombre ?? tiposOrden['$v'] ?? '$v';
    if (clave == 'estado') return estados['$v'] ?? '$v';
    if (clave == 'rol') return const {'admin': 'Administrador', 'editor': 'Editor', 'consulta': 'Consulta'}['$v'] ?? '$v';
    return '$v';
  }

  static const _etiquetas = {
    'id': 'Id',
    'tipo': 'Tipo',
    'nombre': 'Nombre',
    'dominio': 'Dominio',
    'dominios': 'Dominios',
    'parametros': 'Parámetros',
    'minutos': 'Minutos',
    'porcentaje': 'Porcentaje',
    'zona': 'Zona',
    'activa': 'Activa',
    'avisar': 'Avisar a',
    'lat': 'Latitud',
    'lng': 'Longitud',
    'radio_m': 'Radio (m)',
    'etiqueta': 'Etiqueta',
    'serie': 'Serie',
    'asignado_a': 'Asignado a',
    'notas': 'Notas',
    'estado': 'Estado',
    'texto': 'Texto',
    'titulo': 'Título',
    'segundos': 'Segundos',
    'nota': 'Nota',
    'correo': 'Correo',
    'rol': 'Rol',
  };

  static const _herramientas = {
    'crear_regla': 'Crear una regla',
    'cambiar_regla': 'Cambiar una regla',
    'borrar_regla': 'Borrar una regla',
    'crear_zona': 'Crear una zona',
    'cambiar_zona': 'Cambiar una zona',
    'borrar_zona': 'Borrar una zona',
    'cambiar_equipo': 'Cambiar la ficha de un equipo',
    'ordenar_equipo': 'Mandarle una orden a un equipo',
    'cerrar_alerta': 'Cerrar una alerta',
    'invitar_usuario': 'Invitar a una persona',
    'borrar_tablero': 'Borrar un tablero',
  };
}

// ------------------------------------------------------------ conversación

class ResumenConversacion {
  const ResumenConversacion({required this.id, required this.titulo, this.actualizado, this.preguntas = 0});
  final int id;
  final String titulo;
  final Object? actualizado;
  final int preguntas;

  factory ResumenConversacion.deJson(Json m) => ResumenConversacion(
    id: entero(m['id']) ?? 0,
    titulo: '${m['titulo'] ?? ''}',
    actualizado: m['actualizado'],
    preguntas: entero(m['preguntas']) ?? 0,
  );
}

/// Una consulta que hizo el asistente para contestar.
class HerramientaUsada {
  const HerramientaUsada({required this.nombre, required this.titulo, this.error});
  final String nombre;
  final String titulo;
  final String? error;
}

/// Un mensaje de la conversación: lo que preguntó la persona o lo que
/// contestó el asistente (con lo que consultó y lo que propuso).
class MensajeChat {
  MensajeChat({
    required this.deLaPersona,
    this.texto = '',
    List<HerramientaUsada>? herramientas,
    List<Propuesta>? propuestas,
    List<String>? notas,
    this.t,
  }) : herramientas = herramientas ?? [],
       propuestas = propuestas ?? [],
       notas = notas ?? [];

  final bool deLaPersona;
  String texto;
  final List<HerramientaUsada> herramientas;
  final List<Propuesta> propuestas;

  /// Lo que dijo mientras consultaba. Solo mientras llega la respuesta: no se
  /// guarda en la conversación.
  final List<String> notas;
  final Object? t;
}

class Conversacion {
  const Conversacion({required this.id, required this.titulo, required this.mensajes});
  final int id;
  final String titulo;
  final List<MensajeChat> mensajes;

  /// Desde `GET /v1/ia/conversaciones/:id`: cada mensaje de la `vista` del
  /// asistente lleva los ids de sus propuestas, que vienen aparte con su
  /// estado de ahora.
  factory Conversacion.deJson(Json m) {
    final propuestas = {
      for (final p in (m['propuestas'] as List?) ?? const [])
        if (p is Map) entero(p['id']) ?? 0: Propuesta.deJson(p.cast<String, Object?>()),
    };
    return Conversacion(
      id: entero(m['id']) ?? 0,
      titulo: '${m['titulo'] ?? ''}',
      mensajes: [
        for (final v in (m['vista'] as List?) ?? const [])
          if (v is Map)
            MensajeChat(
              deLaPersona: v['rol'] == 'persona',
              texto: '${v['texto'] ?? ''}',
              t: v['t'],
              herramientas: [
                for (final h in (v['herramientas'] as List?) ?? const [])
                  if (h is Map)
                    HerramientaUsada(
                      nombre: '${h['nombre'] ?? ''}',
                      titulo: '${h['titulo'] ?? h['nombre'] ?? ''}',
                      error: texto(h['error']),
                    ),
              ],
              propuestas: [
                for (final id in (v['propuestas'] as List?) ?? const [])
                  ?propuestas[entero(id)],
              ],
            ),
      ],
    );
  }
}
