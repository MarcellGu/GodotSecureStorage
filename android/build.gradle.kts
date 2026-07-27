import java.io.File

// 根工程固定工具链版本，并强制所有 Gradle 生成物位于外部构建根目录。
plugins {
    id("com.android.library") version "8.13.2" apply false
    id("org.jetbrains.kotlin.android") version "2.2.21" apply false
}

val externalBuildRootValue = providers.gradleProperty("secureStorageBuildRoot").orNull
    ?: throw GradleException(
        "必须通过 -PsecureStorageBuildRoot=<绝对路径> 指定外部 Gradle 构建目录。"
    )
val externalBuildRoot = File(externalBuildRootValue).canonicalFile
if (!externalBuildRoot.isAbsolute) {
    throw GradleException("secureStorageBuildRoot 必须是绝对路径：$externalBuildRootValue")
}
val repositoryRoot = rootDir.parentFile.canonicalFile.toPath()
if (externalBuildRoot.toPath().startsWith(repositoryRoot)) {
    throw GradleException("Gradle 构建目录不得位于仓库内：$externalBuildRoot")
}

layout.buildDirectory.set(externalBuildRoot.resolve("root"))
subprojects {
    val projectBuildName = path.trimStart(':').replace(':', File.separatorChar)
    layout.buildDirectory.set(externalBuildRoot.resolve(projectBuildName))
}
