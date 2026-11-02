package com.robinrossner.receipts.ui.components

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import com.robinrossner.receipts.ui.theme.AppTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/** Decodes a photo file off the main thread, down-sampled so a big photo does not sit in memory at full size. */
@Composable
fun rememberBitmap(file: File?, maxPixel: Int = 4096): Bitmap? {
    val state by produceState<Bitmap?>(initialValue = null, file?.path, file?.lastModified()) {
        value = if (file == null || !file.isFile) null else withContext(Dispatchers.IO) { decodeSampled(file, maxPixel) }
    }
    return state
}

fun decodeSampled(file: File, maxPixel: Int): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.path, bounds)
    if (bounds.outWidth <= 0) return null
    var sample = 1
    while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxPixel) sample *= 2
    return BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })
}

/** A photo thumbnail with the small 3dp corners of the upload panel; a flat `rule` square while there is none. */
@Composable
fun Thumbnail(file: File?, modifier: Modifier = Modifier) {
    val bitmap = rememberBitmap(file, 256)
    val shape = RoundedCornerShape(3.dp)
    if (bitmap != null) {
        Image(bitmap.asImageBitmap(), contentDescription = null, modifier = modifier.clip(shape), contentScale = ContentScale.Crop)
    } else {
        Box(modifier.clip(shape).background(AppTheme.colors.rule))
    }
}
