import 'package:device_track_panel/modelo/ubicacion.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final ahora = DateTime.now().toUtc().toIso8601String();

  test('sin estado: versión vieja, y no se avisa en la lista', () {
    final u = ExplicaUbicacion.de({'lat': null});
    expect(u.motivo, isNull);
    expect(u.texto, contains('versión vieja'));
    expect(avisoUbicacion({'lat': null}), isNull);
  });

  test('negada para siempre: qué hacer con el nombre de la app, y aviso en la lista', () {
    final e = {
      'lat': null,
      'ubicacion_estado': {
        'motivo': 'denegada_siempre', 'permiso': 'ninguno', 'fuente_nombre': 'WMS Duralon', 'fuente_tipo': 'app', 't': ahora,
      },
    };
    final u = ExplicaUbicacion.de(e);
    expect(u.arreglable, isTrue);
    expect(u.texto, contains('No volver a preguntar'));
    expect(u.queHacer, contains('Ajustes › Aplicaciones › WMS Duralon › Permisos › Ubicación'));
    expect(u.queHacer, contains('Permitir solo mientras se usa la app'));
    expect(u.datos, ['Sin permiso']);
    expect(avisoUbicacion(e), startsWith('Ubicación: '));
  });

  test('el agente necesita «todo el tiempo»; sin señal no es arreglable', () {
    final agente = ExplicaUbicacion.de({
      'ubicacion_estado': {'motivo': 'sin_segundo_plano', 'fuente_nombre': 'device-track', 'fuente_tipo': 'agente'},
    });
    expect(agente.queHacer, contains('Permitir todo el tiempo'));
    final e = {
      'ubicacion_estado': {'motivo': 'sin_senal', 'espera_s': 20, 'ultima_edad_s': 7200, 'google_play': false},
    };
    final s = ExplicaUbicacion.de(e);
    expect(s.arreglable, isFalse);
    expect(s.texto, contains('en 20 s'));
    expect(s.texto, contains('hace 2 h'));
    expect(s.texto, contains('servicios de Google'));
    expect(avisoUbicacion(e), isNull);
  });

  test('fuentes que dicen distinto se enseñan por separado', () {
    final u = ExplicaUbicacion.de({
      'lat': 18.4,
      'ubicacion_estado': {'motivo': 'ok', 'fuente_tipo': 'agente', 'fuente_nombre': 'device-track'},
      'fuentes': [
        {'nombre': 'device-track', 'tipo': 'agente', 'ubicacion_estado': {'motivo': 'ok'}, 'ubicacion_estado_t': ahora},
        {'nombre': 'WMS', 'tipo': 'app', 'ubicacion_estado': {'motivo': 'denegada'}, 'ubicacion_estado_t': ahora},
      ],
    });
    expect(u.ok, isTrue);
    expect(u.porFuente.map((f) => f.app), ['device-track', 'WMS']);
    expect(u.porFuente.last.texto, contains('Le negaron'));
  });
}
