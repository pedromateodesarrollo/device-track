import 'dart:convert';

import '../http/servidor.dart';
import '../log.dart';
import 'config.dart';
import 'herramientas.dart';
import 'proveedor.dart';
import 'uso.dart';

/// Quién pregunta, para la instrucción del modelo.
class Persona {
  const Persona({
    required this.nombre,
    required this.correo,
    required this.rol,
    required this.organizacion,
    this.dominios = const [],
    this.correoDeSalida = false,
  });

  final String nombre;
  final String correo;
  final String rol;
  final String organizacion;

  /// Los nombres de los dominios a los que está limitada; vacía = toda la
  /// organización.
  final List<String> dominios;
  final bool correoDeSalida;
}

/// Lo que salió de una pregunta.
class Contestacion {
  Contestacion({
    required this.mensajes,
    required this.texto,
    required this.herramientas,
    required this.propuestas,
    required this.uso,
  });

  /// La conversación entera, en el formato del proveedor, con esta pregunta.
  final List<Map<String, Object?>> mensajes;
  final String texto;
  final List<Map<String, Object?>> herramientas;
  final List<Map<String, Object?>> propuestas;
  final IaUso uso;
}

class _Deshacer implements Exception {}

/// El bucle del asistente: pregunta al modelo, corre las herramientas que
/// pide (las consultas, directo; los cambios, como propuesta) y le devuelve
/// los resultados, hasta que contesta.
class Asistente {
  Asistente(this.servidor, {this.base});

  final Servidor servidor;

  /// La dirección del proveedor (solo para las pruebas).
  final Uri? base;

  static const maxVueltas = 12;

  Future<Contestacion> pregunta({
    required ConfigIa config,
    required Sesion sesion,
    required Persona persona,
    required int conversacion,
    required List<Map<String, Object?>> mensajes,
    required String texto,
    required void Function(Map<String, Object?> evento) emite,
    String urlPublica = '',
  }) async {
    final proveedor = IaProveedor.de(config, base: base);
    final disponibles = herramientasPara(sesion);
    final contexto = Contexto(servidor: servidor, sesion: sesion, urlPublica: urlPublica);
    final conversa = [...mensajes, proveedor.mensajeUsuario(texto)];
    final usadas = <Map<String, Object?>>[];
    final propuestas = <Map<String, Object?>>[];
    var uso = const IaUso();
    final instruccion = instruccionDe(persona, puedeCambiar: disponibles.any((h) => h.cambia));

    for (var vuelta = 0; vuelta < maxVueltas; vuelta++) {
      final v = await proveedor.turno(
        instruccion: instruccion,
        mensajes: conversa,
        herramientas: [for (final h in disponibles) h.definicion],
        esfuerzo: 'medium',
      );
      uso += v.uso;
      await registraUso(
        servidor.bd,
        org: sesion.org,
        usuario: sesion.usuario,
        origen: 'chat',
        proveedor: config.proveedor,
        modelo: v.modelo,
        uso: v.uso,
      );
      conversa.add(v.mensaje);

      if (v.motivo != 'herramientas') {
        final texto = switch (v.motivo) {
          'rechazo' => v.texto.isNotEmpty ? v.texto : 'El proveedor no quiso contestar eso. Prueba a preguntarlo de otra forma.',
          'cortada' => '${v.texto}\n\n_(La respuesta se cortó por larga.)_',
          _ => v.texto,
        };
        return Contestacion(mensajes: conversa, texto: texto, herramientas: usadas, propuestas: propuestas, uso: uso);
      }

      if (v.texto.isNotEmpty) emite({'tipo': 'nota', 'texto': v.texto});
      final resultados = <IaResultado>[];
      for (final l in v.llamadas) {
        final h = herramienta(l.nombre);
        if (h == null || !disponibles.contains(h)) {
          resultados.add(IaResultado(l, {'error': 'herramienta_desconocida', 'mensaje': 'No existe ${l.nombre}'}, error: true));
          continue;
        }
        emite({'tipo': 'herramienta', 'nombre': h.nombre, 'titulo': h.titulo});
        final r = await _corre(h, l, contexto, conversacion);
        final fallo = r is Map && r['error'] != null;
        usadas.add({'nombre': h.nombre, 'titulo': h.titulo, if (fallo) 'error': r['mensaje'] ?? r['error']});
        if (r is Map && r['propuesta'] is Map) {
          final pr = (r['propuesta'] as Map).cast<String, Object?>();
          propuestas.add(pr);
          emite({'tipo': 'propuesta', 'propuesta': pr});
          resultados.add(IaResultado(l, {
            'propuesta': pr['id'],
            'estado': 'pendiente_de_confirmar',
            'nota': 'No está hecho: queda propuesto y la persona lo confirma con un botón debajo de tu respuesta.',
          }));
        } else {
          resultados.add(IaResultado(l, _seguro(r), error: fallo));
        }
      }
      conversa.add(proveedor.mensajeResultados(resultados));
    }
    return Contestacion(
      mensajes: conversa,
      texto: 'Me llevó demasiadas consultas y paré aquí. Pregúntamelo más concreto, o por partes.',
      herramientas: usadas,
      propuestas: propuestas,
      uso: uso,
    );
  }

