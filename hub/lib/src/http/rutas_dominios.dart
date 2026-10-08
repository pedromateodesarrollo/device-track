import '../dominios.dart';
import 'servidor.dart';

/// Un dominio agrupa equipos dentro de la organización: una empresa a la que
/// se le da servicio, un almacén, una sucursal. Y acota: una persona o una
/// llave limitada a un dominio solo ve y maneja los equipos de ese dominio.
///
/// Verlos lo puede cualquiera (cada quien, los suyos); crearlos y borrarlos es
/// de quien administra, que siempre alcanza toda la organización.
void registraRutasDominios(Servidor s) {
  s.ruta('GET', '/v1/dominios', (p) async {
    final r = await p.bd.filas(
      '''select d.id, d.nombre, d.slug, d.descripcion, d.creado,
                (select count(*) from dt.equipo e
                  where e.dominio = d.id and e.estado <> 'retirado')::int as equipos
           from dt.dominio d
          where d.org = @o and ${enDominios(p.s.dominios, 'd.id')}
          order by d.slug <> 'general', lower(d.nombre)''',
      {'o': p.s.org},
    );
    return Respuesta.ok({'dominios': r});
  });

  s.ruta('POST', '/v1/dominios', (p) async {
    final nombre = p.texto('nombre');
    if (nombre.isEmpty || nombre.length > 200) {
      return Respuesta.falla(400, 'falta_nombre', 'Ponle nombre al dominio: «Duralon», «Almacén norte»');
    }
    final pedido = p.texto('slug').toLowerCase();
    final String slug;
    if (pedido.isEmpty) {
      slug = await slugDominioLibre(p.bd, p.s.org, nombre);
    } else {
      // Solo dígitos no: se confundiría con un id.
      if (!RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$').hasMatch(pedido) ||
          RegExp(r'^[0-9-]+$').hasMatch(pedido) ||
          pedido.length > 60) {
        return Respuesta.falla(400, 'slug_invalido',
            'El slug va en minúsculas, con números y guiones, y lleva al menos una letra');
      }
      final ocupado = await p.bd.fila(
        'select id from dt.dominio where org = @o and slug = @s',
        {'o': p.s.org, 's': pedido},
      );
      if (ocupado != null) return Respuesta.falla(409, 'slug_en_uso', 'Ya hay un dominio con ese slug');
      slug = pedido;
    }
    final d = await p.bd.fila(
      '''insert into dt.dominio (org, nombre, slug, descripcion)
         values (@o, @n, @s, @d)
         returning id, nombre, slug, descripcion, creado, 0 as equipos''',
      {'o': p.s.org, 'n': nombre, 's': slug, 'd': p.texto('descripcion')},
    );
    return Respuesta.creado(d);
  }, permiso: 'admin');

  // El slug no cambia: es lo que tiene escrito un script o el código de alta
  // de otra app para nombrar el dominio.
  s.ruta('PATCH', '/v1/dominios/:id', (p) async {
    if (p.cuerpo.containsKey('nombre') && (p.texto('nombre').isEmpty || p.texto('nombre').length > 200)) {
      return Respuesta.falla(400, 'falta_nombre', 'El dominio necesita nombre');
    }
    final d = await p.bd.fila(
      '''update dt.dominio
            set nombre = coalesce(@n, nombre), descripcion = coalesce(@d, descripcion)
          where id = @i and org = @o
          returning id, nombre, slug, descripcion, creado,
                    (select count(*) from dt.equipo e
                      where e.dominio = dt.dominio.id and e.estado <> 'retirado')::int as equipos''',
      {
        'i': p.enteroParam('id'),
        'o': p.s.org,
        'n': p.cuerpo.containsKey('nombre') ? p.texto('nombre') : null,
        'd': p.cuerpo.containsKey('descripcion') ? p.texto('descripcion') : null,
      },
    );
    return d == null ? Respuesta.falla(404, 'no_encontrado', 'Ese dominio no existe') : Respuesta.ok(d);
  }, permiso: 'admin');

  /// Solo se borra un dominio vacío. Con equipos dentro, o con alguien que
  /// todavía entra por él, borrarlo dejaría equipos sin dueño o a una persona
  /// sin nada que ver sin que nadie lo decidiera. Sus zonas y reglas sí se van
  /// con él: sin equipos no vigilan nada.
  s.ruta('DELETE', '/v1/dominios/:id', (p) async {
    final id = p.enteroParam('id');
    final d = await p.bd.fila(
      'select slug from dt.dominio where id = @i and org = @o',
      {'i': id, 'o': p.s.org},
    );
    if (d == null) return Respuesta.vacio();
    if (d['slug'] == 'general') {
      return Respuesta.falla(409, 'dominio_general',
          'El dominio General no se borra: es donde cae lo que no tiene otro');
    }
    final uso = await p.bd.fila(
      '''select (select count(*) from dt.equipo where dominio = @i)::int as equipos,
                (select count(*) from dt.alta
                  where dominio = @i and anulada is null
                    and (vence is null or vence > now())
                    and (usos_max is null or usos < usos_max))::int as altas,
                (select count(*) from dt.usuario where @i = any(dominios))::int as personas,
                (select count(*) from dt.llave where @i = any(dominios) and revocada is null)::int as llaves''',
      {'i': id},
    );
    final quedan = [
      if (uso!['equipos'] != 0) _cuenta(uso['equipos'] as int, 'equipo', 'equipos'),
      if (uso['altas'] != 0) _cuenta(uso['altas'] as int, 'código de alta vigente', 'códigos de alta vigentes'),
      if (uso['personas'] != 0) _cuenta(uso['personas'] as int, 'persona', 'personas'),
      if (uso['llaves'] != 0) _cuenta(uso['llaves'] as int, 'llave', 'llaves'),
    ];
    if (quedan.isNotEmpty) {
      return Respuesta.falla(409, 'dominio_en_uso',
          'Todavía tiene ${_y(quedan)}: muévelos, anúlalos o quítaselo antes de borrarlo');
    }
    await p.bd.ejecuta('delete from dt.dominio where id = @i and org = @o', {'i': id, 'o': p.s.org});
    return Respuesta.vacio();
  }, permiso: 'admin');
}

