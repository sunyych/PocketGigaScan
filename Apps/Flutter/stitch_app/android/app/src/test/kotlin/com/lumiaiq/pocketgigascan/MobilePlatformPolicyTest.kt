package com.lumiaiq.pocketgigascan

import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MobilePlatformPolicyTest {
    @Test
    fun activeJobRegistrationSupportsBatchAndIndividualRemoval() {
        val first = MobilePlatformPolicy.updateActiveJobs(emptySet(), active = true, jobId = "job-a")
        val both = MobilePlatformPolicy.updateActiveJobs(first, active = true, jobId = "job-b")
        val remaining = MobilePlatformPolicy.updateActiveJobs(both, active = false, jobId = "job-a")

        assertEquals(setOf("job-a", "job-b"), both)
        assertEquals(setOf("job-b"), remaining)
        assertEquals(emptySet<String>(), MobilePlatformPolicy.updateActiveJobs(remaining, false, null))
    }

    @Test
    fun timeoutJobsMergeAndAcknowledgementPreservesUnprocessedAndNewJobs() {
        val first = MobilePlatformPolicy.mergePendingTimeoutJobs(emptySet(), listOf("job-a", ""))
        val merged = MobilePlatformPolicy.mergePendingTimeoutJobs(first, listOf("job-b", "job-a"))
        val acknowledged = MobilePlatformPolicy.acknowledgePendingTimeoutJobs(merged, listOf("job-a"))
        val later = MobilePlatformPolicy.mergePendingTimeoutJobs(acknowledged, listOf("job-c"))
        val final = MobilePlatformPolicy.acknowledgePendingTimeoutJobs(later, listOf("job-b", "job-c"))

        assertEquals(setOf("job-a", "job-b"), merged)
        assertEquals(setOf("job-b"), acknowledged)
        assertEquals(setOf("job-b", "job-c"), later)
        assertEquals(emptySet<String>(), final)
    }

    @Test
    fun exportMimeAllowListIsExplicit() {
        assertTrue(MobilePlatformPolicy.isSupportedExportMimeType("image/png"))
        assertTrue(MobilePlatformPolicy.isSupportedExportMimeType("image/tiff"))
        assertTrue(MobilePlatformPolicy.isSupportedExportMimeType("image/jxl"))
        assertFalse(MobilePlatformPolicy.isSupportedExportMimeType("image/jpeg"))
        assertFalse(MobilePlatformPolicy.isSupportedExportMimeType(null))
    }

    @Test
    fun outputFolderRequiresPersistableWriteGrantAndTreeUri() {
        // A provider may grant persistent write access without read access.
        assertTrue(MobilePlatformPolicy.isPersistableWritableTreeGrant(0x42))
        assertFalse(MobilePlatformPolicy.isPersistableWritableTreeGrant(0x40))
        assertFalse(MobilePlatformPolicy.isPersistableWritableTreeGrant(0x02))
        assertTrue(MobilePlatformPolicy.isSafTreeUri("content://provider/tree/primary%3APictures"))
        assertFalse(MobilePlatformPolicy.isSafTreeUri("file:///storage/emulated/0/Pictures"))
        assertFalse(MobilePlatformPolicy.isSafTreeUri("content://provider/document/123"))
    }

    @Test
    fun documentNamesCannotEscapeTheSelectedTree() {
        assertEquals(".._result-panorama.png", MobilePlatformPolicy.safeDocumentName("../result-panorama.png"))
        assertEquals("folder_result.png", MobilePlatformPolicy.safeDocumentName("folder\\result.png"))
    }

    @Test
    fun stagingSelectsOnlyDirectJpegFilesAndSanitizesNames() {
        assertTrue(MobilePlatformPolicy.isDirectJpegFile("01_02.JPG", "image/jpeg"))
        assertTrue(MobilePlatformPolicy.isDirectJpegFile("photo.jpeg", "application/octet-stream"))
        assertFalse(MobilePlatformPolicy.isDirectJpegFile("child.jpg", "vnd.android.document/directory"))
        assertFalse(MobilePlatformPolicy.isDirectJpegFile("nested.png", "image/png"))
        assertEquals("a__b.jpg", MobilePlatformPolicy.safeDocumentName("a/\\b.jpg"))
    }

    @Test
    fun fileProviderPolicyRejectsFilesOutsideCanonicalAppFilesDirectory() {
        val root = Files.createTempDirectory("mobile-storage-policy").toFile()
        try {
            val owned = root.resolve("task/export.png").apply {
                parentFile.mkdirs()
                writeText("result")
            }
            val sibling = root.parentFile.resolve("${root.name}-sibling/outside.png").apply {
                parentFile.mkdirs()
                writeText("outside")
            }

            assertTrue(MobilePlatformPolicy.isAppOwnedFile(owned, root))
            assertFalse(MobilePlatformPolicy.isAppOwnedFile(sibling, root))
        } finally {
            root.deleteRecursively()
            root.parentFile.resolve("${root.name}-sibling").deleteRecursively()
        }
    }
}
