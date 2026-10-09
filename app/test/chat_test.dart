// El asistente contesta en NDJSON mientras consulta: una línea JSON por
// evento, que por la red puede llegar partida en cualquier punto (también
// entre los dos bytes de una letra con tilde).
import 'dart:async';
import 'dart:convert';

import 'package:device_track_panel/api/cliente.dart';
import 'package:device_track_panel/modelo/chat.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Lo que mandaría el hub para una pregunta con una consulta y una propuesta.
final _lineas = [
  {'tipo': 'conversacion', 'id': 7, 'titulo': '¿Qué equipos están sin batería?'},
  {'tipo': 'nota', 'texto': 'Voy a mirar la batería de cada equipo.'},
  {'tipo': 'herramienta', 'nombre': 'equipos', 'titulo': 'Consultando los equipos'},
  {
    'tipo': 'propuesta',
    'propuesta': {
      'id': 3,
      'herramienta': 'crear_regla',
      'args': {'tipo': 'bateria_baja', 'parametros': {'porcentaje': 15}, 'avisar': ['ana@x.com']},
      'resumen': 'Crear la regla «Batería baja» al 15 %',
      'estado': 'pendiente',
    },
  },
  {'tipo': 'respuesta', 'texto': 'Hay **2** equipos por debajo del 15 %.'},
  {'tipo': 'fin', 'conversacion': 7, 'uso': {'entrada': 1200, 'salida': 80}},
];

String get _ndjson => '${_lineas.map(jsonEncode).join('\n')}\n';

