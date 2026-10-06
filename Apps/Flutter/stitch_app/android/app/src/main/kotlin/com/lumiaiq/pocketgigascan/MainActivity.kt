package com.lumiaiq.pocketgigascan

import android.app.Activity
import android.content.Intent
import android.content.IntentFilter
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.os.BatteryManager
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val storageExecutor = Executors.newSingleThreadExecutor()
    private var pendingStorageResult: MethodChannel.Result? = null
    private var pendingSave: PendingSave? = null
    private val pendingRenderStartResults = mutableMapOf<String, MethodChannel.Result>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var storage: MethodChannel
    private lateinit var runtime: MethodChannel
    private var timeoutReceiverRegistered = false
    private val timeoutReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(context: android.content.Context?, intent: Intent?) {
            when (intent?.action) {
                RenderForegroundService.ACTION_READY -> {
                    val requestId = intent.getStringExtra(RenderForegroundService.EXTRA_REQUEST_ID) ?: return
                    pendingRenderStartResults.remove(requestId)?.success(true)
                }
                RenderForegroundService.ACTION_TIMEOUT -> {
                    val ids = intent.getStringArrayListExtra(RenderForegroundService.EXTRA_JOB_IDS)
                    runtime.invokeMethod("processingTimeout", ids ?: arrayListOf<String>())
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.lumiaiq.pocketgigascan/power")
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

        runtime = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.lumiaiq.pocketgigascan/runtime")
        runtime.setMethodCallHandler { call, result ->
            when (call.method) {
                "readResourceBudget" -> {
                    val memory = android.app.ActivityManager.MemoryInfo()
                    getSystemService(android.app.ActivityManager::class.java).getMemoryInfo(memory)
                    val power = getSystemService(android.os.PowerManager::class.java)
                    val thermal = if (android.os.Build.VERSION.SDK_INT >= 29) {
                        when (power.currentThermalStatus) {
                            android.os.PowerManager.THERMAL_STATUS_NONE -> "none"
                            android.os.PowerManager.THERMAL_STATUS_LIGHT -> "light"
                            android.os.PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
                            android.os.PowerManager.THERMAL_STATUS_SEVERE -> "severe"
                            android.os.PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
                            android.os.PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
                            android.os.PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
                            else -> "unknown"
                        }
                    } else "unknown"
                    val mib = 1024L * 1024L
                    result.success(mapOf(
                        "totalMemoryMiB" to (memory.totalMem / mib).toInt(),
                        "availableMemoryMiB" to (memory.availMem / mib).toInt(),
                        "cpuCount" to Runtime.getRuntime().availableProcessors(),
                        "availableStorageMiB" to (filesDir.usableSpace / mib).toInt(),
                        "thermalStatus" to thermal,
                    ))
                }
                "readPendingTimeoutJobs" -> {
                    val preferences = getSharedPreferences(RenderForegroundService.PREFERENCES, MODE_PRIVATE)
                    result.success(
                        preferences.getStringSet(RenderForegroundService.PENDING_TIMEOUT_JOBS_KEY, emptySet())
                            .orEmpty().sorted(),
                    )
                }
                "acknowledgeTimeoutJobs" -> {
                    val acknowledged = call.argument<List<String>>("jobIds").orEmpty().toSet()
                    val preferences = getSharedPreferences(RenderForegroundService.PREFERENCES, MODE_PRIVATE)
                    val pending = preferences.getStringSet(
                        RenderForegroundService.PENDING_TIMEOUT_JOBS_KEY,
                        emptySet(),
                    ).orEmpty()
                    val remaining = MobilePlatformPolicy.acknowledgePendingTimeoutJobs(pending, acknowledged)
                    val saved = preferences.edit()
                        .putStringSet(RenderForegroundService.PENDING_TIMEOUT_JOBS_KEY, remaining)
                        .commit()
                    result.success(saved)
                }
                "setProcessingActive" -> {
                    val active = call.argument<Boolean>("active") ?: false
                    val jobId = call.argument<String>("jobId")
                    val preferences = getSharedPreferences(RenderForegroundService.PREFERENCES, MODE_PRIVATE)
                    val previousProcess = preferences.getString(RenderForegroundService.PROCESS_ID_KEY, null)
                    val existing = if (previousProcess == PROCESS_INSTANCE_ID) {
                        preferences.getStringSet(RenderForegroundService.ACTIVE_JOBS_KEY, emptySet()).orEmpty()
                    } else emptySet()
                    val activeIds = MobilePlatformPolicy.updateActiveJobs(existing, active, jobId)
                    preferences.edit()
                        .putString(RenderForegroundService.PROCESS_ID_KEY, PROCESS_INSTANCE_ID)
                        .putStringSet(RenderForegroundService.ACTIVE_JOBS_KEY, activeIds)
                        .apply()
                    try {
                        if (activeIds.isEmpty()) {
                            stopService(Intent(this, RenderForegroundService::class.java))
                            result.success(true)
                        } else {
                            val requestId = UUID.randomUUID().toString()
                            pendingRenderStartResults[requestId] = result
                            RenderForegroundService.start(this, requestId, ArrayList(activeIds.sorted()))
                            mainHandler.postDelayed({
                                pendingRenderStartResults.remove(requestId)?.let {
                                    it.success(false)
                                    rollbackActiveJob(jobId)
                                }
                            }, SERVICE_READY_TIMEOUT_MS)
                        }
                    } catch (error: Exception) {
                        val requestId = pendingRenderStartResults.entries.firstOrNull { it.value === result }?.key
                        if (requestId != null) pendingRenderStartResults.remove(requestId)
                        rollbackActiveJob(jobId)
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
        if (!timeoutReceiverRegistered) {
            ContextCompat.registerReceiver(
                this,
                timeoutReceiver,
                IntentFilter().apply {
                    addAction(RenderForegroundService.ACTION_TIMEOUT)
                    addAction(RenderForegroundService.ACTION_READY)
                },
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
            timeoutReceiverRegistered = true
        }

        storage = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.lumiaiq.pocketgigascan/storage")
        storage.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickBatchParent" -> launchPicker(result)
                "pickOutputFolder" -> launchOutputPicker(result)
                "publishExport" -> publishExport(
                    call.argument("path"), call.argument("treeUri"),
                    call.argument("mimeType"), call.argument("suggestedName"), result,
                )
                "releaseBatchParent" -> releaseBatchParent(call.argument("path"), result)
                "saveExport" -> launchSave(call.argument("path"), call.argument("mimeType"), call.argument("suggestedName"), result)
                "shareExport" -> shareExport(call.argument("path"), call.argument("mimeType"), result)
                else -> result.notImplemented()
            }
        }
    }

    private fun launchPicker(result: MethodChannel.Result) {
        if (!reserveResult(result)) return
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }
        try {
            startActivityForResult(intent, REQUEST_PICK_TREE)
        } catch (error: Exception) {
            pendingStorageResult = null
            result.error("PICKER_UNAVAILABLE", error.message ?: "Folder picker could not be opened", null)
        }
    }

    private fun launchOutputPicker(result: MethodChannel.Result) {
        if (!reserveResult(result)) return
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }
        try {
            startActivityForResult(intent, REQUEST_PICK_OUTPUT_TREE)
        } catch (error: Exception) {
            pendingStorageResult = null
            result.error("PICKER_UNAVAILABLE", error.message ?: "Folder picker could not be opened", null)
        }
    }

    private fun publishExport(path: String?, treeUriValue: String?, mimeType: String?, suggestedName: String?, result: MethodChannel.Result) {
        val source = path?.let(::File)
        val treeUri = treeUriValue?.takeIf { MobilePlatformPolicy.isSafTreeUri(it) }
            ?.let(android.net.Uri::parse)
        val format = mimeType?.takeIf { MobilePlatformPolicy.isSupportedExportMimeType(it) }
        if (source == null || !MobilePlatformPolicy.isAppOwnedFile(source, filesDir) || !source.isFile ||
            treeUri == null || format == null || suggestedName.isNullOrBlank()) {
            result.error("INVALID_EXPORT", "Export path, folder, format, or filename is invalid", null)
            return
        }
        val hasGrant = contentResolver.persistedUriPermissions.any {
            it.uri == treeUri && it.isWritePermission
        }
        if (!hasGrant) {
            result.error("OUTPUT_PERMISSION_MISSING", "Choose the output folder again to restore write access", null)
            return
        }
        storageExecutor.execute {
            var created: android.net.Uri? = null
            try {
                val parent = DocumentsContract.buildDocumentUriUsingTree(
                    treeUri, DocumentsContract.getTreeDocumentId(treeUri),
                )
                created = DocumentsContract.createDocument(
                    contentResolver, parent, format, MobilePlatformPolicy.safeDocumentName(File(suggestedName).name),
                ) ?: throw java.io.IOException("The selected folder refused to create the export")
                contentResolver.openOutputStream(created, "w")?.buffered()?.use { output ->
                    source.inputStream().buffered().use { input -> input.copyTo(output, COPY_BUFFER_SIZE) }
                } ?: throw java.io.IOException("The selected export could not be opened for writing")
                val publishedUri = created
                val name = queryDisplayName(publishedUri) ?: File(suggestedName).name
                runOnUiThread { result.success(mapOf("uri" to publishedUri.toString(), "displayName" to name)) }
            } catch (error: Exception) {
                created?.let { uri -> try { DocumentsContract.deleteDocument(contentResolver, uri) } catch (_: Exception) { } }
                runOnUiThread {
                    result.error("PUBLISH_FAILED", "Could not copy export. Check folder access and free space, then retry: ${error.message ?: "storage error"}", null)
                }
            }
        }
    }

    private fun queryDisplayName(uri: android.net.Uri): String? = try {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    } catch (_: Exception) { null }

    private fun launchSave(path: String?, mimeType: String?, suggestedName: String?, result: MethodChannel.Result) {
        val source = path?.let(::File)
        val format = mimeType?.takeIf { MobilePlatformPolicy.isSupportedExportMimeType(it) }
        if (source == null || !MobilePlatformPolicy.isAppOwnedFile(source, filesDir) || format == null || suggestedName.isNullOrBlank()) {
            result.error("INVALID_EXPORT", "Export path, format, or filename is invalid", null)
            return
        }
        if (!reserveResult(result)) return
        pendingSave = PendingSave(source, result)
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = format
            putExtra(Intent.EXTRA_TITLE, File(suggestedName).name)
        }
        try {
            startActivityForResult(intent, REQUEST_SAVE_EXPORT)
        } catch (error: Exception) {
            pendingSave = null
            pendingStorageResult = null
            result.error("SAVE_DIALOG_UNAVAILABLE", error.message ?: "Save dialog could not be opened", null)
        }
    }

    private fun shareExport(path: String?, mimeType: String?, result: MethodChannel.Result) {
        val file = path?.let(::File)
        val format = mimeType?.takeIf { MobilePlatformPolicy.isSupportedExportMimeType(it) }
        if (file == null || !MobilePlatformPolicy.isAppOwnedFile(file, filesDir) || format == null) {
            result.error("INVALID_EXPORT", "Export path or format is invalid", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val share = Intent(Intent.ACTION_SEND).apply {
                type = format
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(share, getString(R.string.share_export_title)))
            result.success(true)
        } catch (error: Exception) {
            result.error("SHARE_FAILED", error.message ?: "Could not share export", null)
        }
    }

    private fun releaseBatchParent(path: String?, result: MethodChannel.Result) {
        try {
            val stagingRoot = File(filesDir, "staged-batches").canonicalFile
            val stage = path?.let(::File)?.canonicalFile
            if (stage == null || stage.parentFile != stagingRoot || stage == stagingRoot) {
                result.error("INVALID_STAGING_PATH", "Only an app-private staged batch can be released", null)
                return
            }
            result.success(!stage.exists() || stage.deleteRecursively())
        } catch (error: Exception) {
            result.error("STAGING_CLEANUP_FAILED", error.message ?: "Could not remove staged batch copy", null)
        }
    }

    private fun rollbackActiveJob(jobId: String?) {
        val preferences = getSharedPreferences(RenderForegroundService.PREFERENCES, MODE_PRIVATE)
        val existing = preferences.getStringSet(RenderForegroundService.ACTIVE_JOBS_KEY, emptySet()).orEmpty()
        val activeIds = MobilePlatformPolicy.updateActiveJobs(
            existing,
            active = false,
            jobId = jobId ?: MobilePlatformPolicy.ANONYMOUS_JOB_ID,
        )
        preferences.edit().putStringSet(RenderForegroundService.ACTIVE_JOBS_KEY, activeIds).apply()
        if (activeIds.isEmpty()) stopService(Intent(this, RenderForegroundService::class.java))
    }

    private fun reserveResult(result: MethodChannel.Result): Boolean {
        if (pendingStorageResult != null) {
            result.error("STORAGE_BUSY", "Another storage picker is already open", null)
            return false
        }
        pendingStorageResult = result
        return true
    }

    @Deprecated("Deprecated in Android, required for FlutterActivity result routing")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQUEST_PICK_TREE -> handleTreeResult(resultCode, data)
            REQUEST_PICK_OUTPUT_TREE -> handleOutputTreeResult(resultCode, data)
            REQUEST_SAVE_EXPORT -> handleSaveResult(resultCode, data)
        }
    }

    private fun handleOutputTreeResult(resultCode: Int, data: Intent?) {
        val result = pendingStorageResult ?: return
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            pendingStorageResult = null
            result.success(null)
            return
        }
        val treeUri = data.data!!
        try {
            val accessFlags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            if (!MobilePlatformPolicy.isPersistableWritableTreeGrant(
                    accessFlags or (data.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION),
                )) {
                throw SecurityException("The selected folder did not grant persistent write access")
            }
            contentResolver.takePersistableUriPermission(treeUri, accessFlags)
        } catch (error: Exception) {
            pendingStorageResult = null
            result.error("OUTPUT_FOLDER_INVALID", error.message ?: "Choose a writable folder", null)
            return
        }
        storageExecutor.execute {
            var probe: android.net.Uri? = null
            try {
                val documentId = DocumentsContract.getTreeDocumentId(treeUri)
                val parent = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
                probe = DocumentsContract.createDocument(
                    contentResolver, parent, "application/octet-stream",
                    ".pocketgigascan-write-check-${UUID.randomUUID()}",
                ) ?: throw java.io.IOException("The selected folder is not writable")
                contentResolver.openOutputStream(probe, "w")?.use { it.flush() }
                    ?: throw java.io.IOException("The selected folder refused write access")
                if (!DocumentsContract.deleteDocument(contentResolver, probe)) {
                    throw java.io.IOException("Could not validate write access to the selected folder")
                }
                probe = null
                val name = queryDisplayName(treeUri) ?: "Selected folder"
                runOnUiThread {
                    pendingStorageResult = null
                    result.success(mapOf("uri" to treeUri.toString(), "displayName" to name))
                }
            } catch (error: Exception) {
                probe?.let { uri -> try { DocumentsContract.deleteDocument(contentResolver, uri) } catch (_: Exception) { } }
                runOnUiThread {
                    pendingStorageResult = null
                    result.error("OUTPUT_FOLDER_INVALID", error.message ?: "Choose a writable folder", null)
                }
            }
        }
    }

    private fun handleTreeResult(resultCode: Int, data: Intent?) {
        val result = pendingStorageResult ?: return
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            pendingStorageResult = null
            result.success(null)
            return
        }
        val treeUri = data.data!!
        try {
            val granted = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            if ((granted and Intent.FLAG_GRANT_READ_URI_PERMISSION) == 0) {
                throw SecurityException("The selected folder was not granted read access")
            }
            contentResolver.takePersistableUriPermission(treeUri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (error: Exception) {
            pendingStorageResult = null
            result.error("TREE_PERMISSION_FAILED", error.message ?: "Could not retain folder access", null)
            return
        }
        storageExecutor.execute {
            try {
                val staged = SafBatchStager(this).stage(treeUri)
                runOnUiThread {
                    pendingStorageResult = null
                    result.success(staged.absolutePath)
                }
            } catch (error: Exception) {
                runOnUiThread {
                    pendingStorageResult = null
                    result.error("BATCH_STAGE_FAILED", error.message ?: "Could not copy selected JPEG folders", null)
                }
            }
        }
    }

    private fun handleSaveResult(resultCode: Int, data: Intent?) {
        val save = pendingSave ?: return
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            pendingSave = null
            pendingStorageResult = null
            save.result.success(false)
            return
        }
        val destination = data.data!!
        storageExecutor.execute {
            try {
                contentResolver.openOutputStream(destination, "w")?.use { output ->
                    save.source.inputStream().buffered().use { input -> input.copyTo(output, COPY_BUFFER_SIZE) }
                } ?: throw java.io.IOException("The selected destination could not be opened")
                runOnUiThread {
                    pendingSave = null
                    pendingStorageResult = null
                    save.result.success(true)
                }
            } catch (error: Exception) {
                runOnUiThread {
                    pendingSave = null
                    pendingStorageResult = null
                    save.result.error("SAVE_FAILED", error.message ?: "Could not copy export to selected destination", null)
                }
            }
        }
    }

    override fun onDestroy() {
        if (timeoutReceiverRegistered) unregisterReceiver(timeoutReceiver)
        storageExecutor.shutdown()
        super.onDestroy()
    }

    private data class PendingSave(val source: File, val result: MethodChannel.Result)

    companion object {
        private const val REQUEST_PICK_TREE = 4101
        private const val REQUEST_PICK_OUTPUT_TREE = 4103
        private const val REQUEST_SAVE_EXPORT = 4102
        private const val COPY_BUFFER_SIZE = 64 * 1024
        private const val SERVICE_READY_TIMEOUT_MS = 5_000L
        private val PROCESS_INSTANCE_ID = UUID.randomUUID().toString()
    }
}
