import 'db.dart';
import 'ws/canal.dart';

/// Las órdenes que se le mandan a un equipo y cómo le llegan.
///
/// Dos caminos, a propósito: por el WebSocket si está conectado (al instante)
/// y en la respuesta de su siguiente reporte si no. Un equipo sin socket
/// (Doze le cortó la red, la app con el plugin está cerrada) igual se entera
/// en diez minutos.
///
/// Una orden se vuelve a entregar hasta que el equipo acusa recibo: el socket
/// puede caerse justo después de escribir. El equipo descarta la que ya
/// atendió por su `id`.
class Ordenes {
  Ordenes(this.bd, this.canal);

  final Bd bd;
  final Canal canal;

  static const tipos = {'sonar', 'mensaje', 'reportar'};

  /// Lo que todavía no acusó recibo y no venció. Las marca como enviadas.
  Future<List<Map<String, Object?>>> pendientes(Bd bd, int equipo) async {
    return bd.filas(
      '''update dt.orden
            set estado = 'enviada', enviada = coalesce(enviada, now()), actualizada = now()
          where equipo = @e and estado in ('pendiente', 'enviada') and vence > now()
          returning id, tipo, datos''',
      {'e': equipo},
    );
  }

  /// Crea la orden y, si el equipo está conectado, se la manda ya.
  Future<Map<String, Object?>> crea({
    required int org,
    required int equipo,
    required String tipo,
    required Map<String, Object?> datos,
    required Duration vida,
    required String firma,
  }) async {
    final o = await bd.fila(
      '''insert into dt.orden (org, equipo, tipo, datos, creado_por, vence)
         values (@o, @e, @t, @d, @f, now() + make_interval(secs => @v))
         returning id, tipo, datos, estado, creado, vence''',
      {
        'o': org,
        'e': equipo,
        't': tipo,
        'd': datos,
        'f': firma,
        'v': vida.inSeconds,
      },
    );
    if (canal.conectado(equipo)) {
      final n = canal.enviaOrden(equipo, {
        'tipo': 'orden',
        'orden': {'id': o!['id'], 'tipo': tipo, 'datos': datos},
      });
      if (n > 0) {
        await bd.ejecuta(
          '''update dt.orden set estado = 'enviada', enviada = now(), actualizada = now()
              where id = @i and estado = 'pendiente' ''',
          {'i': o['id']},
        );
        return {...o, 'estado': 'enviada'};
      }
    }
    return o!;
  }

  /// Al conectar un equipo se le reparte lo que tenía esperando. Si quien
  /// conecta es una app y el agente ya está, no: las tiene el agente.
  Future<void> entregaPendientes(int equipo, {String tipo = 'agente'}) async {
    if (tipo != 'agente' && canal.agenteConectado(equipo)) return;
    final lista = await pendientes(bd, equipo);
    for (final o in lista) {
      canal.enviaOrden(equipo, {'tipo': 'orden', 'orden': o});
    }
  }

  /// Lo que va en la respuesta de un reporte: nada a una app si el agente del
  /// mismo equipo está conectado (ya las recibió por su socket).
  Future<List<Map<String, Object?>>> paraReporte(Bd bd, int equipo, String tipo) async {
    if (tipo != 'agente' && canal.agenteConectado(equipo)) return const [];
    return pendientes(bd, equipo);
  }

  /// Las que pasaron su hora sin que el equipo dijera nada.
  Future<int> venceViejas() async {
    final r = await bd.filas(
      '''update dt.orden set estado = 'vencida', actualizada = now()
          where estado in ('pendiente', 'enviada') and vence < now()
          returning id''',
    );
    return r.length;
  }
}
