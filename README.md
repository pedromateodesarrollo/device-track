# device-track

Que ningún equipo se pierda: sabes cuáles tienes, dónde están, si siguen vivos
y quién los está usando. Y al que no aparece lo haces sonar desde el panel.

```
  Equipos                              Hub                         Tú
  ──────────────────────          ──────────────────       ──────────────────
  agente (APK)        ── reporte ─►  inventario        ◄──  panel web
  tu app + plugin     ◄─ órdenes ──  historial, mapa   ◄──  API REST (tu ERP)
                         WebSocket   alertas  ─────────────► webhook
```

## Qué resuelve

* **El inventario que nadie lleva.** Cada equipo se da de alta escaneando un
  código QR. Queda con su modelo, su número de serie, a qué grupo pertenece y a
  quién está asignado, y le pones la etiqueta de activo fijo.
* **Saber si sigue vivo.** Cada diez minutos el equipo reporta batería, red,
  espacio libre, las apps que tiene y —si la organización lo pide— su
  ubicación. Con el teléfono dormido también: es lo que Android deja.
* **Encontrar el que se perdió.** «Hacer sonar» lo pone a sonar a todo volumen
  aunque esté en silencio. «Mostrar mensaje» le pone un aviso en pantalla
  («Devuelve este equipo a la oficina»). Y el mapa dice dónde estuvo hoy.
* **Enterarte antes que nadie.** Reglas: el equipo que pasa una hora sin
  reportar, el que se quedó sin batería, el que salió del almacén, el que se
  apagó. Avisan en el panel y por webhook, firmado, a tu sistema.
* **Sin instalar nada si ya tienes una app.** Las apps Flutter meten el plugin y
  reportan solas. Para los demás equipos está el agente, una app aparte. Si un
  teléfono tiene las dos, es UN equipo con dos fuentes.

## Cómo llega un equipo

1. En el panel, **Códigos de alta → Crear**. Sale un código (`dta_…`) y su QR.
   El código solo sirve para dar de alta equipos en tu organización; ponle tope
   de usos y vencimiento.
2. En el equipo, instala el agente (en el hub de Chalona:
   https://apk.chalonasoft.com/i/devicetrack) y escanea el QR; en una Zebra, con
   el lector. O tu app trae el código compilado y se da de alta sola al abrir.
3. El hub le devuelve al equipo su propia credencial (`dtd_…`) y desde ahí
   reporta y escucha órdenes.

Todo lo que hace el panel se puede hacer por API: ver [docs/api.md](docs/api.md).

## Levantar tu propio hub

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
device-track-hub alta --org 1 --nombre "Terminales" --grupo "Almacén" --usos 50
```

Imprimen el resultado —un enlace, una llave, un código— en stdout y nada más,
para que se pueda mandar directo a un archivo sin que pase por la pantalla.

Con nginx delante: `hub/nginx-hub.conf` (límites de peticiones y el
WebSocket). Con systemd: `hub/deploy-hub.sh`.

## Cómo está armado

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

## Meterlo en tu app Flutter

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

## Privacidad

device-track sabe dónde está un equipo. Eso es justo lo que se quiere con una
terminal de almacén y es delicado con el teléfono de una persona:

* El agente lleva siempre una notificación fija que dice de quién es el equipo
  y que reporta su ubicación.
* La organización decide si se pide la ubicación (`ubicacion` en su
  configuración). Apagada, el equipo no la manda y el hub no la guardaría.
* El historial se borra solo a los `dias_historial` (90 por defecto).

No es un sistema para seguir a nadie a escondidas, y no se va a convertir en
uno.

## Lo que NO hace

Bloquear o borrar un equipo a distancia, o encerrarlo en una sola app (modo
quiosco). Eso es administración de dispositivos (MDM) y se hace con Android
Enterprise. device-track sabe dónde está el equipo y le habla; no lo gobierna.

## Seguridad

Antes de montarlo para clientes conviene leer [SECURITY.md](SECURITY.md).
Fallos de seguridad: pedromateo.desarrollo@gmail.com, no un issue público.

## Licencia

Apache-2.0. Úsalo, cámbialo, móntalo para tus clientes.
