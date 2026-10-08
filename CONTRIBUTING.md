# Contribuir

## Levantar el entorno

```bash
# Base de datos (o usa la tuya)
docker compose up -d bd

# Hub, en el puerto que espera el panel en desarrollo
cd hub && dart pub get
DT_DATABASE_URL=postgres://dt:dt@localhost:5432/device_track DT_PUERTO=3141 \
  dart run bin/device_track_hub.dart

# Tu organización (imprime el enlace para poner la clave)
DT_DATABASE_URL=... DT_URL_PUBLICA=http://localhost:5173 \
  dart run bin/device_track_hub.dart org --nombre Prueba --correo tu@correo.com

# Un código de alta para tus equipos de prueba
DT_DATABASE_URL=... dart run bin/device_track_hub.dart alta --org 1 --nombre Pruebas

# Panel, con proxy al hub en :3141
cd manager && npm install && npm run dev
```

## Antes de mandar un cambio

```bash
cd hub && dart analyze && dart test
cd cliente/dart && dart analyze && dart test
cd cliente/flutter && flutter analyze && flutter test
cd manager && npm run build
cd agente/android && ./gradlew assembleRelease
```

Las pruebas del hub contra Postgres (`hub/test/hub_test.dart`) se saltan si no
está `DT_PRUEBA_DATABASE_URL`. Apúntala a una base **desechable**: la prueba
borra el esquema `dt` al empezar.

```bash
docker run -d --name dt-bd -e POSTGRES_PASSWORD=dt -p 127.0.0.1:55433:5432 postgres:16-alpine
DT_PRUEBA_DATABASE_URL='postgres://postgres:dt@127.0.0.1:55433/postgres?sslmode=disable' dart test
```

Para probar el agente o el plugin hace falta un equipo o un emulador Android y
un hub al que hablar (el tuyo, con un código de alta).

## Convenciones

* El código, los comentarios y los mensajes van en español. Los mensajes de
  error son para la persona que los lee: dicen qué pasó y qué hacer.
* Un comentario explica el porqué, no el qué.
* El hub tiene dos dependencias (`postgres` y `crypto`). Una tercera necesita
  una buena razón. El agente, tres (`androidx.core`, `okhttp` y el lector de QR).
* `android-comun/` lo comparten el agente y el plugin: un cambio ahí se prueba
  en los dos.
* Una migración aplicada no se edita: se añade otra.
* Nada de seguimiento a escondidas: el agente lleva siempre su notificación fija
  y la organización decide si se pide la ubicación. Un cambio que lo esconda no
  se acepta.