  /// Una llamada del modelo: la consulta, o la propuesta de un cambio.
  Future<Object?> _corre(Herramienta h, IaLlamada l, Contexto c, int conversacion) async {
    try {
      if (!h.cambia) return h.resultado(await h.corre(c, l.args, null));

      final args = {...l.args}..remove('resumen');
      // Lo que solo toca la base se ensaya y se deshace: lo que se propone ya
      // se sabe que va a salir.
      if (h.ensayable) {
        final r = await ensaya(h, c, args);
        if (r.estado >= 300) return h.resultado(r);
      } else if (h.nombre == 'ordenar_equipo') {
        final e = await c.llama('GET', '/v1/equipos/${args['id']}');
        if (e.estado >= 300) return h.resultado(e);
      }
      final resumen = '${l.args['resumen'] ?? ''}'.trim();
      final p = await servidor.bd.fila(
        '''insert into dt.ia_propuesta (org, usuario, conversacion, herramienta, args, resumen)
           values (@o, @u, @c, @h, @a::jsonb, @r)
           returning id, herramienta, args, resumen, estado''',
        {
          'o': c.sesion.org,
          'u': c.sesion.usuario,
          'c': conversacion,
          'h': h.nombre,
          'a': jsonEncode(args),
          'r': resumen.isEmpty ? h.titulo : (resumen.length > 300 ? resumen.substring(0, 300) : resumen),
        },
      );
      return {'propuesta': p};
    } catch (e, t) {
      log.error('asistente', '${h.nombre}: $e\n$t');
      return {'error': 'error_interno', 'mensaje': 'La herramienta falló'};
    }
  }

  /// Corre [h] dentro de una transacción y la deshace.
  Future<Respuesta> ensaya(Herramienta h, Contexto c, Map<String, Object?> args) async {
    Respuesta? r;
    try {
      await servidor.bd.transaccion((tx) async {
        r = await h.corre(c, args, tx);
        throw _Deshacer();
      });
    } on _Deshacer {
      // Lo esperado: el ensayo no deja nada.
    }
    return r!;
  }

  /// Ejecuta de verdad una propuesta confirmada, con la sesión de quien
  /// confirma.
  Future<Object?> ejecuta(String nombre, Map<String, Object?> args, Sesion sesion, {String urlPublica = ''}) async {
    final h = herramienta(nombre);
    if (h == null) return {'error': 'herramienta_desconocida', 'mensaje': nombre};
    final c = Contexto(servidor: servidor, sesion: sesion, urlPublica: urlPublica);
    return h.resultado(await h.corre(c, args, null));
  }
}

/// El resultado tal cual, pero con tope de tamaño.
Object? _seguro(Object? r) {
  final t = resultadoJson(r);
  try {
    return jsonDecode(t);
  } on FormatException {
    return t; // recortado: va como texto
  }
}

