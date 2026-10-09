import 'dart:convert';

import 'package:device_track_hub/src/alertas.dart';
import 'package:device_track_hub/src/ia/config.dart';
import 'package:device_track_hub/src/ia/proveedor.dart';
import 'package:test/test.dart';

import 'ia_falso.dart';

/// El cliente de IA (`lib/src/ia/`) contra un proveedor falso, y el correo de
/// una alerta. No hace falta base ni red.
void main() {
  late IaFalso falso;
  setUp(() async => falso = await IaFalso.arranca());
  tearDown(() => falso.cierra());

  const herramienta = IaHerramienta(
    nombre: 'listar_equipos',
    descripcion: 'Lista los equipos',
    parametros: {
      'type': 'object',
      'properties': {
        'q': {'type': 'string'},
      },
      'additionalProperties': false,
    },
  );

  group('Anthropic', () {
    IaProveedor proveedor({String modelo = 'claude-opus-5-5'}) => IaProveedor.de(
      ConfigIa(proveedor: 'anthropic', modelo: modelo, clave: 'sk-ant-prueba'),
      base: falso.base,
    );

    test('una llamada a una herramienta y su resultado, con el turno intacto', () async {
      falso.respuestas.add((
        200,
        {
          'model': 'claude-opus-5-5',
          'content': [
            {'type': 'thinking', 'thinking': '', 'signature': 'firma-larga'},
            {'type': 'text', 'text': 'Miro los equipos.'},
            {'type': 'tool_use', 'id': 'toolu_1', 'name': 'listar_equipos', 'input': {'q': 'TC56'}},
          ],
          'stop_reason': 'tool_use',
          'usage': {'input_tokens': 100, 'output_tokens': 20, 'cache_creation_input_tokens': 90},
        },
      ));
      final p = proveedor();
      final v = await p.turno(
        instruccion: 'Eres el asistente.',
        mensajes: [p.mensajeUsuario('¿Dónde está la TC56?')],
        herramientas: [herramienta],
        esfuerzo: 'medium',
      );
      expect(v.motivo, 'herramientas');
      expect(v.texto, 'Miro los equipos.');
      expect(v.llamadas.single.nombre, 'listar_equipos');
      expect(v.llamadas.single.args, {'q': 'TC56'});
      expect(v.uso.entrada, 100);
      expect(v.uso.cacheEscritura, 90);
      // El turno vuelve tal cual, con su bloque de razonamiento y su firma.
      expect((v.mensaje['content'] as List).first, {'type': 'thinking', 'thinking': '', 'signature': 'firma-larga'});

      final pet = falso.peticiones.single;
      expect(pet.ruta, '/v1/messages');
      expect(pet.cabeceras['x-api-key'], 'sk-ant-prueba');
      expect(pet.cabeceras['anthropic-version'], '2023-06-01');
      expect(pet.cabeceras['anthropic-beta'], 'server-side-fallback-2026-07-01');
      expect(pet.cuerpo['model'], 'claude-opus-5-5');
      expect(pet.cuerpo['fallbacks'], 'default');
      expect(pet.cuerpo['output_config'], {'effort': 'medium'});
      expect(pet.cuerpo.containsKey('temperature'), isFalse);
      expect(pet.cuerpo.containsKey('thinking'), isFalse);
      expect(pet.cuerpo['tools'][0]['input_schema']['properties']['q'], {'type': 'string'});
      expect(pet.cuerpo['system'][0]['cache_control'], {'type': 'ephemeral'});

      final r = p.mensajeResultados([
        IaResultado(v.llamadas.single, {'equipos': [{'id': 1, 'visto': DateTime.utc(2026, 10, 9)}]}),
      ]);
      expect(r['role'], 'user');
      final bloque = (r['content'] as List).single as Map;
      expect(bloque['type'], 'tool_result');
      expect(bloque['tool_use_id'], 'toolu_1');
      expect(jsonDecode(bloque['content'] as String)['equipos'][0]['visto'], '2026-10-09T00:00:00.000Z');
    });

    test('Haiku no lleva esfuerzo ni respaldo', () async {
      final p = proveedor(modelo: 'claude-haiku-4-5');
      await p.turno(instruccion: 'x', mensajes: [p.mensajeUsuario('hola')], esfuerzo: 'low');
      final pet = falso.peticiones.single;
      expect(pet.cuerpo.containsKey('output_config'), isFalse);
      expect(pet.cuerpo.containsKey('fallbacks'), isFalse);
      expect(pet.cabeceras.containsKey('anthropic-beta'), isFalse);
    });

    test('negativa y corte', () async {
      falso.respuestas
        ..add((200, {'content': [], 'stop_reason': 'refusal', 'usage': {}}))
        ..add((200, {'content': [{'type': 'text', 'text': 'a medias'}], 'stop_reason': 'max_tokens', 'usage': {}}));
      final p = proveedor();
      expect((await p.turno(instruccion: 'x', mensajes: [p.mensajeUsuario('a')])).motivo, 'rechazo');
      expect((await p.turno(instruccion: 'x', mensajes: [p.mensajeUsuario('a')])).motivo, 'cortada');
    });

    test('clave mala: su código, sin la clave en el detalle', () async {
      final p = IaProveedor.de(
        const ConfigIa(proveedor: 'anthropic', modelo: 'claude-opus-5-5', clave: 'mala'),
        base: falso.base,
      );
      await expectLater(
        p.turno(instruccion: 'x', mensajes: [p.mensajeUsuario('a')]),
        throwsA(isA<IaError>()
            .having((e) => e.codigo, 'codigo', 'ia_clave_invalida')
            .having((e) => e.detalle, 'detalle', isNot(contains('mala')))),
      );
    });

    test('sin nadie que conteste: ia_sin_conexion', () async {
      final p = proveedor();
      await falso.cierra();
      await expectLater(
        p.turno(instruccion: 'x', mensajes: [p.mensajeUsuario('a')]),
        throwsA(isA<IaError>().having((e) => e.codigo, 'codigo', 'ia_sin_conexion')),
      );
    });
  });

  group('Gemini', () {
    IaProveedor proveedor() => IaProveedor.de(
      const ConfigIa(proveedor: 'gemini', modelo: 'gemini-3.8-flash', clave: 'AIza-prueba'),
      base: falso.base,
    );

    test('la clave va en la cabecera, y la firma del razonamiento vuelve', () async {
      falso.respuestas.add((
        200,
        {
          'candidates': [
            {
              'content': {
                'role': 'model',
                'parts': [
                  {
                    'functionCall': {'name': 'listar_equipos', 'args': {'q': 'TC56'}},
                    'thoughtSignature': 'firma-gemini',
                  },
                ],
              },
              'finishReason': 'STOP',
            },
          ],
          'usageMetadata': {'promptTokenCount': 50, 'candidatesTokenCount': 5, 'thoughtsTokenCount': 7},
        },
      ));
      final p = proveedor();
      final v = await p.turno(
        instruccion: 'Eres el asistente.',
        mensajes: [p.mensajeUsuario('¿Dónde está la TC56?')],
        herramientas: [herramienta],
      );
      final pet = falso.peticiones.single;
      expect(pet.ruta, '/v1beta/models/gemini-3.8-flash:generateContent');
      expect(pet.ruta, isNot(contains('AIza')));
      expect(pet.cabeceras['x-goog-api-key'], 'AIza-prueba');
      final decl = pet.cuerpo['tools'][0]['functionDeclarations'][0] as Map;
      expect(decl['parameters'], {
        'type': 'OBJECT',
        'properties': {
          'q': {'type': 'STRING'},
        },
      });

      expect(v.motivo, 'herramientas');
      expect(v.llamadas.single.args, {'q': 'TC56'});
      expect(v.uso.salida, 12);
      expect(((v.mensaje['parts'] as List).single as Map)['thoughtSignature'], 'firma-gemini');

      final r = p.mensajeResultados([IaResultado(v.llamadas.single, [1, 2])]);
      final fr = ((r['parts'] as List).single as Map)['functionResponse'] as Map;
      expect(fr['name'], 'listar_equipos');
      expect(fr.containsKey('id'), isFalse); // sin id propio de Gemini
      expect(fr['response'], {'resultado': [1, 2]});
    });

    test('clave mala de Gemini (un 400)', () async {
      falso.respuestas.add((
        400,
        {
          'error': {'code': 400, 'message': 'API key not valid. Please pass a valid API key.', 'status': 'INVALID_ARGUMENT'},
        },
      ));
      final p = proveedor();
      await expectLater(
        p.turno(instruccion: 'x', mensajes: [p.mensajeUsuario('a')]),
        throwsA(isA<IaError>().having((e) => e.codigo, 'codigo', 'ia_clave_invalida')),
      );
    });
  });

  test('errores HTTP del proveedor', () {
    String c(int e, Object cuerpo) => IaProveedor.errorHttp(e, jsonEncode(cuerpo)).codigo;
    expect(c(404, {'error': {'message': 'model: claude-x'}}), 'ia_modelo_no_existe');
    expect(c(429, {}), 'ia_limite');
    expect(c(529, {'error': {'message': 'Overloaded'}}), 'ia_proveedor_caido');
    expect(c(400, {'error': {'message': 'Your credit balance is too low'}}), 'ia_sin_saldo');
    expect(c(400, {'error': {'message': 'algo raro'}}), 'ia_proveedor_error');
    expect(IaProveedor.errorHttp(500, 'no es json').detalle, contains('no es json'));
  });

  test('el correo de una alerta', () {
    final ahora = DateTime.utc(2026, 10, 9, 15);
    final m = correoDeAlerta(
      {
        'tipo': 'sin_reporte',
        'regla_nombre': '',
        'equipo_id': 7,
        'equipo_nombre': 'TC56 <0900>',
        'etiqueta': 'AF-12',
        'dominio_nombre': 'Duralon',
        'asignado_a': 'Juan',
        'bateria': 40,
        'lat': 18.5,
        'lng': -69.9,
        'org_nombre': 'Chalona',
        'detalle': {'ultima_vez': '2026-10-09T13:40:00Z', 'minutos': 60},
      },
      urlPublica: 'https://devicetrack.ejemplo.com',
      ahora: ahora,
    );
    expect(m.asunto, 'Sin reporte: TC56 <0900>');
    expect(m.texto, contains('Sin reporte: sin contacto desde hace 1 h 20 min'));
    expect(m.texto, contains('Equipo: TC56 <0900> (AF-12)'));
    expect(m.texto, contains('Ver en el panel: https://devicetrack.ejemplo.com/#/panel/equipos/7'));
    expect(m.texto, contains('openstreetmap.org/?mlat=18.5&mlon=-69.9'));
    expect(m.html, contains('TC56 &lt;0900&gt;'));
    expect(m.html, isNot(contains('<0900>')));

    expect(detalleDeAlerta('bateria_baja', {'bateria': 9, 'porcentaje': 15}), '9 % (umbral 15 %)');
    expect(detalleDeAlerta('fuera_de_zona', {'zona': 'A13', 'distancia_m': 1530, 'radio_m': 200}),
        'a 1,5 km de A13 (radio 200 m)');
  });
}
