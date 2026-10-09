# Cambios

## Sin publicar

* **El panel en Android** (`app/`): una app Flutter con los tableros de
  Inicio, los equipos con su ficha (Sonar, Mensaje, Reportar ya, Editar), las
  alertas, el asistente y, en Más, el mapa, las reglas, las personas y la
  cuenta. Habla con el mismo API que el panel web, con la sesión de la persona.
  Se instala desde https://apk.chalonasoft.com/i/devicetrack-panel y se
  actualiza sola con apk-server; en el panel web, **Mi cuenta** trae el enlace
  y su QR.
* **Asistente de IA.** Cada organización pone las credenciales de su propia
  cuenta con Anthropic o Gemini (Organización → Asistente IA, migración 0005):
  el hub no trae una clave propia ni le presta a una organización la de otra.
  El asistente usa las mismas rutas del panel, con la sesión de quien pregunta,
  así que ve y hace lo mismo que esa persona. Lo que cambia algo queda
  **propuesto** y la persona lo confirma o lo descarta (migración 0007).
* **Tableros en Inicio.** El Resumen de siempre es el tablero 0; con el
  asistente se personaliza y se arman otros, propios o compartidos, que se
  calculan con la sesión de quien mira.
* **Avisos por correo.** Cada regla puede avisar a unos correos (hasta 20) por
  el correo de salida de la organización: al abrirse la alerta y uno por hora
  por regla y equipo (migración 0006).
* **Agente 0.1.3**, con el arreglo de la ubicación de abajo y la
  actualización nueva. Se instala desde https://apk.chalonasoft.com/i/devicetrack.
* **El agente se actualiza con la biblioteca de apk-server** (0.2.0), que
  entra al build como un proyecto más: para compilarlo, clona
  [apk-server](https://github.com/pedromateodesarrollo/apk-server) junto a
  device-track o di dónde está con `-Papkserver.dir`. El hub y la app de
  apk-server van en el APK (`manifestPlaceholders`).
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
