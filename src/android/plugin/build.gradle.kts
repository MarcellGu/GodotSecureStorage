import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

val plugin_name = "SecureStorage"
val plugin_initializer_name = "SecureStorageAndroid"
val plugin_package_name = "com.marcellgu.securestorage"
val skip_native_build = providers.gradleProperty("skipNativeBuild").orNull == "true"

android {
    namespace = plugin_package_name
    compileSdk = 36

    if (!skip_native_build) {
        ndkVersion = "28.1.13356709"
    }

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        minSdk = 24
        manifestPlaceholders["godotPluginName"] = plugin_initializer_name
        manifestPlaceholders["godotPluginPackageName"] = plugin_package_name
        ndk {
            abiFilters.add("arm64-v8a")
        }
        if (!skip_native_build) {
            externalNativeBuild {
                cmake {
                    cppFlags("-std=c++17")
                }
            }
        }
    }

    if (!skip_native_build) {
        externalNativeBuild {
            cmake {
                path = file("CMakeLists.txt")
                version = "3.22.1"
            }
        }
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

val copy_gdextension_config by tasks.registering(Copy::class) {
    from("../../addon")
    include("secure_storage.gdextension")
    into("src/main/assets/addons/SecureStorage")
}

tasks.named("preBuild").configure {
    dependsOn(copy_gdextension_config)
}
