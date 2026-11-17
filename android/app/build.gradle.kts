import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

// 仅发布入口主动打开签名开关；配置文件存在不应改变预览包的签名身份。
val releaseSigning = providers.environmentVariable("CODEX_GO_RELEASE_SIGNING").orNull == "true"
val channel = providers.environmentVariable("CODEX_GO_CHANNEL").orNull ?: "release"
require(channel in setOf("release", "beta")) { "无效发布渠道" }
val identity = if (!releaseSigning) "dev.codexgo.app.preview" else if (channel == "beta") "dev.codexgo.app.beta" else "dev.codexgo.app"
val displayName = if (!releaseSigning) "Codex Go Preview" else if (channel == "beta") "Codex Go Beta" else "Codex Go"
val signing = Properties()
if (releaseSigning) {
    val signingFile = rootProject.file("key.properties")
    require(signingFile.isFile) { "正式发布缺少 android/key.properties" }
    signingFile.inputStream().use { signing.load(it) }
    listOf("storeFile", "storePassword", "keyAlias", "keyPassword").forEach { key ->
        require(!signing.getProperty(key).isNullOrBlank()) { "正式发布签名配置缺少字段：$key" }
    }
    require(rootProject.file(signing.getProperty("storeFile")).isFile) { "正式发布签名密钥文件不存在" }
}

android {
    buildFeatures { resValues = true }
    namespace = "dev.codexgo.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    defaultConfig {
        applicationId = identity
        manifestPlaceholders["appLabel"] = displayName
        manifestPlaceholders["appIcon"] = if (channel == "beta") "@drawable/ic_codex_go_beta" else "@drawable/ic_codex_go"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 预览签名不参与正式升级，避免安装到一半才发现签名不一致。
        resValue("string", "update_channel", if (releaseSigning) channel else "preview")
    }
    signingConfigs {
        if (releaseSigning) create("release") {
            keyAlias = signing.getProperty("keyAlias")
            keyPassword = signing.getProperty("keyPassword")
            storeFile = rootProject.file(signing.getProperty("storeFile"))
            storePassword = signing.getProperty("storePassword")
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (releaseSigning) "release" else "debug")
        }
    }
}
kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }
flutter { source = "../.." }
