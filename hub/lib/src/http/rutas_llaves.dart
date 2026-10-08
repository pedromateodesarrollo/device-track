import '../seguridad.dart';
import 'rutas_dominios.dart';
import 'servidor.dart';

/// Permisos que puede llevar una llave de API. Pocos a propósito: la llave que
/// vive en el ERP para pintar el inventario no debería poder mandar a sonar un
/// equipo ni crear otras llaves.
const permisosValidos = {
  // Ver equipos, recorridos, alertas, zonas y reglas.
  'leer',
  // Cambiar la ficha de un equipo, zonas, reglas y códigos de alta.
  'editar',
  // Mandarle órdenes a un equipo (sonar, mensaje, reportar).
  'ordenar',
  // Todo, incluida la gestión de usuarios y de otras llaves. Es para
  // automatizar la administración desde otro sistema; no se reparte.
  'admin',
};

/// Llaves de API para scripts y otros sistemas.
///
/// No caducan solas —un sistema integrado no está para renovar tokens— así que
/// lo que hay es revocación. Una llave puede quedar limitada a unos dominios:
/// la del ERP de un cliente solo ve los equipos de ese cliente.
void registraRutasLlaves(Servidor s) {
  s.ruta('GET', '/v1/llaves', (p) async {
    final r = await p.bd.filas(
      '''select id, nombre, prefijo, permisos, dominios, creado, ultimo_uso, revocada
           from dt.llave where org = @o order by id desc''',
      {'o': p.s.org},
    );
    return Respuesta.ok({'llaves': r});
  }, permiso: 'admin');

  s.ruta('POST', '/v1/llaves', (p) async {
    final nombre = p.texto('nombre');
    if (nombre.isEmpty) {
      return Respuesta.falla(400, 'falta_nombre', 'Ponle nombre para saber después qué la usa');
    }
    final pedidos = ((p.cuerpo['permisos'] as List?) ?? const [])
        .map((x) => x.toString())
        .toSet();
    final permisos = pedidos.isEmpty ? {'leer'} : pedidos;
    final malos = permisos.difference(permisosValidos);
    if (malos.isNotEmpty) {
      return Respuesta.falla(400, 'permiso_invalido',
          'No existe: ${malos.join(", ")}. Válidos: ${permisosValidos.join(", ")}');
    }
    final (dominios, error) = await dominiosDe(p, p.cuerpo['dominios']);
    if (error != null) return error;
    if (permisos.contains('admin') && dominios.isNotEmpty) {
      return Respuesta.falla(400, 'admin_sin_dominios',
          'El permiso admin es de toda la organización: no se limita a unos dominios');
    }

    // Hex, no base64url: el prefijo viaja dentro de `dtk_<prefijo>_<secreto>`
    // y un guion bajo ahí rompería el corte.
    final prefijo = Seguridad.hex(4);
    final secreto = Seguridad.token();
    final l = await p.bd.fila(
      '''insert into dt.llave (org, nombre, prefijo, clave_hash, permisos, dominios)
         values (@o, @n, @p, @h, @perm, @d)
         returning id, nombre, prefijo, permisos, dominios, creado''',
      {
        'o': p.s.org,
        'n': nombre,
        'p': prefijo,
        'h': Seguridad.hashToken(secreto),
        'perm': permisos.toList(),
        'd': dominios,
      },
    );
    return Respuesta.creado({
      ...l!,
      // Única vez que se ve completa. Se guarda hasheada.
      'llave': 'dtk_${prefijo}_$secreto',
    });
  }, permiso: 'admin');

  /// Revocar, no borrar: la fila sigue explicando qué llave mandó la orden de
  /// la semana pasada.
  s.ruta('DELETE', '/v1/llaves/:id', (p) async {
    await p.bd.ejecuta(
      'update dt.llave set revocada = now() where id = @i and org = @o and revocada is null',
      {'i': p.enteroParam('id'), 'o': p.s.org},
    );
    return Respuesta.vacio();
  }, permiso: 'admin');
}
