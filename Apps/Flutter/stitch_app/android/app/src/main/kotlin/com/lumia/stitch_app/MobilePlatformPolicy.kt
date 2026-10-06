package com.lumia.stitch_app

import java.io.File

/** Pure policies used by the Android bridges and their local JVM tests. */
internal object MobilePlatformPolicy {
    const val ANONYMOUS_JOB_ID = "__anonymous_render__"
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
