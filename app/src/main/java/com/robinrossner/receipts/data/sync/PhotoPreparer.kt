package com.robinrossner.receipts.data.sync

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import androidx.exifinterface.media.ExifInterface
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.max
import kotlin.math.roundToInt

/** How to turn the pixels as stored into the picture as taken, for an EXIF orientation value (1..8). */
data class ExifTransform(val rotateDegrees: Int, val flipHorizontal: Boolean) {
    val swapsDimensions get() = rotateDegrees % 180 != 0

    companion object {
        /** Rotate first, then mirror horizontally (the order used by Glide/AOSP for the eight EXIF cases). */
        fun of(orientation: Int): ExifTransform = when (orientation) {
            2 -> ExifTransform(0, true)
            3 -> ExifTransform(180, false)
            4 -> ExifTransform(180, true)
            5 -> ExifTransform(90, true)
            6 -> ExifTransform(90, false)
            7 -> ExifTransform(-90, true)
            8 -> ExifTransform(-90, false)
            else -> ExifTransform(0, false)
        }
    }
}

/**
 * Turns a picked or scanned photo into what the server takes: upright (EXIF orientation applied), JPEG, at most
 * [MAX_DIMENSION] px on the long edge and under [MAX_BYTES] (the Messages API rejects images over 5 MB; the server stores
 * them but the extraction then fails). Lowers the quality first, then the size.
 */
object PhotoPreparer {
    const val MAX_DIMENSION = 2500
    const val MAX_BYTES = 4_500_000
    val QUALITIES = intArrayOf(90, 80, 70, 60, 50, 40)
    const val SHRINK = 0.8
    const val MIN_DIMENSION = 800

    class PrepareException(message: String) : Exception(message)

    /** Something that can render the picture as JPEG with its long edge at most `maxDimension` px (null = cannot). */
    fun interface Encoder {
        fun encode(maxDimension: Int, quality: Int): ByteArray?
    }

    /** The size loop, pure so it is tested without bitmaps. */
    fun encode(encoder: Encoder, maxBytes: Int = MAX_BYTES, startDimension: Int = MAX_DIMENSION): ByteArray {
        var dimension = startDimension.toDouble()
        while (dimension >= MIN_DIMENSION) {
            for (quality in QUALITIES) {
                val data = encoder.encode(dimension.roundToInt(), quality) ?: throw PrepareException("Could not convert the photo to JPEG.")
                if (data.size <= maxBytes) return data
            }
            dimension *= SHRINK
        }
        throw PrepareException("The photo is too large even after compressing it.")
    }

    fun scaledSize(width: Int, height: Int, maxDimension: Int): Pair<Int, Int> {
        val longEdge = max(width, height)
        if (longEdge <= maxDimension) return width to height
        val scale = maxDimension.toDouble() / longEdge
        return max(1, (width * scale).roundToInt()) to max(1, (height * scale).roundToInt())
    }

    /** Largest power-of-two sample size that still leaves the long edge at or above [target]. */
    fun sampleSize(width: Int, height: Int, target: Int = MAX_DIMENSION): Int {
        var sample = 1
        val longEdge = max(width, height)
        while (longEdge / (sample * 2) >= target) sample *= 2
        return sample
    }

    /** Decodes [file] (JPEG, PNG, HEIC, ...), applies its EXIF orientation and encodes the JPEG. */
    fun prepare(file: File): ByteArray {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw PrepareException("This file is not a photo the phone can read.")
        val options = BitmapFactory.Options().apply { inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight) }
        val decoded = BitmapFactory.decodeFile(file.path, options) ?: throw PrepareException("This file is not a photo the phone can read.")
        val orientation = runCatching {
            ExifInterface(file.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
        val upright = upright(decoded, ExifTransform.of(orientation))
        val flattened = flattenAlpha(upright)
        return try {
            encode(Encoder { maxDim, quality -> compress(flattened, maxDim, quality) })
        } finally {
            if (flattened !== decoded) flattened.recycle()
            if (!decoded.isRecycled) decoded.recycle()
        }
    }

    private fun upright(bitmap: Bitmap, t: ExifTransform): Bitmap {
        if (t.rotateDegrees == 0 && !t.flipHorizontal) return bitmap
        val m = Matrix()
        if (t.rotateDegrees != 0) m.postRotate(t.rotateDegrees.toFloat())
        if (t.flipHorizontal) m.postScale(-1f, 1f)
        val out = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
        if (out !== bitmap) bitmap.recycle()
        return out
    }

    /** A PNG with transparency would turn black as JPEG: paint it on white. */
    private fun flattenAlpha(bitmap: Bitmap): Bitmap {
        if (!bitmap.hasAlpha()) return bitmap
        val out = Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888)
        Canvas(out).apply { drawColor(Color.WHITE); drawBitmap(bitmap, 0f, 0f, null) }
        return out
    }

    private fun compress(source: Bitmap, maxDimension: Int, quality: Int): ByteArray? {
        val (w, h) = scaledSize(source.width, source.height, maxDimension)
        val scaled = if (w == source.width && h == source.height) source else Bitmap.createScaledBitmap(source, w, h, true)
        return try {
            ByteArrayOutputStream().also { if (!scaled.compress(Bitmap.CompressFormat.JPEG, quality, it)) return null }.toByteArray()
        } finally {
            if (scaled !== source) scaled.recycle()
        }
    }
}
