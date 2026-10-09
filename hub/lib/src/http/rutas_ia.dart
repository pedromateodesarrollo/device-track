import 'dart:convert';

import '../ia/config.dart';
import '../ia/proveedor.dart';
import '../ia/uso.dart';
import 'servidor.dart';

/// Las credenciales del asistente de IA (migración 0005).
///
/// Son de cada organización: las pone quien la administra, con la cuenta de
/// ella en el proveedor. El hub no trae una clave propia, y una organización
/// sin credenciales simplemente no tiene asistente.
///
/// [base] cambia la dirección del proveedor (solo para las pruebas).
void registraRutasIa(Servidor s, {Uri? base}) {
  s.ruta('GET', '/v1/org/ia', (p) async {
    final c = ConfigIa.deJson((await p.bd.fila('select ia from dt.org where id = @o', {'o': p.s.org}))?['ia']);
    final uso = await p.bd.fila(
      '''select coalesce(sum(entrada), 0)::int as entrada, coalesce(sum(salida), 0)::int as salida,
                count(*)::int as llamadas
           from dt.ia_uso where org = @o and t > now() - interval '30 days' ''',
      {'o': p.s.org},
    );
    return Respuesta.ok({
      ...?c?.publico(),
      if (c == null) 'configurado': false,
      if (c == null) 'disponible': false,
      'proveedores': {
        for (final id in ConfigIa.proveedores) id: {'nombre': ConfigIa.nombres[id], 'modelos': ConfigIa.modelos[id]},
      },
      'uso_30_dias': uso,
    });
  }, permiso: 'admin');

  // La clave no vuelve nunca. Si no viene, o viene vacía, se queda la que
  // estaba, salvo que cambie el proveedor: la clave de uno no sirve en otro.
  // `{quitar: true}` lo borra todo.
  s.ruta('PUT', '/v1/org/ia', (p) async {
    if (p.cuerpo['quitar'] == true) {
      await p.bd.ejecuta("update dt.org set ia = '{}'::jsonb where id = @o", {'o': p.s.org});
      return Respuesta.ok({'configurado': false, 'disponible': false});
    }
    final actual = ConfigIa.deJson((await p.bd.fila('select ia from dt.org where id = @o', {'o': p.s.org}))?['ia']);
    final proveedor = p.texto('proveedor').toLowerCase();
    if (!ConfigIa.proveedores.contains(proveedor)) {
      return Respuesta.falla(400, 'proveedor_invalido', 'El proveedor es ${ConfigIa.proveedores.join(' o ')}');
    }
    final modelo = p.texto('modelo', porDefecto: ConfigIa.modelos[proveedor]!.first).toLowerCase();
    if (!ConfigIa.formatoModelo.hasMatch(modelo)) {
      return Respuesta.falla(400, 'modelo_invalido', 'El modelo es un nombre como ${ConfigIa.modelos[proveedor]!.first}');
    }
    final mismaCuenta = actual != null && actual.proveedor == proveedor;
    final clave = p.texto('clave').isNotEmpty ? p.texto('clave') : (mismaCuenta ? actual.clave : '');
    if (clave.isEmpty) {
      return Respuesta.falla(400, 'falta_clave', 'Pon la clave de API de tu cuenta en ${ConfigIa.nombres[proveedor]}');
    }
    final c = ConfigIa(
      proveedor: proveedor,
      modelo: modelo,
      clave: clave,
      activo: p.cuerpo['activo'] is bool ? p.cuerpo['activo'] as bool : (actual?.activo ?? true),
    );
    await p.bd.ejecuta('update dt.org set ia = @c::jsonb where id = @o', {'c': jsonEncode(c.aJson()), 'o': p.s.org});
    return Respuesta.ok(c.publico());
  }, permiso: 'admin');

  // Una pregunta mínima al proveedor con lo guardado: si contesta, el
  // asistente funcionará. Si no, dice qué contestó (clave mala, modelo que no
  // existe, sin saldo).
  s.ruta('POST', '/v1/org/ia/prueba', (p) async {
    final c = ConfigIa.deJson((await p.bd.fila('select ia from dt.org where id = @o', {'o': p.s.org}))?['ia']);
    if (c == null || !c.completa) {
      return Respuesta.falla(400, 'ia_sin_configurar', 'Primero guarda el proveedor, el modelo y la clave');
    }
    final proveedor = IaProveedor.de(c, base: base, espera: const Duration(seconds: 60));
    try {
      final v = await proveedor.turno(
        instruccion: 'Eres el asistente de device-track. Contesta en español, en una sola línea.',
        mensajes: [proveedor.mensajeUsuario('Prueba de conexión: di «Listo, funciono» y nada más.')],
        maxSalida: 1024,
        esfuerzo: 'low',
      );
      await registraUso(
        p.bd,
        org: p.s.org,
        usuario: p.s.usuario,
        llave: p.s.llave,
        origen: 'prueba',
        proveedor: c.proveedor,
        modelo: v.modelo,
        uso: v.uso,
      );
      return Respuesta.ok({
        'funciona': true,
        'modelo': v.modelo,
        'respuesta': v.texto.length > 200 ? '${v.texto.substring(0, 200)}…' : v.texto,
        'entrada': v.uso.entrada,
        'salida': v.uso.salida,
      });
    } on IaError catch (e) {
      return Respuesta.falla(502, e.codigo, e.detalle);
    }
  }, permiso: 'admin');
}
