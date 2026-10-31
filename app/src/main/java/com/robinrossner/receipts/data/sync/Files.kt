package com.robinrossner.receipts.data.sync

import java.io.File
import java.io.FileOutputStream

/** Where the app keeps files. Stored paths are relative to [root] (the app's files dir). */
class AppPaths(val root: File) {
    /** Prepared JPEGs that wait for (or just completed) their upload. Uploads must retry with the SAME bytes. */
    val outboxDir: File get() = File(root, OUTBOX).apply { mkdirs() }

    /** The phone's bounded cache of photos (see [PhotoCache]). */
    val photoCacheDir: File get() = File(root, CACHE).apply { mkdirs() }

    fun resolve(stored: String?): File? {
        if (stored.isNullOrEmpty()) return null
        return if (stored.startsWith("/")) File(stored) else File(root, stored)
    }

    fun stored(file: File): String {
        val prefix = root.path.trimEnd('/') + "/"
        return if (file.path.startsWith(prefix)) file.path.removePrefix(prefix) else file.path
    }

    companion object {
        const val OUTBOX = "uploads_outbox"
        const val CACHE = "photo_cache"
    }
}

object AtomicFile {
    /** Temp file, flush to disk, rename: a crash never leaves a half-written file under the final name. */
    fun write(file: File, data: ByteArray) {
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, file.name + ".part")
        FileOutputStream(tmp).use {
            it.write(data)
            it.fd.sync()
        }
        if (!tmp.renameTo(file)) {
            file.delete()
            check(tmp.renameTo(file)) { "could not move ${tmp.name} into place" }
        }
    }
}

fun mediaTypeOf(data: ByteArray): String =
    if (data.size >= 4 && data[0] == 0x89.toByte() && data[1] == 0x50.toByte() && data[2] == 0x4E.toByte() && data[3] == 0x47.toByte()) {
        "image/png"
    } else {
        "image/jpeg"
    }

/**
 * The phone's bounded local copy of receipt photos (`photo_cache/<uuid>.jpg|png`). It is only a convenience for showing
 * photos offline: the permanent archive is the laptop. When the total exceeds [maxBytes] the oldest files (by
 * modification time) are removed first; the newest file is always kept.
 */
class PhotoCache(val dir: File, val maxBytes: Long) {
    fun fileFor(uuid: String, mediaType: String?) = File(dir, "$uuid.${extensionFor(mediaType)}")

    /** Moves an existing file (the prepared upload) into the cache. */
    fun adopt(source: File, uuid: String, mediaType: String?): File {
        dir.mkdirs()
        val dest = fileFor(uuid, mediaType)
        if (dest.exists()) dest.delete()
        if (!source.renameTo(dest)) {
            source.copyTo(dest, overwrite = true)
            source.delete()
        }
        dest.setLastModified(System.currentTimeMillis())
        trim()
        return dest
    }

    fun write(data: ByteArray, uuid: String, mediaType: String?): File {
        dir.mkdirs()
        val dest = fileFor(uuid, mediaType)
        AtomicFile.write(dest, data)
        dest.setLastModified(System.currentTimeMillis())
        trim()
        return dest
    }

    private fun entries(): List<File> = dir.listFiles { f -> f.isFile && !f.name.endsWith(".part") }?.toList().orEmpty()

    val totalBytes: Long get() = entries().sumOf { it.length() }
    val count: Int get() = entries().size

    /** Removes the oldest files until the cache fits; returns the names (uuids) removed. */
    fun trim(): List<String> {
        val all = entries().sortedBy { it.lastModified() }.toMutableList()
        var total = all.sumOf { it.length() }
        val removed = mutableListOf<String>()
        while (total > maxBytes && all.size > 1) {
            val oldest = all.removeAt(0)
            val size = oldest.length()
            if (oldest.delete()) {
                total -= size
                removed += oldest.nameWithoutExtension
            }
        }
        return removed
    }

    /** Deletes every cached photo ("Clear cached photos"). */
    fun removeAll() {
        entries().forEach { it.delete() }
    }

    companion object {
        fun extensionFor(mediaType: String?) = if (mediaType?.contains("png", ignoreCase = true) == true) "png" else "jpg"
    }
}
