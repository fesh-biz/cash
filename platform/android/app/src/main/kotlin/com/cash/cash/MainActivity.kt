package com.cash.cash

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.IOException

class MainActivity : FlutterActivity() {
    // Многие телефоны отбрасывают broadcast-пакеты Wi‑Fi для экономии заряда.
    // Пока приложение на экране, держим multicast-lock, чтобы находить компьютер.
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onStart() {
        super.onStart()
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("cash-sync").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            multicastLock = null
        }
    }

    override fun onStop() {
        try {
            multicastLock?.release()
        } catch (e: Exception) {
        }
        multicastLock = null
        super.onStop()
    }

    // ------------------------------------------------------------------
    // Резервные копии: системное окно выбора файла (Storage Access Framework).
    // Канал cash/files: save(name, bytes) -> имя файла | null,
    // open() -> содержимое файла | null (null — окно закрыли).

    private var pendingResult: MethodChannel.Result? = null
    private var pendingBytes: ByteArray? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cash/files")
            .setMethodCallHandler { call, result ->
                if (pendingResult != null) {
                    result.error("busy", "Вікно вибору файлу вже відкрите", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "save" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        if (bytes == null) {
                            result.error("args", "Немає даних для збереження", null)
                            return@setMethodCallHandler
                        }
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/json"
                            putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "cash-backup.json")
                        }
                        launch(intent, REQUEST_SAVE, result, bytes)
                    }
                    "open" -> {
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                        }
                        launch(intent, REQUEST_OPEN, result, null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun launch(intent: Intent, request: Int, result: MethodChannel.Result, bytes: ByteArray?) {
        pendingResult = result
        pendingBytes = bytes
        try {
            startActivityForResult(intent, request)
        } catch (e: Exception) {
            pendingResult = null
            pendingBytes = null
            result.error("no_picker", "Не вдалося відкрити вибір файлу: ${e.message}", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_SAVE && requestCode != REQUEST_OPEN) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingResult ?: return
        val bytes = pendingBytes
        pendingResult = null
        pendingBytes = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        // Чтение и запись — не в главном потоке (файл может быть в облаке).
        Thread {
            try {
                val value: Any = if (requestCode == REQUEST_SAVE) {
                    val out = contentResolver.openOutputStream(uri, "w")
                        ?: throw IOException("не вдалося відкрити файл для запису")
                    out.use { it.write(bytes ?: ByteArray(0)) }
                    displayName(uri)
                } else {
                    val input = contentResolver.openInputStream(uri)
                        ?: throw IOException("не вдалося відкрити файл")
                    input.use { it.readBytes() }
                }
                runOnUiThread { result.success(value) }
            } catch (e: Exception) {
                runOnUiThread { result.error("io", e.message ?: e.toString(), null) }
            }
        }.start()
    }

    private fun displayName(uri: Uri): String {
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val name = c.getString(0)
                    if (!name.isNullOrEmpty()) return name
                }
            }
        } catch (e: Exception) {
        }
        return uri.lastPathSegment ?: ""
    }

    companion object {
        private const val REQUEST_SAVE = 4701
        private const val REQUEST_OPEN = 4702
    }
}
