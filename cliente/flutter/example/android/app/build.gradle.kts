plugins {
    id("com.android.application")
    // El de Flutter va después del de Android y el de Kotlin.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.chalonasoft.devicetrack.ejemplo"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Es el `fuente.paquete` con que el ejemplo se da de alta en el hub.
        applicationId = "com.chalonasoft.devicetrack.ejemplo"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Como todas las apps de la casa: la llave de depuración. Con la
            // misma firma que el agente, los dos ven el mismo ANDROID_ID y el
            // hub los junta en un solo equipo.
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
