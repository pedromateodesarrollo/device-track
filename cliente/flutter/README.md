# device_track_flutter

device-track dentro de una app Flutter: el equipo se da de alta solo, reporta
mientras la app está abierta y atiende las órdenes del panel. Sin instalar el
agente.

Lee del equipo lo mismo que el agente y con el mismo código Kotlin
(`device-track/android-comun`): huella, modelo, batería, red, espacio, apps
instaladas y —si la app tiene el permiso— la ubicación. El protocolo lo pone el
paquete `device_track` (`../dart`), en Dart puro.

## Meterlo en tu app

```yaml
# pubspec.yaml — desde una app en el mismo repositorio (por ruta)
dependencies:
  device_track_flutter:
    path: ../../device-track/cliente/flutter
```

O por git, desde fuera del repositorio:

```yaml
dependencies:
  device_track_flutter:
    git:
      url: https://github.com/pedromateodesarrollo/device-track
      path: cliente/flutter
```

El plugin necesita la carpeta `android-comun` a su lado (la suma como carpeta
de fuentes con una ruta relativa): se usa desde el repositorio, por ruta o por
git, nunca copiando solo `cliente/flutter`.

```dart
// main.dart
late final DeviceTrack equipos;

void main() {
  equipos = DeviceTrack(
    servidor: 'https://devicetrack.chalonasoft.com',
    codigo: 'dta_…', // código de alta de la organización, compilado en la app
    contexto: () => {'empresa': sesion.empresa, 'usuario': sesion.usuario, 'sesion': sesion.activa},
    alOrden: (orden) async {
      // «mensaje» desde el panel: {titulo, texto}
      mostrarAviso(orden.texto('titulo'), orden.texto('texto'));
      return true; // false (o sin alOrden): se contesta «no_soportada»
    },
  );
  equipos.iniciar(); // no hace falta esperarlo; no lanza
  runApp(const MiApp());
}
```

`iniciar` llama `WidgetsFlutterBinding.ensureInitialized()` por su cuenta. Las
apps de la casa compilan con AGP 9.1.0, Kotlin 2.4.0 y
`android.builtInKotlin=false` (lo que escribe Flutter 3.47); el plugin también
funciona con AGP 8. `minSdk` 24.

## Permisos

El plugin trae en su manifiesto, y se suman solos al de la app:

| Permiso | Para qué |
|---|---|
| `INTERNET` | Hablar con el hub. |
| `ACCESS_NETWORK_STATE` | Decir por qué red va el equipo (Wi-Fi, datos). |
| `QUERY_ALL_PACKAGES` | La lista de apps instaladas del inventario. Play la restringe: las apps de la casa no van a Play. |

**La ubicación la declara y la pide cada app.** El plugin no pide nada. Si la
organización la quiere (`ubicacion` en su configuración) y la app tiene el
permiso, cada reporte la lleva; si no, va todo lo demás.

```xml
<!-- android/app/src/main/AndroidManifest.xml -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<!-- opcional: que «sonar» también vibre -->
<uses-permission android:name="android.permission.VIBRATE" />
```

Y en tiempo de ejecución, con el código de la app o con `permission_handler`,
en el momento que tenga sentido para la persona. No hace falta la ubicación
«todo el tiempo» (`ACCESS_BACKGROUND_LOCATION`): el plugin solo reporta con la
app abierta. Con el permiso de ubicación, Android también da el nombre de la
red Wi-Fi.

## Qué hace solo

* **Alta.** La primera vez se da de alta con el código, como fuente `app` con el
  `applicationId` de la app, y guarda la credencial (`dtd_…`) en las
  preferencias privadas de la app. Vuelve a darse de alta si el hub rechaza la
  credencial (401: otra instalación la reemplazó o borraron el equipo), si la
  app cambia de hub o si una copia de seguridad trajo la credencial de otro
  teléfono. Cada alta gasta un uso del código.
