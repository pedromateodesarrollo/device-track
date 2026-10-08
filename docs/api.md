# API de device-track

> El hub cumple este contrato y lo prueba de punta a punta contra Postgres
> (`hub/test/hub_test.dart`). Los clientes (`cliente/dart` y
> `cliente/flutter`) lo prueban contra un hub falso.

Todo lo que hace el panel se puede hacer por API. La base es la dirección de tu
hub y las respuestas son JSON. Un error siempre es
`{"error": "<código>", "mensaje": "<texto para una persona>"}` con su código
HTTP.

Hay dos lados:

* **El equipo** (el agente o una app con el plugin): se da de alta, reporta,
  recibe órdenes. Usa su propia credencial, la del equipo, no la de una persona.
* **Quien lo administra** (el panel, un script, un ERP): ve el inventario, el
  mapa y las alertas, y le manda órdenes al equipo.

## Credenciales

| Prefijo | Qué es | Quién la tiene | Qué permite |
|---|---|---|---|
| `dta_` | Código de alta | Un QR en la pared, una app nuestra compilada | Dar de alta equipos en UNA organización. Nada más. |
| `dtd_` | Credencial del equipo | El equipo, después del alta | Reportar y recibir órdenes de ESE equipo |
| `dtk_` | Llave de API | Un script, un ERP | Lo que digan sus permisos: `leer`, `editar`, `ordenar`, `admin`; y, si se limita, solo en sus dominios |
| JWT | Sesión de persona | El panel | Según el rol: `admin` todo; `editor` lee, edita y ordena; `consulta` solo lee; y, si se limita, solo en sus dominios |

Todas viajan en `authorization: Bearer ...`. Del secreto se guarda solo el
hash: se enseña una vez, al crearlo.

Cada alta gasta un uso del código, también la de una segunda fuente en el
mismo teléfono (el agente después de la app): pon el tope pensando en eso.

**Un código de alta va dentro de un APK, y un APK es público.** Por eso solo
sirve para dar de alta, y cada código tiene tope de usos y vencimiento. Un
equipo dado de alta con un código robado aparece en el panel como cualquier
otro, y se borra. Un código se puede anular sin tocar los equipos que ya entraron
con él.

## Dominios

Un **dominio** agrupa equipos dentro de la organización: una empresa a la que
le das servicio, un almacén, una sucursal. Cada equipo está en uno, y entra en
el del código de alta con que se dio de alta. Toda organización tiene el
dominio **General** (slug `general`), donde cae lo que no tiene otro; quien no
necesite la separación se queda con ese.

A una persona del panel o a una llave de API se le puede **limitar a uno o
varios dominios** (`dominios: [...]`; vacío = toda la organización). Entonces
solo ve y maneja los equipos de esos dominios, con sus códigos de alta, zonas,
reglas y alertas: un equipo de otro dominio, para ella, no existe (404). Así el
encargado de un cliente ve lo suyo y el administrador, todo.

* Administrar (personas, llaves, dominios, la organización) es de toda la
  organización: una persona limitada es `editor` o `consulta`, y una llave
  limitada no lleva `admin` (`400 admin_sin_dominios`).
* Lo que crea una sesión limitada cae en su dominio. Si alcanza varios, tiene
  que decir cuál (`400 falta_dominio`); uno que no alcanza es
  `400 dominio_invalido`.
* Una zona o una regla **sin dominio** es de toda la organización: la ve
  cualquiera (aplica también a sus equipos), pero solo la toca quien alcanza
  toda la organización.
* El dominio y el rol se leen de la base en cada petición: quitárselo a alguien
  vale en el acto, no cuando venza su sesión.

Donde se pide un dominio se acepta su `id` o su `slug`.

| | |
|---|---|
| `GET /v1/dominios` | Los que la sesión alcanza, con cuántos equipos (no retirados) tiene cada uno. |
| `POST /v1/dominios` | `{nombre, slug?, descripcion?}`. Sin `slug`, sale del nombre. Permiso `admin`. |
| `PATCH /v1/dominios/:id` | `{nombre?, descripcion?}`. El slug no cambia: es lo que tiene escrito un script. Permiso `admin`. |
| `DELETE /v1/dominios/:id` | Solo uno vacío: con equipos, códigos de alta vigentes, personas o llaves es `409 dominio_en_uso` (el mensaje dice qué le queda); el General, `409 dominio_general`. Sus zonas y reglas se van con él. Permiso `admin`. |

