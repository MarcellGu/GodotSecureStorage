import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

val pluginInitializerName = "AndroidBackend"
val pluginPackageName = "com.marcellgu.securestorage"

android {
    namespace = pluginPackageName
    compileSdk = 36
    buildToolsVersion = "36.0.0"

    defaultConfig {
        minSdk = 24
        manifestPlaceholders["godotPluginName"] = pluginInitializerName
        manifestPlaceholders["godotPluginPackageName"] = pluginPackageName
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }
}

dependencies {
    implementation("org.godotengine:godot:4.7.1.stable")
}
