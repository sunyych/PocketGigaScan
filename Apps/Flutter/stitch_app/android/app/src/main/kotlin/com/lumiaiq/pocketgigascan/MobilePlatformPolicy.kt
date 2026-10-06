package com.lumiaiq.pocketgigascan

import java.io.File

/** Pure policies used by the Android bridges and their local JVM tests. */
internal object MobilePlatformPolicy {
    const val ANONYMOUS_JOB_ID = "__anonymous_render__"
    private const val WRITE_PERMISSION_FLAG = 0x00000002
    private const val PERSISTABLE_PERMISSION_FLAG = 0x00000040
    private val supportedExportMimeTypes = setOf("image/png", "image/tiff", "image/jxl")

    fun updateActiveJobs(existing: Set<String>, active: Boolean, jobId: String?): Set<String> =
        existing.toMutableSet().apply {
            if (active) add(jobId ?: ANONYMOUS_JOB_ID)
            else if (jobId == null) clear() else remove(jobId)
        }

    fun mergePendingTimeoutJobs(existing: Set<String>, timedOut: Collection<String>): Set<String> =
        existing + timedOut.filter { it.isNotBlank() }

    fun acknowledgePendingTimeoutJobs(existing: Set<String>, acknowledged: Collection<String>): Set<String> =
        existing - acknowledged.toSet()

    fun isSupportedExportMimeType(mimeType: String?): Boolean =
        mimeType != null && mimeType in supportedExportMimeTypes

    fun isPersistableWritableTreeGrant(flags: Int): Boolean =
        (flags and WRITE_PERMISSION_FLAG) != 0 &&
            (flags and PERSISTABLE_PERMISSION_FLAG) != 0

    fun isSafTreeUri(value: String?): Boolean =
        value != null && value.startsWith("content://") && value.contains("/tree/")

    fun isAppOwnedFile(file: File, appFilesDirectory: File): Boolean {
        if (!file.isFile) return false
        val base = appFilesDirectory.canonicalFile.path + File.separator
        return file.canonicalFile.path.startsWith(base)
    }

    fun safeDocumentName(name: String): String =
        name.replace(Regex("[\\\\/:*?\"<>|]"), "_").trim()

    fun isDirectJpegFile(name: String, mimeType: String): Boolean {
        if (mimeType == "vnd.android.document/directory") return false
        val extension = name.substringAfterLast('.', "").lowercase()
        return extension == "jpg" || extension == "jpeg"
    }
}
