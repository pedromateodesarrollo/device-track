import '../db.dart';
import 'proveedor.dart';

/// Apunta lo que gastó una llamada al proveedor, salga como salga: lo que el
/// modelo leyó y escribió se cobra aunque después algo falle.
Future<void> registraUso(
  Bd bd, {
  required int org,
  int? usuario,
  int? llave,
  required String origen,
  required String proveedor,
  required String modelo,
  required IaUso uso,
}) => bd.ejecuta(
  '''insert into dt.ia_uso (org, usuario, llave, origen, proveedor, modelo,
                            entrada, salida, cache_lectura, cache_escritura)
     values (@o, @u, @l, @or, @p, @m, @e, @s, @cl, @ce)''',
  {
    'o': org,
    'u': usuario,
    'l': llave,
    'or': origen,
    'p': proveedor,
    'm': modelo,
    'e': uso.entrada,
    's': uso.salida,
    'cl': uso.cacheLectura,
    'ce': uso.cacheEscritura,
  },
);
