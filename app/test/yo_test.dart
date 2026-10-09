// Lo que cada rol puede, igual que `Sesion.puede` del hub
// (hub/lib/src/http/servidor.dart): la app esconde los botones que el hub
// contestaría con «sin permiso».
import 'package:device_track_panel/modelo/yo.dart';
import 'package:flutter_test/flutter_test.dart';

Yo _yo(String rol, {List<Map<String, Object?>> dominios = const []}) => Yo.deJson({
  'id': 1,
  'correo': 'a@b.c',
  'nombre': 'Ana',
  'rol': rol,
  'org': 1,
  'organizacion': 'Duralon',
  'dominios': dominios,
  'ia': true,
});

void main() {
  test('admin puede todo', () {
    final yo = _yo('admin');
    expect(yo.esAdmin, isTrue);
    for (final p in ['leer', 'editar', 'ordenar', 'admin']) {
      expect(yo.puede(p), isTrue, reason: p);
    }
  });

  test('editor mira, edita y ordena, pero no administra', () {
    final yo = _yo('editor');
    expect(yo.esAdmin, isFalse);
    expect([for (final p in ['leer', 'editar', 'ordenar', 'admin']) yo.puede(p)], [true, true, true, false]);
  });

  test('consulta solo mira', () {
    final yo = _yo('consulta');
    expect([for (final p in ['leer', 'editar', 'ordenar', 'admin']) yo.puede(p)], [true, false, false, false]);
  });

  test('un rol que no se conoce no puede nada', () {
    expect(_yo('api').puede('leer'), isFalse);
  });

  test('limitado a unos dominios, nunca administra aunque diga admin', () {
    final yo = _yo('admin', dominios: [
      {'id': 3, 'nombre': 'Duralon', 'slug': 'duralon'},
      {'id': 5, 'nombre': 'JF', 'slug': 'jf'},
    ]);
    expect(yo.acotado, isTrue);
    expect(yo.esAdmin, isFalse);
    expect(yo.puede('admin'), isFalse);
    expect(yo.puede('leer'), isFalse); // «admin» no es un rol de los limitados
    expect(yo.alcanceTexto, 'Duralon, JF');
    expect(yo.alcanza(3), isTrue);
    expect(yo.alcanza(4), isFalse);
    expect(yo.alcanza(null), isFalse); // lo de toda la organización lo toca quien la alcanza
  });

  test('sin dominios alcanza toda la organización', () {
    final yo = _yo('editor');
    expect(yo.acotado, isFalse);
    expect(yo.alcanza(null), isTrue);
    expect(yo.alcanza(9), isTrue);
    expect(yo.ia, isTrue);
  });
}