## Un equipo es uno solo

El agente y una app con el plugin pueden estar en el mismo teléfono. Los dos
reportan, y en el panel es UN equipo con dos **fuentes**.

El hub los junta por la **huella**: el `ANDROID_ID`. Desde Android 8 ese número
depende de la llave con que se firmó la app: todas las apps firmadas con la
misma llave (el agente y las nuestras) ven el mismo; una firmada con otra llave
ve otro. Si llegan distintos, se juntan por la `serie` cuando el equipo la da
(las Zebra, por ejemplo), o a mano desde el panel («unir equipos»).

## El equipo

### `POST /v1/alta`

*Credencial: código de alta (`dta_`)*

El primer contacto. Si en la organización ya hay un equipo con esa huella (o
esa serie), se le suma la fuente nueva y se devuelve el mismo `equipo`. Repetir
el alta desde la misma fuente revoca la credencial anterior de esa fuente.

| Campo | Tipo | Obligatorio | |
|---|---|---|---|
| `huella` | texto | sí | El `ANDROID_ID` (o lo que identifique al equipo en otra plataforma). |
| `fuente.tipo` | texto | sí | `agente` o `app`. |
| `fuente.paquete` | texto | sí | El `applicationId` de quien reporta. |
| `fuente.nombre` | texto | no | El nombre de la app como se ve en el teléfono («WMS Duralon»). El panel lo enseña en la columna «Aplicación»; sin él, busca el paquete en la lista de apps del equipo y, si no está, enseña el paquete. |
| `fuente.version` | texto | no | `versionName`. |
| `fuente.build` | entero | no | `versionCode`. |
| `equipo.modelo` | texto | no | `Build.MODEL`. |
| `equipo.fabricante` | texto | no | `Build.MANUFACTURER`. |
| `equipo.android` | entero | no | Nivel de SDK. |
| `equipo.serie` | texto | no | Número de serie, si el equipo lo da. |
| `equipo.nombre` | texto | no | Nombre sugerido (si el equipo es nuevo). |

```json
{
  "equipo": { "id": 42, "nombre": "TC51 · 4f2a" },
  "credencial": "dtd_9a8b7c6d_…",
  "config": { "intervalo_s": 600, "ubicacion": true },
  "ws": "wss://TU-HUB/v1/ws"
}
```

### `POST /v1/reporte`

*Credencial: la del equipo (`dtd_`)*

El latido. El agente lo manda cada `intervalo_s` (10 minutos por defecto, lo
que deja Android con el teléfono dormido); una app con el plugin, mientras está
abierta y al volver al frente. Todo es opcional salvo lo que se quiera contar:
lo que no viene, no cambia.

Sin red, el equipo guarda los reportes y los manda juntos en `reportes`, cada
uno con su hora. El historial queda con la hora en que pasó, no con la hora en
que llegó.

| Campo | Tipo | |
|---|---|---|
| `t` | fecha ISO | Cuándo se tomó (por defecto, ahora). |
| `motivo` | texto | `periodico`, `encendido`, `apagando`, `orden`, `abrir` (la app se abrió) o `manual`. |
| `bateria` | entero | 0–100. |
| `cargando` | sí/no | |
| `red.tipo` | texto | `wifi`, `datos`, `ninguna`. |
| `red.ssid` | texto | Nombre de la red Wi-Fi (Android pide permiso de ubicación para darlo). |
| `ubicacion` | objeto | `{lat, lng, precision_m, t}`. Solo si la organización la pide y el equipo dio el permiso. |
| `almacenamiento` | objeto | `{libre, total}` en bytes. |
| `apps` | lista | `[{paquete, version, build}]`. Mandarla solo cuando cambia: el hub guarda la última. |
| `contexto` | objeto | Lo que la app quiera contar: empresa, quién tiene la sesión, almacén. Se guarda por fuente. Hasta 4 KB. |
| `fuente` | objeto | `{nombre, version, build}` de quien reporta, por si la app se actualizó desde el alta. Lo que no viene se queda como estaba. |
| `reportes` | lista | Reportes atrasados, cada uno con estos mismos campos y su `t`. |

**Claves de convención en `contexto`.** El contexto es libre, pero el panel
entiende tres claves, si vienen:

