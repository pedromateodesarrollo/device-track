# device-track panel (Android)

El panel de device-track en el teléfono: los tableros de Inicio, la lista y la
ficha de cada equipo (con Sonar, Mensaje y Reportar ya), las alertas, el
asistente de IA, el mapa, las reglas, las personas y la cuenta. Es una app
nativa en Flutter que habla con el mismo API que el panel web
([docs/api.md](../docs/api.md)); no envuelve la web.

Se entra con el correo y la clave del panel. La dirección del hub viene puesta
(`https://devicetrack.chalonasoft.com`) y se puede cambiar: device-track se
puede hospedar en cualquier parte.

Lo que no está aquí (códigos de alta, zonas, dominios, llaves, la
organización) se hace en el panel web.

## Compilar

Flutter 3.47 y el SDK de Android.

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

El APK de release se firma con la llave de depuración de la máquina que
compila (`signingConfig = signingConfigs.getByName("debug")`): Android solo
instala una actualización encima si la firma es la misma, así que se compila
siempre en una máquina con esa llave.

## Se actualiza sola

Con [apk-server](https://github.com/pedromateodesarrollo/apk-server)
(`apk_server_flutter`): pregunta al abrir, cada hora y cuando el hub avisa;
baja la versión nueva en segundo plano y avisa con una notificación. Instalar
se hace con un toque en Inicio o en Más → Mi cuenta (instalar cierra la app).

A qué apk-server pregunta lo dicen dos líneas de `android/app/build.gradle.kts`
(`apkServerHub` y `apkServerApp`). Quien la publique en su propio apk-server
cambia esas dos.

## Publicar

```bash
./publicar-version.sh
```

Compila y sube el APK; la versión y el build salen de `version:` en
`pubspec.yaml` (súbelo antes). Se instala desde
<https://apk.chalonasoft.com/i/devicetrack-panel>, y ese mismo enlace está en la
app (Más → Mi cuenta) para pasársela a otra persona.
