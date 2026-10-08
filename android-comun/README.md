# android-comun

El Kotlin que comparten el agente (`agente/android`) y el plugin de Flutter
(`cliente/flutter`): leer el equipo, la ubicación, hacer sonar, hablar con el
hub y guardar los reportes sin red.

No es un módulo de Gradle aparte, a propósito: cada uno lo suma como carpeta
de fuentes (`sourceSets["main"].kotlin.srcDir(...)`). Así el plugin se sigue
consumiendo como un paquete de Flutter normal, sin un AAR que publicar.

Necesita en quien lo use: `androidx.core` y `okhttp3`.