| Clave | Tipo | Qué hace el panel |
|---|---|---|
| `usuario` | texto | Quién tiene (o tuvo) la sesión de la app. Sale en la lista de equipos como «Último usuario», tomado de la fuente que reportó más reciente. |
| `almacen` o `lugar` | texto | Dónde trabaja: va debajo del usuario. |
| `sesion` | sí/no | `false` = la app ya cerró la sesión, pero el `usuario` es el de la última; el panel lo marca «sin sesión». Es justo lo que se pregunta cuando un equipo no aparece. |

Ejemplo (la app de un almacén): `{"usuario": "Ana Pérez", "usuario_id": 42,
"empresa": 7, "almacen": "A1 · Repuestos", "sesion": true}`.

La respuesta trae la configuración vigente y las órdenes que estén esperando:
un equipo sin WebSocket también se entera, en el siguiente reporte.

```json
{
  "config": { "intervalo_s": 600, "ubicacion": true },
  "ordenes": [ { "id": 7, "tipo": "sonar", "datos": { "segundos": 30 } } ]
}
```

### `POST /v1/ordenes/:id/estado`

*Credencial: la del equipo (`dtd_`)*

El equipo dice qué pasó con una orden.

| Campo | Tipo | |
|---|---|---|
| `estado` | texto | `recibida`, `hecha` o `fallida`. |
| `detalle` | texto | Opcional: por qué falló, quién la tocó. |

### `GET /v1/ws`

*Credencial: la del equipo (`dtd_`), en la cabecera*

Mientras está abierto, el equipo figura **conectado** y las órdenes le llegan
al instante. Si se cae, el equipo reconecta con espera creciente y, mientras
tanto, las órdenes le llegan en la respuesta del siguiente reporte.

Del hub al equipo:

```json
{ "tipo": "orden", "orden": { "id": 7, "tipo": "sonar", "datos": { "segundos": 30 } } }
{ "tipo": "config", "config": { "intervalo_s": 300, "ubicacion": true } }
```

### Órdenes que entiende el agente

| Tipo | Datos | Qué hace |
|---|---|---|
| `sonar` | `{segundos}` | Suena a todo volumen aunque esté en silencio, hasta que lo toquen o pase el tiempo. Para encontrarlo en el almacén. |
| `mensaje` | `{titulo, texto}` | Muestra un aviso en la pantalla: «Devuelve este equipo a la oficina». |
| `reportar` | — | Manda un reporte ya, con ubicación recién leída. |

Una app con el plugin decide qué órdenes atiende; la que no entiende, la
contesta `fallida` con `detalle: "no_soportada"`.

**Si el equipo tiene el agente conectado, las órdenes van solo al agente**: ni
por el socket ni en la respuesta del reporte le llegan a una app del mismo
teléfono. Sin agente conectado van a quien esté, y la primera que la acusa
`hecha` la cierra.

## Quien administra

### Equipos

Cada ruta pide un permiso: `leer` para mirar, `editar` para cambiar la ficha,
zonas, reglas y códigos de alta, `ordenar` para mandarle órdenes a un equipo y
`admin` para borrar, la organización, las personas y las llaves.

| | |
|---|---|
| `GET /v1/resumen` | Cuántos equipos, conectados, perdidos, sin contacto en 24 h y alertas abiertas (de los dominios que alcanzas). |
| `GET /v1/equipos` | El inventario. Filtros: `q` (nombre, etiqueta, serie, modelo, asignado a), `dominio`, `estado`, `conectado=1/0`, `alerta=1`, `sin_contacto=1` (más de 24 h sin contacto, la misma cuenta del resumen), `retirados=1`. Cada uno con su `dominio` (id) y `dominio_nombre`, su último reporte resumido y sus fuentes (`tipo`, `paquete`, `nombre`, `version`, `ultima_vez`, `contexto`; la que reportó más reciente, primero: es la «Aplicación» de la lista del panel). |
| `GET /v1/equipos/:id` | Ficha: datos, fuentes con su contexto, último reporte, apps instaladas, alertas abiertas. |
| `PATCH /v1/equipos/:id` | `nombre`, `etiqueta` (número de activo), `serie`, `dominio`, `asignado_a`, `notas`, `estado` (`activo`, `guardado`, `perdido`, `retirado`). Cambiarlo de dominio cierra las alertas de reglas del dominio que deja. |
| `GET /v1/equipos/:id/recorrido` | Puntos de ubicación entre `desde` y `hasta` (fechas ISO; por defecto, las últimas 24 horas). |
| `GET /v1/equipos/:id/reportes` | El historial completo entre `desde` y `hasta` (por defecto, las últimas 24 horas), hasta `limite` filas. |
| `POST /v1/equipos/:id/ordenes` | `{tipo, datos, vence_min?}` (por defecto vence en 60 min). Permiso `ordenar`. |
| `GET /v1/equipos/:id/ordenes` | Las últimas órdenes y en qué quedaron. |
| `POST /v1/equipos/:id/unir` | `{con: <id>}`: dos filas que eran el mismo equipo pasan a ser una. |
| `DELETE /v1/equipos/:id` | Lo saca del inventario y revoca sus credenciales. El historial se borra. Permiso `admin`. |

