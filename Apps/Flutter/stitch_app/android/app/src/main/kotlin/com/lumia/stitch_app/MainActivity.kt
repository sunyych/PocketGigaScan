package com.lumia.stitch_app

import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.lumia.stitch_app/power")
            .setMethodCallHandler { call, result ->
                if (call.method != "readPowerState") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                if (battery == null) {
                    result.success(mapOf("state" to "unknown"))
                    return@setMethodCallHandler
                }
                val plugged = battery.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
                val state = when {
                    plugged == -1 -> "unknown"
                    plugged != 0 -> "external"
                    else -> "battery"
                }
                result.success(mapOf("state" to state))
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.lumia.stitch_app/files")
            .setMethodCallHandler { call, result ->
                if (call.method != "shareExport") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                val file = path?.let { java.io.File(it) }
                if (file == null || !file.isFile) {
                    result.error("MISSING_FILE", "Exported PNG does not exist", null)
                    return@setMethodCallHandler
                }
                try {
                    val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
                    val share = Intent(Intent.ACTION_SEND).apply {
                        type = "image/png"
                        putExtra(Intent.EXTRA_STREAM, uri)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivity(Intent.createChooser(share, "分享全景 PNG"))
                    result.success(true)
                } catch (error: Exception) {
                    result.error("SHARE_FAILED", error.message, null)
                }
            }
    }
}