* **Reportes.** Al `iniciar`, cada `intervalo_s` del hub (10 minutos por
  defecto) mientras la app está al frente, y al volver al frente si el último
  fue hace más de 2 minutos (`frenoAlFrente`). La lista de apps va solo cuando
  cambió. Lo que devuelve `contexto` va en cada uno.
* **Sin red.** El reporte que no sale se guarda (hasta 500, se quedan los más
  nuevos) y va en el siguiente, en `reportes`, cada uno con su hora.
* **WebSocket.** Abierto mientras la app está al frente: el panel ve el equipo
  conectado y las órdenes llegan al instante. Se cierra al pasar a segundo
  plano; mientras tanto las órdenes esperan al siguiente reporte. Se cae y
  vuelve solo, con espera creciente.
* **Nada lo tumba.** Un fallo de red, del hub o del plugin queda en
  `estado.ultimoError`; la app sigue.

Con la app cerrada no reporta: Android no lo deja sin un servicio en primer
plano con su notificación fija. Para eso está el agente. Si un teléfono tiene
el agente y una app con el plugin, firmadas con la misma llave, el hub ve el
mismo `ANDROID_ID` y es **un** equipo con dos fuentes.

## Qué hace con cada orden

| Orden | Qué hace | Acuse |
|---|---|---|
| `sonar` `{segundos}` | Suena a todo volumen en el canal de alarmas (aunque esté en silencio) y vibra, de 5 a 300 s o hasta `detenerSonar()`. | `hecha`: «sonó N s» o «la tocaron a los N s» |
| `reportar` | Manda un reporte ya, con ubicación recién leída. | `hecha`, o `fallida` si no salió |
| `mensaje` `{titulo, texto}` | Va a `alOrden`. | `hecha` si devuelve `true`; si no hay `alOrden` o devuelve `false`, `fallida` con `no_soportada` |
| cualquier otra | Nada. | `fallida` con `no_soportada` |

Cada orden se acusa `recibida` al llegar. El hub la repite hasta el acuse (por
el WebSocket y en cada reporte): una repetida no se vuelve a hacer, se le
contesta `hecha` otra vez (o `recibida` si todavía está en curso). Se recuerdan
las últimas 100, también después de cerrar la app.

El plugin no pone una notificación mientras suena: mira `estado.sonando` y
enseña un botón que llame `equipos.detenerSonar()`.

## Una pantalla «Acerca de»

`equipos.estado` es un `ValueNotifier<EstadoDeviceTrack>`:

```dart
ValueListenableBuilder<EstadoDeviceTrack>(
  valueListenable: equipos.estado,
  builder: (context, e, _) => Column(children: [
    if (e.sonando) FilledButton(onPressed: equipos.detenerSonar, child: const Text('Ya lo encontré')),
    Text(e.dadoDeAlta ? 'Equipo ${e.equipoId} · ${e.equipoNombre}' : 'Sin alta'),
    Text(e.conectado ? 'Conectado' : 'Sin conexión'),
    Text('Último reporte: ${e.ultimoReporte ?? '—'}'),
    if (e.pendientes > 0) Text('${e.pendientes} reportes por mandar'),
    if (e.ultimoError != null) Text('Error: ${e.ultimoError}'),
  ]),
)
```

`ultimoError`: `sin_red`, `credencial`, `sin_codigo`, `sin_plugin` (no es
Android) o el código del hub (`codigo_invalido`, `codigo_vencido`,
`codigo_agotado`, `codigo_anulado`…).

También: `equipos.reportar()` (un botón «Reportar ahora»), `equipos.detener()`
(deja de reportar; `iniciar()` lo vuelve a arrancar) y `EquipoNativo()`, para
leer la batería, la red o la ubicación por su cuenta.

## Ejemplo y pruebas

`example/` es una app mínima: se escribe el código de alta y enseña lo que
reporta.

```bash
flutter test                                  # canal y hub falsos
cd example && flutter build apk --debug       # que el Kotlin compile
```
