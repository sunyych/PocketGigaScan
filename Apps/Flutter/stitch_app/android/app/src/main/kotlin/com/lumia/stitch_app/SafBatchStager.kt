package com.lumia.stitch_app

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

/** Copies direct JPEGs from each direct child folder into app-private storage. */
internal class SafBatchStager(private val context: Context) {
    fun stage(treeUri: Uri): File {
        val rootId = DocumentsContract.getTreeDocumentId(treeUri)
        val rootUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, rootId)
        val children = listChildren(treeUri, rootUri)
        val stageRoot = File(context.filesDir, "staged-batches/${UUID.randomUUID()}")
        if (!stageRoot.mkdirs()) throw java.io.IOException("Could not create private staging directory")
        try {
            val usedNames = mutableSetOf<String>()
            for (child in children.filter { it.mimeType == Document.MIME_TYPE_DIR }) {
                val folderName = MobilePlatformPolicy.safeDocumentName(child.name)
                if (folderName.isBlank() || folderName == "." || folderName == "..") continue
                var uniqueFolder = folderName
                var suffix = 2
                while (!usedNames.add(uniqueFolder.lowercase())) {
                    uniqueFolder = "$folderName ($suffix)"
                    suffix++
                }
                val folder = File(stageRoot, uniqueFolder)
                if (!folder.mkdirs()) throw java.io.IOException("Could not stage folder $folderName")
                val folderUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, child.documentId)
                val files = listChildren(treeUri, folderUri)
                    .filter { MobilePlatformPolicy.isDirectJpegFile(it.name, it.mimeType) }
                    .sortedBy { it.name.lowercase() }
                val usedFiles = mutableSetOf<String>()
                for (source in files) {
                    var name = MobilePlatformPolicy.safeDocumentName(source.name)
                    if (name.isBlank()) continue
                    val base = File(name).nameWithoutExtension
                    val extension = File(name).extension.let { if (it.isBlank()) "jpg" else it }
                    var unique = name
                    var fileSuffix = 2
                    while (!usedFiles.add(unique.lowercase())) {
                        unique = "$base ($fileSuffix).$extension"
                        fileSuffix++
                    }
                    val destination = File(folder, unique)
                    val sourceUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, source.documentId)
                    val input = context.contentResolver.openInputStream(sourceUri)
                        ?: throw java.io.IOException("Could not read ${source.name}")
                    input.buffered().use { stream ->
                        FileOutputStream(destination).buffered().use { output ->
                            stream.copyTo(output, COPY_BUFFER_SIZE)
                        }
                    }
                }
            }
            return stageRoot
        } catch (error: Exception) {
            stageRoot.deleteRecursively()
            throw error
        }
    }

    private fun listChildren(treeUri: Uri, parent: Uri): List<Child> {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            DocumentsContract.getDocumentId(parent),
        )
        val rows = mutableListOf<Child>()
        context.contentResolver.query(
            childrenUri,
            arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE),
            null,
            null,
            null,
        )?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(Document.COLUMN_DOCUMENT_ID)
            val nameColumn = cursor.getColumnIndexOrThrow(Document.COLUMN_DISPLAY_NAME)
            val mimeColumn = cursor.getColumnIndexOrThrow(Document.COLUMN_MIME_TYPE)
            while (cursor.moveToNext()) {
                rows += Child(
                    documentId = cursor.getString(idColumn),
                    name = cursor.getString(nameColumn) ?: "",
                    mimeType = cursor.getString(mimeColumn) ?: "",
                )
            }
        } ?: throw java.io.IOException("Selected folder cannot be read")
        return rows
    }

    private data class Child(val documentId: String, val name: String, val mimeType: String)

    companion object { private const val COPY_BUFFER_SIZE = 64 * 1024 }
}
