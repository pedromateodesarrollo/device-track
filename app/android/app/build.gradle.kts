plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.chalonasoft.devicetrack.panel"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Distinto del agente (com.chalonasoft.devicetrack): son dos apps y un
        // teléfono puede tener las dos.
        applicationId = "com.chalonasoft.devicetrack.panel"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Del pubspec.yaml (version: X.Y.Z+N).
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // apk-server: de dónde se actualiza la app y a dónde se publica. Lo lee
        // el plugin apk_server_flutter (del manifiesto) y
        // `dart run apk_server_flutter:publicar` (del APK): no pueden decir
        // cosas distintas. Quien compile la suya para su propio apk-server
        // cambia estas dos líneas.
        manifestPlaceholders["apkServerHub"] = "https://apk.chalonasoft.com"
        manifestPlaceholders["apkServerApp"] = "devicetrack-panel"
    }

    buildTypes {
        release {
            // Firmada con la llave de depuración de la máquina que compila,
            // como las demás apps de la casa: una actualización solo instala
            // encima si la firma es la misma, así que se compila siempre en una
            // máquina con esa llave.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