/// La instrucción del modelo. No lleva la hora (va en cada pregunta): así es
/// la misma en toda la conversación y el proveedor la cachea.
String instruccionDe(Persona p, {required bool puedeCambiar}) {
  final alcance = p.dominios.isEmpty
      ? 'Alcanza toda la organización.'
      : 'Solo alcanza los equipos de: ${p.dominios.join(', ')}.';
  return '''
Eres el asistente de device-track de la organización «${p.organizacion}». device-track lleva el inventario y el seguimiento de los teléfonos y terminales Android de la organización: dónde están, si reportan, su batería y su red, quién los usa. Abre alertas según reglas (sin_reporte, bateria_baja, fuera_de_zona, apagado) y les manda órdenes (sonar, mensaje, reportar). Los equipos se agrupan en dominios (un cliente, un almacén).

Hablas con ${p.nombre} (${p.correo}), rol «${p.rol}». $alcance Las herramientas llaman al panel con SU sesión: ves y haces solo lo que esa persona puede. Si algo contesta sin_permiso o no_encontrado, díselo; no busques otro camino.

Cómo contestar:
- En español, corto y directo. Markdown con listas o tablas cuando ayude.
- Usa los nombres de los equipos (y su etiqueta), no solo los ids.
- No inventes: si no lo sabes, consulta. Si una consulta trae mucho, filtra.
- Las fechas de las herramientas vienen en UTC: dalas en la hora de la persona (cada pregunta dice su hora y su desfase).
- «Conectado» es que tiene el canal abierto ahora; «ultima_vez» es su último contacto de cualquier tipo.

${puedeCambiar ? '''Cambios: las herramientas que cambian algo (reglas, zonas, la ficha de un equipo, órdenes, cerrar alertas, invitar) NO se ejecutan al pedirlas. Quedan propuestas y la persona las confirma con un botón debajo de tu respuesta. Di qué propusiste y que falta su confirmación; nunca digas que ya está hecho. Antes de proponer, consulta lo que haga falta (el id del equipo, de la regla, del dominio, de la zona). Una propuesta por cosa.''' : 'Esta persona solo consulta: no tiene herramientas para cambiar nada. Si pide un cambio, dile que se lo pida a quien administra.'}

Avisos y notificaciones: cuando pidan que les avisen de algo, es una regla; con «avisar» (lista de correos) llega por correo. ${p.correoDeSalida ? 'La organización tiene correo de salida.' : 'La organización todavía no tiene correo de salida: la regla abre la alerta en el panel, pero el correo no saldrá hasta que quien administra lo configure en Organización → Correo de salida.'}

Reportes: consulta y arma el resumen aquí mismo, con tablas si ayuda.

Tableros: la portada del panel son tableros. Quien no tiene uno propio ve el «Resumen» (tablero 0). Puedes crear tableros de la persona (con desde_resumen para partir del Resumen), agregar, cambiar y quitar paneles: eso es directo, sin confirmación, porque es suyo y se deshace fácil. Cada panel es una consulta de solo lectura (fuente resumen, equipos o alertas, con filtros) y una forma (cifra, barras, dona, tabla, mapa). La herramienta prueba el panel antes de guardarlo; si falla, corrígelo. Borrar un tablero entero sí queda propuesto.
''';
}

/// La primera línea de cada pregunta: qué hora es para la persona, y lo que
/// confirmó o descartó desde la última vez.
String contextoDePregunta({
  required DateTime ahoraUtc,
  required int desfaseMin,
  List<Map<String, Object?>> pendientes = const [],
}) {
  final local = ahoraUtc.add(Duration(minutes: desfaseMin));
  const dias = ['lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'];
  const meses = [
    'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
    'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
  ];
  final signo = desfaseMin < 0 ? '−' : '+';
  final h = (desfaseMin.abs() ~/ 60).toString().padLeft(2, '0');
  final m = (desfaseMin.abs() % 60).toString().padLeft(2, '0');
  final hora = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  final b = StringBuffer(
    '[Ahora, para la persona: ${dias[local.weekday - 1]} ${local.day} de ${meses[local.month - 1]} de ${local.year}, '
    '$hora (UTC$signo$h:$m).',
  );
  for (final p in pendientes) {
    final estado = switch (p['estado']) {
      'hecha' => 'la confirmó y quedó hecha',
      'fallida' => 'la confirmó, pero falló: ${p['mensaje'] ?? ''}',
      'descartada' => 'la descartó',
      _ => '${p['estado']}',
    };
    b.write(' Propuesta «${p['resumen']}»: $estado.');
  }
  b.write(']');
  return b.toString();
}
