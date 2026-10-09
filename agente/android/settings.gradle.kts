pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    // Las mismas versiones que las apps Flutter de la casa (trackme): ya están
    // en la caché de Gradle de las máquinas que compilan.
    id("com.android.application") version "9.1.0" apply false
    id("com.android.library") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

rootProject.name = "devicetrack-agente"
include(":app")

// La actualización: la biblioteca de Android de apk-server
// (github.com/pedromateodesarrollo/apk-server, cliente/android), como un
// proyecto más. En chalona-fsd está al lado (apk-server/); en el repositorio
// público de device-track, clónalo junto a device-track
// (`git clone https://github.com/pedromateodesarrollo/apk-server ../apk-server`)
// o di dónde está con -Papkserver.dir=….
val apkServer = providers.gradleProperty("apkserver.dir").orNull?.let { file(it) }
    ?: file("../../../apk-server/cliente/android")
require(apkServer.resolve("build.gradle.kts").isFile) {
    "Falta la biblioteca de apk-server en $apkServer: clona " +
        "https://github.com/pedromateodesarrollo/apk-server junto a device-track " +
        "o pasa -Papkserver.dir=<ruta a apk-server/cliente/android>."
}
include(":apk-server")
project(":apk-server").projectDir = apkServer