**Retirar no es borrar.** `estado: retirado` deja la ficha y el historial, y el
equipo deja de contar para las alertas. Borrar es para lo que entró por error.

### Códigos de alta

| | |
|---|---|
| `GET /v1/altas` | Los códigos, con su dominio y cuántos equipos entraron con cada uno. |
| `POST /v1/altas` | `{nombre, dominio?, usos_max?, vence_dias?}` (o `vence` como fecha ISO). Devuelve el código UNA vez en `codigo`, y en `qr` el texto que va en el código QR: `devicetrack://alta?hub=<tu hub>&codigo=<código>`. Los equipos NUEVOS que entren con él caen en su `dominio` (sin él: el General, o el único que alcances). Uno que ya existía y se da de alta otra vez no cambia de dominio. |
| `DELETE /v1/altas/:id` | Lo anula. Los equipos que ya entraron siguen. |

### Zonas y alertas

| | |
|---|---|
| `GET/POST/PATCH/DELETE /v1/zonas` | Una zona es un círculo: `{nombre, lat, lng, radio_m, dominio?}`. El almacén, la sucursal. Sin `dominio` es de toda la organización. |
| `GET/POST/PATCH/DELETE /v1/reglas` | Qué vigilar, para todos o para un dominio: `{tipo, nombre?, dominio?, parametros, activa?}`. Sin `dominio` vigila a todos los equipos de la organización. El `PATCH` cambia solo lo que trae (`{activa: false}` la apaga y deja lo demás); el tipo no se cambia. Si cambian el dominio, los parámetros o si está activa, sus alertas abiertas se cierran. Una regla `fuera_de_zona` usa una zona de toda la organización o de su mismo dominio. |
| `GET /v1/alertas` | Las alertas abiertas (y las cerradas, con `todas=1`), con el `dominio` y `dominio_nombre` del equipo. |
| `POST /v1/alertas/:id/cerrar` | La cierra a mano, con una nota. |

Tipos de regla:

| Tipo | Parámetros | Se abre cuando | Se cierra cuando |
|---|---|---|---|
| `sin_reporte` | `minutos` | El equipo pasa ese tiempo sin reportar | Vuelve a reportar |
| `bateria_baja` | `porcentaje` | Reporta por debajo, sin cargar | Lo ponen a cargar o sube |
| `fuera_de_zona` | `zona` | Su ubicación queda fuera (descontando la precisión) | Vuelve a entrar |
| `apagado` | — | Avisa que se apaga | Vuelve a encender |

Cada regla avisa en el panel y, si la organización lo configura, por
**webhook**: un POST con la alerta, el equipo (con su `dominio`: `{id, nombre, slug}`) y su última posición, para que el
sistema de cada quien haga lo que quiera (un correo, un mensaje, un ticket).
Va firmado: `X-Device-Track-Firma: sha256=<HMAC-SHA256 del cuerpo con el
secreto>`, y `X-Device-Track-Evento` dice `alerta_abierta`, `alerta_cerrada` o
`prueba`. Sin reintentos: lo que no llega se ve en el panel igual. El correo
directo desde el hub queda para más adelante.

Cerrar una alerta a mano no apaga la regla: si la condición sigue, la próxima
evaluación la vuelve a abrir.

### Organización, personas y llaves

