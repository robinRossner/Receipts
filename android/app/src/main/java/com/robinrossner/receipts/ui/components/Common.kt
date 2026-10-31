package com.robinrossner.receipts.ui.components

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import com.robinrossner.receipts.ui.theme.AppTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale

/** `€12.34`, `—` for none (the Mac app's fmtMoney). */
fun fmtMoney(v: Double?): String = if (v == null) "—" else String.format(Locale.US, "€%.2f", v)

/** `2`, `0.5`, `1.25`: no trailing zeros. */
fun trimmedNumber(v: Double): String {
    val rounded = Math.round(v * 1000) / 1000.0
    if (rounded == Math.rint(rounded) && Math.abs(rounded) < 1e9) return rounded.toLong().toString()
    return String.format(Locale.US, "%.3f", rounded).trimEnd('0').trimEnd('.')
}

/** Parses "2,5" and "2.5". */
fun parseDecimal(text: String): Double? = text.trim().replace(',', '.').toDoubleOrNull()

/** A sheet of paper on the desk: paper fill, hairline border, small corners. */
@Composable
fun Paper(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Surface(
        modifier = modifier,
        color = AppTheme.colors.paper,
        shape = RoundedCornerShape(4.dp),
        border = BorderStroke(1.dp, AppTheme.colors.rule),
        content = content,
    )
}

@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(text.uppercase(), modifier = modifier, style = AppTheme.body(11, androidx.compose.ui.text.font.FontWeight.Medium, AppTheme.colors.inkSoft))
}

@Composable
fun InkButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    Button(
        onClick = onClick, modifier = modifier, enabled = enabled, shape = RoundedCornerShape(4.dp),
        colors = ButtonDefaults.buttonColors(containerColor = AppTheme.colors.ink, contentColor = AppTheme.colors.onInk),
    ) { Text(text, style = AppTheme.body(14, androidx.compose.ui.text.font.FontWeight.Medium)) }
}

@Composable
fun QuietButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, danger: Boolean = false, onClick: () -> Unit) {
    val color = if (danger) AppTheme.colors.penRed else AppTheme.colors.ink
    OutlinedButton(
        onClick = onClick, modifier = modifier, enabled = enabled, shape = RoundedCornerShape(4.dp),
        border = BorderStroke(1.dp, if (danger) AppTheme.colors.penRed else AppTheme.colors.rule),
        colors = ButtonDefaults.outlinedButtonColors(contentColor = color),
    ) { Text(text, style = AppTheme.body(13, androidx.compose.ui.text.font.FontWeight.Medium)) }
}

/** The red box for warnings, failed states and banners. */
@Composable
fun PenBox(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Column(
        modifier = modifier.fillMaxWidth().clip(RoundedCornerShape(4.dp)).background(AppTheme.colors.penRedBg)
            .border(1.dp, AppTheme.colors.penRed, RoundedCornerShape(4.dp)).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) { content() }
}

@Composable
fun LabelValueRow(label: String, modifier: Modifier = Modifier, value: @Composable () -> Unit) {
    Row(modifier.fillMaxWidth().padding(vertical = 4.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = AppTheme.body(14, color = AppTheme.colors.inkSoft))
        value()
    }
}

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

@Composable
fun Thumbnail(file: File?, modifier: Modifier = Modifier) {
    val bitmap = rememberBitmap(file, 256)
    if (bitmap != null) {
        Image(bitmap.asImageBitmap(), contentDescription = null, modifier = modifier.clip(RoundedCornerShape(2.dp)), contentScale = ContentScale.Crop)
    } else {
        Surface(modifier = modifier.clip(RoundedCornerShape(2.dp)), color = AppTheme.colors.rule) {}
    }
}
