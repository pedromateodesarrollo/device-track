# Compila el hub y el panel, y deja una imagen con el binario y poco más.
FROM node:22-alpine AS sitio
WORKDIR /sitio
COPY manager/package*.json ./
RUN npm install --silent
COPY manager/ ./
COPY docs/ /docs/
RUN npm run build

FROM dart:stable AS compilador
WORKDIR /app
# El pubspec y su lockfile primero: mientras no cambien, esta capa se reusa y
# la compilación no vuelve a bajar nada.
COPY hub/pubspec.yaml hub/pubspec.lock ./
RUN dart pub get
COPY hub/ ./
RUN dart compile exe bin/device_track_hub.dart -o /app/device-track-hub

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/device-track
COPY --from=compilador /app/device-track-hub ./
COPY --from=compilador /app/migraciones ./migraciones
COPY --from=sitio /sitio/dist ./manager
ENV DT_MANAGER=/opt/device-track/manager
EXPOSE 3140
CMD ["./device-track-hub"]
