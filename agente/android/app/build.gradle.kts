plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Lo que cambia quien compila su propio agente (con -P o en gradle.properties):
//   devicetrack.hub        el hub que se ofrece en la pantalla de alta
//   devicetrack.apkServer  de dónde se actualiza solo ("" = no se actualiza);
//                          también es a dónde lo sube publicar-version.sh
//   devicetrack.apkApp     cómo se llama allí la app
fun ajuste(nombre: String, porDefecto: String): String =
    (project.findProperty("devicetrack.$nombre") as String?) ?: porDefecto

android {
    namespace = "com.chalonasoft.devicetrack.agente"
    compileSdk = 36

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        // El mismo applicationId en todas las organizaciones: el agente es uno
        // y la organización la decide el código de alta.
        applicationId = "com.chalonasoft.devicetrack"
        minSdk = 24
        targetSdk = 36
        versionCode = 3
        versionName = "0.1.2"
        buildConfigField("String", "HUB_POR_DEFECTO", "\"${ajuste("hub", "https://devicetrack.chalonasoft.com")}\"")
        // apk-server (la biblioteca lo lee del manifiesto; el comando de
        // publicar, del APK).
        manifestPlaceholders["apkServerHub"] = ajuste("apkServer", "https://apk.chalonasoft.com")
        manifestPlaceholders["apkServerApp"] = ajuste("apkApp", "devicetrack")
    }

    sourceSets {
        // El Kotlin que comparte con el plugin de Flutter.
        getByName("main").java.srcDir("../../../android-comun/kotlin")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildTypes {
        release {
            // La llave de depuración de la casa, como todas sus apps: con la
            // misma firma, el agente y las apps propias ven el mismo ANDROID_ID
            // y el hub los junta en un solo equipo. Cambiarla también rompe la
            // actualización (Android no instala encima otra firma).
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // Se actualiza solo (ver settings.gradle.kts y AgenteApp).
    implementation(project(":apk-server"))
    // Escanear el QR del código de alta con la cámara (sin servicios de Google:
    // hay terminales que no los traen). En una Zebra el lector de códigos lo
    // escribe solo en el campo de texto.
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
}