String _cuenta(int n, String uno, String varios) => '$n ${n == 1 ? uno : varios}';

String _y(List<String> l) =>
    l.length == 1 ? l.first : '${l.sublist(0, l.length - 1).join(', ')} y ${l.last}';

/// El dominio que nombra [valor] (id o slug), si existe en la organización y
/// la sesión lo alcanza. Null si no.
Future<int?> buscaDominio(Peticion p, Object? valor) async {
  final v = valor?.toString().trim() ?? '';
  if (v.isEmpty) return null;
  final fila = await p.bd.fila(
    '''select id from dt.dominio
        where org = @o and (id::text = @v or slug = lower(@v))''',
    {'o': p.s.org, 'v': v},
  );
  final id = fila?['id'] as int?;
  return p.s.alcanza(id) ? id : null;
}

/// El dominio de algo que se crea (un código de alta, una zona, una regla),
/// según lo que venga en `cuerpo['dominio']`.
///
/// Si no viene: quien alcanza toda la organización lo pone en el General, o
/// —con [deOrg]— lo deja de toda la organización; quien alcanza un solo
/// dominio, en ese; quien alcanza varios tiene que decir cuál.
///
/// Devuelve el id (null = de toda la organización) o la [Respuesta] de error.
Future<(int?, Respuesta?)> dominioDe(Peticion p, Map<String, Object?> cuerpo, {bool deOrg = false}) async {
  final v = cuerpo['dominio'];
  if (v == null || v.toString().trim().isEmpty) {
    final propios = p.s.dominios;
    if (propios == null) return (deOrg ? null : await dominioGeneral(p.bd, p.s.org), null);
    if (propios.length == 1) return (propios.first, null);
    return (null, Respuesta.falla(400, 'falta_dominio', 'Di en qué dominio: alcanzas más de uno'));
  }
  final id = await buscaDominio(p, v);
  if (id == null) {
    return (null, Respuesta.falla(400, 'dominio_invalido', 'Ese dominio no existe o no lo alcanzas'));
  }
  return (id, null);
}

/// Los dominios de una persona o una llave, de una lista de ids o slugs.
/// Vacía = toda la organización. Lo que no exista es un error, no se ignora:
/// una persona a la que se quería limitar no puede quedar viéndolo todo por
/// un slug mal escrito.
Future<(List<int>, Respuesta?)> dominiosDe(Peticion p, Object? valor) async {
  if (valor == null) return (const <int>[], null);
  if (valor is! List) {
    return (const <int>[], Respuesta.falla(400, 'dominio_invalido', 'dominios es una lista de ids o slugs'));
  }
  final ids = <int>{};
  for (final v in valor) {
    final id = await buscaDominio(p, v);
    if (id == null) {
      return (const <int>[], Respuesta.falla(400, 'dominio_invalido', 'El dominio «$v» no existe'));
    }
    ids.add(id);
  }
  return (ids.toList()..sort(), null);
}
