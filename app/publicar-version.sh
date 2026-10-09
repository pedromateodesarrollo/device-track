#!/usr/bin/env bash
# Compila el panel de device-track para Android y lo publica en apk-server
# (https://apk.chalonasoft.com), de donde se instala (/i/devicetrack-panel) y
# se actualiza solo (apk_server_flutter, configurado en
# android/app/build.gradle.kts).
#
#   ./publicar-version.sh                 # versión y build salen del pubspec.yaml
#   SKIP_BUILD=1 ./publicar-version.sh    # reusa el APK ya compilado
#   ./publicar-version.sh --requerido     # obliga a todos los teléfonos a pasar a esta
#
# Antes de publicar, subir `version: X.Y.Z+N` en pubspec.yaml: los teléfonos
# comparan el número de después del «+».
#
# Dentro de chalona-fsd la llave de apk-server la pone scripts/publicar-apk-server.sh
# (de ~/.config/chalona/apk.env). Fuera (el repositorio público de device-track),
# exporta APK_SERVER_LLAVE con una llave de TU apk-server y cambia el hub y la app
# en android/app/build.gradle.kts.
[[ -n "$BASH_VERSION" ]] || exec bash "$0" "$@"
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$DIR/../.." && pwd)"
LINEA="$(grep -E '^version:' "$DIR/pubspec.yaml" | head -1)"
VERSION="$(sed -E 's/^version:[[:space:]]*([^+[:space:]]+)\+.*/\1/' <<<"$LINEA")"
BUILD="$(sed -E 's/^version:[[:space:]]*[^+]+\+([0-9]+).*/\1/' <<<"$LINEA")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[0-9]+$ ]] \
  || { echo "Error: no entiendo «$LINEA» en pubspec.yaml (va como version: X.Y.Z+N)" >&2; exit 2; }

APK="$DIR/build/app/outputs/flutter-apk/app-release.apk"
if [[ "${SKIP_BUILD:-}" = "1" ]]; then
  echo "== SKIP_BUILD=1: reusando $APK"
else
  echo "== Compilando el panel $VERSION ($BUILD)..."
  (cd "$DIR" && flutter build apk --release)
  # El demonio de Gradle se queda con la RAM horas si no se le para.
  (cd "$DIR/android" && ./gradlew --stop >/dev/null 2>&1) || true
fi
[[ -f "$APK" ]] || { echo "Error: no existe $APK." >&2; exit 1; }

# El hub y la app salen del APK (manifestPlaceholders de android/app/build.gradle.kts).
if [[ -x "$RAIZ/scripts/publicar-apk-server.sh" ]]; then
  (cd "$DIR" && "$RAIZ/scripts/publicar-apk-server.sh" --apk "$APK" --version "$VERSION" --build "$BUILD" "$@")
else
  [[ -n "${APK_SERVER_LLAVE:-}" ]] || { echo "Falta APK_SERVER_LLAVE (una llave de tu apk-server)." >&2; exit 2; }
  (cd "$DIR" && dart run apk_server_flutter:publicar --apk "$APK" --version "$VERSION" --build "$BUILD" "$@")
fi

echo ""
echo "Listo: panel de device-track $VERSION (build $BUILD)."
echo "Instalar en un teléfono: https://apk.chalonasoft.com/i/devicetrack-panel"