Igual que apk-server: `POST /v1/auth/login`, `/v1/usuarios` (con invitación por
enlace de un solo uso, que además se manda por correo si la organización tiene
correo de salida: la respuesta de `POST /v1/usuarios` y de
`POST /v1/usuarios/:id/invitacion` trae `enlace` siempre y `envio`, que es
`null` sin correo de salida, `{enviado: true, para}` o `{enviado: false,
error, detalle}`; `PATCH /v1/usuarios/:id` cambia `rol`, `nombre` o
`dominios`, solo lo que venga) y `/v1/llaves`. Personas y llaves llevan
`dominios: [...]` (ids o slugs; vacío = toda la organización). `GET /v1/yo`
dice los dominios de quien pregunta: `dominios: [{id, nombre, slug}]`, vacío si
alcanza toda la organización.

| | |
|---|---|
| `GET /v1/org` | La configuración: `intervalo_s`, `ubicacion`, `dias_historial`, si el webhook va firmado y —solo para `admin`, porque suele llevar su propio token— `webhook_url` y `correo` (el correo de salida, sin la clave: `clave_puesta` y `configurado`). |
| `PATCH /v1/org` | Cambiarla. Los equipos conectados reciben la configuración nueva al instante; los demás, en su próximo reporte. |
| `POST /v1/org/webhook/secreto` | Genera el secreto con que se firma el webhook. Se enseña una vez. |
| `POST /v1/org/webhook/prueba` | Manda un POST de prueba y dice qué contestó. |
| `PUT /v1/org/correo` | El correo de salida, con el que salen las invitaciones: `host`, `puerto`, `seguridad` (`tls` = TLS directo, 465; `starttls`, 587; `ninguna`, solo en una red propia), `remitente`, `usuario`, `clave`, `nombre` (el que se ve en el «De:»). La `clave` no vuelve nunca; si no viene, o viene vacía, se queda la que estaba. `{"quitar": true}` lo borra. Solo `admin`. |
| `POST /v1/org/correo/prueba` | Manda un correo de prueba a quien lo pide. Si el servidor no lo acepta, `502` con lo que contestó (`correo_autenticacion`, `correo_conexion`, `correo_tls`, `correo_sin_starttls`, `correo_rechazado`, `correo_tiempo`). |

El historial de reportes se borra solo pasados `dias_historial` (90 por
defecto), y una orden que nadie contestó pasa a `vencida` a su hora.

## Lo que NO hace

* **Bloquear, borrar o encerrar el equipo en una sola app (modo quiosco).** Eso
  es administración de dispositivos (MDM) y se hace con Android Enterprise.
  Este servicio sabe dónde está el equipo y le habla; no lo gobierna.
* **Seguir a escondidas.** El agente lleva siempre una notificación fija que
  dice de quién es el equipo y que reporta su ubicación. Android la exige de
  todos modos para un servicio que corre en segundo plano.

## Clientes

* **Agente** (`agente/`, Kotlin; ver [agente/README.md](../agente/README.md)): una app aparte para cualquier equipo,
  tenga o no apps propias. Corre en segundo plano, reporta con el teléfono
  dormido, atiende las órdenes. Se da de alta escaneando el QR de un código.
* **Plugin Flutter** (`cliente/flutter`, paquete `device_track_flutter`): para meterlo en una app que ya existe.
  Lee del equipo lo mismo que el agente (con el mismo código Kotlin), reporta
  mientras la app está abierta y deja que la app atienda las órdenes que quiera.
* **Dart puro** (`cliente/dart`, paquete `device_track`): solo el protocolo, para servidores y otras
  plataformas.
* **Cualquier otro lenguaje**: este documento.

## Meterlo en tu app Flutter

```dart
final equipos = DeviceTrack(
  servidor: 'https://TU-HUB',
  codigo: 'dta_…',                            // código de alta, compilado en la app
  contexto: () => {'empresa': 7, 'sesion': true},
  alOrden: (orden) async => mostrarAviso(orden), // «mensaje»; true si lo atendió
);
equipos.iniciar();
```

El plugin hace el alta (fuente `app`, con el `applicationId` y el nombre de la
app), los reportes
(al abrir, cada `intervalo_s` con la app al frente y al volver al frente), la
cola sin red, el WebSocket mientras la app está abierta y el acuse de las
órdenes: `sonar` y `reportar` los atiende solo, `mensaje` va a `alOrden` y lo
demás se contesta `fallida` con `no_soportada`. Permisos, órdenes y la pantalla
«Acerca de»: [cliente/flutter/README.md](../cliente/flutter/README.md).
