// Lo nativo de device_track_flutter: leer el equipo, la ubicación, hacer
// sonar y guardar la credencial. Ver DeviceTrackPlugin.kt.
//
// Sin `buildscript`: el plugin de Android y el de Kotlin los pone la app que lo
// usa (su settings.gradle.kts), y así no se mezclan dos versiones de AGP.
group = "com.chalonasoft.devicetrack.plugin"
version = "1.0-SNAPSHOT"

plugins {
    id("com.android.library")
}

// AGP 9 trae Kotlin incluido salvo que la app lo apague
// (`android.builtInKotlin=false`, que es lo que escribe el migrador de Flutter
// 3.47). Con AGP 8 el plugin de Kotlin se aplica aquí.
val agpMayor = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION.substringBefore('.').toInt()
val kotlinIncluido =
    agpMayor >= 9 &&
        (providers.gradleProperty("android.builtInKotlin").orNull?.toBoolean() ?: true)
if (!kotlinIncluido) {
    apply(plugin = "org.jetbrains.kotlin.android")
}

// Java y Kotlin al MISMO nivel. Sin fijarlo, Kotlin compila para el JDK que
// corre Gradle (21, por ejemplo) y Java para otro, y Gradle se niega a
// mezclarlos.
extensions.configure<org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension> {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

android {
    namespace = "com.chalonasoft.devicetrack.plugin"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
            // El Kotlin que comparte con el agente (device-track/android-comun):
            // leer el equipo, la ubicación, sonar, el almacén y la cola. No es un
            // módulo aparte, a propósito: así el plugin se consume como un
            // paquete de Flutter normal (por ruta o por git), sin un AAR que
            // publicar.
            java.srcDir("../../../android-comun/kotlin")
        }
    }

    defaultConfig {
        // android-comun usa lo de Android 7 (registerDefaultNetworkCallback).
        minSdk = 24
    }
}

dependencies {
    // Las mismas que el agente: android-comun las necesita.
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
}
