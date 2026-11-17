package dev.codexgo.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

/** 更新安装只通过系统安装器，校验及文件读取放到工作线程，避免阻塞聊天。 */
object AppUpdates {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private class Rejected(val code: String) : Exception(code)

    @Suppress("DEPRECATION")
    private fun flags(): Int = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES

    @Suppress("DEPRECATION")
    private fun version(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun certificates(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return signatures?.map { sig ->
            MessageDigest.getInstance("SHA-256").digest(sig.toByteArray()).joinToString("") { "%02x".format(it) }
        }?.toSet() ?: emptySet()
    }

    private fun directory(context: Context) = File(context.cacheDir, "app-updates").apply { mkdirs() }

    @Suppress("DEPRECATION")
    private fun validate(context: Context, args: Map<*, *>): File {
        if (context.getString(R.string.update_channel) !in setOf("release", "beta")) throw Rejected("preview")
        val file = File(args["path"] as? String ?: "").canonicalFile
        val expected = File(directory(context), "update.apk").canonicalFile
        if (file != expected || !file.isFile) throw Rejected("missing")
        if (file.length() != (args["size"] as? Number)?.toLong()) throw Rejected("integrity")
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        if (actual != args["sha256"]) throw Rejected("integrity")
        val manager = context.packageManager
        val installed = manager.getPackageInfo(context.packageName, flags())
        val incoming = manager.getPackageArchiveInfo(file.path, flags()) ?: throw Rejected("integrity")
        if (incoming.packageName != context.packageName) throw Rejected("identity")
        if (version(incoming) <= version(installed) || version(incoming) != (args["versionCode"] as? Number)?.toLong() ||
            incoming.versionName != args["versionName"]) throw Rejected("version")
        if ((incoming.applicationInfo?.minSdkVersion ?: Int.MAX_VALUE) > Build.VERSION.SDK_INT) throw Rejected("unsupported")
        // 固定发布身份；系统安装器还会对 APK 签名和覆盖安装规则做最终验证。
        val trusted = certificates(installed)
        if (trusted.isEmpty() || trusted != certificates(incoming)) throw Rejected("signature")
        return file
    }

    @Suppress("DEPRECATION")
    fun register(context: Context, engine: FlutterEngine, activity: Activity? = null) {
        val app = context.applicationContext
        val prefs = app.getSharedPreferences("app_updates", Context.MODE_PRIVATE)
        MethodChannel(engine.dartExecutor.binaryMessenger, "codex_go/updates").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "info" -> {
                        val info = app.packageManager.getPackageInfo(app.packageName, 0)
                        result.success(mapOf("versionName" to info.versionName, "versionCode" to version(info),
                            "sdk" to Build.VERSION.SDK_INT, "channel" to app.getString(R.string.update_channel), "official" to (app.getString(R.string.update_channel) in setOf("release", "beta")),
                            "autoCheck" to prefs.getBoolean("autoCheck", true), "lastAttempt" to prefs.getLong("lastAttempt", 0),
                            "skipped" to if (prefs.contains("skipped")) prefs.getLong("skipped", 0) else null,
                            "release" to prefs.getString("release", null),
                            "directory" to directory(app).absolutePath))
                    }
                    "preferences" -> {
                        val args = call.arguments as Map<*, *>
                        val editor = prefs.edit().putBoolean("autoCheck", args["autoCheck"] as Boolean)
                            .putLong("lastAttempt", (args["lastAttempt"] as Number).toLong())
                        val skipped = args["skipped"] as? Number
                        if (skipped == null) editor.remove("skipped") else editor.putLong("skipped", skipped.toLong())
                        editor.putString("release", args["release"] as? String)
                        editor.apply()
                        result.success(null)
                    }
                    "validate", "install" -> {
                        val args = call.arguments as Map<*, *>
                        worker.execute {
                            try {
                                val apk = validate(app, args)
                                main.post {
                                    try {
                                        if (call.method == "validate") result.success(null)
                                        else if (activity == null || activity.isDestroyed || activity.isFinishing) result.error("unavailable", "Open the app to install", null)
                                        else if (Build.VERSION.SDK_INT >= 26 && !app.packageManager.canRequestPackageInstalls()) {
                                            activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${app.packageName}")))
                                            result.success("permission")
                                        } else {
                                            val uri = FileProvider.getUriForFile(app, "${app.packageName}.updates", apk)
                                            activity.startActivity(Intent(Intent.ACTION_INSTALL_PACKAGE).setDataAndType(uri, "application/vnd.android.package-archive")
                                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                                            result.success("installer")
                                        }
                                    } catch (_: Exception) { result.error("installer", "Cannot open system installer", null) }
                                }
                            } catch (e: Exception) {
                                main.post { result.error((e as? Rejected)?.code ?: "storage", "Update verification failed", null) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("unavailable", "Update service unavailable", null) }
        }
    }
}