/// Parte [bytes] en trozos de [n] bytes, como podrían llegar por la red.
Stream<List<int>> _enTrozos(List<int> bytes, int n) async* {
  for (var i = 0; i < bytes.length; i += n) {
    yield bytes.sublist(i, i + n > bytes.length ? bytes.length : i + n);
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('eventosDe', () {
    for (final n in [1, 2, 3, 7, 64, 100000]) {
      test('lee los mismos eventos con trozos de $n bytes', () async {
        final eventos = await eventosDe(_enTrozos(utf8.encode(_ndjson), n)).toList();
        expect(eventos.map((e) => e.runtimeType), [
          EventoConversacion,
          EventoNota,
          EventoHerramienta,
          EventoPropuesta,
          EventoRespuesta,
          EventoFin,
        ]);
        final c = eventos[0] as EventoConversacion;
        expect(c.id, 7);
        expect(c.titulo, '¿Qué equipos están sin batería?'); // la tilde partida entre trozos
        final p = (eventos[3] as EventoPropuesta).propuesta;
        expect(p.id, 3);
        expect(p.pendiente, isTrue);
        expect(p.argsLegibles, contains(('Tipo', 'Batería baja')));
        expect(p.argsLegibles, contains(('Avisar a', 'ana@x.com')));
        expect(p.argsLegibles, contains(('Parámetros · Porcentaje', '15')));
        expect((eventos[4] as EventoRespuesta).texto, contains('**2**'));
        final fin = eventos[5] as EventoFin;
        expect((fin.conversacion, fin.entrada, fin.salida), (7, 1200, 80));
      });
    }

    test('la última línea sin salto final también cuenta', () async {
      final eventos = await eventosDe(Stream.value(utf8.encode('{"tipo":"nota","texto":"a"}\n{"tipo":"nota","texto":"b"}'))).toList();
      expect(eventos.map((e) => (e as EventoNota).texto), ['a', 'b']);
    });

    test('una línea rota no tumba la conversación', () async {
      final eventos = await eventosDe(Stream.value(utf8.encode('{"tipo":"nota","texto":"a"}\nesto no es json\n\n'
          '{"tipo":"error","error":"ia_sin_saldo","mensaje":"402"}\n'))).toList();
      expect(eventos[0], isA<EventoNota>());
      expect(eventos[1], isA<EventoIlegible>());
      final e = eventos[2] as EventoError;
      expect(e.codigo, 'ia_sin_saldo');
      expect(e.paraLaPersona, startsWith('Tu cuenta del proveedor se quedó sin saldo'));
      expect(e.paraLaPersona, endsWith('(402)'));
    });
  });

  group('HubCliente.chat', () {
    test('con 200 devuelve los eventos según llegan, con el token y el desfase', () async {
      late http.BaseRequest pedido;
      late String cuerpo;
      final cliente = HubCliente(
        hub: 'https://hub.test',
        token: 'tk',
        cliente: MockClient.streaming((req, cuerpoReq) async {
          pedido = req;
          cuerpo = await cuerpoReq.bytesToString();
          return http.StreamedResponse(_enTrozos(utf8.encode(_ndjson), 5), 200,
              headers: {'content-type': 'application/x-ndjson'});
        }),
      );
      final eventos = await (await cliente.chat({'mensaje': 'hola', 'desfase_min': -240})).toList();
      expect(pedido.url.toString(), 'https://hub.test/v1/ia/chat');
      expect(pedido.headers['authorization'], 'Bearer tk');
      expect(jsonDecode(cuerpo), {'mensaje': 'hola', 'desfase_min': -240});
      expect(eventos.last, isA<EventoFin>());
    });

    test('si no es 200 es un error normal: conversacion_larga', () async {
      final cliente = HubCliente(
        hub: 'https://hub.test',
        token: 'tk',
        cliente: MockClient((_) async => http.Response(
              jsonEncode({'error': 'conversacion_larga', 'mensaje': 'Esta conversación ya es muy larga: empieza una nueva'}),
              409,
            )),
      );
      await expectLater(
        cliente.chat({'mensaje': 'hola'}),
        throwsA(isA<HubError>()
            .having((e) => e.codigo, 'codigo', 'conversacion_larga')
            .having((e) => e.estado, 'estado', 409)
            .having((e) => e.mensaje, 'mensaje', contains('empieza una nueva'))),
      );
    });
  });

  group('HubCliente', () {
    test('enseña el mensaje del hub', () async {
      final cliente = HubCliente(
        hub: 'https://hub.test',
        cliente: MockClient((_) async =>
            http.Response(jsonEncode({'error': 'credenciales_invalidas', 'mensaje': 'Correo o clave incorrectos'}), 401)),
      );
      await expectLater(
        cliente.post('/v1/auth/login', {'correo': 'a@b.c', 'clave': 'x'}),
        throwsA(isA<HubError>().having((e) => e.mensaje, 'mensaje', 'Correo o clave incorrectos')),
      );
    });

    test('un 401 con sesión avisa que venció; sin sesión (el login), no', () async {
      var vencida = 0;
      http.Client da401() => MockClient((_) async => http.Response('{"error":"no_autorizado","mensaje":"x"}', 401));
      final conToken = HubCliente(hub: 'https://hub.test', token: 'tk', cliente: da401(), alVencer: () => vencida++);
      await expectLater(conToken.get('/v1/yo'), throwsA(isA<HubError>()));
      expect(vencida, 1);
      final sinToken = HubCliente(hub: 'https://hub.test', cliente: da401(), alVencer: () => vencida++);
      await expectLater(sinToken.post('/v1/auth/login'), throwsA(isA<HubError>()));
      expect(vencida, 1);
    });

    test('un 204 es un objeto vacío y una página que no es JSON se explica', () async {
      final vacio = HubCliente(hub: 'https://hub.test', cliente: MockClient((_) async => http.Response('', 204)));
      expect(await vacio.borra('/v1/tableros/3'), isEmpty);
      final html = HubCliente(hub: 'https://hub.test', cliente: MockClient((_) async => http.Response('<html>', 200)));
      await expectLater(
        html.get('/v1/yo'),
        throwsA(isA<HubError>().having((e) => e.mensaje, 'mensaje', contains('¿Es la dirección de un hub?'))),
      );
    });
  });

  group('normalizaHub', () {
    test('acepta la dirección como la escriba la gente', () {
      expect(normalizaHub('devicetrack.chalonasoft.com'), 'https://devicetrack.chalonasoft.com');
      expect(normalizaHub(' https://hub.miempresa.com/ '), 'https://hub.miempresa.com');
      expect(normalizaHub('https://hub.miempresa.com/#/panel'), 'https://hub.miempresa.com');
      expect(normalizaHub('http://192.168.1.10:3140'), 'http://192.168.1.10:3140');
      expect(normalizaHub(''), isNull);
      expect(normalizaHub('ftp://x.com'), isNull);
    });
  });
}
