#!/usr/bin/env bash
# Compila el agente y lo publica en apk-server (https://apk.chalonasoft.com),
# de donde se instala (/i/devicetrack) y se actualiza solo (Actualizador.kt).
#
#   ./publicar-version.sh                 # versión y build salen de app/build.gradle.kts
#   SKIP_BUILD=1 ./publicar-version.sh    # reusa el APK ya compilado
#   ./publicar-version.sh --requerido     # obliga a todos los equipos a pasar a esta
#
# Antes de publicar, subir versionCode (y versionName) en
# android/app/build.gradle.kts: los equipos comparan ese número.
# La llave de apk-server sale de ~/.config/chalona/apk.env (la lee el script común).
[[ -n "$BASH_VERSION" ]] || exec bash "$0" "$@"
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$DIR/../.." && pwd)"
GRADLE="$DIR/android/app/build.gradle.kts"
VERSION="$(grep -oP 'versionName = "\K[^"]+' "$GRADLE")"
BUILD="$(grep -oP 'versionCode = \K[0-9]+' "$GRADLE")"
[[ -n "$VERSION" && -n "$BUILD" ]] || { echo "Error: no encuentro versionName/versionCode en $GRADLE" >&2; exit 2; }

APK="$DIR/android/app/build/outputs/apk/release/app-release.apk"
if [[ "${SKIP_BUILD:-}" = "1" ]]; then
  echo "== SKIP_BUILD=1: reusando $APK"
else
  echo "== Compilando el agente $VERSION ($BUILD)..."
  (cd "$DIR/android" && ./gradlew --no-daemon -q assembleRelease)
  # El demonio de Gradle se queda con la RAM horas si no se le para.
  (cd "$DIR/android" && ./gradlew --stop >/dev/null 2>&1) || true
fi
[[ -f "$APK" ]] || { echo "Error: no existe $APK." >&2; exit 1; }

"$RAIZ/scripts/publicar-apk-server.sh" --app devicetrack --apk "$APK" \
  --version "$VERSION" --build "$BUILD" ${1:-}

echo ""
echo "Listo: agente de device-track $VERSION (build $BUILD)."
echo "Instalar en un equipo: https://apk.chalonasoft.com/i/devicetrack"
