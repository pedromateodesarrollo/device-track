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
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

rootProject.name = "devicetrack-agente"
include(":app")
