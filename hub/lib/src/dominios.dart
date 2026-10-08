import 'db.dart';

/// El filtro de alcance sobre [columna] (la de dominio de un equipo, una zona,
/// una regla, un código de alta).
///
/// Con [dominios] null la sesión alcanza toda la organización y no se filtra
/// nada más. Con lista, solo esos. [tambienDeOrg] deja pasar además lo que no
/// tiene dominio, que es de toda la organización: una zona o una regla así la
/// ve cualquiera (aplica también a sus equipos), pero solo la toca quien
/// alcanza toda la organización.
///
/// Los ids van escritos en el SQL y no como parámetro: son enteros leídos de
/// la base al autenticar, nunca texto del cliente, y así una ruta no tiene
/// que acordarse de pasar un parámetro más para que el filtro funcione.
String enDominios(List<int>? dominios, String columna, {bool tambienDeOrg = false}) {
  if (dominios == null) return 'true';
  final lista = dominios.join(', ');
  return tambienDeOrg ? '($columna is null or $columna in ($lista))' : '$columna in ($lista)';
}

/// El dominio «General» de [org], que toda organización tiene. Se crea si no
/// está: un hub que venga de una versión anterior no puede quedarse sin él.
Future<int> dominioGeneral(Bd bd, int org) async {
  final fila = await bd.fila(
    '''insert into dt.dominio (org, nombre, slug)
       values (@o, 'General', 'general')
       on conflict (org, slug) do update set nombre = dt.dominio.nombre
       returning id''',
    {'o': org},
  );
  return fila!['id'] as int;
}

/// Un slug libre dentro de [org] a partir de [texto].
///
/// Nunca solo dígitos: el API acepta un dominio por id o por slug, y un slug
/// «7» se confundiría con el dominio 7.
Future<String> slugDominioLibre(Bd bd, int org, String texto) async {
  var raiz = texto
      .toLowerCase()
      .replaceAllMapped(RegExp('[áàäâéèëêíìïîóòöôúùüûñç]'), (m) => _sinAcento[m[0]]!)
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (raiz.isEmpty) raiz = 'dominio';
  if (RegExp(r'^[0-9-]+$').hasMatch(raiz)) raiz = 'd-$raiz';
  if (raiz.length > 60) raiz = raiz.substring(0, 60).replaceAll(RegExp(r'-+$'), '');
  for (var i = 0; i < 50; i++) {
    final intento = i == 0 ? raiz : '$raiz-$i';
    final ocupado = await bd.fila(
      'select id from dt.dominio where org = @o and slug = @s',
      {'o': org, 's': intento},
    );
    if (ocupado == null) return intento;
  }
  return '$raiz-${DateTime.now().millisecondsSinceEpoch}';
}

/// Lo mismo que hace la migración 0002 con los grupos de antes: «Almacén» y
/// «almacen» dan el mismo slug.
const _sinAcento = {
  'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e',
  'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i', 'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o',
  'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u', 'ñ': 'n', 'ç': 'c',
};
