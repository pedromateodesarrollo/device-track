# device-track

**Una página web donde ves todos los teléfonos y terminales Android de tu
empresa: cuáles tienes, dónde están, si siguen funcionando y quién los está
usando. Y si uno se pierde, lo haces sonar desde la página para encontrarlo.**

Software libre y gratis (licencia Apache 2.0): lo instalas en tu propio servidor.

> **In English:** device-track is a free, self-hosted web panel to keep track of
> your company's Android phones and rugged terminals: which ones you have, where
> they are, whether they are still working and who is using them. A small app on
> each device reports battery, network, free storage, installed apps and
> (optionally) location every 10 minutes. From the panel you see them on a list
> and on a map, get alerts (low battery, silent for an hour, left the warehouse,
> switched off), and can make a lost device ring at full volume or show a message
> on its screen. Flutter apps can report through a plugin, without the extra app.
> It never tracks in secret: the device always shows a notification saying it is
> being tracked. The rest of this documentation is in Spanish.

![La lista de equipos: nombre, a quién está asignado, si está conectado, batería y red](docs/img/equipos.jpg)

## ¿Para qué sirve?

Una empresa tiene 20, 50 o 200 equipos Android: las terminales del almacén, los
teléfonos de los repartidores, las tabletas de la tienda. Con el tiempo pasa
siempre lo mismo:

* nadie sabe bien cuántos hay ni quién tiene cuál;
* uno deja de funcionar y nadie se entera hasta que hace falta;
* uno se pierde entre los estantes del almacén, o se queda en la casa de alguien;
* se descargan y nadie los pone a cargar.

device-track resuelve eso con dos cosas: **una app pequeña en cada equipo** y
**una página web** donde los ves todos juntos.

## ¿Cómo funciona?

1. **Instalas la app en el equipo y escaneas un código QR** que te da la
   página. Eso es todo: el equipo aparece en la lista.
2. **Cada 10 minutos el equipo cuenta cómo está**: cuánta batería tiene, a qué
   red está conectado, cuánto espacio le queda, qué apps tiene instaladas y,
   si tú lo pides, dónde está. Lo hace solo, con la pantalla apagada y sin que
   nadie toque nada.
3. **Tú lo ves en la página**: la lista, el mapa, y un aviso cuando algo va mal.

## ¿Qué puedes hacer desde la página?

* **Ver todos tus equipos**, en una lista o en un mapa, y saber cuál está
  conectado ahora y cuándo dio señales por última vez cada uno.
* **Hacerlo sonar**: suena a todo volumen aunque esté en silencio, hasta que
  alguien lo toque. Para encontrarlo cuando no aparece.
* **Mandarle un mensaje** que sale en su pantalla: «Devuelve este equipo a la
  oficina».
* **Ver por dónde anduvo** en el día.
* **Recibir avisos** cuando un equipo se queda sin batería, lleva una hora sin
  dar señales, sale del almacén o lo apagan.
* **Llevar el inventario**: a quién está asignado cada uno, su número de activo
  fijo, su número de serie, en qué dominio está.
* **Separar por dominios**: los equipos de cada cliente, almacén o sucursal, y
  a quién dejas ver cuáles. El encargado de un cliente ve los suyos; tú, todos.
* **Saber quién lo tenía**: si la app que corre en el equipo dice quién tiene la
  sesión, el panel enseña el último usuario de cada uno, y su almacén.
* **Invitar por correo**: cada organización pone su propio correo de salida
  (SMTP) en el panel y las invitaciones le llegan a cada persona. Sin él, la
  invitación es un enlace que compartes tú.

![El mapa con los equipos y las zonas](docs/img/mapa.jpg)

![La ficha de un equipo: su estado, sus datos, por dónde anduvo y los botones para hacerlo sonar o mandarle un mensaje](docs/img/equipo.jpg)

<p>
  <img src="docs/img/celular.jpg" alt="La lista de equipos en el celular" width="260">
  &nbsp;
  <img src="docs/img/agente.jpg" alt="La app en el equipo: a dónde reporta y cuándo fue el último reporte" width="300">
</p>

La página también funciona en el celular (izquierda). A la derecha, la app que
va en cada equipo: dice a dónde reporta y cuándo fue la última vez.

## Lo que NO hace

* **No espía.** El equipo muestra siempre un aviso fijo que dice que tiene
  seguimiento y a dónde reporta. La empresa decide si pide la ubicación, y el
  historial se borra solo (a los 90 días, o lo que la empresa diga).
* **No bloquea, no borra y no encierra el equipo en una sola app.** Eso es otra
  cosa (administración de dispositivos, MDM) y se hace con Android Enterprise.
  device-track sabe dónde está el equipo y le habla; no lo gobierna.

## ¿Cómo lo uso?

* **Para probarlo o usarlo en tu empresa**: monta tu propio servidor, con
  Docker en dos comandos (abajo). Es tuyo: los datos no salen de tu servidor.
* **Si tienes tu propia app Flutter**, no hace falta instalar la app aparte:
  mete el plugin y tu app reporta sola (más abajo).
* **Si tienes otro sistema** (un ERP, un inventario), todo lo que hace la
  página se puede hacer por API: [docs/api.md](docs/api.md).

---

