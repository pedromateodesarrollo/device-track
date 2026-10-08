# Cambios

## Sin publicar

* **Arreglo: la lectura de la ubicación tumbaba la app en Android 10 o
  anterior.** El oyente era una lambda y solo traía `onLocationChanged`; antes
  de la API 30 `onStatusChanged`, `onProviderEnabled` y `onProviderDisabled`
  son abstractos, y cuando el GPS cambiaba de estado (al conseguir satélites)
  `AbstractMethodError` en el hilo `devicetrack-ubicacion` cerraba el proceso
  entero. Afectaba al agente y a toda app con el plugin (visto en Zebra
  TC52/TC56/TC57 con Android 8.1). Ahora el oyente implementa los cuatro.
* **La aplicación que reporta.** La fuente manda el nombre de la app
  (`fuente.nombre`, la etiqueta del lanzador) en el alta y en cada reporte; el
  agente y el plugin lo hacen solos. La lista de equipos tiene la columna
  «Aplicación»: la fuente que reportó más reciente, con su versión y las demás
  debajo. Una app de antes, que no lo manda, sale con el nombre que tenga en la
  lista de apps del equipo. Migración 0004.
* **La lista de equipos se ordena por cualquier columna** (clic en el
  encabezado; en el celular, un selector). Lo vacío va siempre al final y el
  orden se recuerda en el navegador.
* **Dominios** en lugar de grupos: agrupan equipos dentro de la organización
  (un cliente, un almacén) y acotan a quién los ve. Una persona o una llave
  limitada a unos dominios solo ve y maneja sus equipos, códigos de alta,
  zonas, reglas y alertas. Toda organización tiene el dominio General.
  `GET /v1/grupos` pasa a ser `GET /v1/dominios`; el campo `grupo` de equipos,
  códigos, reglas, alertas y webhook pasa a ser `dominio` (+ `dominio_nombre`;
  en el webhook, `{id, nombre, slug}`). La migración 0002 convierte cada grupo
  en un dominio con su nombre, y los códigos de alta siguen valiendo.
  En la consola, `alta --grupo` pasa a ser `alta --dominio`.

## 0.1.0 — sin publicar

Primera versión del hub.

* Alta de equipos con código de alta (`dta_`), una credencial por fuente
  (`dtd_`), el agente y una app en el mismo teléfono son un solo equipo.
* Reporte con batería, red, ubicación, almacenamiento, apps y contexto; reportes
  atrasados en lote.
* Órdenes `sonar`, `mensaje` y `reportar`, por WebSocket o en la respuesta del
  reporte; vencen.
* Zonas, reglas (`sin_reporte`, `bateria_baja`, `fuera_de_zona`, `apagado`),
  alertas y webhook firmado.
* Panel, personas con roles (`admin`, `editor`, `consulta`) y llaves de API.
