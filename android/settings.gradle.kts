pluginManagement {
    // Gradle 从这些官方仓库解析 Android/Kotlin 构建插件。
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    // 禁止子项目临时加入其他仓库，依赖来源保持集中和可审计。
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "SecureStorage"
// 整个 Gradle 工程只有一个会产生 AAR 的 :plugin module。
include(":plugin")