## Para quien lo monta

```
  Equipos                              Hub                         Tú
  ──────────────────────          ──────────────────       ──────────────────
  agente (APK)        ── reporte ─►  inventario        ◄──  panel web
  tu app + plugin     ◄─ órdenes ──  historial, mapa   ◄──  API REST (tu ERP)
                         WebSocket   alertas  ─────────────► webhook
```

Tres piezas: el **hub** (el servidor, en Dart, con Postgres), el **panel** (la
página web, la sirve el mismo hub) y lo que va en el equipo: el **agente** (una
app Android aparte, para cualquier equipo) o el **plugin** dentro de tu app
Flutter. Si un teléfono tiene las dos, es un solo equipo con dos fuentes.

### Cómo llega un equipo

1. En el panel, **Códigos de alta → Crear**. Sale un código (`dta_…`) y su QR.
   El código solo sirve para dar de alta equipos en tu organización; ponle tope
   de usos y vencimiento.
2. En el equipo, instala el agente y escanea el QR; en una Zebra, con el lector.
   O tu app trae el código compilado y se da de alta sola al abrir. El agente
   compilado se puede bajar de https://apk.chalonasoft.com/i/devicetrack (habla
   con el hub que diga el QR); para compilar el tuyo, ver
   [agente/README.md](agente/README.md).
3. El hub le devuelve al equipo su propia credencial (`dtd_…`) y desde ahí
   reporta y escucha órdenes.

### Levantar tu propio hub

```bash
docker compose up -d
docker compose exec hub ./device-track-hub org --nombre "Mi empresa" --correo tu@correo.com
```

La segunda línea crea tu organización y te devuelve el enlace para poner tu
clave. Sin Docker:

```bash
cd hub
dart pub get
DT_DATABASE_URL=postgres://usuario:clave@localhost:5432/device_track \
  dart run bin/device_track_hub.dart
```

Necesita un Postgres. Las migraciones se aplican solas al arrancar, todo en el
esquema `dt`.

| Variable | Por defecto | Para qué |
|---|---|---|
| `DT_DATABASE_URL` | — | Obligatoria |
| `DT_HOST` | `0.0.0.0` | `127.0.0.1` detrás de un nginx en la misma máquina |
| `DT_PUERTO` | 3140 | |
| `DT_SECRETO_JWT` | aleatoria | Fíjala: si cambia, se cierran todas las sesiones |
| `DT_REGISTRO` | `cerrado` | `cerrado` (por invitación) o `abierto` |
| `DT_URL_PUBLICA` | se deduce del proxy | `https://tu-hub`: va en el QR de los códigos de alta |
| `DT_CORS` | `*` | Lista de orígenes separada por comas |
| `DT_MANAGER` | `manager` | Carpeta del panel compilado |

Órdenes de consola, para lo que no se puede hacer desde el panel porque todavía
no hay nadie que entre:

```bash
device-track-hub org --nombre N --correo C     # organización + su administrador (imprime el enlace)
device-track-hub invitar --correo C            # enlace nuevo para alguien que ya existe
device-track-hub llave --org 1 --nombre "ERP" --permisos leer
device-track-hub alta --org 1 --nombre "Terminales" --dominio almacen --usos 50
```

Imprimen el resultado —un enlace, una llave, un código— en stdout y nada más,
para que se pueda mandar directo a un archivo sin que pase por la pantalla.

Con nginx delante: `hub/nginx-hub.conf` (límites de peticiones y el
WebSocket). Con systemd: `hub/deploy-hub.sh`.

### Cómo está armado

| Carpeta | Qué hay |
|---|---|
| `hub/` | Servidor: REST, WebSocket de los equipos, alertas, limpieza. Dart, dos dependencias |
| `manager/` | Sitio web: presentación, documentación y panel |
| `docs/` | Referencia del API |
| `agente/` | El agente: app Android aparte, nativa. Se instala desde apk-server y se actualiza sola. Ver [agente/README.md](agente/README.md) |
| `android-comun/` | El Kotlin que comparten el agente y el plugin |
| `cliente/flutter/` | El plugin de Flutter (`device_track_flutter`), con una app de ejemplo |
| `cliente/dart/` | El protocolo del equipo en Dart puro (`device_track`), para servidores y otras plataformas |
| `android-comun/` | El Kotlin que comparten el agente y el plugin |

### Meterlo en tu app Flutter

```dart
final equipos = DeviceTrack(
  servidor: 'https://tu-hub',
  codigo: 'dta_…',                       // código de alta, compilado en la app
  contexto: () => {'empresa': 7, 'usuario': 'ana'},
);
equipos.iniciar();                       // se da de alta sola, reporta, escucha órdenes
```

Se da de alta la primera vez, reporta mientras la app está abierta y atiende
`sonar` y `reportar` sola (`mensaje`, si la app quiere). La ubicación la
declara y la pide la app. Todo en
[cliente/flutter/README.md](cliente/flutter/README.md).


## Seguridad

Antes de montarlo para clientes conviene leer [SECURITY.md](SECURITY.md).
Fallos de seguridad: pedromateo.desarrollo@gmail.com, no un issue público.

## Licencia

Apache-2.0. Úsalo, cámbialo, móntalo para tus clientes.
