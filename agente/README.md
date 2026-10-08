# Agente de device-track (Android)

La app que se instala en un equipo para que device-track lo siga: reporta su
estado cada diez minutos, mantiene el WebSocket con el hub y atiende las
órdenes del panel. Sirve para cualquier equipo Android 7 o más, tenga o no
apps propias. Nativa (Kotlin), 2,5 MB, sin servicios de Google.

## Instalar en un equipo

1. Abre **https://apk.chalonasoft.com/i/devicetrack** en el equipo e instala.
2. En el panel, **Códigos de alta → Crear**. Sale un código y su QR.
3. Abre el agente y dale el código:
   * **Zebra y otras terminales con lector**: con el campo de texto delante,
     escanea el QR con el gatillo. El lector lo escribe y termina con Enter.
   * **Teléfono**: «Escanear con la cámara»; o la cámara del teléfono abre el
     QR (`devicetrack://alta?…`) y lleva al agente.
   * **A mano**: pega el código `dta_…`; pide entonces la dirección del hub.
4. Acepta los permisos que pide, uno a la vez:
   * notificaciones (el aviso fijo y los mensajes);
   * ubicación, y después **«Permitir todo el tiempo»** (solo si la
     organización pide la ubicación);
   * sin ahorro de batería (si no, Android retrasa los reportes).

Desde ahí trabaja solo: con la pantalla cerrada, al reiniciar el equipo y al
actualizarse. Abrir el agente solo sirve para ver qué está reportando y si le
falta un permiso.

## Qué manda

Cada `intervalo_s` de la organización (10 minutos por defecto, lo que Android
deja con el equipo dormido), al encender, al abrir el agente y —con lo que
alcance— al apagarse:

| | |
|---|---|
| Batería y si carga | `BatteryManager` |
| Red y nombre de la Wi-Fi | El nombre pide permiso de ubicación (regla de Android) |
| Ubicación | El servicio de ubicación de Android, GPS y red a la vez, 30 s de plazo. No usa los servicios de Google: hay Zebra sin ellos |
| Espacio libre | La partición de datos |
| Apps instaladas | Las que alguien instaló y las del sistema actualizadas. Solo cuando la lista cambia |
| Serie | En Zebra, por OEMInfo, si el administrador le dio el permiso con StageNow |

Sin red guarda hasta 500 reportes y los manda juntos al volver, cada uno con
su hora.

## Las órdenes

| Orden | Qué hace |
|---|---|
| Hacer sonar | El sonido de alarma a todo volumen en el canal de alarmas (suena en silencio y en «no molestar»), vibrando, hasta que lo toquen o pase el tiempo. Devuelve el volumen como estaba. El panel dice si lo tocaron y a los cuántos segundos |
| Mostrar mensaje | Notificación y pantalla completa, aunque el equipo esté bloqueado |
| Reportar ya | Un reporte con la ubicación recién leída |

Una orden puede llegar dos veces (por el socket y en un reporte); el agente la
hace una sola vez y la vuelve a acusar.

## La notificación fija

Siempre a la vista: «Equipo con seguimiento: *nombre* — reporta su estado y
su ubicación a *hub*». Android la exige para un servicio en segundo plano y es,
además, la regla del proyecto: nada de seguimiento a escondidas.

## Se actualiza solo

Pregunta a apk-server como mucho cada hora, baja con Wi-Fi e instala. Para que
pueda, el equipo tiene que tener permitido **«instalar apps desconocidas»** para
el agente: a mano una vez, o en una flota por StageNow o el MDM.

**La primera actualización pide confirmar una vez** (probado en el emulador,
2026-10-08): Android solo deja instalar sin preguntar a quien instaló la
versión de ahora, y la primera la instaló el navegador o el instalador del
sistema. El agente deja una notificación «Hay una versión nueva — toca para
instalarla». En un teléfono con servicios de Google, Play Protect además pide
revisarla («Scan app» → «Install»); las Zebra sin servicios de Google no lo
tienen. Desde esa primera, el agente es su propio instalador y las siguientes
van sin preguntar (Android 12 o más).

Publicar una versión:

```bash
# subir versionCode (y versionName) en android/app/build.gradle.kts
./publicar-version.sh                # compila y publica en apk-server
./publicar-version.sh --requerido    # todos los equipos tienen que pasar a esta
```

## Compilar tu propio agente

Si montas tu propio hub, compílalo con tus direcciones (o ponlas en
`android/gradle.properties`):

```bash
cd android
./gradlew assembleRelease \
  -Pdevicetrack.hub=https://equipos.tu-dominio.com \
  -Pdevicetrack.apkServer=https://apk.tu-dominio.com \
  -Pdevicetrack.apkApp=devicetrack
```

| Propiedad | Por defecto | Para qué |
|---|---|---|
| `devicetrack.hub` | `https://devicetrack.chalonasoft.com` | El hub que se ofrece cuando el código de alta viene suelto (`dta_…`); el QR ya trae el suyo |
| `devicetrack.apkServer` | `https://apk.chalonasoft.com` | De dónde se actualiza solo ([apk-server](https://github.com/pedromateodesarrollo/apk-server)). Vacío = no se actualiza |
| `devicetrack.apkApp` | `devicetrack` | Cómo se llama la app en ese apk-server |

Y decide con qué llave firmarlo (`signingConfig` en `app/build.gradle.kts`):
tal como está, firma con la llave de depuración de la máquina que compila
(`~/.android/debug.keystore`), que no va en el repositorio.

## Firma

El agente que se publica en apk.chalonasoft.com va firmado con la misma llave
que las apps de Chalona. Con la misma llave, el agente y las apps ven el mismo
ANDROID_ID y el hub los junta en un solo equipo; cambiarla rompe eso y la
actualización. Si firmas el tuyo, firma con esa misma llave tus apps.

## Cómo está armado

| | |
|---|---|
| `android/app/.../agente/` | Lo propio del agente: servicio, alarma, pantallas, órdenes, actualización |
| `../android-comun/` | Lo que comparte con el plugin de Flutter: leer el equipo, ubicación, sonar, hub, cola, WebSocket |

Compila con el SDK de Android y Gradle 9 (`cd android && ./gradlew assembleRelease`).
